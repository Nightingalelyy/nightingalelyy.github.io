import Foundation
import CryptoKit
import Darwin

struct RepositoryStoreError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private struct WriterDraft: Codable {
    var rawContent: String
    var baseBlob: String?
    var baseContent: String?
    var updatedAt: String
}

private struct WriterQueueEntry: Codable {
    var rawContent: String
    var baseBlob: String?
    var baseContent: String?
    var queuedAt: String
}

private struct WriterConflict: Codable {
    var base: String
    var local: String
    var remote: String
    var remoteBlob: String?
}

private struct WriterState: Codable {
    var version = 1
    var drafts: [String: WriterDraft] = [:]
    var queue: [String: WriterQueueEntry] = [:]
    var conflicts: [String: WriterConflict] = [:]
    // Optional so state written before local categories were introduced still decodes.
    var categories: [String]?
    var state = "ready"
    var message = "Ready to write offline."
    var lastSyncedAt: String?
}

private struct RepositoryArticle {
    let rawContent: String
    let blob: String
}

private struct GitResult {
    let status: Int32
    let output: Data
    let error: Data
    var text: String { String(data: output, encoding: .utf8) ?? "" }
    var errorText: String { String(data: error, encoding: .utf8) ?? "" }
}

/// All methods must be called from the same serial queue. The app owns root and
/// its bare repository; the user's development checkout is never modified.
final class RepositoryStore {
    static let productionRemote = "https://github.com/Nightingalelyy/nightingalelyy.github.io.git"
    private let root: URL
    private let remoteURL: String
    private let seedRepo: URL?
    private let identity: (name: String, email: String)?
    private let fm = FileManager.default
    private var state = WriterState()
    private var durableState = WriterState()
    private var articles: [String: RepositoryArticle] = [:]
    private var cachedCommit: String?
    private var initialized = false

    init(root: URL, remoteURL: String = RepositoryStore.productionRemote,
         seedRepo: URL? = nil, identity: (name: String, email: String)? = nil) {
        self.root = root.standardizedFileURL
        self.remoteURL = remoteURL
        self.seedRepo = seedRepo
        self.identity = identity
    }

    private var repository: URL { root.appendingPathComponent("repository.git", isDirectory: true) }
    private var stateFile: URL { root.appendingPathComponent("state.json") }
    private var assetsRoot: URL { root.appendingPathComponent("assets", isDirectory: true) }
    private var remoteRef: String { "refs/remotes/origin/main" }
    private func now() -> String { ISO8601DateFormatter().string(from: Date()) }
    private func digest(_ value: String) -> String { SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() }
    private func fail(_ message: String) -> RepositoryStoreError { RepositoryStoreError(message: message) }

