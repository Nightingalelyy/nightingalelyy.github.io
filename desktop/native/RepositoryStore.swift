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

private struct WriterLocalRemoval: Codable {
    var expectedRevision: String
    var sourceSHA256: String
    var expectedRemoteBlob: String
    var liveURL: String
    var removedAt: String
    var title: String?
    var draft: WriterDraft?
}

private struct WriterDeletion: Codable {
    var sourceSHA256: String
    var commit: String
    var status: String
    var liveURL: String
    var uploadedAt: String
    var workflowURL: String?
    var checkedAt: String?
    var message: String?
}

private struct WriterDeletionIntent: Codable {
    var commit: String
    var parentCommit: String
    var sourceSHA256: String
    var expectedRevision: String
    var remoteBlob: String
    var liveURL: String
    var createdAt: String
    var retainedRef: String
}

private struct WriterTemplate: Codable {
    var id: String
    var name: String
    var rawContent: String
    var updatedAt: String?
    var importedFromID: String? = nil
}

private struct WriterPrivateSyncConflict: Codable {
    var base: WriterDraft?
    var remote: WriterDraft
    var remoteRevision: String
}

private struct WriterPrivateSync: Codable {
    var enabled = false
    // Optional for storage written before automatic private sync existed.
    var autoSyncEnabled: Bool?
    var repository: String?
    var status = "disabled"
    var message = "Private draft sync is disconnected. Writing and website publishing still work normally."
    var lastSyncedAt: String?
    var bases: [String: WriterDraft] = [:]
    var conflicts: [String: WriterPrivateSyncConflict] = [:]
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
    var localRemovals: [String: WriterLocalRemoval]?
    var deletions: [String: WriterDeletion]?
    var deletionIntents: [String: WriterDeletionIntent]?
    var privateSync: WriterPrivateSync?
    var state = "ready"
    var message = "Ready to write offline."
    var lastSyncedAt: String?
}

private struct PrivateSyncCapture {
    let state: WriterState
    let articles: [String: RepositoryArticle]
    let commit: String?
}

struct PrivateAutoSyncPlan {
    let token: String
    fileprivate let sequence: UInt64
    fileprivate let repository: String
    fileprivate let capture: PrivateSyncCapture
    fileprivate let protectedPaths: Set<String>
}

struct PrivateAutoSyncResult {
    let token: String
    fileprivate let plan: PrivateAutoSyncPlan
    fileprivate let drafts: [String: WriterDraft]
    fileprivate let assets: [String: Data]
    fileprivate let failure: String?
    fileprivate let hasRemoteProof: Bool
    fileprivate let didWrite: Bool
}

