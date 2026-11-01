import AppKit
import WebKit
import UniformTypeIdentifiers

private let bridgeScript = """
(() => {
  let nextId = 0;
  const pending = new Map();
  window.native = Object.freeze({call(method, params = {}) {
    return new Promise((resolve, reject) => {
      const id = String(++nextId);
      pending.set(id, {resolve, reject});
      window.webkit.messageHandlers.writer.postMessage({id, method, params});
    });
  }});
  window.__nativeReceive = (message) => {
    const request = pending.get(message.id);
    if (!request) return;
    pending.delete(message.id);
    if (message.ok) request.resolve(message.result);
    else request.reject(new Error(message.error || 'The operation failed.'));
  };
})();
"""

final class WriterDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
    private var window: NSWindow!
    private var webView: WKWebView!
    private var store: RepositoryStore!
    private var codeHighlighter: CodeHighlighter!
    private var publishingValidator: PublishingValidator!
    private let deploymentClient = DeploymentClient()
    private let deploymentWorker = DispatchQueue(label: "io.github.nightingalelyy.writer.deployment")
    private var pendingBackup: (token: String, data: Data)?
    private let worker = DispatchQueue(label: "io.github.nightingalelyy.writer.storage")
    private let highlightWorker = DispatchQueue(label: "io.github.nightingalelyy.writer.highlight", qos: .userInitiated)
    private var allowClose = false
    private var closing = false
    private var webRoot: URL!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let root = support.appendingPathComponent("Nightingale Writer", isDirectory: true)
        let seed = Bundle.main.resourceURL?.appendingPathComponent("Seed.git", isDirectory: true)
        publishingValidator = PublishingValidator(resources: Bundle.main.resourceURL!)
        store = RepositoryStore(root: root, seedRepo: seed, validation: { [weak self] payload in
            guard let validator = self?.publishingValidator else { throw NSError(domain: "Writer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Publishing checks are unavailable."]) }
            return try validator.validate(payload)
        })
        codeHighlighter = CodeHighlighter(resources: Bundle.main.resourceURL!)
        let controller = WKUserContentController()
        controller.addUserScript(WKUserScript(source: bridgeScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        controller.add(self, name: "writer")
        let configuration = WKWebViewConfiguration()
        configuration.userContentController = controller
        configuration.websiteDataStore = .default()
        webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = false
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1440, height: 940), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Nightingale Writer"
        window.subtitle = "nightingalelyy.github.io"
        window.minSize = NSSize(width: 1000, height: 680)
        window.contentView = webView
        window.delegate = self
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("WriterMainWindow")
        window.center()
        buildMenu()
        webRoot = Bundle.main.resourceURL!.appendingPathComponent("web", isDirectory: true)
        webView.loadFileURL(webRoot.appendingPathComponent("index.html"), allowingReadAccessTo: webRoot)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func buildMenu() {
        let bar = NSMenu()
        let app = NSMenu()
        app.addItem(withTitle: "About Nightingale Writer", action: #selector(showAbout), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Hide Nightingale Writer", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(.separator())
        app.addItem(withTitle: "Quit Nightingale Writer", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appItem = NSMenuItem(); appItem.submenu = app; bar.addItem(appItem)
        let file = NSMenu(title: "File")
        file.addItem(withTitle: "New Article", action: #selector(newArticle), keyEquivalent: "n")
        file.addItem(withTitle: "Save Locally", action: #selector(saveArticle), keyEquivalent: "s")
        file.addItem(withTitle: "Refresh from GitHub", action: #selector(refreshArticles), keyEquivalent: "r")
        let publish = file.addItem(withTitle: "Publish Article", action: #selector(publishArticle), keyEquivalent: "p")
        publish.keyEquivalentModifierMask = [.command, .shift]
        let fileItem = NSMenuItem(); fileItem.submenu = file; bar.addItem(fileItem)
        let edit = NSMenu(title: "Edit")
        for (name, action, key) in [("Undo", "undo:", "z"), ("Redo", "redo:", "Z"), ("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            edit.addItem(withTitle: name, action: Selector(action), keyEquivalent: key)
        }
        let pasteImage = edit.addItem(withTitle: "Paste Image", action: #selector(pasteClipboardImage), keyEquivalent: "v")
        pasteImage.keyEquivalentModifierMask = [.command, .shift]
        let editItem = NSMenuItem(); editItem.submenu = edit; bar.addItem(editItem)
        let help = NSMenu(title: "Help")
        help.addItem(withTitle: "Open Pages CMS", action: #selector(openCMS), keyEquivalent: "")
        help.addItem(withTitle: "Open Website", action: #selector(openSite), keyEquivalent: "")
        help.addItem(withTitle: "Show Local Data", action: #selector(showData), keyEquivalent: "")
        let helpItem = NSMenuItem(); helpItem.submenu = help; bar.addItem(helpItem)
        NSApp.mainMenu = bar
    }

    @objc private func showAbout() { NSApp.orderFrontStandardAboutPanel(options: [.applicationName: "Nightingale Writer", .applicationVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "", .credits: NSAttributedString(string: "Write offline. Publish when you're ready.")]) }
    @objc private func newArticle() { webView.evaluateJavaScript("window.writer?.newArticle?.()") }
    @objc private func saveArticle() { webView.evaluateJavaScript("window.writer?.saveCurrent?.()") }
    @objc private func refreshArticles() { webView.evaluateJavaScript("window.writer?.refresh?.()") }
    @objc private func publishArticle() { webView.evaluateJavaScript("window.writer?.publishCurrent?.()") }
    @objc private func pasteClipboardImage() { webView.evaluateJavaScript("window.writer?.pasteImage?.()") }
    @objc private func openCMS() { NSWorkspace.shared.open(URL(string: "https://app.pagescms.org/Nightingalelyy/nightingalelyy.github.io/main")!) }
    @objc private func openSite() { NSWorkspace.shared.open(URL(string: "https://nightingalelyy.github.io")!) }
    @objc private func showData() {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Nightingale Writer")
        NSWorkspace.shared.open(root)
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame, message.frameInfo.request.url?.isFileURL == true,
              let body = message.body as? [String: Any], let id = body["id"] as? String,
              let method = body["method"] as? String else { return }
        let params = body["params"] as? [String: Any] ?? [:]
        if method == "chooseImage" { chooseImage(id: id, optimize: params["optimize"] as? Bool ?? true); return }
        if method == "pasteImage" {
            let pasteboard = NSPasteboard.general
            let formats: [(NSPasteboard.PasteboardType, String)] = [(.png, "png"), (.init(UTType.jpeg.identifier), "jpg"), (.init(UTType.gif.identifier), "gif"), (.init(UTType.webP.identifier), "webp"), (.tiff, "tiff")]
            for (type, ext) in formats {
                if let data = pasteboard.data(forType: type) {
                    storeImage(id: id, data: data, filename: "pasted-image.\(ext)", optimize: params["optimize"] as? Bool ?? true)
                    return
                }
            }
            respond(id, error: "Copy an image or screenshot first, then choose Paste image.")
            return
        }
        if method == "importImage" {
            guard let encoded = params["base64"] as? String, encoded.utf8.count <= 28 * 1024 * 1024,
                  let data = Data(base64Encoded: encoded), let filename = params["filename"] as? String else {
                respond(id, error: "The pasted image is invalid or larger than 20 MB."); return
            }
            storeImage(id: id, data: data, filename: filename, optimize: params["optimize"] as? Bool ?? true)
            return
        }
        if method == "openCMS" { openCMS(); respond(id, result: [:]); return }
        if method == "openSite" { openSite(); respond(id, result: [:]); return }
        if method == "exportBackup" { exportBackup(id: id); return }
        if method == "chooseBackup" { chooseBackup(id: id); return }
        if method == "cancelBackupImport" { pendingBackup = nil; respond(id, result: [:]); return }
        if method == "restoreBackup" {
            guard let token = params["token"] as? String, let pending = pendingBackup, pending.token == token else { respond(id, error: "Choose the backup again before restoring it."); return }
            pendingBackup = nil
            worker.async { [weak self] in
                guard let self = self else { return }
                do {
                    let result = try self.store.restoreBackup(pending.data)
                    DispatchQueue.main.async { self.respond(id, result: result) }
                } catch { DispatchQueue.main.async { self.respond(id, error: error.localizedDescription) } }
            }
            return
        }
        if method == "pollPublicationStatus" { pollPublicationStatus(id: id); return }
        if method == "openExternal" {
            guard let raw = params["url"] as? String, let url = URL(string: raw), url.scheme == "https", url.user == nil, url.password == nil,
                  url.host == "nightingalelyy.github.io" || (url.host == "github.com" && url.path.lowercased().hasPrefix("/nightingalelyy/nightingalelyy.github.io/actions/")) else { respond(id, error: "This is not a website or build link."); return }
            NSWorkspace.shared.open(url); respond(id, result: [:]); return
        }
        if method == "highlightCode" {
            highlightWorker.async { [weak self] in
                guard let self = self else { return }
                do {
                    let result = try self.codeHighlighter.highlight(params)
                    DispatchQueue.main.async { self.respond(id, result: result) }
                } catch {
                    DispatchQueue.main.async { self.respond(id, error: error.localizedDescription) }
                }
            }
            return
        }
        let allowed: Set<String> = ["bootstrap", "status", "listArticles", "readArticle", "saveDraft", "createArticle", "createCategory", "renameCategory", "mergeCategory", "listTemplates", "saveTemplate", "removeTemplate", "refresh", "queuePublish", "processQueue", "resolveConflict", "readAsset", "cancelQueued", "discardDraft", "validatePublication", "listHistory", "readHistory", "restoreHistory", "removeLocally", "restoreLocalRemoval", "prepareDeletion", "deleteArticle"]
        guard allowed.contains(method) else { respond(id, error: "Unknown operation."); return }
        worker.async { [weak self] in
            guard let self = self else { return }
            do {
                let result = try self.store.handle(method: method, params: params)
                DispatchQueue.main.async { self.respond(id, result: result) }
            } catch {
                let text = error.localizedDescription
                DispatchQueue.main.async { self.respond(id, error: text) }
            }
        }
    }

    private func pollPublicationStatus(id: String) {
        worker.async { [weak self] in
            guard let self = self else { return }
            do {
                let targets = try self.store.deploymentTargets()
                self.deploymentWorker.async {
                    let report = self.deploymentClient.poll(targets)
                    self.worker.async {
                        do {
                            let result = try self.store.applyDeploymentStatus(report)
                            DispatchQueue.main.async { self.respond(id, result: result) }
                        } catch { DispatchQueue.main.async { self.respond(id, error: error.localizedDescription) } }
                    }
                }
            } catch { DispatchQueue.main.async { self.respond(id, error: error.localizedDescription) } }
        }
    }

    private func exportBackup(id: String) {
        let panel = NSSavePanel()
        panel.title = "Export Nightingale Writer Backup"
        panel.message = "Includes unpublished drafts, images, and history. Keep this file in a private location."
        let dateFormatter = DateFormatter(); dateFormatter.locale = Locale(identifier: "en_US_POSIX"); dateFormatter.dateFormat = "yyyy-MM-dd"
        panel.nameFieldStringValue = "Nightingale Writer Backup \(dateFormatter.string(from: Date())).json"
        panel.allowedContentTypes = [.json]
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self = self else { return }
            guard response == .OK, let url = panel.url else { self.respond(id, result: ["cancelled": true]); return }
            self.worker.async {
                do {
                    let data = try self.store.exportBackup()
                    try data.write(to: url, options: .atomic)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
                    DispatchQueue.main.async { self.respond(id, result: ["fileName": url.lastPathComponent]) }
                } catch { DispatchQueue.main.async { self.respond(id, error: error.localizedDescription) } }
            }
        }
    }

    private func chooseBackup(id: String) {
        pendingBackup = nil
        let panel = NSOpenPanel()
        panel.title = "Choose a Nightingale Writer Backup"
        panel.allowedContentTypes = [.json]
        let backups = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Nightingale Writer/backups", isDirectory: true)
        if FileManager.default.fileExists(atPath: backups.path) { panel.directoryURL = backups }
        panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self = self else { return }
            guard response == .OK, let url = panel.url else { self.respond(id, result: ["cancelled": true]); return }
            self.worker.async {
                do {
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size <= 256 * 1024 * 1024 else { throw NSError(domain: "Writer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Choose a backup smaller than 256 MB."]) }
                    let data = try Data(contentsOf: url)
                    var summary = try self.store.inspectBackup(data)
                    summary["fileName"] = url.lastPathComponent
                    let token = UUID().uuidString
                    DispatchQueue.main.async {
                        self.pendingBackup = (token, data)
                        self.respond(id, result: ["token": token, "summary": summary])
                    }
                } catch { DispatchQueue.main.async { self.respond(id, error: error.localizedDescription) } }
            }
        }
    }

    private func storeImage(id: String, data: Data, filename: String, optimize: Bool) {
        worker.async { [weak self] in
            guard let self = self else { return }
            do {
                let image = try MediaProcessor.prepare(data, filename: filename, optimize: optimize)
                var result = try self.store.handle(method: "importImage", params: ["filename": image.filename, "base64": image.data.base64EncodedString()])
                result["imageInfo"] = ["width": image.width, "height": image.height, "originalBytes": image.originalBytes, "bytes": image.data.count, "note": image.note]
                DispatchQueue.main.async { self.respond(id, result: result) }
            } catch { DispatchQueue.main.async { self.respond(id, error: error.localizedDescription) } }
        }
    }

    private func chooseImage(id: String, optimize: Bool) {
        let panel = NSOpenPanel()
        panel.title = "Insert an image"
        panel.allowedContentTypes = [.png, .jpeg, .gif, .webP, .tiff]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard let self = self else { return }
            guard response == .OK, let url = panel.url else { self.respond(id, result: ["cancelled": true]); return }
            self.worker.async {
                do {
                    let values = try url.resourceValues(forKeys: [.fileSizeKey])
                    guard (values.fileSize ?? 0) <= 20 * 1024 * 1024 else { throw NSError(domain: "Writer", code: 1, userInfo: [NSLocalizedDescriptionKey: "Choose an image smaller than 20 MB."]) }
                    let data = try Data(contentsOf: url)
                    self.storeImage(id: id, data: data, filename: url.lastPathComponent, optimize: optimize)
                } catch {
                    DispatchQueue.main.async { self.respond(id, error: error.localizedDescription) }
                }
            }
        }
    }

    private func respond(_ id: String, result: [String: Any] = [:], error: String? = nil) {
        let payload: [String: Any] = error.map { ["id": id, "ok": false, "error": $0] } ?? ["id": id, "ok": true, "result": result]
        guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]), let json = String(data: data, encoding: .utf8) else { return }
        webView.evaluateJavaScript("window.__nativeReceive(\(json));", completionHandler: nil)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        // A script-free srcdoc preview inherits the bundled editor's origin.
        if url.absoluteString.split(separator: "#", maxSplits: 1).first == "about:srcdoc", navigationAction.targetFrame?.isMainFrame == false { decisionHandler(.allow); return }
        if url.isFileURL, url.standardizedFileURL.path.hasPrefix(webRoot.path + "/") { decisionHandler(.allow); return }
        if navigationAction.navigationType == .linkActivated, ["https", "http"].contains(url.scheme ?? "") { NSWorkspace.shared.open(url) }
        decisionHandler(.cancel)
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url, ["https", "http"].contains(url.scheme ?? "") { NSWorkspace.shared.open(url) }
        return nil
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (Bool) -> Void) {
        let alert = NSAlert(); alert.messageText = message; alert.addButton(withTitle: "Continue"); alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { completionHandler($0 == .alertFirstButtonReturn) }
    }

    private func flushBeforeClose(_ completion: @escaping (Bool) -> Void) {
        guard !closing else { completion(false); return }
        closing = true
        webView.callAsyncJavaScript("return window.writer ? await window.writer.flushBeforeClose() : true;", arguments: [:], in: nil, in: .page) { [weak self] result in
            guard let self = self else { completion(false); return }
            self.closing = false
            switch result {
            case .success(let value):
                let saved = (value as? Bool) == true
                self.allowClose = saved
                completion(saved)
            case .failure(let error):
                let alert = NSAlert(); alert.messageText = "Your latest changes could not be saved."; alert.informativeText = error.localizedDescription; alert.addButton(withTitle: "Keep Writing")
                alert.beginSheetModal(for: self.window) { _ in completion(false) }
            }
        }
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if allowClose { return true }
        flushBeforeClose { if $0 { sender.close() } }
        return false
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if allowClose { return .terminateNow }
        flushBeforeClose { sender.reply(toApplicationShouldTerminate: $0) }
        return .terminateLater
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { window.makeKeyAndOrderFront(nil); return true }
}

@main
struct NightingaleWriter {
    static func main() {
        let app = NSApplication.shared
        let delegate = WriterDelegate()
        app.delegate = delegate
        app.run()
        withExtendedLifetime(delegate) {}
    }
}