    func handle(method: String, params: [String: Any] = [:]) throws -> [String: Any] {
        try initialize()
        switch method {
        case "bootstrap", "status", "listArticles": return try bootstrap()
        case "createCategory":
            let supplied = try string(params, "name")
            guard !supplied.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) }) else {
                throw fail("Category names cannot contain control characters or line breaks.")
            }
            let name = supplied.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
            guard !name.isEmpty, name.count <= 80 else { throw fail("Enter a category name between 1 and 80 characters.") }
            let canonical = (state.categories ?? []).first {
                $0.compare(name, options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX")) == .orderedSame
            } ?? name
            if !(state.categories ?? []).contains(canonical) {
                state.categories = (state.categories ?? []) + [canonical]
                try persist()
            }
            var result = try bootstrap()
            result["category"] = canonical
            return result
        case "readArticle": return try articleJSON(path: string(params, "path"))
        case "saveDraft":
            return try saveDraft(path: string(params, "path"), raw: string(params, "rawContent"),
                                 expected: string(params, "expectedRevision"))
        case "createArticle":
            let path = try string(params, "path")
            try validateArticlePath(path, creating: true)
            guard articles[path] == nil, state.drafts[path] == nil else { throw fail("An article already exists at this path. Choose another filename.") }
            let raw = try string(params, "rawContent")
            try validateArticleContent(raw)
            state.drafts[path] = WriterDraft(rawContent: raw, baseBlob: nil, baseContent: nil, updatedAt: now())
            state.state = "local"; state.message = "Article saved on this Mac."
            try persist()
            return try articleJSON(path: path)
        case "discardDraft":
            let path = try string(params, "path")
            try validateArticlePath(path)
            guard state.queue[path] == nil else { throw fail("Cancel the queued publication before discarding this draft.") }
            if let draft = state.drafts[path] { try archive(path: path, draft: draft) }
            state.drafts.removeValue(forKey: path); state.conflicts.removeValue(forKey: path)
            state.state = "ready"; state.message = "Local draft discarded. A recovery copy is saved on this Mac."
            try persist(); return try bootstrap()
        case "refresh":
            do {
                try fetch()
                state.state = state.queue.isEmpty ? "ready" : "queued"
                state.message = "Latest articles downloaded. Local drafts are safe."
                state.lastSyncedAt = now()
            } catch { networkFailure(error) }
            try persist(); return try bootstrap()
        case "verifyPublishAccess":
            do {
                try fetch()
                _ = try git(["push", "--dry-run", "origin", "\(remoteRef):refs/heads/main"], at: repository, network: true)
                state.state = state.queue.isEmpty ? "ready" : "queued"
                state.message = "GitHub publishing credentials verified. No changes were published."
            } catch { networkFailure(error) }
            try persist(); return try bootstrap()
        case "queuePublish":
            let path = try string(params, "path")
            try validateArticlePath(path)
            guard let draft = state.drafts[path] else { throw fail("There are no local changes to publish for this article.") }
            guard state.conflicts[path] == nil else { throw fail("Resolve the conflicting edits before publishing this article.") }
            state.queue[path] = WriterQueueEntry(rawContent: draft.rawContent, baseBlob: draft.baseBlob,
                                                baseContent: draft.baseContent, queuedAt: now())
            state.state = "queued"; state.message = "Publication queued. Only this saved version will be published."
            try persist(); return try bootstrap()
        case "cancelQueued":
            let path = try string(params, "path")
            try validateArticlePath(path)
            state.queue.removeValue(forKey: path); state.conflicts.removeValue(forKey: path)
            state.state = "local"; state.message = "Publication canceled. Your local draft is saved."
            try persist(); return try bootstrap()
        case "processQueue": return try processQueue()
        case "resolveConflict":
            let path = try string(params, "path")
            try validateArticlePath(path)
            guard let conflict = state.conflicts[path] else { throw fail("This article has no conflict to resolve.") }
            let raw = try string(params, "rawContent")
            try validateArticleContent(raw)
            if let previous = state.drafts[path] { try archive(path: path, draft: previous) }
            state.drafts[path] = WriterDraft(rawContent: raw, baseBlob: conflict.remoteBlob,
                                            baseContent: conflict.remote, updatedAt: now())
            state.queue.removeValue(forKey: path); state.conflicts.removeValue(forKey: path)
            state.state = "local"; state.message = "Resolution saved locally. Choose Publish when ready."
            try persist(); return try articleJSON(path: path)
        case "importImage":
            let filename = try string(params, "filename")
            guard let data = Data(base64Encoded: try string(params, "base64")) else { throw fail("The image data is invalid.") }
            return try importImage(filename: filename, data: data)
        case "readAsset": return try readAsset(path: string(params, "path"))
        default: throw fail("Unknown application command: \(method)")
        }
    }

    private func string(_ params: [String: Any], _ key: String) throws -> String {
        guard let value = params[key] as? String else { throw fail("Missing required value: \(key)") }
        return value
    }

    private func initialize() throws {
        if initialized { return }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        if fm.fileExists(atPath: stateFile.path) {
            do { state = try JSONDecoder().decode(WriterState.self, from: Data(contentsOf: stateFile)) }
            catch { throw fail("Local draft storage could not be read. It has been preserved at \(stateFile.path).") }
        }
        durableState = state
        if !fm.fileExists(atPath: repository.path) {
            let temporary = root.appendingPathComponent("initial-clone-\(UUID().uuidString)")
            defer { try? fm.removeItem(at: temporary) }
            if let seedRepo, fm.fileExists(atPath: seedRepo.path) {
                _ = try git(["clone", "--bare", "--no-hardlinks", "--", seedRepo.path, temporary.path], network: true)
            } else {
                _ = try git(["clone", "--bare", "--single-branch", "--branch", "main", "--", remoteURL, temporary.path], network: true)
            }
            _ = try git(["remote", "set-url", "origin", remoteURL], at: temporary)
            _ = try git(["config", "remote.origin.fetch", "+refs/heads/main:\(remoteRef)"], at: temporary)
            let main = try git(["rev-parse", "refs/heads/main"], at: temporary).text.trimmingCharacters(in: .whitespacesAndNewlines)
            _ = try git(["update-ref", remoteRef, main], at: temporary)
            try fm.moveItem(at: temporary, to: repository)
        }
        guard !(try repository.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink.orFalse else { throw fail("The managed repository must not be a symbolic link.") }
        let actualRemote = try git(["remote", "get-url", "origin"], at: repository).text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard actualRemote == remoteURL else { throw fail("The managed repository points to an unexpected remote. Publishing is disabled.") }
        guard try git(["rev-parse", "--is-bare-repository"], at: repository).text.trimmingCharacters(in: .whitespacesAndNewlines) == "true" else { throw fail("The application repository must be bare.") }
        try reloadArticles()
        initialized = true
        try persist()
    }

    private func persist() throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            try encoder.encode(state).write(to: stateFile, options: .atomic)
            durableState = state
        } catch {
            state = durableState
            throw fail("Could not save local changes to disk. Your last saved version is intact. Free disk space or check folder permissions, then retry.")
        }
    }

    private func archive(path: String, draft: WriterDraft) throws {
        let dir = root.appendingPathComponent("history/\(digest(path))", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let entry: [String: Any] = ["path": path, "rawContent": draft.rawContent, "savedAt": now()]
        try JSONSerialization.data(withJSONObject: entry, options: [.prettyPrinted]).write(to: dir.appendingPathComponent("\(UUID().uuidString).json"), options: .atomic)
    }

    private func validateRelative(_ path: String) throws {
        guard !path.isEmpty, path.utf8.count < 1024, !path.hasPrefix("/"), !path.contains("\\"),
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !path.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else {
            throw fail("The file path is not allowed.")
        }
    }

    private func validateArticlePath(_ path: String, creating: Bool = false) throws {
        try validateRelative(path)
        guard path == "index.md" || path == "404.md" || (path.hasPrefix("_docs/") && path.hasSuffix(".md")) else { throw fail("Only articles, the homepage, and the not-found page can be edited.") }
        let name = (path as NSString).lastPathComponent.lowercased()
        guard !["_defaults.md", "readme.md", "1.md"].contains(name), !path.split(separator: "/").contains(where: { $0.hasPrefix(".") }) else { throw fail("This template file cannot be edited in the app.") }
        if creating, !path.hasPrefix("_docs/") { throw fail("Create new articles inside the articles collection.") }
    }

    private func validateArticleContent(_ raw: String) throws {
        guard raw.utf8.count <= 5 * 1024 * 1024, raw.hasPrefix("---\n") || raw.hasPrefix("---\r\n"),
              raw.dropFirst(3).contains("\n---") else { throw fail("Articles must have YAML frontmatter and be smaller than 5 MB.") }
    }

    private func reloadArticles() throws {
        let commit = try git(["rev-parse", remoteRef], at: repository).text.trimmingCharacters(in: .whitespacesAndNewlines)
        if cachedCommit == commit { return }
        let tree = try git(["ls-tree", "-r", "-z", commit], at: repository).output
        var entries: [(String, String)] = []
        for record in tree.split(separator: 0) {
            guard let row = String(data: Data(record), encoding: .utf8), let tab = row.firstIndex(of: "\t") else { continue }
            let info = row[..<tab].split(separator: " ")
            let path = String(row[row.index(after: tab)...])
            guard info.count == 3, ["100644", "100755"].contains(String(info[0])), info[1] == "blob", (try? validateArticlePath(path)) != nil else { continue }
            entries.append((path, String(info[2])))
        }
        var loaded: [String: RepositoryArticle] = [:]
        if !entries.isEmpty {
            let result = try git(["cat-file", "--batch"], at: repository, input: Data(entries.map { $0.1 + "\n" }.joined().utf8)).output
            var offset = 0
            for (path, blob) in entries {
                guard let newline = result[offset...].firstIndex(of: 10), let header = String(data: result[offset..<newline], encoding: .utf8), let sizeText = header.split(separator: " ").last, let size = Int(sizeText) else { throw fail("Could not read article data from Git.") }
                let start = newline + 1, end = start + size
                guard end < result.count else { throw fail("Incomplete article data was returned by Git.") }
                if let raw = String(data: result[start..<end], encoding: .utf8), raw.hasPrefix("---\n") || raw.hasPrefix("---\r\n") {
                    loaded[path] = RepositoryArticle(rawContent: raw, blob: blob)
                }
                offset = end + 1
            }
        }
        articles = loaded; cachedCommit = commit
    }

    private func statusJSON() -> [String: Any] {
        var result: [String: Any] = ["state": state.state, "message": state.message,
                                    "queuedCount": state.queue.count, "draftCount": state.drafts.count,
                                    "conflictCount": state.conflicts.count]
        if let time = state.lastSyncedAt { result["lastSyncedAt"] = time }
        return result
    }

    private func bootstrap() throws -> [String: Any] {
        let paths = Set(articles.keys).union(state.drafts.keys).sorted()
        return ["articles": try paths.map { try articleJSON(path: $0) }, "categories": state.categories ?? [], "status": statusJSON(),
                "repositoryPath": repository.path, "remoteURL": remoteURL, "branch": "main"]
    }

    private func articleJSON(path: String) throws -> [String: Any] {
        try validateArticlePath(path)
        guard let raw = state.drafts[path]?.rawContent ?? articles[path]?.rawContent else { throw fail("This article could not be found.") }
        var result: [String: Any] = ["path": path, "rawContent": raw, "revision": digest(raw),
                                    "isDraft": state.drafts[path] != nil, "isQueued": state.queue[path] != nil]
        if let queue = state.queue[path] { result["queuedRevision"] = digest(queue.rawContent) }
        if let conflict = state.conflicts[path] { result["conflict"] = ["base": conflict.base, "local": conflict.local, "remote": conflict.remote] }
        return result
    }

    private func saveDraft(path: String, raw: String, expected: String) throws -> [String: Any] {
        try validateArticlePath(path); try validateArticleContent(raw)
        guard let current = state.drafts[path]?.rawContent ?? articles[path]?.rawContent else { throw fail("Create the article before saving changes.") }
        guard digest(current) == expected else { throw fail("This article changed since it was opened. Reload it before saving, so neither version is overwritten.") }
        if raw == articles[path]?.rawContent, state.queue[path] == nil, state.conflicts[path] == nil {
            state.drafts.removeValue(forKey: path)
        } else {
            let previous = state.drafts[path]
            state.drafts[path] = WriterDraft(rawContent: raw, baseBlob: previous != nil ? previous!.baseBlob : articles[path]?.blob,
                                            baseContent: previous != nil ? previous!.baseContent : articles[path]?.rawContent, updatedAt: now())
        }
        state.state = state.queue.isEmpty ? "local" : "queued"
        state.message = state.queue.isEmpty ? "Saved on this Mac." : "Saved locally. The previously queued version is unchanged."
        try persist(); return try articleJSON(path: path)
    }

    private func fetch() throws {
        _ = try git(["fetch", "--no-tags", "origin", "+refs/heads/main:\(remoteRef)"], at: repository, network: true)
        try reloadArticles()
    }

    private func networkFailure(_ error: Error) {
        let details = error.localizedDescription
        let lower = details.lowercased()
        if lower.contains("authentication") || lower.contains("could not read username") || lower.contains("permission denied") || lower.contains("403") || lower.contains("terminal prompts disabled") {
            state.state = "authentication"
            state.message = "GitHub authentication is needed. Sign in with GitHub CLI or configure your Git credential helper, then retry. Your local work is safe."
        } else {
            state.state = "offline"
            state.message = state.queue.isEmpty ? "Could not reach GitHub. You can continue writing offline." : "Waiting for GitHub. Queued articles and local drafts are saved on this Mac."
        }
    }

    private func processQueue() throws -> [String: Any] {
        guard !state.queue.isEmpty else { return try bootstrap() }
        do { try fetch() } catch { networkFailure(error); try persist(); return try bootstrap() }
        var published = 0
        for path in state.queue.keys.sorted() {
            guard let snapshot = state.queue[path] else { continue }
            let remote = articles[path]
            if remote?.rawContent == snapshot.rawContent {
                finishPublication(path: path, snapshot: snapshot); published += 1; try persist(); continue
            }
            if remote?.blob != snapshot.baseBlob {
                state.conflicts[path] = WriterConflict(base: snapshot.baseContent ?? "", local: snapshot.rawContent,
                                                       remote: remote?.rawContent ?? "", remoteBlob: remote?.blob)
                state.state = "conflict"; state.message = "This article also changed online. Review both versions before publishing."
                try persist(); continue
            }
            do {
                try publish(path: path, snapshot: snapshot)
                finishPublication(path: path, snapshot: snapshot)
                published += 1; try persist()
            } catch {
                if error.localizedDescription.contains("rejected") || error.localizedDescription.contains("fetch first") || error.localizedDescription.contains("non-fast-forward") {
                    state.state = "queued"; state.message = "The site changed while publishing. Refresh and retry; your queued version is safe."
                } else if error.localizedDescription.contains("Git author identity") {
                    state.state = "error"; state.message = error.localizedDescription
                } else if error.localizedDescription.hasPrefix("Git operation failed:") || error.localizedDescription.contains("connection timed out") {
                    networkFailure(error)
                } else {
                    state.state = "error"; state.message = error.localizedDescription
                }
                try persist(); break
            }
        }
        if !state.conflicts.isEmpty {
            state.state = "conflict"; state.message = "Conflicting edits need review. Both versions are saved."
        } else if state.queue.isEmpty {
            state.state = "synced"; state.message = published > 0 ? "Published to GitHub. The website will update after its build finishes." : "Everything is up to date."
        }
        try persist(); return try bootstrap()
    }

    private func finishPublication(path: String, snapshot: WriterQueueEntry) {
        if let draft = state.drafts[path] {
            if draft.rawContent == snapshot.rawContent { state.drafts.removeValue(forKey: path) }
            else { state.drafts[path] = WriterDraft(rawContent: draft.rawContent, baseBlob: articles[path]?.blob,
                                                   baseContent: articles[path]?.rawContent, updatedAt: draft.updatedAt) }
        }
        state.queue.removeValue(forKey: path); state.conflicts.removeValue(forKey: path)
        state.lastSyncedAt = now()
    }

    private func publish(path: String, snapshot: WriterQueueEntry) throws {
        guard let commit = cachedCommit else { throw fail("The remote repository has not been loaded.") }
        let directory = root.appendingPathComponent("publish-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: directory) }
        _ = try git(["clone", "--no-checkout", "--no-hardlinks", "--", repository.path, directory.path])
        _ = try git(["checkout", "--detach", commit], at: directory)
        _ = try git(["remote", "set-url", "origin", remoteURL], at: directory)
        let name: String
        let email: String
        if let identity { name = identity.name; email = identity.email }
        else {
            name = (try? git(["config", "--get", "user.name"], at: repository).text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""
            email = (try? git(["config", "--get", "user.email"], at: repository).text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? ""
        }
        guard !name.isEmpty, !email.isEmpty else { throw fail("Git author identity is missing. Set your Git user.name and user.email, then retry publishing.") }
        _ = try git(["config", "user.name", name], at: directory)
        _ = try git(["config", "user.email", email], at: directory)
        let destination = try safeDestination(path, inside: directory)
        try Data(snapshot.rawContent.utf8).write(to: destination, options: .atomic)
        var changed = [path]
        for asset in referencedStagedAssets(snapshot.rawContent) {
            let source = try safeExisting(asset, inside: assetsRoot)
            let target = try safeDestination(asset, inside: directory)
            try Data(contentsOf: source).write(to: target, options: .atomic)
            changed.append(asset)
        }
        _ = try git(["add", "--"] + changed, at: directory)
        _ = try git(["-c", "commit.gpgsign=false", "commit", "-m", "Publish \((path as NSString).lastPathComponent) via Nightingale Writer"], at: directory)
        _ = try git(["push", "origin", "HEAD:refs/heads/main"], at: directory, network: true)
        // Record the successfully pushed commit without requiring another network request.
        _ = try git(["fetch", "--no-tags", directory.path, "+HEAD:\(remoteRef)"], at: repository)
        try reloadArticles()
    }

    private func referencedStagedAssets(_ raw: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: "(?:^|[/\\(\\\"'])images/uploads/([A-Za-z0-9._-]+)")
        let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
        let names = regex.matches(in: raw, range: range).compactMap { match -> String? in
            guard let r = Range(match.range(at: 1), in: raw) else { return nil }
            let path = "images/uploads/\(raw[r])"
            return fm.fileExists(atPath: assetsRoot.appendingPathComponent(path).path) ? path : nil
        }
        return Array(Set(names)).sorted()
    }

    private func safeDestination(_ path: String, inside base: URL) throws -> URL {
        try validateRelative(path)
        var current = base
        let pieces = path.split(separator: "/", omittingEmptySubsequences: false)
        for (index, piece) in pieces.enumerated() {
            current = current.appendingPathComponent(String(piece), isDirectory: index < pieces.count - 1)
            if fm.fileExists(atPath: current.path) || (try? current.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                let values = try current.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey])
                guard values.isSymbolicLink != true else { throw fail("Symbolic links cannot be edited or used as assets.") }
                if index < pieces.count - 1 { guard values.isDirectory == true else { throw fail("An article path contains a non-directory.") } }
                else { guard values.isRegularFile == true else { throw fail("The target is not a regular file.") } }
            } else if index < pieces.count - 1 {
                try fm.createDirectory(at: current, withIntermediateDirectories: false)
            }
        }
        return current
    }

    private func safeExisting(_ path: String, inside base: URL) throws -> URL {
        try validateRelative(path)
        var current = base
        for piece in path.split(separator: "/") {
            current = current.appendingPathComponent(String(piece))
            let values = try current.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw fail("Symbolic links cannot be used as assets.") }
        }
        guard (try current.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else { throw fail("This asset is not a regular file.") }
        return current
    }

    private func imageMIME(_ ext: String) -> String? {
        ["png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg", "gif": "image/gif", "webp": "image/webp"][ext.lowercased()]
    }

    private func importImage(filename: String, data: Data) throws -> [String: Any] {
        let ext = (filename as NSString).pathExtension.lowercased()
        guard let mime = imageMIME(ext), !data.isEmpty, data.count <= 20 * 1024 * 1024 else { throw fail("Choose a PNG, JPEG, GIF, or WebP image smaller than 20 MB.") }
        let bytes = [UInt8](data.prefix(12))
        let valid = (ext == "png" && bytes.starts(with: [137, 80, 78, 71, 13, 10, 26, 10])) ||
            (["jpg", "jpeg"].contains(ext) && bytes.starts(with: [255, 216, 255])) ||
            (ext == "gif" && (String(data: data.prefix(6), encoding: .ascii)?.hasPrefix("GIF8") == true)) ||
            (ext == "webp" && String(data: data.prefix(4), encoding: .ascii) == "RIFF" && String(data: data.dropFirst(8).prefix(4), encoding: .ascii) == "WEBP")
        guard valid else { throw fail("The file contents do not match its image type.") }
        let stem = (filename as NSString).deletingPathExtension.lowercased().replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let safeStem = String(stem.prefix(60)).isEmpty ? "image" : String(stem.prefix(60))
        let path = "images/uploads/\(safeStem)-\(UUID().uuidString.lowercased().prefix(8)).\(ext)"
        try fm.createDirectory(at: assetsRoot, withIntermediateDirectories: true)
        let file = try safeDestination(path, inside: assetsRoot)
        try data.write(to: file, options: .atomic)
        return ["path": "/" + path, "mime": mime, "base64": data.base64EncodedString()]
    }

    private func readAsset(path supplied: String) throws -> [String: Any] {
        let path = supplied.hasPrefix("/") ? String(supplied.dropFirst()) : supplied
        try validateRelative(path)
        guard path.hasPrefix("images/") || ["siteicon.png", "apple-touch-icon.png", "touch-icon.png"].contains(path), let mime = imageMIME((path as NSString).pathExtension) else { throw fail("Only repository image assets can be previewed.") }
        let data: Data
        if fm.fileExists(atPath: assetsRoot.appendingPathComponent(path).path) {
            data = try Data(contentsOf: safeExisting(path, inside: assetsRoot))
        } else {
            let tree = try git(["ls-tree", remoteRef, "--", path], at: repository).text
            guard tree.hasPrefix("100644 blob ") || tree.hasPrefix("100755 blob ") else { throw fail("The image was not found in the repository.") }
            data = try git(["show", "\(remoteRef):\(path)"], at: repository).output
        }
        guard data.count <= 20 * 1024 * 1024 else { throw fail("The image is too large to preview.") }
        return ["path": "/" + path, "mime": mime, "base64": data.base64EncodedString()]
    }

    private func temporaryOutput() throws -> FileHandle {
        var template = Array((NSTemporaryDirectory() + "nightingale-git-XXXXXX").utf8CString)
        let descriptor = mkstemp(&template)
        guard descriptor >= 0 else { throw fail("Could not create temporary storage for Git.") }
        unlink(template)
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    @discardableResult
    private func git(_ arguments: [String], at directory: URL? = nil, input: Data? = nil, network: Bool = false) throws -> GitResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        var args = ["-c", "core.hooksPath=/dev/null", "-c", "core.quotepath=false", "-c", "credential.interactive=never"]
        if let directory { args += ["-C", directory.path] }
        process.arguments = args + arguments
        var environment = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") }
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:" + (environment["PATH"] ?? "")
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["GIT_SSH_COMMAND"] = "/usr/bin/ssh -oBatchMode=yes -oConnectTimeout=10"
        process.environment = environment
        // Unlinked regular files avoid pipe deadlocks if a credential/network child
        // outlives git after a timeout. The private files have no filesystem name.
        let stdout = try temporaryOutput(), stderr = try temporaryOutput(), stdin = Pipe()
        defer { try? stdout.close(); try? stderr.close() }
        process.standardOutput = stdout; process.standardError = stderr
        process.standardInput = input == nil ? FileHandle.nullDevice : stdin
        let completion = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in completion.signal() }
        try process.run()
        let ownProcessGroup = getpgid(process.processIdentifier) == process.processIdentifier
        if let input { try stdin.fileHandleForWriting.write(contentsOf: input); try stdin.fileHandleForWriting.close() }
        let expired = completion.wait(timeout: .now() + (network ? 35 : 20)) == .timedOut
        if expired {
            if ownProcessGroup { kill(-process.processIdentifier, SIGTERM) }
            process.terminate()
            if completion.wait(timeout: .now() + 2) == .timedOut {
                if ownProcessGroup { kill(-process.processIdentifier, SIGKILL) }
                kill(process.processIdentifier, SIGKILL)
                _ = completion.wait(timeout: .now() + 2)
            }
            throw fail("GitHub connection timed out. Your local work has been saved.")
        }
        try stdout.seek(toOffset: 0); try stderr.seek(toOffset: 0)
        let result = GitResult(status: process.terminationStatus,
                               output: try stdout.readToEnd() ?? Data(),
                               error: try stderr.readToEnd() ?? Data())
        guard result.status == 0 else {
            let message = result.errorText.isEmpty ? result.text : result.errorText
            // Git credentials never appear in arguments, and remote URLs are fixed by the app.
            throw fail("Git operation failed: \(String(message.prefix(1600)).trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        return result
    }
}

private extension Optional where Wrapped == Bool {
    var orFalse: Bool { self ?? false }
}
