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

private struct WriterPublication: Codable {
    var sourceSHA256: String
    var commit: String?
    var status: String
    var liveURL: String
    var workflowURL: String?
    var checkedAt: String?
    var uploadedAt: String?
    var message: String?
}

private struct WriterTemplate: Codable {
    var id: String
    var name: String
    var rawContent: String
    var updatedAt: String?
    var importedFromID: String? = nil
}

private struct WriterState: Codable {
    var version = 1
    var drafts: [String: WriterDraft] = [:]
    var queue: [String: WriterQueueEntry] = [:]
    var conflicts: [String: WriterConflict] = [:]
    // Optional so state written before local categories were introduced still decodes.
    var categories: [String]?
    var publications: [String: WriterPublication]?
    var templates: [String: WriterTemplate]?
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
    private let validation: (([String: Any]) throws -> [String: Any])?
    private let fm = FileManager.default
    private var state = WriterState()
    private var durableState = WriterState()
    private var articles: [String: RepositoryArticle] = [:]
    private var cachedCommit: String?
    private var initialized = false
    private var pendingHistoryPrunes = Set<String>()
    private var backupWarning: String?
    private var needsRestore = false
    private var corruptStateBytes: Data?
    private var recoveryWriteInProgress = false
    private let standardDates = ISO8601DateFormatter()
    private let fractionalDates: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private let maxBackupBytes = 256 * 1024 * 1024

    init(root: URL, remoteURL: String = RepositoryStore.productionRemote,
         seedRepo: URL? = nil, identity: (name: String, email: String)? = nil,
         validation: (([String: Any]) throws -> [String: Any])? = nil) {
        self.root = root.standardizedFileURL
        self.remoteURL = remoteURL
        self.seedRepo = seedRepo
        self.identity = identity
        self.validation = validation
    }

    private var repository: URL { root.appendingPathComponent("repository.git", isDirectory: true) }
    private var stateFile: URL { root.appendingPathComponent("state.json") }
    private var assetsRoot: URL { root.appendingPathComponent("assets", isDirectory: true) }
    private var remoteRef: String { "refs/remotes/origin/main" }
    private func now() -> String { standardDates.string(from: Date()) }
    private func digest(_ value: String) -> String { SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() }
    private func fail(_ message: String) -> RepositoryStoreError { RepositoryStoreError(message: message) }