private final class PrivateAutoAuthorization {
    private let lock = NSLock()
    private var sequence: UInt64 = 0
    private var token: String?
    private var working = false
    func begin(_ token: String) -> UInt64 { lock.lock(); defer { lock.unlock() }; sequence &+= 1; self.token = token; return sequence }
    @discardableResult func invalidate() -> UInt64 { lock.lock(); defer { lock.unlock() }; sequence &+= 1; token = nil; return sequence }
    func permits(_ plan: PrivateAutoSyncPlan) -> Bool { lock.lock(); defer { lock.unlock() }; return token == plan.token && sequence == plan.sequence }
    func start(_ plan: PrivateAutoSyncPlan) -> Bool { lock.lock(); defer { lock.unlock() }; guard !working, token == plan.token, sequence == plan.sequence else { return false }; working = true; return true }
    func stop() { lock.lock(); working = false; lock.unlock() }
    var isWorking: Bool { lock.lock(); defer { lock.unlock() }; return working }
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

/// Storage methods run on one serial queue. runPrivateAutoSync is the sole
/// exception: it uses an immutable capture and locked authorization on a separate
/// network worker. The user's development checkout is never modified.
final class RepositoryStore {
    static let productionRemote = "https://github.com/Nightingalelyy/nightingalelyy.github.io.git"
    private let root: URL
    private let remoteURL: String
    private let seedRepo: URL?
    private let identity: (name: String, email: String)?
    private let validation: (([String: Any]) throws -> [String: Any])?
    private let draftTransport: PrivateDraftTransport
    private let privateAutoAuthorization = PrivateAutoAuthorization()
    private var activePrivateAutoToken: String?
    private var latestPrivateAutoCompletion: UInt64 = 0
    private var lastPrivateAutoCheckedAt: String?
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
         validation: (([String: Any]) throws -> [String: Any])? = nil, draftTransport: PrivateDraftTransport? = nil) {
        self.root = root.standardizedFileURL
        self.remoteURL = remoteURL
        self.seedRepo = seedRepo
        self.identity = identity
        self.validation = validation
        self.draftTransport = draftTransport ?? PrivateDraftGitHubTransport(root: root.appendingPathComponent("private-sync-cache", isDirectory: true))
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
        if needsRestore && method == "syncPrivateDrafts" && params["automatic"] as? Bool == true { return try bootstrap() }
        if needsRestore && !["bootstrap", "status", "listArticles", "readArticle", "listHistory", "readHistory", "readAsset", "listTemplates", "privateSyncStatus"].contains(method) {
            throw fail("Local draft storage needs recovery. Restore a valid backup before editing or publishing.")
        }
        switch method {
        case "bootstrap", "status", "listArticles", "privateSyncStatus": return try bootstrap()
        case "configurePrivateSync": return try configurePrivateSync(params)
        case "syncPrivateDrafts":
            guard params["automatic"] as? Bool != true else { throw fail("Automatic private sync must use the background begin/run/finish lifecycle.") }
            return try syncPrivateDrafts()
        case "setPrivateAutoSync": return try setPrivateAutoSync(params)
        case "cancelPrivateAutoSync": return try cancelPrivateAutoSync()
        case "resolvePrivateSyncConflict": return try resolvePrivateSyncConflict(params)
        case "disconnectPrivateSync":
            if var sync = state.privateSync {
                privateAutoAuthorization.invalidate(); activePrivateAutoToken = nil
                sync.enabled = false; sync.autoSyncEnabled = false
                sync.status = sync.conflicts.isEmpty ? "disabled" : "conflict"
                sync.message = "Private draft sync disconnected. Local drafts, shared copies, and unresolved versions are preserved."
                state.privateSync = sync; try persist()
            }
            return try bootstrap()
        case "removeLocally": return try removeLocally(params)
        case "restoreLocalRemoval": return try restoreLocalRemoval(params)
        case "prepareDeletion": return try prepareDeletion(params)
        case "deleteArticle": return try deleteArticle(params)
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
            guard state.queue[path] == nil, state.deletionIntents?[path] == nil else { throw fail("Cancel queued publication and settle pending deletion status before restoring a version.") }
            let entry = try historyEntry(path: path, id: string(params, "id"))
            let content = entry["rawContent"] as! String
            if let current = state.drafts[path]?.rawContent ?? articles[path]?.rawContent {
                guard params["expectedRevision"] as? String == digest(current) else { throw fail("The article changed. Reload it before restoring a version.") }
                try archiveContent(path: path, content: current, reason: "before-restore")
            } else if params["expectedRevision"] != nil { throw fail("This article no longer exists. Reload its history before restoring.") }
            try automaticBackup(force: true)
            state.drafts[path] = WriterDraft(rawContent: content, baseBlob: articles[path]?.blob, baseContent: articles[path]?.rawContent, updatedAt: now())
            state.conflicts.removeValue(forKey: path)
            state.localRemovals?.removeValue(forKey: path)
            state.state = "local"; state.message = "Version restored locally. Choose Publish when ready."
            try persist(); return try bootstrap()
        case "readArticle": return try articleJSON(path: string(params, "path"))
        case "saveDraft":
            return try saveDraft(path: string(params, "path"), raw: string(params, "rawContent"),
                                 expected: string(params, "expectedRevision"))
        case "createArticle":
            let path = try string(params, "path")
            try validateArticlePath(path, creating: true)
            guard articles[path] == nil, state.drafts[path] == nil, state.localRemovals?[path] == nil, state.deletionIntents?[path] == nil else { throw fail("An article already exists at this path. Choose another filename.") }
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
            guard state.deletionIntents?[path] == nil, state.localRemovals?[path] == nil else { throw fail("Restore the locally removed item and settle any deletion status before publishing.") }
            guard let draft = state.drafts[path] else { throw fail("There are no local changes to publish for this article.") }
            guard state.conflicts[path] == nil, state.privateSync?.conflicts[path] == nil else { throw fail("Resolve website and private draft conflicts before publishing this article.") }
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
        case "processQueue":
            let selected = params["path"] as? String
            if let selected {
                try validateArticlePath(selected)
                guard let queued = state.queue[selected], params["expectedQueuedRevision"] as? String == digest(queued.rawContent) else { throw fail("The queued version changed. Review this article before publishing it.") }
            }
            return try processQueue(path: selected)
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

    private func deletionIssue(_ path: String, _ code: String, _ message: String) -> [String: Any] {
        ["severity": "error", "path": path, "code": code, "message": message]
    }

    private func localRemovalJSON(path: String, record: WriterLocalRemoval) -> [String: Any] {
        var result: [String: Any] = ["path": path, "scope": "published", "status": "local", "expectedRevision": record.expectedRevision,
            "sourceSHA256": record.sourceSHA256, "expectedRemoteBlob": record.expectedRemoteBlob, "liveURL": record.liveURL,
            "removedAt": record.removedAt, "message": "Removed from this app. The GitHub source is unchanged; a separate confirmation is required to delete it."]
        if let title = record.title { result["title"] = title }
        return result
    }

    private func removeLocally(_ params: [String: Any]) throws -> [String: Any] {
        guard params["confirmation"] as? String == "REMOVE" else { throw fail("Confirm removal from the app before continuing.") }
        let path = try string(params, "path"); try validateArticlePath(path)
        guard state.localRemovals?[path] == nil, state.deletionIntents?[path] == nil else { throw fail("This removal is already pending. Review its existing status.") }
        guard state.queue[path] == nil, state.conflicts[path] == nil else { throw fail("Cancel queued publication and resolve conflicts before removing this article.") }
        guard let raw = state.drafts[path]?.rawContent ?? articles[path]?.rawContent,
              params["expectedRevision"] as? String == digest(raw) else { throw fail("This article changed. Reload it before removing it.") }
        let draft = state.drafts[path], remote = articles[path]
        if let remote, let draft, draft.baseBlob != remote.blob { throw fail("The online source changed since this draft began. Resolve that change before removing the article.") }
        guard remote != nil || draft?.baseBlob == nil else { throw fail("The remote article is no longer cached. Refresh before deciding how to remove this draft.") }
        try automaticBackup(force: true)
        let previous = state
        var archived: [URL] = []
        do {
            if let file = try archiveContent(path: path, content: raw, reason: "before-local-removal") { archived.append(file) }
            if let remote, remote.rawContent != raw, let file = try archiveContent(path: path, content: remote.rawContent, reason: "published-before-local-removal") { archived.append(file) }
            state.drafts.removeValue(forKey: path)
            var result: [String: Any]
            if let remote {
                let title = (params["title"] as? String).map { String($0.prefix(300)) }
                let record = WriterLocalRemoval(expectedRevision: digest(raw), sourceSHA256: digest(remote.rawContent), expectedRemoteBlob: remote.blob,
                    liveURL: publicationJSON(path: path)?["liveURL"] as? String ?? liveURL(path), removedAt: now(), title: title, draft: draft)
                var removals = state.localRemovals ?? [:]; removals[path] = record; state.localRemovals = removals
                result = localRemovalJSON(path: path, record: record)
            } else {
                result = ["path": path, "scope": "local", "status": "deleted", "expectedRevision": digest(raw), "expectedRemoteBlob": "", "sourceSHA256": digest(raw), "removedAt": now(),
                          "message": "Local draft removed. GitHub was not changed; its source remains available in History."]
            }
            state.message = result["message"] as! String
            try persist()
            var snapshot = try bootstrap(); snapshot["localRemoval"] = result; return snapshot
        } catch {
            state = previous
            for file in archived { try? fm.removeItem(at: file) }
            pendingHistoryPrunes.removeAll()
            throw error
        }
    }

    private func restoreLocalRemoval(_ params: [String: Any]) throws -> [String: Any] {
        let path = try string(params, "path"); try validateArticlePath(path)
        guard state.deletionIntents?[path] == nil else { throw fail("A GitHub deletion is awaiting confirmation. Refresh its status before restoring locally.") }
        guard let record = state.localRemovals?[path] else { throw fail("This article is not locally removed.") }
        guard record.draft != nil || articles[path] != nil else { throw fail("The online source is no longer present. Restore its saved version from History.") }
        try automaticBackup(force: true)
        if let draft = record.draft { state.drafts[path] = draft }
        state.localRemovals?.removeValue(forKey: path)
        state.message = "Restored in this app. GitHub was not changed."
        try persist(); return try bootstrap()
    }

    private func prepareDeletion(_ params: [String: Any]) throws -> [String: Any] {
        let path = try string(params, "path"); try validateArticlePath(path)
        let suppliedRevision = try string(params, "expectedRevision")
        var issues: [[String: Any]] = []
        guard var removal = state.localRemovals?[path] else {
            let local = state.drafts[path]
            let isLocal = local != nil && local?.baseBlob == nil && articles[path] == nil
            return ["path": path, "scope": isLocal ? "local" : "published", "expectedRevision": suppliedRevision, "expectedRemoteBlob": "", "canDelete": false,
                    "issues": [deletionIssue(path, "remove_locally_first", "Remove this item from the app first. Deleting its GitHub source requires a second confirmation.")], "liveURL": liveURL(path)]
        }
        var plan: [String: Any] = ["path": path, "scope": "published", "expectedRevision": removal.expectedRevision,
            "expectedRemoteBlob": removal.expectedRemoteBlob, "liveURL": removal.liveURL]
        do { try fetch() }
        catch {
            plan["canDelete"] = false; plan["issues"] = [deletionIssue(path, "offline", "Connect to GitHub to review deletion. Deletions are never queued for automatic retry.")]
            return try deletionPlanSnapshot(plan)
        }
        let pendingIntent = state.deletionIntents?[path]
        if let pendingIntent {
            plan["retrying"] = true
            if cachedCommit != pendingIntent.parentCommit || articles[path]?.blob != pendingIntent.remoteBlob {
                issues.append(deletionIssue(path, "deletion_pending", "The earlier deletion has not been settled and the remote source differs. Refresh its status before another decision."))
            }
            if params["renewReview"] as? Bool == true {
                issues.append(deletionIssue(path, "deletion_pending", "An uncertain attempt must retain its original reviewed source. Review that attempt again instead."))
            }
        }
        if state.queue[path] != nil || state.conflicts[path] != nil { issues.append(deletionIssue(path, "pending_work", "Cancel queued publication and resolve conflicts before deleting the GitHub source.")) }
        guard let remote = articles[path] else {
            plan["canDelete"] = false; plan["issues"] = issues + [deletionIssue(path, "source_missing", "The source is no longer present on GitHub. Refresh deletion status or recover its local version from History.")]
            return try deletionPlanSnapshot(plan)
        }
        let remoteHash = digest(remote.rawContent)
        if params["renewReview"] as? Bool == true && pendingIntent == nil {
            guard suppliedRevision == remoteHash else {
                plan["canDelete"] = false; plan["latestRevision"] = remoteHash; plan["canReviewLatest"] = true
                plan["issues"] = [deletionIssue(path, "remote_changed", "The remote source changed again. Review its latest version before confirming deletion.")]
                return try deletionPlanSnapshot(plan)
            }
            removal.expectedRemoteBlob = remote.blob; removal.sourceSHA256 = remoteHash; removal.expectedRevision = remoteHash
            state.localRemovals?[path] = removal
            do { try persist() }
            catch {
                plan["canDelete"] = false
                plan["issues"] = [deletionIssue(path, "storage_failed", "The renewed review could not be saved on this Mac. Check local storage and review again.")]
                return try deletionPlanSnapshot(plan)
            }
            plan["expectedRemoteBlob"] = removal.expectedRemoteBlob; plan["expectedRevision"] = removal.expectedRevision
        } else if suppliedRevision != removal.expectedRevision {
            issues.append(deletionIssue(path, "stale_revision", "This removal review is stale. Open a new deletion review."))
        }
        if remote.blob != removal.expectedRemoteBlob {
            issues.append(deletionIssue(path, "remote_changed", "This source changed on GitHub after local removal. Review the latest source before deleting it."))
            plan["latestRevision"] = remoteHash; plan["canReviewLatest"] = true
        }
        if issues.isEmpty {
            do {
                let report = try remainingSourceValidation(deleting: path)
                let validationIssues = report["issues"] as? [[String: Any]] ?? []
                issues += validationIssues
                if report["ok"] as? Bool != true && !validationIssues.contains(where: { $0["severity"] as? String == "error" }) {
                    issues.append(deletionIssue(path, "validation_failed", "Remaining site sources failed validation."))
                }
            } catch { issues.append(deletionIssue(path, "validation_unavailable", "The remaining site sources could not be validated. Nothing was deleted.")) }
        }
        plan["canDelete"] = !issues.contains { $0["severity"] as? String == "error" }
        plan["issues"] = issues
        return try deletionPlanSnapshot(plan)
    }

    private func deletionPlanSnapshot(_ plan: [String: Any]) throws -> [String: Any] {
        var result = plan
        result["snapshot"] = try bootstrap()
        return result
    }

    private func remainingSourceValidation(deleting path: String) throws -> [String: Any] {
        guard let validation else { return ["ok": true, "issues": []] }
        let tree = try git(["ls-tree", "-r", "--name-only", "-z", remoteRef], at: repository).text.split(separator: "\0").map(String.init)
        let files = tree.filter { $0 != path }
        var documents = articles.filter { $0.key != path }.map { ["path": $0.key, "rawContent": $0.value.rawContent] }
        let editable = Set(documents.compactMap { $0["path"] })
        var routedDocuments = documents
        for file in files where !editable.contains(file) && !file.hasPrefix("_") && (file.hasSuffix(".md") || file.hasSuffix(".html")) {
            guard let raw = try? git(["show", "\(remoteRef):\(file)"], at: repository).text,
                  raw.hasPrefix("---\n") || raw.hasPrefix("---\r\n") else { continue }
            if file == "admin/index.md" { documents.append(["path": file, "rawContent": raw]) }
            routedDocuments.append(["path": file, "rawContent": raw])
        }
        var routes = Set<String>()
        for document in routedDocuments {
            let file = document["path"]!, raw = document["rawContent"]!
            let opening = raw.firstIndex(of: "\n")!
            let end = raw.range(of: "(?m)^---[\\t ]*\\r?(?:\\n|$)", options: .regularExpression, range: raw.index(after: opening)..<raw.endIndex)
            let header = end.map { String(raw[..<$0.lowerBound]) } ?? ""
            let explicit = header.split(separator: "\n").first { $0.hasPrefix("permalink:") }.map { String($0.dropFirst(10)).trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "\"'")) }
            if let explicit, explicit.hasPrefix("/") { routes.insert(explicit) }
            else if file == "index.md" || file == "index.html" { routes.insert("/") }
            else if file == "404.md" { routes.insert("/404.html") }
            else if file.hasPrefix("_docs/") { routes.insert("/" + file.dropFirst(6).dropLast(3) + "/") }
            else if file.hasSuffix("/index.md") || file.hasSuffix("/index.html") { routes.insert("/" + (file as NSString).deletingLastPathComponent + "/") }
            else { routes.insert("/" + (file as NSString).deletingPathExtension + "/") }
        }
        return try validation(["schemaVersion": 1, "documents": documents.sorted { $0["path"]! < $1["path"]! }, "files": files, "routes": routes.sorted(),
                               "site": ["url": "https://nightingalelyy.github.io", "baseurl": ""]])
    }

