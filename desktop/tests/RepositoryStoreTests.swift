import Foundation

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

@main
struct RepositoryStoreTests {
    static let fm = FileManager.default
    static var assertions = 0
    static let identity = (name: "Writer Test", email: "writer-test@example.invalid")

    static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        assertions += 1
        if try !condition() { throw TestFailure(description: message) }
    }

    static func rejects(_ message: String, _ block: () throws -> Void) throws {
        do { try block() } catch { assertions += 1; return }
        throw TestFailure(description: message)
    }

    @discardableResult
    static func git(_ args: [String], at dir: URL? = nil) throws -> String {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false"] + (dir.map { ["-C", $0.path] } ?? []) + args
        var env = ProcessInfo.processInfo.environment
        env["GIT_TERMINAL_PROMPT"] = "0"; p.environment = env
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = pipe
        try p.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        let output = String(data: data, encoding: .utf8) ?? ""
        guard p.terminationStatus == 0 else { throw TestFailure(description: "git \(args) failed: \(output)") }
        return output
    }

    static func write(_ raw: String, _ path: String, at dir: URL) throws {
        let file = dir.appendingPathComponent(path)
        try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(raw.utf8).write(to: file)
    }

    static func raw(_ title: String, body: String) -> String {
        "---\ntitle: \(title)\nauthor: Yuyang Liu\ndate: 2026-10-31\ncategory: Articles\norder: 1000\ncustom: keep-this-field\n---\n\(body)\n"
    }

    static func all(_ result: [String: Any]) -> [[String: Any]] { result["articles"] as! [[String: Any]] }
    static func item(_ store: RepositoryStore, _ path: String) throws -> [String: Any] { try store.handle(method: "readArticle", params: ["path": path]) }
    static func save(_ store: RepositoryStore, _ path: String, _ content: String) throws {
        let existing = try item(store, path)
        _ = try store.handle(method: "saveDraft", params: ["path": path, "rawContent": content, "expectedRevision": existing["revision"]!])
    }
    static func queue(_ store: RepositoryStore, _ path: String) throws { _ = try store.handle(method: "queuePublish", params: ["path": path]) }
    static func process(_ store: RepositoryStore) throws -> [String: Any] { try store.handle(method: "processQueue") }
    static func status(_ result: [String: Any]) -> [String: Any] { result["status"] as! [String: Any] }

    static func main() throws {
        let root = fm.temporaryDirectory.appendingPathComponent("nightingale-store-tests-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let source = root.appendingPathComponent("source")
        let remote = root.appendingPathComponent("remote.git")
        let dataRoot = root.appendingPathComponent("app-data")
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try git(["init", "-b", "main"], at: source)
        try git(["config", "user.name", identity.name], at: source)
        try git(["config", "user.email", identity.email], at: source)
        let articlePath = "_docs/BFS/2026-10-01-example.md"
        let original = raw("Example", body: "Original paragraph.\n\n```cpp\nint a = 1;\n```\n\n10<sup>5</sup>")
        try write(original, articlePath, at: source)
        try write("---\ntitle: Homepage\n---\n", "index.md", at: source)
        try write("---\ntitle: Missing\npermalink: /404.html\nsitemap: false\n---\nNot found.\n", "404.md", at: source)
        try write("", "_docs/Graph/1.md", at: source)
        try write("---\ntitle:\n---\n", "_docs/_defaults.md", at: source)
        try write("Do not publish app source changes.\n", "unrelated.txt", at: source)
        try git(["add", "."], at: source); try git(["commit", "-m", "Initial test site"], at: source)
        try git(["clone", "--bare", source.path, remote.path])
        let store = RepositoryStore(root: dataRoot, remoteURL: remote.path, seedRepo: source, identity: identity)
        let bootstrap = try store.handle(method: "bootstrap")
        try expect(all(bootstrap).count == 3, "Must include articles and editable pages, not placeholders")
        try expect(try item(store, articlePath)["rawContent"] as? String == original, "Article must be read byte-for-byte")

        // Stale-save prevention and local persistence never modify the checkout.
        let oldRevision = try item(store, articlePath)["revision"] as! String
        let localChange = raw("Example", body: "A locally edited paragraph.")
        try save(store, articlePath, localChange)
        try rejects("Stale save should be rejected") {
            _ = try store.handle(method: "saveDraft", params: ["path": articlePath, "rawContent": original, "expectedRevision": oldRevision])
        }
        try expect(try String(contentsOf: source.appendingPathComponent(articlePath), encoding: .utf8) == original, "Source checkout must never be mutated")
        try expect(try git(["show", "main:\(articlePath)"], at: remote) == original, "Local save must not publish")
        let restarted = RepositoryStore(root: dataRoot, remoteURL: remote.path, seedRepo: source, identity: identity)
        _ = try restarted.handle(method: "bootstrap")
        try expect(try item(restarted, articlePath)["rawContent"] as? String == localChange, "Draft must survive restart")
        _ = try restarted.handle(method: "discardDraft", params: ["path": articlePath])
        try expect(try item(restarted, articlePath)["rawContent"] as? String == original, "Discard restores repository content")
        try expect(fm.fileExists(atPath: dataRoot.appendingPathComponent("history").path), "Discard must preserve a recovery copy")

        // Queued publication is an immutable snapshot, including across offline restart.
        let newPath = "_docs/2026-10-31-offline-article.md"
        let versionA = raw("Offline article", body: "Queued version A.\n\n```cpp\nint answer() { return 42; }\n```\n\n10<sup>5</sup>")
        let versionB = raw("Offline article", body: "Later local version B, not queued.")
        _ = try restarted.handle(method: "createArticle", params: ["path": newPath, "rawContent": versionA])
        try queue(restarted, newPath)
        try rejects("Queued drafts cannot be discarded") { _ = try restarted.handle(method: "discardDraft", params: ["path": newPath]) }
        let hiddenRemote = root.appendingPathComponent("offline-remote.git")
        try fm.moveItem(at: remote, to: hiddenRemote)
        let offline = try process(restarted)
        try expect(status(offline)["state"] as? String == "offline", "Missing remote must produce offline status")
        try expect(status(offline)["queuedCount"] as? Int == 1, "Queue must persist after failed connection")
        let offlineRestart = RepositoryStore(root: dataRoot, remoteURL: remote.path, seedRepo: source, identity: identity)
        _ = try offlineRestart.handle(method: "bootstrap")
        try save(offlineRestart, newPath, versionB)
        try fm.moveItem(at: hiddenRemote, to: remote)
        let publishedA = try process(offlineRestart)
        try expect(status(publishedA)["queuedCount"] as? Int == 0, "Successful publish clears queue")
        try expect(try git(["show", "main:\(newPath)"], at: remote) == versionA, "Only explicitly queued version A may publish")
        let remaining = try item(offlineRestart, newPath)
        try expect(remaining["rawContent"] as? String == versionB && remaining["isDraft"] as? Bool == true, "Later unqueued draft must remain local")
        try queue(offlineRestart, newPath); _ = try process(offlineRestart)
        try expect(try git(["show", "main:\(newPath)"], at: remote) == versionB, "Later draft can be explicitly published")
        try expect(try item(offlineRestart, newPath)["isDraft"] as? Bool == false, "Published matching draft is clean")

        // External edits cause a conflict without overwriting either version.
        let external = root.appendingPathComponent("external")
        try git(["clone", remote.path, external.path])
        try git(["config", "user.name", identity.name], at: external)
        try git(["config", "user.email", identity.email], at: external)
        let mine = raw("Example", body: "My offline edit.")
        let theirs = raw("Example", body: "An online CMS edit.")
        try save(offlineRestart, articlePath, mine); try queue(offlineRestart, articlePath)
        try write(theirs, articlePath, at: external)
        try git(["add", "--", articlePath], at: external); try git(["commit", "-m", "Online edit"], at: external); try git(["push", "origin", "main"], at: external)
        let conflicted = try process(offlineRestart)
        try expect(status(conflicted)["state"] as? String == "conflict", "Concurrent edits must stop publication")
        let conflict = try item(offlineRestart, articlePath)["conflict"] as! [String: String]
        try expect(conflict["local"] == mine && conflict["remote"] == theirs && conflict["base"] == original, "Conflict must preserve base, local, and remote")
        try expect(try git(["show", "main:\(articlePath)"], at: remote) == theirs, "Conflict must not overwrite remote")
        let resolved = raw("Example", body: "Combined offline and online edits.")
        _ = try offlineRestart.handle(method: "resolveConflict", params: ["path": articlePath, "rawContent": resolved])
        try expect(try item(offlineRestart, articlePath)["isQueued"] as? Bool == false, "Resolution must require a fresh Publish action")
        try queue(offlineRestart, articlePath); _ = try process(offlineRestart)
        try expect(try git(["show", "main:\(articlePath)"], at: remote) == resolved, "Explicit resolution should publish safely")

        // New local file colliding with a remote file must keep its nil base even after another local save.
        let collisionPath = "_docs/2026-10-31-collision.md"
        _ = try offlineRestart.handle(method: "createArticle", params: ["path": collisionPath, "rawContent": raw("Collision", body: "Local new article")])
        try git(["pull", "--ff-only"], at: external)
        try write(raw("Collision", body: "Online new article"), collisionPath, at: external)
        try git(["add", "--", collisionPath], at: external); try git(["commit", "-m", "Online creation"], at: external); try git(["push", "origin", "main"], at: external)
        _ = try offlineRestart.handle(method: "refresh")
        try save(offlineRestart, collisionPath, raw("Collision", body: "Local article edited again")); try queue(offlineRestart, collisionPath)
        _ = try process(offlineRestart)
        try expect(try item(offlineRestart, collisionPath)["conflict"] != nil, "Saving after refresh must not conceal a new-file collision")
        _ = try offlineRestart.handle(method: "cancelQueued", params: ["path": collisionPath])
        _ = try offlineRestart.handle(method: "discardDraft", params: ["path": collisionPath])

        // Raster image imports work offline; only referenced assets are published.
        let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+aA1cAAAAASUVORK5CYII="
        let imported = try offlineRestart.handle(method: "importImage", params: ["filename": "offline example.png", "base64": png])
        let unused = try offlineRestart.handle(method: "importImage", params: ["filename": "unused.png", "base64": png])
        let imagePath = imported["path"] as! String
        let asset = try offlineRestart.handle(method: "readAsset", params: ["path": imagePath])
        try expect(asset["base64"] as? String == png, "Staged image must be available offline")
        try save(offlineRestart, newPath, raw("Offline article", body: "![Example](\(imagePath))"))
        try queue(offlineRestart, newPath); _ = try process(offlineRestart)
        let remoteTree = try git(["ls-tree", "-r", "--name-only", "main"], at: remote)
        try expect(remoteTree.contains(String(imagePath.dropFirst())), "Referenced staged image must publish with article")
        try expect(!remoteTree.contains(String((unused["path"] as! String).dropFirst())), "Unreferenced staged image must stay local")
        try expect(try git(["show", "main:unrelated.txt"], at: remote) == "Do not publish app source changes.\n", "Publishing must not change unrelated files")

        // Invalid paths, assets, and unsafe file types are rejected.
        for path in ["../index.md", "_docs/../../escape.md", "/etc/passwd", "_docs//bad.md", "_docs/.hidden.md", "README.md", "_docs/_defaults.md"] {
            try rejects("Path should be rejected: \(path)") { _ = try offlineRestart.handle(method: "createArticle", params: ["path": path, "rawContent": original]) }
        }
        try rejects("Asset traversal must be rejected") { _ = try offlineRestart.handle(method: "readAsset", params: ["path": "/images/../../state.json"]) }
        try rejects("SVG imports must be rejected") { _ = try offlineRestart.handle(method: "importImage", params: ["filename": "unsafe.svg", "base64": Data("<svg/>".utf8).base64EncodedString()]) }
        try rejects("Mismatched image content must be rejected") { _ = try offlineRestart.handle(method: "importImage", params: ["filename": "fake.png", "base64": Data("not an image".utf8).base64EncodedString()]) }

        // A failed durable write must not advance the in-memory revision.
        let beforeDiskFailure = try item(offlineRestart, "404.md")
        let statePath = dataRoot.appendingPathComponent("state.json")
        let stateBackup = dataRoot.appendingPathComponent("state-backup.json")
        try fm.moveItem(at: statePath, to: stateBackup)
        try fm.createDirectory(at: statePath, withIntermediateDirectories: false)
        let failedSaveParams: [String: Any] = ["path": "404.md", "rawContent": raw("Missing", body: "A recovery test"), "expectedRevision": beforeDiskFailure["revision"]!]
        try rejects("Disk write failure must reject the save") { _ = try offlineRestart.handle(method: "saveDraft", params: failedSaveParams) }
        try fm.removeItem(at: statePath); try fm.moveItem(at: stateBackup, to: statePath)
        _ = try offlineRestart.handle(method: "saveDraft", params: failedSaveParams)
        try expect(try item(offlineRestart, "404.md")["isDraft"] as? Bool == true, "Same save revision must be retryable after disk recovery")
        _ = try offlineRestart.handle(method: "discardDraft", params: ["path": "404.md"])
        let credentialCheck = try offlineRestart.handle(method: "verifyPublishAccess")
        try expect(status(credentialCheck)["message"] as? String == "GitHub publishing credentials verified. No changes were published.", "Dry-run publish access should succeed without content changes")

        print("RepositoryStore integration tests passed: \(assertions) assertions")
        print("Covered offline restart, safe saves, immutable queued versions, publish, conflicts, explicit resolution, new-file collision, raster assets, scoped writes, and path validation.")
    }
}