    func handle(method: String, params: [String: Any] = [:]) throws -> [String: Any] {
        try initialize()
        if needsRestore && !["bootstrap", "status", "listArticles", "readArticle", "listHistory", "readHistory", "readAsset", "listTemplates"].contains(method) {
            throw fail("Local draft storage needs recovery. Restore a valid backup before editing or publishing.")
        }
        switch method {
        case "bootstrap", "status", "listArticles": return try bootstrap()
        case "renameCategory", "mergeCategory": return try renameCategory(params)
        case "listTemplates": return ["templates": templateList()]
        case "saveTemplate": return try saveTemplate(params)
        case "removeTemplate", "deleteTemplate":
            let id = try string(params, "id")
            guard state.templates?[id] != nil else { throw fail("This template no longer exists. Refresh the template list.") }
            try automaticBackup(force: true)
            state.templates?.removeValue(forKey: id)
            try persist(); return try bootstrap()
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
        case "listHistory": return ["entries": try historyEntries(path: params["path"] as? String, includeContent: false)]
        case "readHistory": return try historyEntry(path: string(params, "path"), id: string(params, "id"))
        case "restoreHistory":
            let path = try string(params, "path")
            guard state.queue[path] == nil else { throw fail("Cancel queued publication before restoring a version.") }
            let entry = try historyEntry(path: path, id: string(params, "id"))
            let content = entry["rawContent"] as! String
            if let current = state.drafts[path]?.rawContent ?? articles[path]?.rawContent {
                guard params["expectedRevision"] as? String == digest(current) else { throw fail("The article changed. Reload it before restoring a version.") }
                try archiveContent(path: path, content: current, reason: "before-restore")
            } else if params["expectedRevision"] != nil { throw fail("This article no longer exists. Reload its history before restoring.") }
            try automaticBackup(force: true)
            state.drafts[path] = WriterDraft(rawContent: content, baseBlob: articles[path]?.blob, baseContent: articles[path]?.rawContent, updatedAt: now())
            state.conflicts.removeValue(forKey: path)
            state.state = "local"; state.message = "Version restored locally. Choose Publish when ready."
            try persist(); return try bootstrap()
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
            try archiveContent(path: path, content: raw, reason: "created")
            state.drafts[path] = WriterDraft(rawContent: raw, baseBlob: nil, baseContent: nil, updatedAt: now())
            state.state = "local"; state.message = "Article saved on this Mac."
            try persist()
            return try articleJSON(path: path)
        case "discardDraft":
            let path = try string(params, "path")
            try validateArticlePath(path)
            guard state.queue[path] == nil else { throw fail("Cancel the queued publication before discarding this draft.") }
            if let draft = state.drafts[path] { try automaticBackup(force: true); try archive(path: path, draft: draft) }
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
        case "validatePublication":
            let path = try string(params, "path")
            try validateArticlePath(path)
            guard let raw = state.drafts[path]?.rawContent ?? articles[path]?.rawContent else { throw fail("Article not found.") }
            if let expected = params["expectedRevision"] as? String, expected != digest(raw) { throw fail("The article changed. Save and validate the current version.") }
            var report = try validationReport(path: path, raw: raw)
            report["revision"] = digest(raw)
            return report
        case "queuePublish":
            let path = try string(params, "path")
            try validateArticlePath(path)
            guard let draft = state.drafts[path] else { throw fail("There are no local changes to publish for this article.") }
            guard state.conflicts[path] == nil else { throw fail("Resolve the conflicting edits before publishing this article.") }
            if let expected = params["expectedRevision"] as? String, expected != digest(draft.rawContent) { throw fail("The article changed. Save and validate the current version before publishing.") }
            try requireValidPublication(path: path, raw: draft.rawContent)
            try archiveContent(path: path, content: draft.rawContent, reason: "queued")
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

    private func normalizedLabel(_ supplied: String, kind: String) throws -> String {
        guard !supplied.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) }) else {
            throw fail("\(kind) names cannot contain control characters or line breaks.")
        }
        let name = supplied.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
        guard !name.isEmpty, name.count <= 80 else { throw fail("Enter a \(kind.lowercased()) name between 1 and 80 characters.") }
        return name
    }

    private func sameLabel(_ lhs: String, _ rhs: String) -> Bool {
        lhs.compare(rhs, options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX")) == .orderedSame
    }

    private func articleBody(_ content: String) throws -> String {
        try validateArticleContent(content)
        guard let openingEnd = content.firstIndex(of: "\n"),
              let closing = content.range(of: "(?m)^---[\\t ]*\\r?(?:\\n|$)", options: .regularExpression, range: content.index(after: openingEnd)..<content.endIndex) else {
            throw fail("The article frontmatter delimiter is invalid.")
        }
        return String(content[closing.upperBound...])
    }

    private func renameCategory(_ params: [String: Any]) throws -> [String: Any] {
        let from = try normalizedLabel((params["from"] ?? params["sourceName"]) as? String ?? "", kind: "Category")
        let proposed = try normalizedLabel((params["to"] ?? params["targetName"]) as? String ?? "", kind: "Category")
        let to = (state.categories ?? []).first { !sameLabel($0, from) && sameLabel($0, proposed) } ?? proposed
        guard let expected = params["expectedRevisions"] as? [String: String],
              let changes = params["changes"] as? [[String: Any]], changes.count <= 10000 else { throw fail("A category change requires a complete library revision snapshot.") }
        let paths = Set(articles.keys).union(state.drafts.keys)
        guard Set(expected.keys) == paths else { throw fail("The article library changed. Refresh it before renaming a category.") }
        for path in paths {
            let current = state.drafts[path]?.rawContent ?? articles[path]!.rawContent
            guard expected[path] == digest(current) else { throw fail("An article changed. Refresh the library before renaming a category.") }
        }
        var prepared: [(path: String, old: String, new: String)] = []
        var seen = Set<String>()
        for change in changes {
            let path = try string(change, "path")
            try validateArticlePath(path)
            guard paths.contains(path), seen.insert(path).inserted else { throw fail("The category change contains an unknown or repeated article.") }
            guard state.queue[path] == nil, state.conflicts[path] == nil else { throw fail("Cancel queued publication and resolve conflicts for affected articles before changing a category.") }
            let old = state.drafts[path]?.rawContent ?? articles[path]!.rawContent
            guard try string(change, "expectedRevision") == digest(old) else { throw fail("An affected article changed. Refresh the library and try again.") }
            let new = try string(change, "rawContent")
            guard try articleBody(old) == articleBody(new) else { throw fail("A category change cannot modify article text or code.") }
            prepared.append((path, old, new))
        }
        guard !prepared.isEmpty || (state.categories ?? []).contains(where: { sameLabel($0, from) }) else { throw fail("The source category no longer exists. Refresh the library.") }
        try automaticBackup(force: true)
        let previous = state
        var recoveryFiles: [URL] = []
        do {
            for change in prepared where change.old != change.new {
                if let file = try archiveContent(path: change.path, content: change.old, reason: "before-category-change") { recoveryFiles.append(file) }
                let existing = state.drafts[change.path]
                state.drafts[change.path] = WriterDraft(rawContent: change.new,
                    baseBlob: existing != nil ? existing!.baseBlob : articles[change.path]?.blob,
                    baseContent: existing != nil ? existing!.baseContent : articles[change.path]?.rawContent, updatedAt: now())
            }
            var categories = (state.categories ?? []).filter { !sameLabel($0, from) }
            if !categories.contains(where: { sameLabel($0, to) }) { categories.append(to) }
            state.categories = categories
            if state.queue.isEmpty && state.conflicts.isEmpty { state.state = "local" }
            state.message = "Category updated locally. Article URLs and publication queue are unchanged."
            try persist()
        } catch {
            state = previous
            for file in recoveryFiles { try? fm.removeItem(at: file) }
            pendingHistoryPrunes.removeAll()
            throw error
        }
        var result = try bootstrap()
        result["category"] = to
        result["categoryChange"] = ["from": from, "to": to, "articlesChanged": prepared.filter { $0.old != $0.new }.count]
        return result
    }

    private func templateJSON(_ template: WriterTemplate) -> [String: Any] {
        var result: [String: Any] = ["id": template.id, "name": template.name, "rawContent": template.rawContent]
        if let updated = template.updatedAt { result["updatedAt"] = updated }
        return result
    }

    private func templateList() -> [[String: Any]] {
        (state.templates ?? [:]).values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }.map(templateJSON)
    }

    private func validateTemplates(_ templates: [String: WriterTemplate]) throws {
        guard templates.count <= 100 else { throw fail("Keep at most 100 local templates.") }
        var names = Set<String>()
        for (id, template) in templates {
            guard id == template.id, UUID(uuidString: id) != nil, template.rawContent.utf8.count <= 5 * 1024 * 1024,
                  template.importedFromID == nil || UUID(uuidString: template.importedFromID!) != nil else { throw fail("A template is invalid or exceeds the 5 MiB content limit.") }
            let name = try normalizedLabel(template.name, kind: "Template")
            let key = name.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            guard names.insert(key).inserted else { throw fail("Template names must be distinct.") }
        }
    }

    private func saveTemplate(_ params: [String: Any]) throws -> [String: Any] {
        let name = try normalizedLabel(string(params, "name"), kind: "Template")
        let content = try string(params, "rawContent")
        guard content.utf8.count <= 5 * 1024 * 1024 else { throw fail("A template must be smaller than 5 MiB.") }
        var templates = state.templates ?? [:]
        let id: String
        if let requested = params["id"] as? String {
            guard templates[requested] != nil else { throw fail("This template no longer exists. Refresh the template list.") }
            id = requested
        } else {
            guard templates.count < 100 else { throw fail("Keep at most 100 local templates.") }
            id = UUID().uuidString
        }
        guard !templates.values.contains(where: { $0.id != id && sameLabel($0.name, name) }) else { throw fail("A template already uses this name. Choose another name.") }
        if templates[id] != nil { try automaticBackup(force: true) }
        let template = WriterTemplate(id: id, name: name, rawContent: content, updatedAt: now(), importedFromID: templates[id]?.importedFromID)
        templates[id] = template; state.templates = templates
        try persist()
        var result = try bootstrap(); result["template"] = templateJSON(template)
        return result
    }

    private func mergedTemplates(_ incoming: [String: WriterTemplate]) throws -> [String: WriterTemplate] {
        var templates = state.templates ?? [:]
        for template in incoming.values.sorted(by: { $0.id < $1.id }) {
            let normalizedName = try normalizedLabel(template.name, kind: "Template")
            let sourceID = template.importedFromID ?? template.id
            if templates.values.contains(where: {
                $0.rawContent == template.rawContent && (sameLabel($0.name, normalizedName) || $0.id == template.id || $0.importedFromID == sourceID)
            }) { continue }
            var candidate = template
            candidate.name = normalizedName
            if templates[candidate.id] != nil { candidate.id = UUID().uuidString; candidate.importedFromID = sourceID }
            if templates.values.contains(where: { sameLabel($0.name, candidate.name) }) {
                var index = 1
                repeat {
                    let suffix = index == 1 ? " (imported)" : " (imported \(index))"
                    candidate.name = String(normalizedName.prefix(80 - suffix.count)) + suffix
                    index += 1
                } while templates.values.contains(where: { sameLabel($0.name, candidate.name) })
            }
            templates[candidate.id] = candidate
            guard templates.count <= 100 else { throw fail("Restoring this backup would exceed 100 local templates. Existing templates were not changed.") }
        }
        return templates
    }

    private func string(_ params: [String: Any], _ key: String) throws -> String {
        guard let value = params[key] as? String else { throw fail("Missing required value: \(key)") }
        return value
    }

    private func initialize() throws {
        if initialized { return }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        if fm.fileExists(atPath: stateFile.path) {
            let original = try Data(contentsOf: stateFile)
            do { state = try JSONDecoder().decode(WriterState.self, from: original) }
            catch {
                corruptStateBytes = original; needsRestore = true
                state = WriterState(); state.state = "recovery"
                state.message = "Local draft storage could not be read. It is preserved unchanged. Restore a backup to resume editing."
            }
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
        if !needsRestore { try persist() }
    }

    private func persist() throws {
        guard !needsRestore || recoveryWriteInProgress else { throw fail("Restore a valid backup before changing local storage.") }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let meaningful = try workFingerprint(state) != workFingerprint(durableState)
        do {
            try encoder.encode(state).write(to: stateFile, options: .atomic)
            durableState = state
        } catch {
            state = durableState
            throw fail("Could not save local changes to disk. Your last saved version is intact. Free disk space or check folder permissions, then retry.")
        }
        for path in pendingHistoryPrunes { try? pruneHistory(path: path) }
        pendingHistoryPrunes.removeAll()
        if meaningful {
            do { try automaticBackup(); backupWarning = nil }
            catch { backupWarning = "Local work was saved, but the automatic backup could not be written." }
        }
    }

    private func archive(path: String, draft: WriterDraft) throws {
        try archiveContent(path: path, content: draft.rawContent, reason: "recovery")
    }

    private func historyDate(_ value: String) -> Date {
        return fractionalDates.date(from: value) ?? standardDates.date(from: value) ?? .distantPast
    }

    @discardableResult
    private func archiveContent(path: String, content: String, reason: String, coalesce: Bool = false) throws -> URL? {
        try validateArticlePath(path); try validateArticleContent(content)
        let previous = try historyEntries(path: path, includeContent: false)
        if coalesce, let first = previous.first,
           Date().timeIntervalSince(historyDate(first["savedAt"] as? String ?? "")) < 30 { return nil }
        if coalesce, previous.first?["revision"] as? String == digest(content) { return nil }
        let directory = root.appendingPathComponent("history/\(digest(path))", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let id = UUID().uuidString
        let entry: [String: Any] = ["id": id, "path": path, "rawContent": content, "savedAt": fractionalDates.string(from: Date()), "reason": reason, "revision": digest(content)]
        let file = directory.appendingPathComponent(id + ".json")
        try JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]).write(to: file, options: .atomic)
        pendingHistoryPrunes.insert(path)
        return file
    }

    private func historyEntry(path: String, id: String) throws -> [String: Any] {
        try validateArticlePath(path)
        guard UUID(uuidString: id) != nil else { throw fail("Invalid history version.") }
        let file = try safeExisting("history/\(digest(path))/\(id).json", inside: root)
        let data = try Data(contentsOf: file)
        guard data.count <= 6 * 1024 * 1024, var entry = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              entry["path"] as? String == path, let content = entry["rawContent"] as? String else { throw fail("This history version could not be read.") }
        try validateArticleContent(content)
        entry["id"] = id; entry["revision"] = digest(content)
        entry["reason"] = entry["reason"] as? String ?? "recovery"
        entry["savedAt"] = entry["savedAt"] as? String ?? ""
        return entry
    }

    private func historyEntries(path: String?, includeContent: Bool) throws -> [[String: Any]] {
        if let path { try validateArticlePath(path) }
        let historyRoot = root.appendingPathComponent("history", isDirectory: true)
        guard fm.fileExists(atPath: historyRoot.path) else { return [] }
        let directories: [URL]
        if let path { directories = [historyRoot.appendingPathComponent(digest(path))] }
        else { directories = try fm.contentsOfDirectory(at: historyRoot, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [.skipsHiddenFiles]) }
        var entries: [[String: Any]] = []
        for directory in directories where fm.fileExists(atPath: directory.path) {
            guard (try directory.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else { throw fail("History cannot contain symbolic links.") }
            for file in try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) where file.pathExtension == "json" {
                let id = file.deletingPathExtension().lastPathComponent
                guard UUID(uuidString: id) != nil else { continue }
                let safeFile = try safeExisting("history/\(directory.lastPathComponent)/\(file.lastPathComponent)", inside: root)
                let data = try Data(contentsOf: safeFile)
                guard data.count <= 6 * 1024 * 1024, let value = try JSONSerialization.jsonObject(with: data) as? [String: Any], let entryPath = value["path"] as? String,
                      directory.lastPathComponent == digest(entryPath) else { throw fail("A history record is invalid.") }
                var entry = try historyEntry(path: entryPath, id: id)
                if !includeContent { entry.removeValue(forKey: "rawContent") }
                entries.append(entry)
            }
        }
        return entries.map { ($0, historyDate($0["savedAt"] as? String ?? "")) }.sorted { $0.1 > $1.1 }.map { $0.0 }
    }

    private func pruneHistory(path: String) throws {
        let entries = try historyEntries(path: path, includeContent: false)
        for entry in entries.dropFirst(100) {
            if let id = entry["id"] as? String { try fm.removeItem(at: root.appendingPathComponent("history/\(digest(path))/\(id).json")) }
        }
    }

    private func workFingerprint(_ value: WriterState) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value.drafts) + encoder.encode(value.queue) + encoder.encode(value.categories) + encoder.encode(value.templates)
    }

    func exportBackup() throws -> Data {
        try initialize()
        guard !needsRestore else { throw fail("Restore a valid backup before exporting. The original unreadable storage file is preserved.") }
        let encodedState = try JSONSerialization.jsonObject(with: JSONEncoder().encode(state))
        var assets: [[String: Any]] = []
        if let enumerator = fm.enumerator(at: assetsRoot, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) {
            for case let file as URL in enumerator {
                let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isSymbolicLink != true else { throw fail("Backup assets cannot contain symbolic links.") }
                guard values.isRegularFile == true else { continue }
                let filePath = file.resolvingSymlinksInPath().path
                let basePath = assetsRoot.resolvingSymlinksInPath().path
                guard filePath.hasPrefix(basePath + "/") else { throw fail("A backup image is outside local asset storage.") }
                let path = String(filePath.dropFirst(basePath.count + 1))
                guard path.hasPrefix("images/uploads/") else { continue }
                let data = try Data(contentsOf: safeExisting(path, inside: assetsRoot))
                guard data.count <= 20 * 1024 * 1024 else { throw fail("A backup image exceeds the 20 MB limit.") }
                assets.append(["path": path, "base64": data.base64EncodedString(), "sha256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()])
            }
        }
        let payload: [String: Any] = ["format": "nightingale-writer-backup", "formatVersion": 1, "createdAt": now(), "repository": remoteURL,
                                     "state": encodedState, "assets": assets, "history": try historyEntries(path: nil, includeContent: true)]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        guard data.count <= maxBackupBytes else { throw fail("The local backup exceeds the 256 MB limit. Your working data is unchanged.") }
        return data
    }

    private func validatedBackup(_ data: Data) throws -> (WriterState, [[String: Any]], [(String, Data)], String) {
        guard data.count <= maxBackupBytes, let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              payload["format"] as? String == "nightingale-writer-backup", payload["formatVersion"] as? Int == 1,
              payload["repository"] as? String == remoteURL, let stateObject = payload["state"],
              let histories = payload["history"] as? [[String: Any]], histories.count <= 50000,
              let images = payload["assets"] as? [[String: Any]], images.count <= 10000 else { throw fail("Choose a valid Nightingale Writer backup for this repository (up to 256 MB).") }
        let restored = try JSONDecoder().decode(WriterState.self, from: JSONSerialization.data(withJSONObject: stateObject))
        guard restored.version == 1, restored.drafts.count <= 10000, restored.queue.count <= 10000 else { throw fail("This backup version or size is unsupported.") }
        try validateTemplates(restored.templates ?? [:])
        _ = try mergedTemplates(restored.templates ?? [:])
        for (path, draft) in restored.drafts { try validateArticlePath(path); try validateArticleContent(draft.rawContent) }
        for (path, queued) in restored.queue { try validateArticlePath(path); try validateArticleContent(queued.rawContent) }
        for name in restored.categories ?? [] {
            guard !name.isEmpty, name.count <= 80, !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) }) else { throw fail("A backup category is invalid.") }
        }
        for entry in histories {
            guard let path = entry["path"] as? String, let raw = entry["rawContent"] as? String else { throw fail("A backup history entry is invalid.") }
            try validateArticlePath(path); try validateArticleContent(raw)
        }
        var assets: [(String, Data)] = []; var names = Set<String>()
        for image in images {
            guard let path = image["path"] as? String, path.hasPrefix("images/uploads/"), let encoded = image["base64"] as? String,
                  let bytes = Data(base64Encoded: encoded), !bytes.isEmpty, bytes.count <= 20 * 1024 * 1024,
                  imageMIME((path as NSString).pathExtension) != nil else { throw fail("A backup image is invalid.") }
            try validateRelative(path)
            let normalizedPath = path.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            guard names.insert(normalizedPath).inserted else { throw fail("A backup contains duplicate image paths.") }
            let hash = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            guard image["sha256"] as? String == hash else { throw fail("A backup image failed its integrity check.") }
            if fm.fileExists(atPath: assetsRoot.appendingPathComponent(path).path) {
                guard try Data(contentsOf: safeExisting(path, inside: assetsRoot)) == bytes else { throw fail("A backup image conflicts with an existing local image. Nothing was restored.") }
            }
            assets.append((path, bytes))
        }
        return (restored, histories, assets, payload["createdAt"] as? String ?? "")
    }

    func inspectBackup(_ data: Data) throws -> [String: Any] {
        try initialize()
        let (restored, history, assets, createdAt) = try validatedBackup(data)
        return ["formatVersion": 1, "createdAt": createdAt, "draftCount": restored.drafts.count, "queuedCount": restored.queue.count,
                "categoryCount": restored.categories?.count ?? 0, "templateCount": restored.templates?.count ?? 0, "assetCount": assets.count, "historyCount": history.count, "bytes": data.count,
                "existingDraftCollisions": restored.drafts.filter { path, draft in state.drafts[path] != nil && state.drafts[path]?.rawContent != draft.rawContent }.count]
    }

    func restoreBackup(_ data: Data) throws -> [String: Any] {
        try initialize()
        let (restored, histories, assets, _) = try validatedBackup(data)
        let previous = state
        let mergedLocalTemplates = try mergedTemplates(restored.templates ?? [:])
        let templatesAdded = mergedLocalTemplates.count - (state.templates?.count ?? 0)
        let recovering = needsRestore
        var corruptCheckpoint: String?
        if recovering {
            guard let original = corruptStateBytes, try Data(contentsOf: stateFile) == original else { throw fail("Local storage changed since recovery started. Restart the app before restoring a backup.") }
            let directory = root.appendingPathComponent("recovery", isDirectory: true)
            try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let timestamp = now().replacingOccurrences(of: ":", with: "-")
            let file = directory.appendingPathComponent("\(timestamp)-\(UUID().uuidString).corrupt-state.json")
            try original.write(to: file, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            corruptCheckpoint = file.path
        } else {
            let backupDirectory = root.appendingPathComponent("backups", isDirectory: true)
            try fm.createDirectory(at: backupDirectory, withIntermediateDirectories: true)
            try exportBackup().write(to: backupDirectory.appendingPathComponent("before-import-\(UUID().uuidString).nightingale-backup.json"), options: .atomic)
            try pruneBackups()
        }
        var createdFiles: [URL] = []
        var draftsAdded = 0, versionsAdded = 0
        do {
            try fm.createDirectory(at: assetsRoot, withIntermediateDirectories: true)
            for (path, bytes) in assets where !fm.fileExists(atPath: assetsRoot.appendingPathComponent(path).path) {
                let destination = try safeDestination(path, inside: assetsRoot)
                try bytes.write(to: destination, options: .atomic); createdFiles.append(destination)
            }
            for (path, draft) in restored.drafts {
                if state.drafts[path] == nil && state.queue[path] == nil {
                    state.drafts[path] = draft; draftsAdded += 1
                } else if state.drafts[path]?.rawContent != draft.rawContent {
                    if let file = try archiveContent(path: path, content: draft.rawContent, reason: "imported-conflict") { createdFiles.append(file); versionsAdded += 1 }
                }
            }
            for (path, queued) in restored.queue {
                if state.drafts[path] == nil && state.queue[path] == nil {
                    state.drafts[path] = WriterDraft(rawContent: queued.rawContent, baseBlob: queued.baseBlob, baseContent: queued.baseContent, updatedAt: now()); draftsAdded += 1
                } else if state.drafts[path]?.rawContent != queued.rawContent {
                    if let file = try archiveContent(path: path, content: queued.rawContent, reason: "imported-queued-version") { createdFiles.append(file); versionsAdded += 1 }
                }
            }
            for entry in histories {
                let path = entry["path"] as! String, raw = entry["rawContent"] as! String
                let known = try historyEntries(path: path, includeContent: false)
                if !known.contains(where: { $0["revision"] as? String == digest(raw) }) {
                    if let file = try archiveContent(path: path, content: raw, reason: "imported-history") { createdFiles.append(file); versionsAdded += 1 }
                }
            }
            var categories = state.categories ?? []
            for name in restored.categories ?? [] where !categories.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) { categories.append(name) }
            state.categories = categories
            state.templates = mergedLocalTemplates
            // Existing queue/conflicts/publication status are untouched; imported queues are never activated.
            if recovering {
                guard let original = corruptStateBytes, try Data(contentsOf: stateFile) == original else { throw fail("Unreadable local storage changed during recovery. Nothing was replaced.") }
                state.state = "local"; state.message = "Backup recovered locally. Review drafts before choosing Publish."
                recoveryWriteInProgress = true
            }
            defer { recoveryWriteInProgress = false }
            try persist()
        } catch {
            recoveryWriteInProgress = false
            state = previous
            for file in createdFiles { try? fm.removeItem(at: file) }
            pendingHistoryPrunes.removeAll()
            throw error
        }
        if recovering {
            needsRestore = false; corruptStateBytes = nil
            do { try automaticBackup(force: true); backupWarning = nil }
            catch { backupWarning = "Recovery succeeded, but the automatic backup could not be written." }
        }
        var result = try bootstrap()
        var summary: [String: Any] = ["draftsAdded": draftsAdded, "versionsAdded": versionsAdded, "templatesAdded": templatesAdded, "activeQueueRestored": false]
        if let checkpoint = corruptCheckpoint { summary["corruptStateCheckpoint"] = checkpoint }
        result["backupResult"] = summary
        return result
    }

    private func automaticBackup(force: Bool = false) throws {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyy-MM-dd"
        let directory = root.appendingPathComponent("backups", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(formatter.string(from: Date()) + ".nightingale-backup.json")
        if !force, fm.fileExists(atPath: file.path),
           let modified = try file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
           Date().timeIntervalSince(modified) < 300 { return }
        try exportBackup().write(to: file, options: .atomic)
        try pruneBackups()
    }

    private func pruneBackups() throws {
        let directory = root.appendingPathComponent("backups", isDirectory: true)
        guard fm.fileExists(atPath: directory.path) else { return }
        let files = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])
        let daily = files.filter { $0.lastPathComponent.range(of: "^[0-9]{4}-[0-9]{2}-[0-9]{2}\\.nightingale-backup\\.json$", options: .regularExpression) != nil }.sorted { $0.lastPathComponent > $1.lastPathComponent }
        let imports = files.filter { $0.lastPathComponent.hasPrefix("before-import-") && $0.lastPathComponent.hasSuffix(".nightingale-backup.json") }.sorted {
            ((try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast) > ((try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
        }
        for old in Array(daily.dropFirst(20)) + Array(imports.dropFirst(20)) { try fm.removeItem(at: old) }
    }

    private func validationReport(path: String, raw: String) throws -> [String: Any] {
        guard let validation else { return ["ok": true, "issues": [], "summary": ["documents": 1, "codeBlocks": 0]] }
        let tree = try git(["ls-tree", "-r", "--name-only", remoteRef], at: repository).text.split(separator: "\n").map(String.init)
        let files = Array(Set(tree + referencedStagedAssets(raw) + [path])).sorted()
        var routes = Set(articles.keys.map { articlePath -> String in
            if articlePath == "index.md" { return "/" }
            if articlePath == "404.md" { return "/404.html" }
            return "/" + articlePath.dropFirst("_docs/".count).dropLast(3) + "/"
        })
        routes.insert(path == "index.md" ? "/" : path == "404.md" ? "/404.html" : "/" + path.dropFirst("_docs/".count).dropLast(3) + "/")
        for file in tree where !file.hasPrefix("_") && (file.hasSuffix(".md") || file.hasSuffix(".html")) {
            guard let source = try? git(["show", "\(remoteRef):\(file)"], at: repository).text, source.hasPrefix("---\n"),
                  let end = source.dropFirst(4).range(of: "\n---") else { continue }
            let header = String(source[..<end.lowerBound])
            let explicit = header.split(separator: "\n").first { $0.hasPrefix("permalink:") }.map { String($0.dropFirst("permalink:".count)).trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }
            if let explicit, explicit.hasPrefix("/") { routes.insert(explicit) }
            else if file == "index.md" || file == "index.html" { routes.insert("/") }
            else if file.hasSuffix("/index.md") || file.hasSuffix("/index.html") { routes.insert("/" + (file as NSString).deletingLastPathComponent + "/") }
            else { routes.insert("/" + (file as NSString).deletingPathExtension + "/") }
        }
        return try validation(["schemaVersion": 1, "documents": [["path": path, "rawContent": raw]], "files": files, "routes": routes.sorted(),
                               "site": ["url": "https://nightingalelyy.github.io", "baseurl": ""]])
    }

    private func requireValidPublication(path: String, raw: String) throws {
        let report = try validationReport(path: path, raw: raw)
        guard report["ok"] as? Bool == true else { throw fail("Publication validation failed. Review the article's validation results before publishing.") }
    }

    private func liveURL(_ path: String) -> String {
        let route = path == "index.md" ? "" : path == "404.md" ? "404.html" : String(path.dropFirst("_docs/".count).dropLast(3)) + "/"
        return "https://nightingalelyy.github.io/" + (route.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed.subtracting(CharacterSet(charactersIn: "?#%"))) ?? route)
    }

    private func publicationJSON(path: String) -> [String: Any]? {
        let known = state.publications?[path]
        let sourceHash = articles[path].map { digest($0.rawContent) }
        let record: WriterPublication
        if let known, known.sourceSHA256 == sourceHash || known.status == "uploaded" { record = known }
        else if let sourceHash { record = WriterPublication(sourceSHA256: sourceHash, commit: cachedCommit, status: "unknown", liveURL: liveURL(path), workflowURL: nil, checkedAt: nil, uploadedAt: nil, message: nil) }
        else { return nil }
        var result: [String: Any] = ["path": path, "sourceSHA256": record.sourceSHA256, "status": record.status, "liveURL": record.liveURL]
        if let value = record.commit { result["commit"] = value }
        if let value = record.workflowURL { result["workflowURL"] = value }
        if let value = record.checkedAt { result["checkedAt"] = value }
        if let value = record.uploadedAt { result["uploadedAt"] = value }
        if let value = record.message { result["message"] = value }
        return result
    }

    private func publicationTargets() -> [[String: Any]] {
        Set(articles.keys).union(state.publications?.keys.map { $0 } ?? []).sorted().compactMap { publicationJSON(path: $0) }
    }

    func deploymentTargets() throws -> [String: Any] {
        try initialize()
        var result: [String: Any] = ["targets": publicationTargets()]
        if let cachedCommit { result["remoteCommit"] = cachedCommit }
        return result
    }

    func applyDeploymentStatus(_ report: [String: Any]) throws -> [String: Any] {
        try initialize()
        if needsRestore { return try bootstrap() }
        guard let results = report["results"] as? [[String: Any]], results.count <= 10000 else { throw fail("Invalid deployment report.") }
        var publications = state.publications ?? [:]
        for result in results {
            guard let path = result["path"] as? String, let target = publicationJSON(path: path), let hash = result["sourceSHA256"] as? String,
                  hash == target["sourceSHA256"] as? String, let status = result["status"] as? String,
                  ["uploaded", "building", "live", "failed", "unknown"].contains(status) else { continue }
            if let commit = result["commit"] as? String, let expected = target["commit"] as? String, commit != expected { continue }
            let checkedAt = result["checkedAt"] as? String ?? now()
            if let old = publications[path]?.checkedAt, historyDate(old) > historyDate(checkedAt) { continue }
            let workflow = result["workflowURL"] as? String
            if let workflow, !(workflow.hasPrefix("https://github.com/Nightingalelyy/nightingalelyy.github.io/actions/")) { continue }
            var verifiedURL = liveURL(path)
            if let supplied = result["liveURL"] as? String {
                guard let url = URLComponents(string: supplied), url.scheme == "https", url.host?.lowercased() == "nightingalelyy.github.io", url.user == nil, url.password == nil, url.port == nil || url.port == 443 else { continue }
                verifiedURL = supplied
            }
            publications[path] = WriterPublication(sourceSHA256: hash, commit: target["commit"] as? String, status: status, liveURL: verifiedURL,
                                                   workflowURL: workflow, checkedAt: checkedAt, uploadedAt: target["uploadedAt"] as? String, message: result["message"] as? String)
        }
        state.publications = publications
        try persist(); return try bootstrap()
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
        var result: [String: Any] = ["articles": try paths.map { try articleJSON(path: $0) }, "categories": state.categories ?? [], "templates": templateList(), "status": statusJSON(),
                "repositoryPath": repository.path, "remoteURL": remoteURL, "branch": "main", "publications": publicationTargets(),
                "recovery": ["needsRestore": needsRestore, "message": needsRestore ? state.message : "", "automaticBackupDirectory": root.appendingPathComponent("backups").path, "historyLimitPerArticle": 100]]
        if let warning = backupWarning { result["backupWarning"] = warning }
        return result
    }

    private func articleJSON(path: String) throws -> [String: Any] {
        try validateArticlePath(path)
        guard let raw = state.drafts[path]?.rawContent ?? articles[path]?.rawContent else { throw fail("This article could not be found.") }
        var result: [String: Any] = ["path": path, "rawContent": raw, "revision": digest(raw),
                                    "isDraft": state.drafts[path] != nil, "isQueued": state.queue[path] != nil]
        if let publication = publicationJSON(path: path) {
            var record = publication; record["matchesCurrentRevision"] = record["sourceSHA256"] as? String == digest(raw)
            result["publication"] = record
        }
        if let queue = state.queue[path] { result["queuedRevision"] = digest(queue.rawContent) }
        if let conflict = state.conflicts[path] { result["conflict"] = ["base": conflict.base, "local": conflict.local, "remote": conflict.remote] }
        return result
    }

    private func saveDraft(path: String, raw: String, expected: String) throws -> [String: Any] {
        try validateArticlePath(path); try validateArticleContent(raw)
        guard let current = state.drafts[path]?.rawContent ?? articles[path]?.rawContent else { throw fail("Create the article before saving changes.") }
        guard digest(current) == expected else { throw fail("This article changed since it was opened. Reload it before saving, so neither version is overwritten.") }
        if raw != current { try archiveContent(path: path, content: current, reason: "autosave", coalesce: true) }
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
                try requireValidPublication(path: path, raw: snapshot.rawContent)
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
            state.state = "synced"; state.message = published > 0 ? "Uploaded to GitHub. Website deployment is awaiting verification." : "Everything is up to date."
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
        let uploadedCommit = try git(["rev-parse", "HEAD"], at: directory).text.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try git(["push", "origin", "HEAD:refs/heads/main"], at: directory, network: true)
        var publications = state.publications ?? [:]
        publications[path] = WriterPublication(sourceSHA256: digest(snapshot.rawContent), commit: uploadedCommit, status: "uploaded", liveURL: liveURL(path), workflowURL: nil, checkedAt: nil, uploadedAt: now(), message: "Uploaded to GitHub; website deployment is not yet verified.")
        state.publications = publications
        try persist()
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
        do { try automaticBackup(); backupWarning = nil }
        catch { backupWarning = "The image is saved locally, but the automatic backup could not be written." }
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