    private func deletionResponse(path: String, status: String, message: String, commit: String? = nil, issues: [[String: Any]] = []) throws -> [String: Any] {
        var result = try bootstrap()
        var deletion: [String: Any] = ["path": path, "scope": "published", "status": status, "message": message, "issues": issues]
        if let commit { deletion["commit"] = commit }
        result["deletion"] = deletion
        return result
    }

    private func deleteArticle(_ params: [String: Any]) throws -> [String: Any] {
        guard params["confirmation"] as? String == "DELETE" else { throw fail("A second explicit DELETE confirmation is required to erase the GitHub source.") }
        let path = try string(params, "path"); try validateArticlePath(path)
        guard params["scope"] as? String == "published", state.localRemovals?[path] != nil else { throw fail("Remove the item locally, then review and separately confirm its GitHub deletion.") }
        let plan = try prepareDeletion(["path": path, "expectedRevision": try string(params, "expectedRevision")])
        var issues = plan["issues"] as? [[String: Any]] ?? []
        if params["expectedRemoteBlob"] as? String != plan["expectedRemoteBlob"] as? String { issues.append(deletionIssue(path, "stale_remote_blob", "The remote deletion review is stale. Review the current source again.")) }
        guard plan["canDelete"] as? Bool == true, !issues.contains(where: { $0["severity"] as? String == "error" }),
              let removal = state.localRemovals?[path], let remote = articles[path], let parent = cachedCommit else {
            return try deletionResponse(path: path, status: "failed", message: "Deletion was blocked. The item remains locally removed and its GitHub source was not erased by this request.", issues: issues)
        }
        let retryIntent = state.deletionIntents?[path]
        do {
            guard retryIntent != nil || (state.deletionIntents?.count ?? 0) < 20 else { throw fail("Refresh pending deletion confirmations before starting another deletion.") }
            try automaticBackup(force: true)
            try archiveContent(path: path, content: remote.rawContent, reason: "before-repository-deletion")
            if let draft = removal.draft, draft.rawContent != remote.rawContent { try archiveContent(path: path, content: draft.rawContent, reason: "unpublished-before-repository-deletion") }
            let directory = root.appendingPathComponent("delete-\(UUID().uuidString)", isDirectory: true)
            defer { try? fm.removeItem(at: directory) }
            _ = try git(["clone", "--no-checkout", "--no-hardlinks", "--", repository.path, directory.path])
            _ = try git(["remote", "set-url", "origin", remoteURL], at: directory)
            let commit: String
            if let intent = retryIntent {
                guard parent == intent.parentCommit, remote.blob == intent.remoteBlob, removal.expectedRevision == intent.expectedRevision else {
                    throw fail("The earlier deletion no longer matches the reviewed source. Refresh before retrying.")
                }
                // Reuse the exact retained commit. This remains idempotent if the first push was accepted late.
                let changed = try git(["diff", "--name-only", "-z", intent.parentCommit, intent.commit], at: repository).text.split(separator: "\0").map(String.init)
                let actualParent = try git(["rev-parse", "\(intent.commit)^"], at: repository).text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard changed == [path], actualParent == intent.parentCommit,
                      (try? git(["cat-file", "-e", "\(intent.commit):\(path)"], at: repository)) == nil else {
                    throw fail("The retained deletion does not match its original source. No retry was pushed.")
                }
                _ = try git(["fetch", "--no-tags", repository.path, intent.retainedRef], at: directory)
                _ = try git(["checkout", "--detach", intent.commit], at: directory)
                commit = intent.commit
            } else {
                _ = try git(["checkout", "--detach", parent], at: directory)
                let name = identity?.name ?? ((try? git(["config", "--get", "user.name"], at: repository).text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? "")
                let email = identity?.email ?? ((try? git(["config", "--get", "user.email"], at: repository).text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? "")
                guard !name.isEmpty, !email.isEmpty else { throw fail("Git author identity is missing. No deletion was pushed.") }
                _ = try git(["config", "user.name", name], at: directory); _ = try git(["config", "user.email", email], at: directory)
                _ = try git(["--literal-pathspecs", "rm", "--", path], at: directory)
                _ = try git(["-c", "commit.gpgsign=false", "commit", "-m", "Delete \((path as NSString).lastPathComponent) via Nightingale Writer"], at: directory)
                commit = try git(["rev-parse", "HEAD"], at: directory).text.trimmingCharacters(in: .whitespacesAndNewlines)
                let changed = try git(["diff", "--name-only", "-z", parent, commit], at: directory).text.split(separator: "\0").map(String.init)
                guard changed == [path], (try? git(["cat-file", "-e", "\(commit):\(path)"], at: directory)) == nil else {
                    throw fail("The prepared commit changes more than the selected source. No deletion was pushed.")
                }
                let retainedRef = "refs/nightingale/deletions/\(UUID().uuidString.lowercased())"
                _ = try git(["fetch", "--no-tags", directory.path, "+HEAD:\(retainedRef)"], at: repository)
                var intents = state.deletionIntents ?? [:]
                intents[path] = WriterDeletionIntent(commit: commit, parentCommit: parent, sourceSHA256: digest(remote.rawContent), expectedRevision: removal.expectedRevision,
                    remoteBlob: remote.blob, liveURL: removal.liveURL, createdAt: now(), retainedRef: retainedRef)
                state.deletionIntents = intents
                state.state = "unknown"
                state.message = "GitHub deletion requested. Its result has not been confirmed. No automatic retry will occur."
                // Durable intent is written before the irreversible push, and is never an execution queue.
                do { try persist() }
                catch { _ = try? git(["update-ref", "-d", retainedRef], at: repository); throw error }
            }
            do { _ = try git(["push", "origin", "HEAD:refs/heads/main"], at: directory, network: true) }
            catch {
                // Even a failed connection may have delivered the push. Only ancestry can settle it.
                try? fetch()
                if state.deletions?[path] != nil { return try deletionResponse(path: path, status: "uploaded", message: "The GitHub source was erased. Website removal is awaiting deployment verification.", commit: commit) }
                if state.deletionIntents?[path] == nil { return try deletionResponse(path: path, status: "failed", message: "GitHub now has a different revision. The item remains locally removed; review the current source before trying again.") }
                return try deletionResponse(path: path, status: "unknown", message: "Remote deletion could not be confirmed. Refresh to check it; this operation will never retry automatically.", commit: commit)
            }
            do {
                _ = try git(["fetch", "--no-tags", directory.path, "+HEAD:\(remoteRef)"], at: repository)
                try reloadArticles(); try reconcileDeletionIntents()
                return try deletionResponse(path: path, status: "uploaded", message: "The GitHub source was erased. Website removal is awaiting deployment verification.", commit: commit)
            } catch {
                return try deletionResponse(path: path, status: "unknown", message: "GitHub accepted the deletion, but its local status could not be saved. Refresh to reconcile it; no deletion will be retried automatically.", commit: commit)
            }
        } catch {
            let uncertain = state.deletionIntents?[path] != nil
            return try deletionResponse(path: path, status: uncertain ? "unknown" : "failed",
                message: "This deletion attempt could not be prepared or saved. No new deletion request was sent. " + error.localizedDescription,
                issues: [deletionIssue(path, "preparation_failed", error.localizedDescription)])
        }
    }

    private func isKnownDescendant(_ commit: String, of ancestor: String) -> Bool {
        guard commit.range(of: "^[0-9a-f]{40,64}$", options: .regularExpression) != nil,
              ancestor.range(of: "^[0-9a-f]{40,64}$", options: .regularExpression) != nil else { return false }
        return (try? git(["merge-base", "--is-ancestor", ancestor, commit], at: repository)) != nil
    }

    private func reconcileDeletionIntents(persistChanges: Bool = true) throws {
        guard let head = cachedCommit, !needsRestore else { return }
        var changed = false, releaseRefs: [String] = []
        for (path, intent) in state.deletionIntents ?? [:] {
            if isKnownDescendant(head, of: intent.commit) {
                if articles[path] == nil {
                    var records = state.deletions ?? [:]
                    records[path] = WriterDeletion(sourceSHA256: intent.sourceSHA256, commit: intent.commit, status: "uploaded", liveURL: intent.liveURL,
                        uploadedAt: intent.createdAt, workflowURL: nil, checkedAt: nil, message: "GitHub source erased; website removal is awaiting verification.")
                    state.deletions = records
                    state.state = "synced"
                    state.message = "The GitHub source was erased. Website removal is awaiting deployment verification."
                    state.publications?.removeValue(forKey: path)
                    state.localRemovals?.removeValue(forKey: path)
                    if let newer = state.drafts[path] { state.drafts[path] = WriterDraft(rawContent: newer.rawContent, baseBlob: nil, baseContent: nil, updatedAt: newer.updatedAt) }
                } else {
                    // The source was deliberately recreated after the deletion commit.
                    state.deletions?.removeValue(forKey: path)
                    state.state = "ready"
                    state.message = "The source is present again on GitHub. Review its latest version before another deletion."
                }
                state.deletionIntents?.removeValue(forKey: path); releaseRefs.append(intent.retainedRef); changed = true
            } else if head != intent.parentCommit && isKnownDescendant(head, of: intent.parentCommit) {
                // Another remote commit won the race. No automatic rebase or retry is allowed.
                state.deletionIntents?.removeValue(forKey: path); releaseRefs.append(intent.retainedRef); changed = true
                state.state = "ready"
                state.message = "GitHub now has a different revision. Review the locally removed source before trying again."
            }
        }
        for (path, deletion) in state.deletions ?? [:] where articles[path] != nil && isKnownDescendant(head, of: deletion.commit) {
            state.deletions?.removeValue(forKey: path); changed = true
        }
        if !(state.deletionIntents ?? [:]).isEmpty {
            let pendingMessage = "GitHub deletion requested. Its result has not been confirmed. No automatic retry will occur."
            if state.state != "unknown" || state.message != pendingMessage {
                state.state = "unknown"; state.message = pendingMessage; changed = true
            }
        }
        if changed {
            pruneDeletionRecords()
            if persistChanges { try persist() }
            for ref in releaseRefs { _ = try? git(["update-ref", "-d", ref], at: repository) }
        }
    }

    private func pruneDeletionRecords() {
        let records = state.deletions ?? [:]
        let pending = records.filter { ["uploaded", "building"].contains($0.value.status) }
        let finished = records.filter { !["uploaded", "building"].contains($0.value.status) }.sorted { $0.value.uploadedAt > $1.value.uploadedAt }
        var kept = pending
        for (path, record) in finished.prefix(max(0, 20 - pending.count)) { kept[path] = record }
        state.deletions = kept
    }

    private func deletionRows(includeLocal: Bool) -> [[String: Any]] {
        var rows: [String: [String: Any]] = [:]
        if includeLocal {
            for (path, removal) in state.localRemovals ?? [:] { rows[path] = localRemovalJSON(path: path, record: removal) }
        }
        for (path, record) in state.deletions ?? [:] {
            var row: [String: Any] = ["operation": "delete", "path": path, "scope": "published", "sourceSHA256": record.sourceSHA256, "commit": record.commit,
                "status": record.status, "liveURL": record.liveURL, "uploadedAt": record.uploadedAt]
            if let value = record.workflowURL { row["workflowURL"] = value }
            if let value = record.checkedAt { row["checkedAt"] = value }
            if let value = record.message { row["message"] = value }
            rows[path] = row
        }
        for (path, intent) in state.deletionIntents ?? [:] {
            rows[path] = ["operation": "delete", "path": path, "scope": "published", "sourceSHA256": intent.sourceSHA256, "commit": intent.commit,
                "status": "unknown", "expectedRevision": intent.expectedRevision, "expectedRemoteBlob": intent.remoteBlob, "liveURL": intent.liveURL, "uploadedAt": intent.createdAt,
                "message": "Remote deletion confirmation pending. Refresh to verify; no automatic retry will occur."]
        }
        return rows.values.sorted { ($0["uploadedAt"] as? String ?? $0["removedAt"] as? String ?? "") > ($1["uploadedAt"] as? String ?? $1["removedAt"] as? String ?? "") }
    }

    private func applyDeletionStatus(_ result: [String: Any]) throws {
        guard let path = result["path"] as? String, var record = state.deletions?[path],
              result["sourceSHA256"] as? String == record.sourceSHA256, result["commit"] as? String == record.commit,
              let status = result["status"] as? String, ["uploaded", "building", "deleted", "failed"].contains(status) else { return }
        let checkedAt = result["checkedAt"] as? String ?? now()
        if let previous = record.checkedAt, historyDate(previous) > historyDate(checkedAt) { return }
        if status == "deleted" {
            guard articles[path] == nil, let manifest = result["manifestCommit"] as? String, isKnownDescendant(manifest, of: record.commit) else { return }
        }
        if let workflow = result["workflowURL"] as? String {
            guard workflow.hasPrefix("https://github.com/Nightingalelyy/nightingalelyy.github.io/actions/") else { return }
            record.workflowURL = workflow
        }
        record.status = status; record.checkedAt = checkedAt; record.message = result["message"] as? String
        state.deletions?[path] = record; pruneDeletionRecords()
    }

    private let maxPrivateSyncBytes = 64 * 1024 * 1024

    private func privateDraftIdentity(_ draft: WriterDraft) throws -> String {
        let object: [String: Any] = ["rawContent": draft.rawContent, "baseBlob": draft.baseBlob as Any? ?? NSNull(), "baseContent": draft.baseContent as Any? ?? NSNull()]
        return SHA256.hash(data: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])).map { String(format: "%02x", $0) }.joined()
    }

    private func privateSyncJSON() -> [String: Any] {
        let sync = state.privateSync ?? WriterPrivateSync()
        let conflicts: [[String: Any]] = sync.conflicts.keys.sorted().compactMap { path in
            guard let conflict = sync.conflicts[path] else { return nil }
            let local = state.drafts[path]
            return ["path": path, "local": local?.rawContent as Any? ?? NSNull(), "remote": conflict.remote.rawContent,
                    "base": conflict.base?.rawContent as Any? ?? NSNull(), "localRevision": local.map { digest($0.rawContent) } ?? "",
                    "remoteRevision": conflict.remoteRevision]
        }
        var result: [String: Any] = ["enabled": sync.enabled, "autoSyncEnabled": sync.autoSyncEnabled ?? false,
                                   "autoSyncInProgress": activePrivateAutoToken != nil || privateAutoAuthorization.isWorking, "state": sync.status, "message": sync.message,
                                   "conflicts": conflicts, "draftCount": state.drafts.count]
        if sync.enabled && sync.status == "synced", state.drafts.contains(where: { path, draft in
            guard let base = sync.bases[path] else { return true }
            return (try? privateDraftIdentity(draft)) != (try? privateDraftIdentity(base))
        }) {
            result["state"] = "ready"; result["message"] = "Local draft edits are waiting for private sync. Website publishing is separate."
        }
        if let repository = sync.repository { result["repository"] = repository }
        if let checked = lastPrivateAutoCheckedAt { result["lastAutoCheckedAt"] = checked }
        if let time = sync.lastSyncedAt { result["lastSyncedAt"] = time }
        return result
    }

    private func configurePrivateSync(_ params: [String: Any]) throws -> [String: Any] {
        guard params["confirmation"] as? String == "CONNECT" else { throw fail("Confirm connecting to the private draft repository first.") }
        let repository = try PrivateDraftGitHubTransport.canonicalRepository(string(params, "repository"))
        var sync = state.privateSync ?? WriterPrivateSync()
        if sync.repository?.lowercased() != repository.lowercased() {
            guard sync.conflicts.isEmpty else { throw fail("Resolve private draft conflicts before connecting a different repository.") }
            sync = WriterPrivateSync(); lastPrivateAutoCheckedAt = nil
        }
        privateAutoAuthorization.invalidate(); activePrivateAutoToken = nil
        try draftTransport.verify(repository: repository)
        sync.enabled = true; sync.repository = repository
        sync.status = sync.conflicts.isEmpty ? "ready" : "conflict"
        sync.message = "Connected to private draft storage. Choose Sync drafts to transfer local work. Website publishing is separate."
        state.privateSync = sync
        try persist(); return try bootstrap()
    }

    // Internal for isolated parser tests. It never initializes storage or uses the network.
    func privateAssetPaths(_ raw: String) throws -> [String] {
        var units = Array(raw.utf16)
        var remainingWork = units.count * 8 + 1024
        func spendWork() throws {
            remainingWork -= 1
            guard remainingWork >= 0 else { throw fail("Draft image references are too complex to scan safely. Simplify unmatched brackets or backticks before syncing.") }
        }
        func text() -> String { String(decoding: units, as: UTF16.self) }
        func matches(_ pattern: String, in source: String) throws -> [NSTextCheckingResult] {
            try NSRegularExpression(pattern: pattern).matches(in: source, range: NSRange(location: 0, length: (source as NSString).length))
        }
        func mask(_ range: NSRange) {
            for index in range.location..<min(units.count, NSMaxRange(range)) where units[index] != 10 && units[index] != 13 { units[index] = 32 }
        }
        if let header = try matches(#"\A---\r?\n[\s\S]*?\r?\n---(?:\r?\n|\z)"#, in: raw).first { mask(header.range) }
        // Code is data, not a request to upload the image paths shown in examples.
        var fence: (character: Character, length: Int)?
        var lineOffset = 0
        var listIndent: Int?
        for originalLine in text().components(separatedBy: "\n") {
            let range = NSRange(location: lineOffset, length: originalLine.utf16.count)
            lineOffset += range.length + 1
            let line = originalLine.replacingOccurrences(of: #"^ {0,3}(?:>[ \t]?)+"#, with: "", options: .regularExpression)
            let leading = line.prefix { $0 == " " || $0 == "\t" }.reduce(0) { $0 + ($1 == "\t" ? 4 : 1) }
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if let open = fence {
                mask(range)
                let run = trimmed.prefix { $0 == open.character }
                if run.count >= open.length && trimmed.dropFirst(run.count).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { fence = nil }
                continue
            }
            if let marker = try matches(#"^ {0,3}(?:[-+*]|[0-9]+[.)])[ \t]+"#, in: line).first { listIndent = marker.range.length }
            else if !trimmed.isEmpty, let indent = listIndent, leading < indent { listIndent = nil }
            if leading >= (listIndent.map { $0 + 4 } ?? 4) { mask(range); continue }
            let possible = line.replacingOccurrences(of: #"^ {0,3}(?:[-+*]|[0-9]+[.)])[ \t]+"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
            if let character = possible.first, character == "`" || character == "~" {
                let run = possible.prefix { $0 == character }
                if run.count >= 3 && !(character == "`" && possible.dropFirst(run.count).contains("`")) { fence = (character, run.count); mask(range) }
            }
        }
        for match in try matches(#"(?is)<!--[\s\S]*?(?:-->|\z)|<(pre|code|script|style|textarea)\b[^>]*>[\s\S]*?(?:</\1\s*>|\z)"#, in: text()) { mask(match.range) }
        func escaped(_ position: Int, in input: [UInt16]) -> Bool {
            var cursor = position, count = 0
            while cursor > 0 && input[cursor - 1] == 92 { cursor -= 1; count += 1 }
            return count % 2 == 1
        }
        var cursor = 0
        while cursor < units.count {
            guard units[cursor] == 96 && !escaped(cursor, in: units) else { cursor += 1; continue }
            let start = cursor
            while cursor < units.count && units[cursor] == 96 { cursor += 1 }
            let length = cursor - start
            var closing = cursor
            while closing < units.count {
                try spendWork()
                if units[closing] != 96 { closing += 1; continue }
                let beginning = closing
                while closing < units.count && units[closing] == 96 { try spendWork(); closing += 1 }
                if closing - beginning == length { mask(NSRange(location: start, length: closing - start)); cursor = closing; break }
            }
        }
        func unescape(_ value: String) -> String {
            value.replacingOccurrences(of: ##"\\([!\"#$%&'()*+,\-./:;<=>?@\[\]\\^_`{|}~])"##, with: "$1", options: .regularExpression)
        }
        func label(_ value: String) -> String {
            unescape(value).precomposedStringWithCanonicalMapping.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        }
        let definitionsSource = text() as NSString
        var definitions: [String: String] = [:]
        for definition in try matches(#"(?m)^ {0,3}\[([^\]\r\n]+)\]:[ \t]*(?:\r?\n[ \t]{0,3})?(?:<([^>\r\n]+)>|((?:\\.|[^\s])+))[^\r\n]*"#, in: definitionsSource as String) {
            let key = label(definitionsSource.substring(with: definition.range(at: 1)))
            let destination = definition.range(at: 2).location == NSNotFound ? definition.range(at: 3) : definition.range(at: 2)
            if definitions[key] == nil { definitions[key] = definitionsSource.substring(with: destination) }
            mask(definition.range)
        }
        let markdown = units
        var urls: [String] = []
        func string(_ start: Int, _ end: Int) -> String { String(decoding: markdown[start..<end], as: UTF16.self) }
        func bracketEnd(_ start: Int) throws -> Int? {
            var depth = 1, index = start + 1
            while index < markdown.count {
                try spendWork()
                if markdown[index] == 92 { index += 2; continue }
                if markdown[index] == 91 { depth += 1 }
                if markdown[index] == 93 { depth -= 1; if depth == 0 { return index } }
                index += 1
            }
            return nil
        }
        func whitespace(_ value: UInt16) -> Bool { [9, 10, 13, 32].contains(value) }
        func inlineDestination(_ opening: Int) throws -> (String, Int)? {
            var index = opening + 1
            while index < markdown.count && whitespace(markdown[index]) { try spendWork(); index += 1 }
            let destination: String
            if index < markdown.count && markdown[index] == 60 {
                let start = index + 1; index += 1
                while index < markdown.count && markdown[index] != 62 && markdown[index] != 10 && markdown[index] != 13 { try spendWork(); index += markdown[index] == 92 ? 2 : 1 }
                guard index < markdown.count && markdown[index] == 62 else { return nil }
                destination = string(start, index); index += 1
            } else {
                let start = index
                var depth = 0
                while index < markdown.count {
                    try spendWork()
                    let character = markdown[index]
                    if character == 92 { index += 2; continue }
                    if character == 40 { depth += 1 }
                    if character == 41 { if depth == 0 { break }; depth -= 1 }
                    if whitespace(character) { break }
                    index += 1
                }
                guard index <= markdown.count, depth == 0 else { return nil }
                destination = string(start, index)
            }
            while index < markdown.count && whitespace(markdown[index]) { try spendWork(); index += 1 }
            if index < markdown.count && [34, 39, 40].contains(markdown[index]) {
                let closing: UInt16 = markdown[index] == 40 ? 41 : markdown[index]; index += 1
                while index < markdown.count && markdown[index] != closing { try spendWork(); index += markdown[index] == 92 ? 2 : 1 }
                guard index < markdown.count else { return nil }; index += 1
                while index < markdown.count && whitespace(markdown[index]) { try spendWork(); index += 1 }
            }
            guard index < markdown.count && markdown[index] == 41 else { return nil }
            return (destination, index + 1)
        }
        cursor = 0
        while cursor + 1 < markdown.count {
            guard markdown[cursor] == 33, markdown[cursor + 1] == 91, !escaped(cursor, in: markdown), let end = try bracketEnd(cursor + 1) else { cursor += 1; continue }
            let alt = string(cursor + 2, end)
            var finish = end + 1
            var destination: String?
            if finish < markdown.count && markdown[finish] == 40, let parsed = try inlineDestination(finish) { destination = parsed.0; finish = parsed.1 }
            else if finish < markdown.count && markdown[finish] == 91, let referenceEnd = try bracketEnd(finish) {
                let reference = string(finish + 1, referenceEnd)
                destination = definitions[label(reference.isEmpty ? alt : reference)]; finish = referenceEnd + 1
            } else { destination = definitions[label(alt)] }
            if let destination { urls.append(unescape(destination)); mask(NSRange(location: cursor, length: finish - cursor)) }
            cursor = finish
        }
        let html = text() as NSString
        for tag in try matches(#"(?is)<img\b(?:[^>\"']|\"[^\"]*\"|'[^']*')*>"#, in: html as String) {
            guard !escaped(tag.range.location, in: units) else { continue }
            let markup = html.substring(with: tag.range) as NSString
            if let source = try matches(#"(?is)\ssrc\s*=\s*(?:\"([^\"]*)\"|'([^']*)'|([^\s>]+))"#, in: markup as String).first {
                let range = (1...3).map { source.range(at: $0) }.first { $0.location != NSNotFound }!
                urls.append(markup.substring(with: range))
            }
        }
        var paths = Set<String>()
        for supplied in urls {
            var url = supplied.trimmingCharacters(in: .whitespacesAndNewlines)
            for (entity, value) in [("&quot;", "\""), ("&#39;", "'"), ("&apos;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&amp;", "&")] { url = url.replacingOccurrences(of: entity, with: value) }
            if url.hasPrefix("//") || url.range(of: #"^[a-zA-Z][a-zA-Z0-9+.-]*:"#, options: .regularExpression) != nil {
                guard let absolute = URLComponents(string: url.hasPrefix("//") ? "https:" + url : url),
                      ["http", "https"].contains(absolute.scheme?.lowercased() ?? ""),
                      absolute.host?.lowercased() == "nightingalelyy.github.io", absolute.user == nil, absolute.password == nil,
                      absolute.port == nil || absolute.port == (absolute.scheme?.lowercased() == "https" ? 443 : 80) else { continue }
                url = absolute.percentEncodedPath
            }
            while url.hasPrefix("./") { url.removeFirst(2) }
            if url.hasPrefix("/") { url.removeFirst() }
            guard url.hasPrefix("images/uploads/") else { continue }
            url = String(url.prefix { $0 != "?" && $0 != "#" })
            guard let path = url.removingPercentEncoding else { throw fail("A draft image path has invalid URL encoding.") }
            try validateRelative(path); paths.insert(path)
        }
        return paths.sorted()
    }

    private func validatePrivateImage(path: String, data: Data) throws {
        try validateRelative(path)
        guard path.hasPrefix("images/uploads/"), !data.isEmpty, data.count <= 20 * 1024 * 1024,
              imageMIME((path as NSString).pathExtension) != nil else { throw fail("Private draft images must be supported raster files below 20 MB.") }
        let ext = (path as NSString).pathExtension.lowercased(), head = Array(data.prefix(12))
        let valid = (ext == "png" && head.starts(with: [137, 80, 78, 71, 13, 10, 26, 10])) ||
            (["jpg", "jpeg"].contains(ext) && head.starts(with: [255, 216, 255])) ||
            (ext == "gif" && (data.prefix(6) == Data("GIF87a".utf8) || data.prefix(6) == Data("GIF89a".utf8))) ||
            (ext == "webp" && String(data: data.prefix(4), encoding: .ascii) == "RIFF" && String(data: data.dropFirst(8).prefix(4), encoding: .ascii) == "WEBP")
        guard valid else { throw fail("A private draft image does not match its file type.") }
    }

    private func validatePrivateDraft(_ draft: WriterDraft, path: String) throws {
        try validateArticlePath(path); try validateArticleContent(draft.rawContent)
        if let base = draft.baseContent { try validateArticleContent(base) }
        guard draft.baseBlob == nil || draft.baseBlob?.range(of: "^[0-9a-f]{40,64}$", options: .regularExpression) != nil,
              (draft.baseBlob == nil) == (draft.baseContent == nil), draft.updatedAt.utf8.count <= 100 else { throw fail("A private draft has invalid publication base metadata.") }
    }

    private func decodePrivatePayload(_ data: Data?, capture: PrivateSyncCapture? = nil) throws -> (drafts: [String: WriterDraft], assets: [String: Data]) {
        let localState = capture?.state ?? state, localArticles = capture?.articles ?? articles
        guard let data else { return ([:], [:]) }
        guard data.count <= maxPrivateSyncBytes, let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(payload.keys) == Set(["format", "formatVersion", "publicationRepository", "drafts", "assets"]),
              payload["format"] as? String == "nightingale-private-drafts", payload["formatVersion"] as? Int == 1,
              payload["publicationRepository"] as? String == remoteURL, let draftObjects = payload["drafts"] as? [String: Any], draftObjects.count <= 1000,
              let imageObjects = payload["assets"] as? [[String: Any]], imageObjects.count <= 1000 else {
            throw fail("The private draft snapshot is invalid, belongs to another website, or exceeds 64 MB.")
        }
        var drafts: [String: WriterDraft] = [:], names = Set<String>()
        for (path, object) in draftObjects {
            guard let fields = object as? [String: Any], Set(fields.keys).isSubset(of: Set(["rawContent", "baseBlob", "baseContent", "updatedAt"])) else { throw fail("A private draft contains unsupported fields.") }
            let draft = try JSONDecoder().decode(WriterDraft.self, from: JSONSerialization.data(withJSONObject: fields))
            try validatePrivateDraft(draft, path: path)
            let normalized = path.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            guard names.insert(normalized).inserted else { throw fail("Private draft filenames collide on this Mac.") }
            let localPaths = Set(localState.drafts.keys).union(localArticles.keys).union(localState.localRemovals?.keys.map { $0 } ?? [])
            guard !localPaths.contains(where: { !$0.utf8.elementsEqual(path.utf8) && $0.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX")) == normalized }) else {
                throw fail("An incoming private draft filename conflicts with an existing local filename. Nothing was imported.")
            }
            drafts[path] = draft
        }
        var assets: [String: Data] = [:]; names.removeAll()
        for object in imageObjects {
            guard Set(object.keys) == Set(["path", "base64", "sha256"]), let path = object["path"] as? String,
                  let base64 = object["base64"] as? String, let data = Data(base64Encoded: base64),
                  object["sha256"] as? String == SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() else { throw fail("A private draft image failed its integrity check.") }
            try validatePrivateImage(path: path, data: data)
            let normalized = path.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            guard names.insert(normalized).inserted else { throw fail("Private image filenames collide on this Mac.") }
            if fm.fileExists(atPath: assetsRoot.appendingPathComponent(path).path) {
                guard try Data(contentsOf: safeExisting(path, inside: assetsRoot)) == data else { throw fail("A private image conflicts with an existing image. Both versions are preserved; nothing was imported.") }
            }
            assets[path] = data
        }
        for draft in drafts.values {
            for path in try privateAssetPaths(draft.rawContent) where assets[path] == nil {
                // Already-published uploads may be supplied by the site's cached Git tree.
                guard (try? readAsset(path: path, gitReference: capture?.commit)) != nil else { throw fail("A private draft is missing its image: \(path)") }
            }
        }
        return (drafts, assets)
    }

    private func privatePayload(drafts: [String: WriterDraft], remoteAssets: [String: Data], gitReference: String? = nil) throws -> (data: Data, assets: [String: Data]) {
        guard drafts.count <= 1000 else { throw fail("Private draft sync supports up to 1000 retained drafts.") }
        var assets = remoteAssets
        var articleNames = Set<String>()
        for (path, draft) in drafts {
            try validatePrivateDraft(draft, path: path)
            let normalized = path.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            guard articleNames.insert(normalized).inserted else { throw fail("Private draft filenames collide on this Mac.") }
            for imagePath in try privateAssetPaths(draft.rawContent) {
                if fm.fileExists(atPath: assetsRoot.appendingPathComponent(imagePath).path) {
                    let data = try Data(contentsOf: safeExisting(imagePath, inside: assetsRoot))
                    try validatePrivateImage(path: imagePath, data: data)
                    if let remote = assets[imagePath], remote != data { throw fail("A private image conflicts with this Mac's image. Nothing was overwritten.") }
                    assets[imagePath] = data
                } else if assets[imagePath] == nil {
                    let image = try readAsset(path: imagePath, gitReference: gitReference)
                    guard let encoded = image["base64"] as? String, let data = Data(base64Encoded: encoded) else { throw fail("A draft image could not be read.") }
                    try validatePrivateImage(path: imagePath, data: data); assets[imagePath] = data
                }
            }
        }
        let assetNames = assets.keys.map { $0.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX")) }
        guard Set(assetNames).count == assets.count else { throw fail("Private image filenames collide on this Mac.") }
        guard assets.count <= 1000 else { throw fail("Private draft sync supports up to 1000 retained images.") }
        let encodedDrafts = try JSONSerialization.jsonObject(with: JSONEncoder().encode(drafts))
        let images: [[String: Any]] = assets.keys.sorted().map { path in
            let data = assets[path]!
            return ["path": path, "base64": data.base64EncodedString(), "sha256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()]
        }
        let payload: [String: Any] = ["format": "nightingale-private-drafts", "formatVersion": 1, "publicationRepository": remoteURL,
                                    "drafts": encodedDrafts, "assets": images]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        guard data.count <= maxPrivateSyncBytes else { throw fail("Private drafts and retained images exceed the 64 MB sync limit. Your local work is unchanged.") }
        return (data, assets)
    }

    private func privateSyncEqual<T: Encodable>(_ lhs: T, _ rhs: T) throws -> Bool {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(lhs) == encoder.encode(rhs)
    }

    private func checkedPrivateProtectedPaths(_ paths: [String]) throws -> Set<String> {
        guard paths.count <= 1000 else { throw fail("Too many protected editor paths.") }
        for path in paths { try validateArticlePath(path) }
        return Set(paths)
    }

    private func setPrivateAutoSync(_ params: [String: Any]) throws -> [String: Any] {
        guard let enabled = params["enabled"] as? Bool else { throw fail("Choose whether automatic private sync is enabled.") }
        guard var sync = state.privateSync else {
            if !enabled { return try bootstrap() }
            throw fail("Connect private draft storage before enabling automatic sync.")
        }
        guard !enabled || (sync.enabled && sync.repository != nil) else { throw fail("Connect private draft storage before enabling automatic sync.") }
        if (sync.autoSyncEnabled ?? false) != enabled {
            privateAutoAuthorization.invalidate(); activePrivateAutoToken = nil
            sync.autoSyncEnabled = enabled
            state.privateSync = sync
            try persist()
        }
        return try bootstrap()
    }

    /// Storage queue only. Cancellation stops a not-yet-started upload. An upload
    /// already accepted by the provider can still be acknowledged without imports.
    func cancelPrivateAutoSync() throws -> [String: Any] {
        try initialize()
        privateAutoAuthorization.invalidate(); activePrivateAutoToken = nil
        return try bootstrap()
    }

    /// Storage queue only: capture immutable values without network or persistence.
    func beginPrivateAutoSync(_ params: [String: Any]) throws -> PrivateAutoSyncPlan? {
        try initialize()
        guard !needsRestore, let sync = state.privateSync, sync.enabled, sync.autoSyncEnabled == true,
              let repository = sync.repository, sync.conflicts.isEmpty, state.conflicts.isEmpty,
              activePrivateAutoToken == nil, !privateAutoAuthorization.isWorking else { return nil }
        guard let supplied = params["protectedPaths"] as? [String] else { throw fail("Automatic sync requires the current editor's protected paths.") }
        let protected = try checkedPrivateProtectedPaths(supplied)
        let token = UUID().uuidString.lowercased(), sequence = privateAutoAuthorization.begin(token)
        activePrivateAutoToken = token
        return PrivateAutoSyncPlan(token: token, sequence: sequence, repository: repository,
            capture: PrivateSyncCapture(state: state, articles: articles, commit: cachedCommit), protectedPaths: protected)
    }

    /// Background network queue only. This reads captured values, immutable image
    /// files/Git objects and the locked authorization ticket, never live store state.
    func runPrivateAutoSync(_ plan: PrivateAutoSyncPlan) -> PrivateAutoSyncResult {
        guard privateAutoAuthorization.start(plan) else {
            return PrivateAutoSyncResult(token: plan.token, plan: plan, drafts: [:], assets: [:], failure: "Automatic private sync was cancelled.", hasRemoteProof: false, didWrite: false)
        }
        defer { privateAutoAuthorization.stop() }
        var proofDrafts: [String: WriterDraft] = [:], proofAssets: [String: Data] = [:], hasProof = false
        do {
            let fetched = try draftTransport.read(repository: plan.repository)
            let incoming = try decodePrivatePayload(fetched.data, capture: plan.capture)
            proofDrafts = incoming.drafts; proofAssets = incoming.assets; hasProof = true
            guard privateAutoAuthorization.permits(plan) else { throw fail("Automatic private sync was cancelled before uploading.") }
            let localState = plan.capture.state
            let sync = localState.privateSync ?? WriterPrivateSync()
            var shared = incoming.drafts
            for path in Set(localState.drafts.keys).union(incoming.drafts.keys).union(sync.bases.keys).sorted() {
                let local = localState.drafts[path], base = sync.bases[path]
                guard let remote = incoming.drafts[path] else {
                    if let retained = local ?? base { shared[path] = retained }
                    continue
                }
                let remoteID = try privateDraftIdentity(remote)
                if let local, try privateDraftIdentity(local) == remoteID { continue }
                if let base, try privateDraftIdentity(base) == remoteID, let local { shared[path] = local }
                // Changed incoming versions stay in shared storage. Their optimistic
                // local merge waits for the UI's latest protected paths at finish.
            }
            let outgoing = try privatePayload(drafts: shared, remoteAssets: incoming.assets, gitReference: plan.capture.commit)
            var wrote = false
            if outgoing.data != fetched.data {
                _ = try draftTransport.write(repository: plan.repository, data: outgoing.data, expectedRevision: fetched.revision, beforeUpload: { [privateAutoAuthorization] in
                    guard privateAutoAuthorization.permits(plan) else { throw RepositoryStoreError(message: "Automatic private sync was cancelled before uploading.") }
                })
                wrote = true
            }
            return PrivateAutoSyncResult(token: plan.token, plan: plan, drafts: shared, assets: outgoing.assets, failure: nil, hasRemoteProof: true, didWrite: wrote)
        } catch {
            return PrivateAutoSyncResult(token: plan.token, plan: plan, drafts: proofDrafts, assets: proofAssets, failure: error.localizedDescription, hasRemoteProof: hasProof, didWrite: false)
        }
    }

    private func privateAutoResponse(_ plan: PrivateAutoSyncPlan, changed: Bool, skipped: String? = nil) throws -> [String: Any] {
        if activePrivateAutoToken == plan.token { activePrivateAutoToken = nil; privateAutoAuthorization.invalidate() }
        var result = try bootstrap()
        var detail: [String: Any] = ["automatic": true, "changed": changed]
        if let skipped { detail["skipped"] = skipped }
        result["privateSyncResult"] = detail
        return result
    }

    /// Storage queue only. The UI flushes saves and briefly protects its current
    /// selection before calling this method; network time never blocks autosaves.
    func finishPrivateAutoSync(_ result: PrivateAutoSyncResult, protectedPaths: [String]) throws -> [String: Any] {
        try initialize()
        let plan = result.plan
        defer { if activePrivateAutoToken == plan.token { activePrivateAutoToken = nil; privateAutoAuthorization.invalidate() } }
        let protected = try checkedPrivateProtectedPaths(protectedPaths)
        guard !needsRestore, var sync = state.privateSync,
              sync.repository?.lowercased() == plan.repository.lowercased(), plan.sequence > latestPrivateAutoCompletion else {
            return try privateAutoResponse(plan, changed: false, skipped: "stale-or-recovery")
        }
        latestPrivateAutoCompletion = plan.sequence
        let allowed = privateAutoAuthorization.permits(plan) && sync.enabled && sync.autoSyncEnabled == true && sync.conflicts.isEmpty && state.conflicts.isEmpty
        let mayImport = allowed && result.failure == nil
        if mayImport { lastPrivateAutoCheckedAt = now() }
        let previous = state
        var nextDrafts = state.drafts, archives: [(String, String, String)] = [], createdFiles: [URL] = []
        do {
            if mayImport {
                // The library may have changed while the network worker ran.
                let localPaths = Set(state.drafts.keys).union(articles.keys).union(state.localRemovals?.keys.map { $0 } ?? [])
                for path in result.drafts.keys {
                    let normalized = path.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                    guard !localPaths.contains(where: { !$0.utf8.elementsEqual(path.utf8) && $0.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX")) == normalized }) else {
                        throw fail("An incoming automatic draft conflicts with a filename created on this Mac. No local draft was replaced.")
                    }
                }
                for (path, bytes) in result.assets where fm.fileExists(atPath: assetsRoot.appendingPathComponent(path).path) {
                    guard try Data(contentsOf: safeExisting(path, inside: assetsRoot)) == bytes else { throw fail("An incoming private image conflicts with this Mac's image. Nothing was overwritten.") }
                }
            }
            if result.hasRemoteProof {
                for path in result.drafts.keys.sorted() {
                    guard let remote = result.drafts[path], sync.conflicts[path] == nil else { continue }
                    let capturedLocal = plan.capture.state.drafts[path], capturedBase = plan.capture.state.privateSync?.bases[path], local = state.drafts[path]
                    let remoteID = try privateDraftIdentity(remote)
                    let capturedLocalID = try capturedLocal.map { try privateDraftIdentity($0) }
                    let capturedBaseID = try capturedBase.map { try privateDraftIdentity($0) }
                    let localID = try local.map { try privateDraftIdentity($0) }
                    let currentBaseID = try sync.bases[path].map { try privateDraftIdentity($0) }
                    // A successful upload of captured A is the common base even if
                    // autosave has since written B, or the user removed A locally.
                    if remoteID == capturedLocalID || remoteID == localID {
                        sync.bases[path] = remote
                        continue
                    }
                    guard mayImport else { continue }
                    if remoteID == capturedBaseID {
                        if currentBaseID == capturedBaseID { sync.bases[path] = remote }
                        continue
                    }
                    let structuralProtection = state.queue[path] != nil || state.conflicts[path] != nil || state.localRemovals?[path] != nil || state.deletionIntents?[path] != nil
                    if local == nil, let published = articles[path], digest(published.rawContent) == digest(remote.rawContent), !structuralProtection {
                        sync.bases[path] = remote
                    } else if !structuralProtection && !protected.contains(path) && localID == capturedLocalID && currentBaseID == capturedBaseID &&
                              ((capturedLocal == nil && capturedBase == nil) || capturedLocalID == capturedBaseID) {
                        if let local { archives.append((path, local.rawContent, "before-private-auto-sync")) }
                        nextDrafts[path] = remote; sync.bases[path] = remote
                    } else {
                        if sync.conflicts[path]?.remoteRevision != remoteID { archives.append((path, remote.rawContent, "private-auto-sync-conflict")) }
                        sync.conflicts[path] = WriterPrivateSyncConflict(base: capturedBase, remote: remote, remoteRevision: remoteID)
                    }
                }
            }
            let newAssets = mayImport ? result.assets.filter { !fm.fileExists(atPath: assetsRoot.appendingPathComponent($0.key).path) } : [:]
            let draftsChanged = try !privateSyncEqual(nextDrafts, state.drafts)
            let metadataChanged = try !privateSyncEqual(sync, state.privateSync!)
            let localWork = draftsChanged || !newAssets.isEmpty || !archives.isEmpty
            if !allowed && !metadataChanged { return try privateAutoResponse(plan, changed: false, skipped: "cancelled-or-paused") }
            if allowed, let failure = result.failure {
                sync.status = ["offline", "network", "connection", "timed out", "resolve host"].contains(where: { failure.lowercased().contains($0) }) ? "offline" : "error"
                sync.message = "Automatic private sync could not finish. Local writing is safe. " + failure
                guard try !privateSyncEqual(sync, state.privateSync!) else { return try privateAutoResponse(plan, changed: false, skipped: "unchanged-error") }
            } else if !localWork && !metadataChanged && !result.didWrite && sync.status == "synced" {
                return try privateAutoResponse(plan, changed: false, skipped: "unchanged")
            } else if allowed {
                sync.status = sync.conflicts.isEmpty ? "synced" : "conflict"
                sync.message = sync.conflicts.isEmpty ? "Private drafts synced. Website publishing remains manual." : "An incoming private draft needs review. Your current text and the other version are preserved."
                sync.lastSyncedAt = now()
            }
            if localWork { try automaticBackup(force: true) }
            for (path, bytes) in newAssets {
                try fm.createDirectory(at: assetsRoot, withIntermediateDirectories: true)
                let file = try safeDestination(path, inside: assetsRoot)
                try bytes.write(to: file, options: .atomic); createdFiles.append(file)
            }
            for (path, raw, reason) in archives {
                if let file = try archiveContent(path: path, content: raw, reason: reason) { createdFiles.append(file) }
            }
            state.drafts = nextDrafts; state.privateSync = sync
            try persist()
            if localWork { do { try automaticBackup(force: true) } catch { backupWarning = "Private drafts were received, but the automatic backup could not be written." } }
            return try privateAutoResponse(plan, changed: true, skipped: allowed ? nil : "cancelled-upload-acknowledged")
        } catch {
            state = previous
            for file in createdFiles { try? fm.removeItem(at: file) }
            pendingHistoryPrunes.removeAll()
            throw error
        }
    }

    private func syncPrivateDrafts() throws -> [String: Any] {
        guard activePrivateAutoToken == nil && !privateAutoAuthorization.isWorking else { throw fail("A background private sync is finishing. Wait for it or cancel it before syncing manually.") }
        latestPrivateAutoCompletion = privateAutoAuthorization.invalidate()
        guard var sync = state.privateSync, sync.enabled, let repository = sync.repository else { throw fail("Connect private draft storage before syncing.") }
        let previous = state
        var createdFiles: [URL] = []
        do {
            let fetched = try draftTransport.read(repository: repository)
            let incoming = try decodePrivatePayload(fetched.data)
            var shared = incoming.drafts, nextDrafts = state.drafts
            var archives: [(String, String, String)] = []
            let paths = Set(state.drafts.keys).union(incoming.drafts.keys).union(sync.bases.keys)
            for path in paths.sorted() {
                let local = state.drafts[path], remote = incoming.drafts[path], base = sync.bases[path]
                let protected = state.queue[path] != nil || state.conflicts[path] != nil || state.localRemovals?[path] != nil || state.deletionIntents?[path] != nil
                guard let remote else {
                    // Absence is never a deletion instruction. Retain a previously shared copy.
                    if let retained = local ?? base { shared[path] = retained; sync.bases[path] = retained }
                    sync.conflicts.removeValue(forKey: path)
                    continue
                }
                let remoteID = try privateDraftIdentity(remote)
                let localID = try local.map { try privateDraftIdentity($0) }
                let baseID = try base.map { try privateDraftIdentity($0) }
                if localID == remoteID {
                    sync.bases[path] = remote; sync.conflicts.removeValue(forKey: path)
                } else if baseID == remoteID {
                    if let local { shared[path] = local; sync.bases[path] = local }
                    else { sync.bases[path] = remote }
                    sync.conflicts.removeValue(forKey: path)
                } else if local == nil && articles[path]?.rawContent == remote.rawContent && !protected {
                    // Publishing/discarding a synchronized draft must not recreate an identical draft.
                    sync.bases[path] = remote; sync.conflicts.removeValue(forKey: path)
                } else if !protected && ((base == nil && local == nil) || (base != nil && localID == baseID)) {
                    if let local { archives.append((path, local.rawContent, "before-private-sync")) }
                    nextDrafts[path] = remote; sync.bases[path] = remote; sync.conflicts.removeValue(forKey: path)
                } else {
                    if sync.conflicts[path]?.remoteRevision != remoteID { archives.append((path, remote.rawContent, "private-sync-conflict")) }
                    sync.conflicts[path] = WriterPrivateSyncConflict(base: base, remote: remote, remoteRevision: remoteID)
                }
            }
            let outgoing = try privatePayload(drafts: shared, remoteAssets: incoming.assets)
            // Complete validation precedes any upload or local mutation. Transport uses an expected-revision CAS write.
            if outgoing.data != fetched.data {
                _ = try draftTransport.write(repository: repository, data: outgoing.data, expectedRevision: fetched.revision)
            }
            try automaticBackup(force: true)
            try fm.createDirectory(at: assetsRoot, withIntermediateDirectories: true)
            for (path, bytes) in outgoing.assets where !fm.fileExists(atPath: assetsRoot.appendingPathComponent(path).path) {
                let target = try safeDestination(path, inside: assetsRoot)
                try bytes.write(to: target, options: .atomic); createdFiles.append(target)
            }
            for (path, raw, reason) in archives {
                if let file = try archiveContent(path: path, content: raw, reason: reason) { createdFiles.append(file) }
            }
            state.drafts = nextDrafts
            sync.status = sync.conflicts.isEmpty ? "synced" : "conflict"
            sync.message = sync.conflicts.isEmpty ? "Private drafts synced. Website publishing is unchanged." : "Private drafts need review. Both versions are preserved; website publishing is blocked for these articles."
            sync.lastSyncedAt = now(); state.privateSync = sync
            try persist()
            do { try automaticBackup(force: true) } catch { backupWarning = "Private drafts synced, but the automatic backup could not be written." }
            return try bootstrap()
        } catch {
            state = previous
            for file in createdFiles { try? fm.removeItem(at: file) }
            pendingHistoryPrunes.removeAll()
            var failed = previous.privateSync ?? WriterPrivateSync()
            let detail = error.localizedDescription
            failed.status = ["offline", "network", "connection", "timed out", "resolve host"].contains(where: { detail.lowercased().contains($0) }) ? "offline" : "error"
            failed.message = "Private draft sync could not finish. This Mac's drafts are unchanged. " + detail
            state.privateSync = failed
            try persist(); return try bootstrap()
        }
    }

    private func resolvePrivateSyncConflict(_ params: [String: Any]) throws -> [String: Any] {
        let path = try string(params, "path"); try validateArticlePath(path)
        guard var sync = state.privateSync, let conflict = sync.conflicts[path] else { throw fail("This private draft conflict is no longer available.") }
        let local = state.drafts[path]
        guard params["expectedLocalRevision"] as? String == (local.map { digest($0.rawContent) } ?? ""),
              params["expectedRemoteRevision"] as? String == conflict.remoteRevision else { throw fail("The conflict changed. Reload both versions before choosing.") }
        let choice = try string(params, "choice")
        guard ["local", "remote"].contains(choice) else { throw fail("Choose the local or private remote version.") }
        if choice == "remote" {
            guard state.queue[path] == nil, state.conflicts[path] == nil, state.localRemovals?[path] == nil, state.deletionIntents?[path] == nil else {
                throw fail("Cancel queued publication, resolve website conflicts, and restore locally removed items before using the private remote version.")
            }
        }
        try automaticBackup(force: true)
        if let local { try archiveContent(path: path, content: local.rawContent, reason: "before-private-resolution") }
        if choice == "remote" { state.drafts[path] = conflict.remote }
        // Accepting local absence only acknowledges the shared copy; it never erases it.
        sync.bases[path] = conflict.remote; sync.conflicts.removeValue(forKey: path)
        sync.status = sync.conflicts.isEmpty ? (sync.enabled ? "ready" : "disabled") : "conflict"
        sync.message = "Private draft choice saved on this Mac. Sync drafts again to share it. Website publishing is separate."
        state.privateSync = sync
        try persist(); return try bootstrap()
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
        let paths = Set(articles.keys).union(state.drafts.keys).subtracting(state.localRemovals?.keys.map { $0 } ?? [])
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
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard (try root.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else { throw fail("Local draft storage cannot be a symbolic link.") }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
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
        if !needsRestore { try reconcileDeletionIntents(persistChanges: false); try persist() }
    }

    private func persist() throws {
        guard !needsRestore || recoveryWriteInProgress else { throw fail("Restore a valid backup before changing local storage.") }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let meaningful = try workFingerprint(state) != workFingerprint(durableState)
        do {
            let temporary = root.appendingPathComponent(".state-\(UUID().uuidString).tmp")
            defer { try? fm.removeItem(at: temporary) }
            guard fm.createFile(atPath: temporary.path, contents: try encoder.encode(state), attributes: [.posixPermissions: 0o600]) else {
                throw fail("Could not create private local draft storage.")
            }
            guard rename(temporary.path, stateFile.path) == 0 else { throw fail("Could not atomically replace local draft storage.") }
            durableState = state
            if !state.conflicts.isEmpty || !(state.privateSync?.conflicts ?? [:]).isEmpty { privateAutoAuthorization.invalidate() }
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
        return try encoder.encode(value.drafts) + encoder.encode(value.queue) + encoder.encode(value.categories) + encoder.encode(value.templates) + encoder.encode(value.localRemovals)
    }

    func exportBackup() throws -> Data {
        try initialize()
        guard !needsRestore else { throw fail("Restore a valid backup before exporting. The original unreadable storage file is preserved.") }
        var portableState = state; portableState.privateSync = nil
        let encodedState = try JSONSerialization.jsonObject(with: JSONEncoder().encode(portableState))
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
        guard var portableState = stateObject as? [String: Any] else { throw fail("Invalid backup state.") }
        portableState.removeValue(forKey: "privateSync")
        let restored = try JSONDecoder().decode(WriterState.self, from: JSONSerialization.data(withJSONObject: portableState))
        guard restored.version == 1, restored.drafts.count <= 10000, restored.queue.count <= 10000 else { throw fail("This backup version or size is unsupported.") }
        try validateTemplates(restored.templates ?? [:])
        _ = try mergedTemplates(restored.templates ?? [:])
        for (path, draft) in restored.drafts { try validateArticlePath(path); try validateArticleContent(draft.rawContent) }
        for (path, queued) in restored.queue { try validateArticlePath(path); try validateArticleContent(queued.rawContent) }
        for (path, removal) in restored.localRemovals ?? [:] { try validateArticlePath(path); if let draft = removal.draft { try validateArticleContent(draft.rawContent) } }
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
        guard activePrivateAutoToken == nil && !privateAutoAuthorization.isWorking else { throw fail("Finish or cancel background private sync before restoring a backup.") }
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
                if state.drafts[path] == nil && state.queue[path] == nil && state.localRemovals?[path] == nil {
                    state.drafts[path] = draft; draftsAdded += 1
                } else if state.drafts[path]?.rawContent != draft.rawContent {
                    if let file = try archiveContent(path: path, content: draft.rawContent, reason: "imported-conflict") { createdFiles.append(file); versionsAdded += 1 }
                }
            }
            for (path, queued) in restored.queue {
                if state.drafts[path] == nil && state.queue[path] == nil && state.localRemovals?[path] == nil {
                    state.drafts[path] = WriterDraft(rawContent: queued.rawContent, baseBlob: queued.baseBlob, baseContent: queued.baseContent, updatedAt: now()); draftsAdded += 1
                } else if state.drafts[path]?.rawContent != queued.rawContent {
                    if let file = try archiveContent(path: path, content: queued.rawContent, reason: "imported-queued-version") { createdFiles.append(file); versionsAdded += 1 }
                }
            }
            for (path, removal) in restored.localRemovals ?? [:] {
                if let draft = removal.draft, let file = try archiveContent(path: path, content: draft.rawContent, reason: "imported-removed-draft") {
                    createdFiles.append(file); versionsAdded += 1
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
        let tree = try git(["ls-tree", "-r", "--name-only", "-z", remoteRef], at: repository).text.split(separator: "\0").map(String.init)
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
        guard state.localRemovals?[path] == nil, state.deletionIntents?[path] == nil, state.deletions?[path] == nil else { return nil }
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
        let publications = Set(articles.keys).union(state.publications?.keys.map { $0 } ?? []).sorted().compactMap { publicationJSON(path: $0) }
        return publications + deletionRows(includeLocal: false)
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
            if result["operation"] as? String == "delete" { try applyDeletionStatus(result); continue }
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
        let paths = Set(articles.keys).union(state.drafts.keys).subtracting(state.localRemovals?.keys.map { $0 } ?? []).sorted()
        var result: [String: Any] = ["articles": try paths.map { try articleJSON(path: $0) }, "categories": state.categories ?? [], "templates": templateList(), "status": statusJSON(),
                "repositoryPath": repository.path, "remoteURL": remoteURL, "branch": "main", "publications": publicationTargets().filter { $0["operation"] as? String != "delete" }, "deletions": deletionRows(includeLocal: true),
                "privateSync": privateSyncJSON(), "recovery": ["needsRestore": needsRestore, "message": needsRestore ? state.message : "", "automaticBackupDirectory": root.appendingPathComponent("backups").path, "historyLimitPerArticle": 100]]
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
        guard state.localRemovals?[path] == nil, state.deletionIntents?[path] == nil else { throw fail("Restore this locally removed item before editing it.") }
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
        try reconcileDeletionIntents()
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

    private func processQueue(path selectedPath: String? = nil) throws -> [String: Any] {
        guard !state.queue.isEmpty else { return try bootstrap() }
        do { try fetch() } catch { networkFailure(error); try persist(); return try bootstrap() }
        var published = 0
        for path in selectedPath.map({ [$0] }) ?? state.queue.keys.sorted() {
            guard let snapshot = state.queue[path] else { continue }
            if state.privateSync?.conflicts[path] != nil {
                state.state = "conflict"; state.message = "Resolve the private draft conflict before publishing this article."
                try persist(); continue
            }
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
        if !state.conflicts.isEmpty || !(state.privateSync?.conflicts ?? [:]).isEmpty {
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
        state.deletions?.removeValue(forKey: path)
        state.localRemovals?.removeValue(forKey: path)
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

    private func readAsset(path supplied: String, gitReference: String? = nil) throws -> [String: Any] {
        let path = supplied.hasPrefix("/") ? String(supplied.dropFirst()) : supplied
        try validateRelative(path)
        guard path.hasPrefix("images/") || ["siteicon.png", "apple-touch-icon.png", "touch-icon.png"].contains(path), let mime = imageMIME((path as NSString).pathExtension) else { throw fail("Only repository image assets can be previewed.") }
        let data: Data
        if fm.fileExists(atPath: assetsRoot.appendingPathComponent(path).path) {
            data = try Data(contentsOf: safeExisting(path, inside: assetsRoot))
        } else {
            let reference = gitReference ?? remoteRef
            let tree = try git(["ls-tree", reference, "--", path], at: repository).text
            guard tree.hasPrefix("100644 blob ") || tree.hasPrefix("100755 blob ") else { throw fail("The image was not found in the repository.") }
            data = try git(["show", "\(reference):\(path)"], at: repository).output
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
