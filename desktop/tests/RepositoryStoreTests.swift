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

    static func selectedQueueTests(_ root: URL) throws {
        let source = root.appendingPathComponent("manual-queue-source"), remote = root.appendingPathComponent("manual-queue-remote.git")
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try git(["init", "-b", "main"], at: source)
        try git(["config", "user.name", identity.name], at: source); try git(["config", "user.email", identity.email], at: source)
        let first = "_docs/first.md", second = "_docs/second.md"
        let original = raw("Original", body: "Published"), queued = raw("Queued", body: "Reviewed version"), newer = raw("Newer", body: "Keep these later edits local")
        try write(original, first, at: source); try write(original, second, at: source)
        try git(["add", "."], at: source); try git(["commit", "-m", "Manual queue fixture"], at: source)
        try git(["clone", "--bare", source.path, remote.path])
        let store = RepositoryStore(root: root.appendingPathComponent("manual-queue-data"), remoteURL: remote.path, seedRepo: source, identity: identity)
        _ = try store.handle(method: "bootstrap")
        try save(store, first, queued); try queue(store, first)
        try save(store, second, queued); try queue(store, second)
        let queuedRevision = try item(store, first)["queuedRevision"] as! String
        try save(store, first, newer)
        let initialHead = try git(["rev-parse", "main"], at: remote)
        _ = try store.handle(method: "refresh")
        try expect(try git(["rev-parse", "main"], at: remote) == initialHead, "Website refresh cannot publish either queued article")
        try rejects("A selected retry must supply the exact queued revision") { _ = try store.handle(method: "processQueue", params: ["path": first]) }
        try rejects("A stale queued revision must not upload any article") { _ = try store.handle(method: "processQueue", params: ["path": first, "expectedQueuedRevision": "stale"]) }
        try expect(try git(["rev-parse", "main"], at: remote) == initialHead, "Rejected retries must leave the public head unchanged")
        let finished = try store.handle(method: "processQueue", params: ["path": first, "expectedQueuedRevision": queuedRevision])
        try expect(try git(["show", "main:" + first], at: remote) == queued, "Explicit retry publishes the reviewed snapshot")
        try expect(try git(["show", "main:" + second], at: remote) == original, "Retrying one article must not publish another queued article")
        try expect(try item(store, first)["rawContent"] as? String == newer, "Retrying an older queued version preserves later local edits")
        try expect(try item(store, second)["isQueued"] as? Bool == true && status(finished)["queuedCount"] as? Int == 1, "The other queued version still waits for its own explicit retry")
    }

    static func deletionTests(_ root: URL) throws {
        let source = root.appendingPathComponent("deletion-source"), remote = root.appendingPathComponent("deletion-remote.git")
        let app = root.appendingPathComponent("deletion-data")
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        try git(["init", "-b", "main"], at: source)
        try git(["config", "user.name", identity.name], at: source); try git(["config", "user.email", identity.email], at: source)
        let path = "_docs/Notes/北京.md", other = "_docs/other.md", wildcard = "_docs/a*[bc].md", neighbor = "_docs/abc.md"
        let original = raw("Delete me", body: "Published article"), draft = raw("Delete me", body: "Unpublished changes that must survive cancellation")
        try write(original, path, at: source); try write(raw("Other", body: "Keep this"), other, at: source)
        try write(raw("Literal wildcard", body: "Only erase this exact path"), wildcard, at: source)
        try write(raw("Matching neighbor", body: "Keep this exact source"), neighbor, at: source)
        try write("---\ntitle: Home\n---\nHome", "index.md", at: source)
        try write("---\ntitle: Missing\npermalink: /404.html\n---\nMissing", "404.md", at: source)
        try write("---\ntitle: Admin\npermalink: /admin/\n---\nCMS", "admin/index.md", at: source)
        try write("---\npermalink: /search/\n---\n{% for doc in site.docs %}{{ doc.title }}{% endfor %}", "search.html", at: source)
        try write("---\ntitle: Changes\n---\n{% include changes.html %}", "changelog.html", at: source)
        try write("shared-image-bytes", "images/shared.png", at: source); try write("keep bytes", "unrelated.txt", at: source)
        try git(["add", "."], at: source); try git(["commit", "-m", "Deletion fixture"], at: source)
        try git(["clone", "--bare", source.path, remote.path]); try git(["remote", "add", "origin", remote.path], at: source)
        let initialCommit = try git(["rev-parse", "main"], at: remote).trimmingCharacters(in: .whitespacesAndNewlines)
        var captured: [String: Any] = [:], blockValidation = false, race = false
        let validator: ([String: Any]) throws -> [String: Any] = { request in
            captured = request
            if race {
                race = false
                try git(["pull", "--ff-only", "origin", "main"], at: source)
                try write("A competing remote update", "unrelated.txt", at: source)
                try git(["add", "unrelated.txt"], at: source); try git(["commit", "-m", "Competing remote edit"], at: source)
                try git(["push", "origin", "main"], at: source)
            }
            return ["ok": !blockValidation, "issues": blockValidation ? [["severity": "error", "code": "link.missing", "path": other, "message": "Remaining article links to deleted source"]] : []]
        }
        let store = RepositoryStore(root: app, remoteURL: remote.path, seedRepo: source, identity: identity, validation: validator)
        _ = try store.handle(method: "bootstrap")
        func rows(_ snapshot: [String: Any]) -> [[String: Any]] { snapshot["deletions"] as! [[String: Any]] }
        func revision(_ path: String) throws -> String { try item(store, path)["revision"] as! String }
        func hide(_ path: String) throws -> [String: Any] {
            try store.handle(method: "removeLocally", params: ["path": path, "expectedRevision": revision(path), "confirmation": "REMOVE", "title": "A removed title"])
        }
        func plan(_ path: String, _ snapshot: [String: Any]) throws -> [String: Any] {
            let row = rows(snapshot).first { $0["path"] as? String == path }!
            return try store.handle(method: "prepareDeletion", params: ["path": path, "expectedRevision": row["expectedRevision"]!])
        }
        func confirm(_ report: [String: Any]) throws -> [String: Any] {
            try store.handle(method: "deleteArticle", params: ["path": report["path"]!, "scope": "published", "expectedRevision": report["expectedRevision"]!, "expectedRemoteBlob": report["expectedRemoteBlob"]!, "confirmation": "DELETE"])
        }
        try rejects("First removal requires explicit REMOVE") { _ = try store.handle(method: "removeLocally", params: ["path": path, "expectedRevision": revision(path)]) }
        try rejects("GitHub deletion cannot bypass first local removal") { _ = try store.handle(method: "deleteArticle", params: ["path": path, "scope": "published", "expectedRevision": revision(path), "expectedRemoteBlob": "", "confirmation": "DELETE"]) }
        try save(store, path, draft); try queue(store, path)
        try rejects("Queued source cannot be locally removed") { _ = try hide(path) }
        _ = try store.handle(method: "cancelQueued", params: ["path": path])
        let beforeRemoval = try revision(path)
        let hidden = try hide(path)
        try expect(!all(hidden).contains { $0["path"] as? String == path }, "First confirmation hides the article locally")
        try expect(rows(hidden).first?["status"] as? String == "local", "Hidden published article must await a separate remote decision")
        try expect(try git(["rev-parse", "main"], at: remote).trimmingCharacters(in: .whitespacesAndNewlines) == initialCommit, "First confirmation must not change GitHub")
        try rejects("Hidden article cannot be saved by a stale editor") { _ = try store.handle(method: "saveDraft", params: ["path": path, "expectedRevision": beforeRemoval, "rawContent": original]) }
        try rejects("Hidden article cannot be queued directly") { try queue(store, path) }
        let hiddenBackup = try store.exportBackup()
        let hiddenRestart = RepositoryStore(root: app, remoteURL: remote.path, identity: identity, validation: validator)
        try expect(!all(try hiddenRestart.handle(method: "refresh")).contains { $0["path"] as? String == path }, "Local removal survives refresh and restart")
        let restored = try hiddenRestart.handle(method: "restoreLocalRemoval", params: ["path": path])
        try expect(all(restored).first { $0["path"] as? String == path }?["rawContent"] as? String == draft, "Restore locally recovers exact unpublished draft")
        // Keep one store authoritative for the remaining checks.
        _ = try store.handle(method: "restoreLocalRemoval", params: ["path": path])
        let stateFile = app.appendingPathComponent("state.json"), savedState = app.appendingPathComponent("held-state.json")
        try fm.moveItem(at: stateFile, to: savedState); try fm.createDirectory(at: stateFile, withIntermediateDirectories: false)
        try rejects("Local removal must abort on atomic storage failure") { _ = try hide(path) }
        try fm.removeItem(at: stateFile); try fm.moveItem(at: savedState, to: stateFile)
        try expect(try item(store, path)["rawContent"] as? String == draft, "Failed removal keeps unpublished content intact")
        try expect(rows(try store.handle(method: "bootstrap")).isEmpty, "Failed removal does not hide the article")
        let unrelatedQueue = "_docs/unrelated-queued.md"
        _ = try store.handle(method: "createArticle", params: ["path": unrelatedQueue, "rawContent": raw("Queued", body: "Must not publish during deletion")])
        try queue(store, unrelatedQueue)
        let hiddenAgain = try hide(path)
        let ownRemovalImport = try store.restoreBackup(hiddenBackup)
        try expect(rows(ownRemovalImport).first { $0["path"] as? String == path }?["status"] as? String == "local", "Backup import preserves an existing local removal")
        let staleLocalPlan = try store.handle(method: "prepareDeletion", params: ["path": path, "expectedRevision": "stale"])
        try expect(staleLocalPlan["canDelete"] as? Bool == false, "Stale source revision cannot approve deletion")
        let reviewed = try plan(path, hiddenAgain)
        try expect(reviewed["canDelete"] as? Bool == true, "Valid remaining sources permit deletion review")
        try expect(reviewed["snapshot"] is [String: Any], "Deletion review returns the refreshed library snapshot")
        let documentPaths = (captured["documents"] as! [[String: String]]).map { $0["path"]! }
        try expect(documentPaths.contains("admin/index.md") && documentPaths.contains(other), "Validation includes all remaining authored sources including admin")
        try expect(!documentPaths.contains(path) && !documentPaths.contains("search.html") && !documentPaths.contains("changelog.html"), "Deleted source and Liquid templates must not be validated as authored documents")
        try expect((captured["files"] as! [String]).contains("images/shared.png") && !(captured["files"] as! [String]).contains(path), "Validation retains shared assets and excludes erased source")
        try expect((captured["routes"] as! [String]).contains("/search/") && !(captured["routes"] as! [String]).contains("/Notes/北京/"), "Routes include remaining templates and exclude deleted article")
        try rejects("Second confirmation is mandatory") { _ = try store.handle(method: "deleteArticle", params: reviewed) }
        blockValidation = true
        let blocked = try confirm(reviewed)
        try expect((blocked["deletion"] as! [String: Any])["status"] as? String == "failed", "Remaining-source errors block deletion again at confirmation")
        try expect(rows(blocked).first?["status"] as? String == "local", "Blocked deletion remains available for local restore or renewed review")
        blockValidation = false
        let beforeFailedPush = try git(["rev-parse", "main"], at: remote)
        try fm.moveItem(at: stateFile, to: savedState); try fm.createDirectory(at: stateFile, withIntermediateDirectories: false)
        let storageBlocked = try confirm(reviewed)
        try fm.removeItem(at: stateFile); try fm.moveItem(at: savedState, to: stateFile)
        try expect((storageBlocked["deletion"] as! [String: Any])["status"] as? String == "failed", "Failed intent persistence returns a fresh blocked snapshot")
        try expect(try git(["rev-parse", "main"], at: remote) == beforeFailedPush, "Intent persistence failure must prevent the remote push")
        try expect(rows(storageBlocked).first { $0["path"] as? String == path }?["status"] as? String == "local", "Failed intent persistence retains local removal and its restoration path")
        let wrongBlob = try store.handle(method: "deleteArticle", params: ["path": path, "scope": "published", "expectedRevision": reviewed["expectedRevision"]!, "expectedRemoteBlob": "old-blob", "confirmation": "DELETE"])
        try expect((wrongBlob["deletion"] as! [String: Any])["status"] as? String == "failed", "Stale remote blob token cannot approve deletion")
        // CMS edits invalidate both the captured remote blob and the reviewed source token.
        try write(raw("Delete me", body: "CMS version"), path, at: source)
        try write(raw("Other", body: "CMS changed selected next article"), other, at: source)
        try git(["add", path, other], at: source); try git(["commit", "-m", "CMS edits"], at: source); try git(["push", "origin", "main"], at: source)
        let stale = try plan(path, hiddenAgain)
        try expect(stale["canDelete"] as? Bool == false && stale["canReviewLatest"] as? Bool == true, "Remote edit requires an explicit renewed review")
        try expect(all(stale["snapshot"] as! [String: Any]).first { $0["path"] as? String == other }?["rawContent"] as? String == raw("Other", body: "CMS changed selected next article"), "Review snapshot refreshes other article revisions for safe cancellation")
        let renewed = try store.handle(method: "prepareDeletion", params: ["path": path, "expectedRevision": stale["latestRevision"]!, "renewReview": true])
        try expect(renewed["canDelete"] as? Bool == true && renewed["expectedRevision"] as? String == stale["latestRevision"] as? String, "Renewal binds confirmation to the acknowledged latest source")
        let removed = try confirm(renewed)
        let deletion = (removed["deletion"] as! [String: Any]), row = rows(removed).first!
        try expect(deletion["status"] as? String == "uploaded", "Successful second confirmation uploads one deletion")
        let uploadedMessage = status(removed)["message"] as! String
        try expect(uploadedMessage.contains("source was erased") && uploadedMessage.contains("awaiting deployment") && !uploadedMessage.contains("unchanged"), "Uploaded deletion footer must replace the first-stage GitHub-unchanged message")
        let durableUploadedState = try JSONSerialization.jsonObject(with: Data(contentsOf: stateFile)) as! [String: Any]
        try expect(durableUploadedState["message"] as? String == uploadedMessage, "The confirmed deletion message must persist with its uploaded record")
        try expect(row["rawContent"] == nil && row["draft"] == nil, "Deletion status and deployment targets must not expose retained drafts")
        try expect(try item(store, unrelatedQueue)["isQueued"] as? Bool == true, "Deletion must preserve unrelated queued publication")
        try rejects("Deleting another source must not process unrelated queued articles") { _ = try git(["show", "main:\(unrelatedQueue)"], at: remote) }
        _ = try store.handle(method: "cancelQueued", params: ["path": unrelatedQueue])
        try rejects("The selected article must be absent from Git main") { _ = try git(["show", "main:\(path)"], at: remote) }
        try expect(try git(["show", "main:images/shared.png"], at: remote) == "shared-image-bytes", "Deletion must not remove shared images")
        try expect(try git(["show", "main:unrelated.txt"], at: remote) == "keep bytes", "Deletion must not include unrelated local changes")
        let history = try store.handle(method: "listHistory", params: ["path": path])["entries"] as! [[String: Any]]
        var historicalContents: [String] = []
        for entry in history { historicalContents.append(try store.handle(method: "readHistory", params: ["path": path, "id": entry["id"]!])["rawContent"] as! String) }
        try expect(historicalContents.contains(draft) && historicalContents.contains(original), "Deleted source and unpublished content remain recoverable")
        let targets = try store.deploymentTargets()["targets"] as! [[String: Any]]
        try expect(targets.filter { $0["path"] as? String == path }.count == 1 && targets.first { $0["path"] as? String == path }?["operation"] as? String == "delete", "Removed paths only create deletion deployment targets")
        var candidate = row; candidate["status"] = "deleted"; candidate["manifestCommit"] = initialCommit
        var polled = try store.applyDeploymentStatus(["results": [candidate]])
        try expect(rows(polled).first?["status"] as? String == "uploaded", "An old manifest cannot falsely verify website deletion")
        candidate["manifestCommit"] = row["commit"]
        polled = try store.applyDeploymentStatus(["results": [candidate]])
        try expect(rows(polled).first?["status"] as? String == "deleted", "Manifest at known deletion commit verifies website removal")
        var stalePublication = row; stalePublication.removeValue(forKey: "operation"); stalePublication["status"] = "live"
        polled = try store.applyDeploymentStatus(["results": [stalePublication]])
        try expect(!(polled["publications"] as! [[String: Any]]).contains { $0["path"] as? String == path }, "Stale ordinary publication reports cannot resurrect deleted targets")
        // Imported removal/deletion metadata is inert; unpublished held source is history only.
        let recipient = RepositoryStore(root: root.appendingPathComponent("deletion-import"), remoteURL: remote.path, identity: identity)
        let imported = try recipient.restoreBackup(hiddenBackup)
        try expect(rows(imported).isEmpty && !(try recipient.deploymentTargets()["targets"] as! [[String: Any]]).contains { $0["operation"] as? String == "delete" }, "Backup import never activates local removals or remote deletion intents")
        try expect(!(try recipient.handle(method: "listHistory", params: ["path": path])["entries"] as! [[String: Any]]).isEmpty, "Imported unpublished removed draft is preserved in history")
        // Root pages are deletable with the same second gate, without phantom root routes.
        let hiddenHome = try hide("index.md"), homePlan = try plan("index.md", hiddenHome)
        try expect(!(captured["routes"] as! [String]).contains("/"), "Deleting index does not invent a remaining root route")
        _ = try confirm(homePlan)
        let hidden404 = try hide("404.md"), missingPlan = try plan("404.md", hidden404)
        try expect(!(captured["routes"] as! [String]).contains("/404.html"), "Deleting404 does not invent a remaining404 route")
        _ = try confirm(missingPlan)
        try rejects("Home source must be erased after second confirmation") { _ = try git(["show", "main:index.md"], at: remote) }
        try rejects("404 source must be erased after second confirmation") { _ = try git(["show", "main:404.md"], at: remote) }
        let hiddenWildcard = try hide(wildcard), wildcardPlan = try plan(wildcard, hiddenWildcard)
        _ = try confirm(wildcardPlan)
        try rejects("Literal wildcard and bracket source must be removed") { _ = try git(["cat-file", "-e", "main:\(wildcard)"], at: remote) }
        try expect(try git(["show", "main:\(neighbor)"], at: remote) == raw("Matching neighbor", body: "Keep this exact source"), "Git pathspec characters must not delete a matching neighbor")
        // Competing remote commit wins safely: no force, no auto-retry, local removal retained.
        let hiddenOther = try hide(other), otherPlan = try plan(other, hiddenOther)
        race = true
        let raced = try confirm(otherPlan)
        try expect((raced["deletion"] as! [String: Any])["status"] as? String == "failed", "A non-fast-forward push must be a rejected deletion")
        try expect(rows(raced).first { $0["path"] as? String == other }?["status"] as? String == "local", "Rejected deletion remains restorable and reviewable")
        try expect(try git(["show", "main:\(other)"], at: remote).contains("CMS changed"), "A competing push preserves the source")
        let remoteAfterRace = try git(["rev-parse", "main"], at: remote)
        _ = try process(store)
        try expect(try git(["rev-parse", "main"], at: remote) == remoteAfterRace, "Queue processing never retries deletion")
        // Offline first-stage removal works, while remote erasure remains blocked.
        let localPath = "_docs/offline.md"
        _ = try store.handle(method: "createArticle", params: ["path": localPath, "rawContent": raw("Offline", body: "Local only")])
        let movedRemote = root.appendingPathComponent("offline-deletion-remote.git")
        try fm.moveItem(at: remote, to: movedRemote)
        let localRemoved = try hide(localPath)
        try expect((localRemoved["localRemoval"] as! [String: Any])["scope"] as? String == "local", "Offline local-only draft removal never needs GitHub")
        let offlinePlan = try plan(other, raced)
        try expect(offlinePlan["canDelete"] as? Bool == false, "Offline GitHub deletion is blocked rather than queued")
        try fm.moveItem(at: movedRemote, to: remote)
        _ = try store.handle(method: "restoreLocalRemoval", params: ["path": other])
        // A durable intent models a crash after push. Fetch/disk failure cannot lose it or retry it.
        let intentHidden = try hide(other), intentRow = rows(intentHidden).first { $0["path"] as? String == other }!
        let parent = try git(["rev-parse", "main"], at: remote).trimmingCharacters(in: .whitespacesAndNewlines)
        try git(["pull", "--ff-only", "origin", "main"], at: source); try git(["rm", "--", other], at: source)
        try git(["commit", "-m", "Simulated confirmed deletion before app crash"], at: source)
        let plannedCommit = try git(["rev-parse", "HEAD"], at: source).trimmingCharacters(in: .whitespacesAndNewlines)
        let privateRef = "refs/nightingale/deletions/test-intent"
        try git(["fetch", source.path, "HEAD:\(privateRef)"], at: app.appendingPathComponent("repository.git"))
        var stateJSON = try JSONSerialization.jsonObject(with: Data(contentsOf: stateFile)) as! [String: Any]
        stateJSON["deletionIntents"] = [other: ["commit": plannedCommit, "parentCommit": parent, "sourceSHA256": intentRow["sourceSHA256"]!, "expectedRevision": intentRow["expectedRevision"]!, "remoteBlob": intentRow["expectedRemoteBlob"]!, "liveURL": intentRow["liveURL"]!, "createdAt": "2026-11-02T00:00:00Z", "retainedRef": privateRef]]
        try JSONSerialization.data(withJSONObject: stateJSON).write(to: stateFile, options: .atomic)
        let pending = RepositoryStore(root: app, remoteURL: remote.path, identity: identity, validation: validator)
        let pendingSnapshot = try pending.handle(method: "bootstrap")
        try expect(rows(pendingSnapshot).first { $0["path"] as? String == other }?["status"] as? String == "unknown", "Unresolved intent stays unknown before ancestry confirmation")
        let uncertainMessage = status(pendingSnapshot)["message"] as! String
        try expect(uncertainMessage.contains("not been confirmed") && !uncertainMessage.contains("unchanged"), "Unresolved intent footer must honestly describe uncertain remote state")
        _ = try process(pending)
        try expect(try git(["rev-parse", "main"], at: remote).trimmingCharacters(in: .whitespacesAndNewlines) == parent, "Relaunch and queue processing cannot execute a durable intent")
        var falseUpload = rows(pendingSnapshot).first { $0["path"] as? String == other }!; falseUpload["status"] = "uploaded"
        let stillUnknown = try pending.applyDeploymentStatus(["results": [falseUpload]])
        try expect(rows(stillUnknown).first { $0["path"] as? String == other }?["status"] as? String == "unknown", "Deployment polling alone cannot settle an ambiguous Git push")
        // Explicit retry is safe even after a timeout: it publishes exactly the retained commit.
        let retryRemote = root.appendingPathComponent("retry-deletion-remote.git"), retryApp = root.appendingPathComponent("retry-deletion-data")
        try fm.copyItem(at: remote, to: retryRemote); try fm.copyItem(at: app, to: retryApp)
        try git(["remote", "set-url", "origin", retryRemote.path], at: retryApp.appendingPathComponent("repository.git"))
        let retryStore = RepositoryStore(root: retryApp, remoteURL: retryRemote.path, identity: identity, validation: validator)
        let retryReview = try retryStore.handle(method: "prepareDeletion", params: ["path": other, "expectedRevision": intentRow["expectedRevision"]!])
        try expect(retryReview["canDelete"] as? Bool == true && retryReview["retrying"] as? Bool == true, "Explicit retry review permits the unchanged original parent and blob")
        let retryResult = try retryStore.handle(method: "deleteArticle", params: ["path": other, "scope": "published", "expectedRevision": retryReview["expectedRevision"]!, "expectedRemoteBlob": retryReview["expectedRemoteBlob"]!, "confirmation": "DELETE"])
        try expect((retryResult["deletion"] as! [String: Any])["commit"] as? String == plannedCommit, "Explicit retry must reuse the persisted commit identity")
        try expect(try git(["rev-parse", "main"], at: retryRemote).trimmingCharacters(in: .whitespacesAndNewlines) == plannedCommit, "Retry pushes exactly the original planned deletion")
        try expect(try git(["rev-parse", "main"], at: remote).trimmingCharacters(in: .whitespacesAndNewlines) == parent, "Retry fixture cannot alter the independent crash-recovery remote")
        try git(["push", "origin", "main"], at: source)
        try fm.moveItem(at: stateFile, to: savedState); try fm.createDirectory(at: stateFile, withIntermediateDirectories: false)
        try rejects("Post-push reconciliation storage failure must be reported") { _ = try pending.handle(method: "refresh") }
        try fm.removeItem(at: stateFile); try fm.moveItem(at: savedState, to: stateFile)
        try expect(status(try pending.handle(method: "bootstrap"))["message"] as? String == uncertainMessage, "Post-push storage failure must retain the durable uncertain message")
        let recovered = RepositoryStore(root: app, remoteURL: remote.path, identity: identity, validation: validator)
        let settled = try recovered.handle(method: "bootstrap")
        try expect(rows(settled).first { $0["path"] as? String == other }?["status"] as? String == "uploaded", "Relaunch reconciles already pushed deletion through cached commit ancestry")
        try expect((status(settled)["message"] as! String).contains("source was erased"), "Relaunch reconciliation persists the truthful uploaded footer")
        try expect(!all(settled).contains { $0["path"] as? String == other }, "Post-push recovery cannot recreate erased source from stale cache")
        let deletionBackup = try recovered.exportBackup()
        let cleanRecipient = RepositoryStore(root: root.appendingPathComponent("tombstone-import"), remoteURL: remote.path, identity: identity)
        try expect(rows(try cleanRecipient.restoreBackup(deletionBackup)).isEmpty, "Imported deletion records never become active monitoring or execution state")
        // A newer known descendant manifest also verifies removal; a random unknown SHA does not.
        try write("New deployment", "unrelated.txt", at: source); try git(["add", "unrelated.txt"], at: source)
        try git(["commit", "-m", "Newer deployment"], at: source); try git(["push", "origin", "main"], at: source)
        let later = try recovered.handle(method: "refresh")
        var laterCandidate = rows(later).first { $0["path"] as? String == other }!; laterCandidate["status"] = "deleted"; laterCandidate["manifestCommit"] = String(repeating: "a", count: 40)
        try expect(rows(try recovered.applyDeploymentStatus(["results": [laterCandidate]])).first { $0["path"] as? String == other }?["status"] as? String == "uploaded", "Unknown manifest SHA cannot prove removal")
        laterCandidate["manifestCommit"] = try git(["rev-parse", "HEAD"], at: source).trimmingCharacters(in: .whitespacesAndNewlines)
        try expect(rows(try recovered.applyDeploymentStatus(["results": [laterCandidate]])).first { $0["path"] as? String == other }?["status"] as? String == "deleted", "Known descendant manifest verifies removal")
        try write(raw("Recreated", body: "Deliberately recreated in CMS"), other, at: source)
        try git(["add", other], at: source); try git(["commit", "-m", "Recreate article"], at: source); try git(["push", "origin", "main"], at: source)
        let recreated = try recovered.handle(method: "refresh")
        try expect(all(recreated).contains { $0["path"] as? String == other } && !rows(recreated).contains { $0["path"] as? String == other }, "Intentional external recreation clears old deletion status")
    }

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

        // Upgrade existing local storage without changing drafts, queued versions, or conflicts.
        let categoryDataRoot = root.appendingPathComponent("category-app-data")
        let categorySeed = RepositoryStore(root: categoryDataRoot, remoteURL: remote.path, seedRepo: source, identity: identity)
        _ = try categorySeed.handle(method: "bootstrap")
        let categoryDraftPath = "_docs/2026-11-01-category-migration.md"
        let categoryDraftRaw = raw("Migration draft", body: "This draft and its queued snapshot must survive the storage upgrade.")
        _ = try categorySeed.handle(method: "createArticle", params: ["path": categoryDraftPath, "rawContent": categoryDraftRaw])
        try queue(categorySeed, categoryDraftPath)
        let categoryStatePath = categoryDataRoot.appendingPathComponent("state.json")
        var legacyState = try JSONSerialization.jsonObject(with: Data(contentsOf: categoryStatePath)) as! [String: Any]
        legacyState.removeValue(forKey: "categories")
        legacyState["conflicts"] = [categoryDraftPath: ["base": "", "local": categoryDraftRaw, "remote": "A preserved online version."]]
        legacyState["state"] = "conflict"
        legacyState["message"] = "Conflicting edits need review. Both versions are saved."
        try JSONSerialization.data(withJSONObject: legacyState).write(to: categoryStatePath, options: .atomic)
        let legacyDrafts = legacyState["drafts"] as! NSDictionary
        let legacyQueue = legacyState["queue"] as! NSDictionary
        let legacyConflicts = legacyState["conflicts"] as! NSDictionary
        let remoteBeforeCategory = try git(["rev-parse", "main"], at: remote)
        let categoryStore = RepositoryStore(root: categoryDataRoot, remoteURL: remote.path, identity: identity)
        let upgraded = try categoryStore.handle(method: "bootstrap")
        try expect(upgraded["categories"] as? [String] == [], "Old state without categories must load with an empty category list")
        try expect(status(upgraded)["queuedCount"] as? Int == 1 && status(upgraded)["draftCount"] as? Int == 1, "Migration must preserve draft and queue counts")
        let createdCategory = try categoryStore.handle(method: "createCategory", params: ["name": "  Cafe\u{301}  "])
        let canonicalCategory = createdCategory["category"] as! String
        try expect(canonicalCategory.utf8.elementsEqual("Café".utf8), "Category creation must trim and precompose Unicode")
        try expect(createdCategory["categories"] as? [String] == ["Café"], "An explicit empty category must be returned in bootstrap")
        try expect(status(createdCategory)["state"] as? String == "conflict", "Creating a category must not clear the existing sync state")
        let duplicateCategory = try categoryStore.handle(method: "createCategory", params: ["name": "CAFÉ"])
        try expect(duplicateCategory["category"] as? String == "Café" && duplicateCategory["categories"] as? [String] == ["Café"], "Case-insensitive duplicates must return the original canonical category")
        let savedCategoryState = try JSONSerialization.jsonObject(with: Data(contentsOf: categoryStatePath)) as! [String: Any]
        try expect(legacyDrafts.isEqual(savedCategoryState["drafts"]), "Category storage must retain original draft data")
        try expect(legacyQueue.isEqual(savedCategoryState["queue"]), "Category storage must retain original publication snapshot")
        try expect(legacyConflicts.isEqual(savedCategoryState["conflicts"]), "Category storage must retain all conflict versions")
        let categoryRestart = RepositoryStore(root: categoryDataRoot, remoteURL: remote.path, identity: identity)
        let restartedCategories = try categoryRestart.handle(method: "bootstrap")
        try expect(restartedCategories["categories"] as? [String] == ["Café"], "Empty categories must survive app restart")
        let refreshedCategories = try categoryRestart.handle(method: "refresh")
        try expect(refreshedCategories["categories"] as? [String] == ["Café"], "Empty categories must survive repository synchronization")
        try expect(try git(["rev-parse", "main"], at: remote) == remoteBeforeCategory, "Category creation must not publish or change Git history")
        for name in ["", "   ", "A\nB", "A\rB", "\tTab", "Null\u{0}", "Line\u{2028}break", String(repeating: "界", count: 81)] {
            try rejects("Invalid category name must be rejected") { _ = try categoryRestart.handle(method: "createCategory", params: ["name": name]) }
        }
        let longestCategory = String(repeating: "界", count: 80)
        let validLongCategory = try categoryRestart.handle(method: "createCategory", params: ["name": longestCategory])
        try expect(validLongCategory["category"] as? String == longestCategory, "An 80-character Unicode category must be accepted")

        // Rolling local history survives discarded files; restoration cannot bypass publication intent.
        let recoveryRoot = root.appendingPathComponent("recovery-data")
        let recovery = RepositoryStore(root: recoveryRoot, remoteURL: remote.path, seedRepo: source, identity: identity)
        _ = try recovery.handle(method: "bootstrap")
        let recoveryPath = "_docs/2026-11-02-recover-me.md"
        let firstVersion = raw("Recovery", body: "First local version")
        _ = try recovery.handle(method: "createArticle", params: ["path": recoveryPath, "rawContent": firstVersion])
        try save(recovery, recoveryPath, raw("Recovery", body: "Second version"))
        let historyBeforeCoalescing = (try recovery.handle(method: "listHistory", params: ["path": recoveryPath])["entries"] as! [[String: Any]]).count
        try save(recovery, recoveryPath, raw("Recovery", body: "Third version"))
        let history = try recovery.handle(method: "listHistory", params: ["path": recoveryPath])["entries"] as! [[String: Any]]
        try expect(history.count == historyBeforeCoalescing, "Autosave history must coalesce within30seconds")
        let originalHistory = history.first { $0["reason"] as? String == "created" }!
        let originalID = originalHistory["id"] as! String
        try queue(recovery, recoveryPath)
        try rejects("History cannot replace an actively queued article") { _ = try recovery.handle(method: "restoreHistory", params: ["path": recoveryPath, "id": originalID, "expectedRevision": item(recovery, recoveryPath)["revision"]!]) }
        _ = try recovery.handle(method: "cancelQueued", params: ["path": recoveryPath])
        try rejects("History restoration must check the currently viewed revision") { _ = try recovery.handle(method: "restoreHistory", params: ["path": recoveryPath, "id": originalID, "expectedRevision": "stale"]) }
        _ = try recovery.handle(method: "discardDraft", params: ["path": recoveryPath])
        let globalHistory = try recovery.handle(method: "listHistory")["entries"] as! [[String: Any]]
        try expect(globalHistory.contains { $0["path"] as? String == recoveryPath }, "Discarded articles must remain discoverable in global history")
        let restoredHistory = try recovery.handle(method: "restoreHistory", params: ["path": recoveryPath, "id": originalID])
        try expect(try item(recovery, recoveryPath)["rawContent"] as? String == firstVersion, "An absent article can be recovered from history")
        try expect(status(restoredHistory)["queuedCount"] as? Int == 0, "History restore must not queue publication")
        try rejects("History IDs cannot traverse the filesystem") { _ = try recovery.handle(method: "readHistory", params: ["path": recoveryPath, "id": "../../state"]) }

        // Backup merging preserves existing drafts/queues; imported queued versions are inert recovery data.
        let donorRoot = root.appendingPathComponent("donor-data")
        let donor = RepositoryStore(root: donorRoot, remoteURL: remote.path, seedRepo: source, identity: identity)
        _ = try donor.handle(method: "bootstrap")
        _ = try donor.handle(method: "createArticle", params: ["path": recoveryPath, "rawContent": raw("Recovery", body: "Conflicting imported version")])
        let importedPath = "_docs/2026-11-02-import-me.md"
        let donorImage = try donor.handle(method: "importImage", params: ["filename": "backup-image.png", "base64": png])
        let donorRaw = raw("Imported", body: "Queued in the old backup. ![Image](\(donorImage["path"] as! String))")
        _ = try donor.handle(method: "createArticle", params: ["path": importedPath, "rawContent": donorRaw])
        try queue(donor, importedPath)
        try queue(recovery, recoveryPath)
        let beforeRestoreQueue = try JSONSerialization.jsonObject(with: Data(contentsOf: recoveryRoot.appendingPathComponent("state.json"))) as! [String: Any]
        let beforeRestoreHead = try git(["rev-parse", "main"], at: remote)
        let backupData = try donor.exportBackup()
        let backupSummary = try recovery.inspectBackup(backupData)
        try expect(backupSummary["assetCount"] as? Int == 1, "Backup export must include staged assets through macOS temporary-path aliases")
        try expect(backupSummary["existingDraftCollisions"] as? Int == 1, "Backup inspection must disclose existing draft collisions")
        let backupImported = try recovery.restoreBackup(backupData)
        try expect(try item(recovery, recoveryPath)["rawContent"] as? String == firstVersion, "Import must preserve the current local draft")
        try expect(try item(recovery, importedPath)["rawContent"] as? String == donorRaw, "Nonconflicting imported drafts must be recoverable")
        try expect(try item(recovery, importedPath)["isQueued"] as? Bool == false, "Imported queue entries must never become active")
        try expect(status(backupImported)["queuedCount"] as? Int == 1, "Only the existing queue must remain active")
        let afterRestoreState = try JSONSerialization.jsonObject(with: Data(contentsOf: recoveryRoot.appendingPathComponent("state.json"))) as! [String: Any]
        try expect((beforeRestoreQueue["queue"] as! NSDictionary).isEqual(afterRestoreState["queue"]), "Backup import cannot alter existing queued snapshots")
        try expect(try git(["rev-parse", "main"], at: remote) == beforeRestoreHead, "Backup restore must not publish anything")
        let importedHistory = try recovery.handle(method: "listHistory", params: ["path": recoveryPath])["entries"] as! [[String: Any]]
        try expect(importedHistory.contains { $0["reason"] as? String == "imported-conflict" }, "Conflicting imported draft must be retained in history")
        try expect(try recovery.handle(method: "readAsset", params: ["path": donorImage["path"]!])["base64"] as? String == png, "Backup must restore staged images for offline preview")
        var invalidBackup = try JSONSerialization.jsonObject(with: backupData) as! [String: Any]
        invalidBackup["repository"] = "https://example.invalid/other.git"
        try rejects("Backups for other repositories must be rejected") { _ = try recovery.inspectBackup(JSONSerialization.data(withJSONObject: invalidBackup)) }
        invalidBackup = try JSONSerialization.jsonObject(with: backupData) as! [String: Any]
        var badAssets = invalidBackup["assets"] as! [[String: Any]]
        badAssets[0]["path"] = "images/uploads/../../../escape.png"; invalidBackup["assets"] = badAssets
        try rejects("Backup asset traversal must be rejected") { _ = try recovery.restoreBackup(JSONSerialization.data(withJSONObject: invalidBackup)) }

        // Failed restoration is transactional for new drafts, history, and staged assets.
        let atomicPath = "_docs/2026-11-02-atomic-import.md"
        _ = try donor.handle(method: "createArticle", params: ["path": atomicPath, "rawContent": raw("Atomic", body: "Must not partly restore")])
        let atomicImage = try donor.handle(method: "importImage", params: ["filename": "atomic-image.png", "base64": png])
        let atomicData = try donor.exportBackup()
        let receiverState = recoveryRoot.appendingPathComponent("state.json")
        let receiverSaved = recoveryRoot.appendingPathComponent("saved-state.json")
        try fm.moveItem(at: receiverState, to: receiverSaved); try fm.createDirectory(at: receiverState, withIntermediateDirectories: false)
        try rejects("A failed state write must abort backup restoration") { _ = try recovery.restoreBackup(atomicData) }
        try fm.removeItem(at: receiverState); try fm.moveItem(at: receiverSaved, to: receiverState)
        try rejects("An aborted backup cannot leave a new draft") { _ = try item(recovery, atomicPath) }
        try expect(!fm.fileExists(atPath: recoveryRoot.appendingPathComponent("assets").appendingPathComponent(String((atomicImage["path"] as! String).dropFirst())).path), "Aborted restore must remove newly created staged assets")
        try expect(try item(recovery, recoveryPath)["rawContent"] as? String == firstVersion, "Aborted restore must preserve existing local content")
        let recoveryRestart = RepositoryStore(root: recoveryRoot, remoteURL: remote.path, identity: identity)
        try expect(status(try recoveryRestart.handle(method: "bootstrap"))["queuedCount"] as? Int == 1, "Backup restore semantics must survive restart")

        // Daily backups refresh after the throttle and retain20 dates independently from import checkpoints.
        let backupsDirectory = recoveryRoot.appendingPathComponent("backups")
        let daily = try fm.contentsOfDirectory(at: backupsDirectory, includingPropertiesForKeys: nil).first { !$0.lastPathComponent.hasPrefix("before-import-") }!
        try fm.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -301)], ofItemAtPath: daily.path)
        try save(recoveryRestart, importedPath, raw("Imported", body: "A newer meaningful draft change"))
        let dailyContent = try JSONSerialization.jsonObject(with: Data(contentsOf: daily)) as! [String: Any]
        let dailyState = dailyContent["state"] as! [String: Any]
        try expect(((dailyState["drafts"] as! [String: Any])[importedPath] as! [String: Any])["rawContent"] as? String == raw("Imported", body: "A newer meaningful draft change"), "Today's snapshot must refresh with later meaningful changes")
        for day in 1...25 { try Data("{}".utf8).write(to: backupsDirectory.appendingPathComponent(String(format: "2020-01-%02d.nightingale-backup.json", day))) }
        _ = try recoveryRestart.handle(method: "cancelQueued", params: ["path": recoveryPath])
        _ = try recoveryRestart.handle(method: "discardDraft", params: ["path": recoveryPath])
        let retained = try fm.contentsOfDirectory(at: backupsDirectory, includingPropertiesForKeys: nil)
        try expect(retained.filter { !$0.lastPathComponent.hasPrefix("before-import-") }.count == 20, "Daily retention must keep20 snapshots")
        try expect(retained.contains { $0.lastPathComponent.hasPrefix("before-import-") }, "Import checkpoints must not displace daily backups")

        for _ in 0..<105 { try queue(recoveryRestart, importedPath) }
        let boundedHistory = try recoveryRestart.handle(method: "listHistory", params: ["path": importedPath])["entries"] as! [[String: Any]]
        try expect(boundedHistory.count == 100, "Milestone history must retain at most100 versions per article")
        _ = try recoveryRestart.handle(method: "cancelQueued", params: ["path": importedPath])

        // Publication reports bind to the uploaded source and commit; source-only changes never mean Live.
        let publisher = RepositoryStore(root: root.appendingPathComponent("publication-data"), remoteURL: remote.path, seedRepo: source, identity: identity)
        _ = try publisher.handle(method: "bootstrap"); _ = try publisher.handle(method: "refresh")
        let publicationPath = "_docs/2026-11-02-publication-status.md"
        _ = try publisher.handle(method: "createArticle", params: ["path": publicationPath, "rawContent": raw("Publishing", body: "First uploaded revision")])
        try queue(publisher, publicationPath); _ = try process(publisher)
        let publication = try item(publisher, publicationPath)["publication"] as! [String: Any]
        try expect(publication["status"] as? String == "uploaded", "A successful Git push is Uploaded, never implicitly Live")
        try expect((publication["commit"] as? String)?.count == 40, "Publication must retain the uploaded commit")
        var observation = publication; observation["status"] = "live"; observation["checkedAt"] = "2026-11-02T12:00:00Z"; observation["liveURL"] = "https://nightingalelyy.github.io/custom-publishing-route/"
        _ = try publisher.applyDeploymentStatus(["results": [observation]])
        let live = try item(publisher, publicationPath)["publication"] as! [String: Any]
        try expect(live["status"] as? String == "live", "Verified manifest observation must mark the matching revision Live")
        try expect(live["liveURL"] as? String == observation["liveURL"] as? String, "Verified same-site permalink must be retained")
        var stale = observation; stale["sourceSHA256"] = String(repeating: "0", count: 64); stale["status"] = "failed"
        _ = try publisher.applyDeploymentStatus(["results": [stale]])
        try expect((try item(publisher, publicationPath)["publication"] as! [String: Any])["status"] as? String == "live", "Stale source-hash results cannot overwrite current publication state")
        stale = observation; stale["commit"] = String(repeating: "0", count: 40); stale["status"] = "failed"
        _ = try publisher.applyDeploymentStatus(["results": [stale]])
        try expect((try item(publisher, publicationPath)["publication"] as! [String: Any])["status"] as? String == "live", "Stale commit results cannot overwrite publication state")
        stale = observation; stale["liveURL"] = "https://example.invalid/phishing"; stale["status"] = "failed"
        _ = try publisher.applyDeploymentStatus(["results": [stale]])
        try expect((try item(publisher, publicationPath)["publication"] as! [String: Any])["status"] as? String == "live", "Deployment URLs outside the personal site must be rejected")
        var failedObservation = observation; failedObservation["status"] = "failed"; failedObservation["checkedAt"] = "2026-11-02T12:01:00Z"
        _ = try publisher.applyDeploymentStatus(["results": [failedObservation]])
        try expect((try item(publisher, publicationPath)["publication"] as! [String: Any])["status"] as? String == "failed", "A matching failed deployment must be represented honestly")
        try save(publisher, publicationPath, raw("Publishing", body: "A newer local-only draft"))
        try expect((try item(publisher, publicationPath)["publication"] as! [String: Any])["matchesCurrentRevision"] as? Bool == false, "A newer local draft must not inherit the earlier revision's Live badge")

        // Validate both the queued version and refreshed publication snapshot; validation failures never push.
        var allowValidation = false
        var validationCalls: [[String: Any]] = []
        let guarded = RepositoryStore(root: root.appendingPathComponent("validation-data"), remoteURL: remote.path, seedRepo: source, identity: identity, validation: { payload in
            validationCalls.append(payload)
            return ["ok": allowValidation, "issues": allowValidation ? [] : [["severity": "error", "message": "Invalid fixture"]], "summary": ["documents": 1, "codeBlocks": 0]]
        })
        _ = try guarded.handle(method: "bootstrap"); _ = try guarded.handle(method: "refresh")
        let guardedPath = "_docs/2026-11-02-validation-gate.md"
        let guardedRaw = raw("Validation", body: "An exact queued snapshot")
        _ = try guarded.handle(method: "createArticle", params: ["path": guardedPath, "rawContent": guardedRaw])
        try rejects("Validation errors must stop queueing") { try queue(guarded, guardedPath) }
        allowValidation = true
        try rejects("A stale validated editor revision must not queue") { _ = try guarded.handle(method: "queuePublish", params: ["path": guardedPath, "expectedRevision": "stale"]) }
        try queue(guarded, guardedPath)
        try save(guarded, guardedPath, raw("Validation", body: "A later unqueued edit"))
        allowValidation = false
        let preBlockedHead = try git(["rev-parse", "main"], at: remote)
        let blocked = try process(guarded)
        try expect(status(blocked)["queuedCount"] as? Int == 1, "A blocked publication must retain its queue snapshot")
        try expect(try git(["rev-parse", "main"], at: remote) == preBlockedHead, "Publish-time validation failure must leave remote unchanged")
        let validatedDocuments = validationCalls.last!["documents"] as! [[String: Any]]
        try expect(validatedDocuments[0]["rawContent"] as? String == guardedRaw, "Publish-time validation must use the queued version, not later local edits")

        // Corrupt state opens a read-only library and is never silently replaced with empty data.
        let corruptRoot = root.appendingPathComponent("corrupt-state-data")
        let seedCorrupt = RepositoryStore(root: corruptRoot, remoteURL: remote.path, seedRepo: source, identity: identity)
        _ = try seedCorrupt.handle(method: "bootstrap")
        let corruptFile = corruptRoot.appendingPathComponent("state.json")
        let corruptBytes = Data("{broken local draft storage\\n".utf8)
        try corruptBytes.write(to: corruptFile)
        let recoveringStore = RepositoryStore(root: corruptRoot, remoteURL: remote.path, seedRepo: source, identity: identity)
        let recoveryBootstrap = try recoveringStore.handle(method: "bootstrap")
        try expect((recoveryBootstrap["recovery"] as! [String: Any])["needsRestore"] as? Bool == true, "Corrupt storage must enter explicit recovery mode")
        try expect(!all(recoveryBootstrap).isEmpty, "Published library must remain readable during recovery")
        try expect(try Data(contentsOf: corruptFile) == corruptBytes, "Bootstrap must preserve corrupt bytes exactly")
        for method in ["createCategory", "createArticle", "processQueue", "refresh", "discardDraft", "restoreHistory", "importImage", "renameCategory", "mergeCategory", "saveTemplate", "removeTemplate", "removeLocally", "restoreLocalRemoval", "prepareDeletion", "deleteArticle"] {
            try rejects("Recovery must block mutation: \(method)") { _ = try recoveringStore.handle(method: method) }
        }
        try rejects("Recovery export must not produce a misleading empty backup") { _ = try recoveringStore.exportBackup() }
        _ = try recoveringStore.applyDeploymentStatus(["results": []])
        try expect(try Data(contentsOf: corruptFile) == corruptBytes, "Deployment polling must not rewrite unreadable state")
        _ = try recoveringStore.inspectBackup(backupData)
        try rejects("Invalid recovery backup must be rejected") { _ = try recoveringStore.restoreBackup(Data("{}".utf8)) }
        try expect(try Data(contentsOf: corruptFile) == corruptBytes, "Invalid restore must leave original corrupt bytes intact")
        // Force a staging failure after the private checkpoint, before the atomic state commit.
        let blockedHistory = corruptRoot.appendingPathComponent("history")
        try Data("not a directory".utf8).write(to: blockedHistory)
        try rejects("A staged recovery failure must not replace unreadable state") { _ = try recoveringStore.restoreBackup(backupData) }
        try expect(try Data(contentsOf: corruptFile) == corruptBytes, "Recovery failure must preserve original state bytes")
        try expect((try recoveringStore.handle(method: "bootstrap")["recovery"] as! [String: Any])["needsRestore"] as? Bool == true, "Failed recovery must stay read-only")
        try fm.removeItem(at: blockedHistory)
        let beforeRecoveryHead = try git(["rev-parse", "main"], at: remote)
        let recoveredBackup = try recoveringStore.restoreBackup(backupData)
        try expect((recoveredBackup["recovery"] as! [String: Any])["needsRestore"] as? Bool == false, "A successful valid restore must leave recovery mode")
        try expect(status(recoveredBackup)["queuedCount"] as? Int == 0, "Corrupt-state recovery must never reactivate imported queues")
        try expect(try item(recoveringStore, importedPath)["rawContent"] as? String == donorRaw, "Recovered draft must match the chosen backup")
        let checkpoint = (recoveredBackup["backupResult"] as! [String: Any])["corruptStateCheckpoint"] as! String
        try expect(try Data(contentsOf: URL(fileURLWithPath: checkpoint)) == corruptBytes, "Original unreadable bytes must remain recoverable after success")
        let checkpointPermissions = try fm.attributesOfItem(atPath: checkpoint)[.posixPermissions] as! NSNumber
        try expect(checkpointPermissions.intValue & 0o777 == 0o600, "The corrupt-state checkpoint must be private")
        try expect(try git(["rev-parse", "main"], at: remote) == beforeRecoveryHead, "Recovery must not publish any article")
        let recoveredRestart = RepositoryStore(root: corruptRoot, remoteURL: remote.path, identity: identity)
        try expect((try recoveredRestart.handle(method: "bootstrap")["recovery"] as! [String: Any])["needsRestore"] as? Bool == false, "Recovered valid storage must load normally after restart")

        do {
            // Category changes prepare all rows first, then commit local drafts as one transaction.
            let managementRoot = root.appendingPathComponent("management-data")
            let management = RepositoryStore(root: managementRoot, remoteURL: remote.path, seedRepo: source, identity: identity)
            _ = try management.handle(method: "bootstrap")
            let secondPath = "_docs/2026-11-02-category-batch.md"
            _ = try management.handle(method: "createArticle", params: ["path": secondPath, "rawContent": raw("Second", body: "Body and code must not change.\n\n```cpp\nint value = 7;\n```")])
            let affected = [articlePath, secondPath]
            func categoryPayload(_ store: RepositoryStore, from: String, to: String) throws -> [String: Any] {
                let snapshot = try store.handle(method: "bootstrap")
                let revisions = Dictionary(uniqueKeysWithValues: all(snapshot).map { ($0["path"] as! String, $0["revision"] as! String) })
                let changes: [[String: Any]] = try affected.map { path in
                    let article = try item(store, path)
                    return ["path": path, "expectedRevision": article["revision"]!, "rawContent": (article["rawContent"] as! String).replacingOccurrences(of: "category: \(from)\n", with: "category: \(to)\n")]
                }
                return ["from": from, "to": to, "expectedRevisions": revisions, "changes": changes]
            }
            let staleBatch = try categoryPayload(management, from: "Articles", to: "Writing")
            try save(management, "index.md", "---\ntitle: Homepage\n---\nUnrelated newer edit.\n")
            try rejects("A category batch must guard unrelated library revisions too") { _ = try management.handle(method: "renameCategory", params: staleBatch) }
            try expect(try item(management, articlePath)["rawContent"] as? String == original, "A stale category batch cannot partially change its first article")
            var incomplete = try categoryPayload(management, from: "Articles", to: "Writing")
            var partialRevisions = incomplete["expectedRevisions"] as! [String: String]; partialRevisions.removeValue(forKey: "404.md"); incomplete["expectedRevisions"] = partialRevisions
            try rejects("The category snapshot must include every library path") { _ = try management.handle(method: "renameCategory", params: incomplete) }
            var badRow = try categoryPayload(management, from: "Articles", to: "Writing")
            var badChanges = badRow["changes"] as! [[String: Any]]; badChanges[1]["expectedRevision"] = "stale"; badRow["changes"] = badChanges
            try rejects("Every affected row must match its saved revision") { _ = try management.handle(method: "renameCategory", params: badRow) }
            var changedBody = try categoryPayload(management, from: "Articles", to: "Writing")
            var bodyChanges = changedBody["changes"] as! [[String: Any]]; bodyChanges[0]["rawContent"] = (bodyChanges[0]["rawContent"] as! String) + "Unintended text edit.\n"; changedBody["changes"] = bodyChanges
            try rejects("Category changes cannot alter body text or code") { _ = try management.handle(method: "renameCategory", params: changedBody) }
            try queue(management, secondPath)
            try rejects("Queued affected articles must block the whole category batch") { _ = try management.handle(method: "renameCategory", params: categoryPayload(management, from: "Articles", to: "Writing")) }
            _ = try management.handle(method: "cancelQueued", params: ["path": secondPath])
            let beforeCategoryState = try JSONSerialization.jsonObject(with: Data(contentsOf: managementRoot.appendingPathComponent("state.json"))) as! [String: Any]
            let secondBase = (beforeCategoryState["drafts"] as! [String: Any])[secondPath] as! [String: Any]
            let unchangedRemote = try git(["rev-parse", "main"], at: remote)
            let renamed = try management.handle(method: "renameCategory", params: categoryPayload(management, from: "Articles", to: "Writing"))
            try expect((renamed["categoryChange"] as! [String: Any])["articlesChanged"] as? Int == 2, "Both category rows must change together")
            for path in affected {
                try expect((try item(management, path)["rawContent"] as! String).contains("category: Writing\n"), "Renamed articles must remain at their original paths")
                try expect(try item(management, path)["isDraft"] as? Bool == true, "Category updates must remain local drafts")
                try expect(try item(management, path)["isQueued"] as? Bool == false, "Category updates must not queue publication")
            }
            let afterCategoryState = try JSONSerialization.jsonObject(with: Data(contentsOf: managementRoot.appendingPathComponent("state.json"))) as! [String: Any]
            let secondAfter = (afterCategoryState["drafts"] as! [String: Any])[secondPath] as! [String: Any]
            try expect(secondBase["baseBlob"] == nil && secondAfter["baseBlob"] == nil, "An existing new draft must preserve its nil remote base")
            try expect(try git(["rev-parse", "main"], at: remote) == unchangedRemote, "Category management must never publish")
            let managementRestart = RepositoryStore(root: managementRoot, remoteURL: remote.path, identity: identity)
            let restoredManagement = try managementRestart.handle(method: "bootstrap")
            try expect((restoredManagement["categories"] as! [String]).contains("Writing"), "Renamed local categories must survive restart")
            _ = try managementRestart.handle(method: "createCategory", params: ["name": "Target"])
            let mergedCategory = try managementRestart.handle(method: "mergeCategory", params: categoryPayload(managementRestart, from: "Writing", to: "Target"))
            try expect((mergedCategory["categories"] as! [String]).filter { $0 == "Target" }.count == 1, "Merging must reuse one target category")
            try expect(!(mergedCategory["categories"] as! [String]).contains("Writing"), "Merging must remove the old explicit category")
            _ = try managementRestart.handle(method: "createCategory", params: ["name": "Empty"])
            let emptySnapshot = try managementRestart.handle(method: "bootstrap")
            let emptyRevisions = Dictionary(uniqueKeysWithValues: all(emptySnapshot).map { ($0["path"] as! String, $0["revision"] as! String) })
            let emptyRename = try managementRestart.handle(method: "renameCategory", params: ["from": "Empty", "to": "Unused", "expectedRevisions": emptyRevisions, "changes": []])
            try expect((emptyRename["categories"] as! [String]).contains("Unused"), "An empty local category can be renamed without moving files")

            // A failed disk write rolls back the entire batch and its new history entries.
            let batchBefore = try item(managementRestart, articlePath)["rawContent"] as! String
            let batchHistoryCount = (try managementRestart.handle(method: "listHistory")["entries"] as! [[String: Any]]).count
            let managementState = managementRoot.appendingPathComponent("state.json"), managementSaved = managementRoot.appendingPathComponent("saved-state.json")
            let failingBatch = try categoryPayload(managementRestart, from: "Target", to: "Atomic")
            try fm.moveItem(at: managementState, to: managementSaved); try fm.createDirectory(at: managementState, withIntermediateDirectories: false)
            try rejects("Failed category persistence must abort all changes") { _ = try managementRestart.handle(method: "renameCategory", params: failingBatch) }
            try fm.removeItem(at: managementState); try fm.moveItem(at: managementSaved, to: managementState)
            try expect(try item(managementRestart, articlePath)["rawContent"] as? String == batchBefore, "Failed category batch must preserve prior drafts")
            try expect((try managementRestart.handle(method: "listHistory")["entries"] as! [[String: Any]]).count == batchHistoryCount, "Failed category batch must roll back newly created history")
            var conflictState = try JSONSerialization.jsonObject(with: Data(contentsOf: managementState)) as! [String: Any]
            conflictState["conflicts"] = [articlePath: ["base": original, "local": batchBefore, "remote": "Unresolved remote edit"]]
            try JSONSerialization.data(withJSONObject: conflictState).write(to: managementState, options: .atomic)
            let conflictedManagement = RepositoryStore(root: managementRoot, remoteURL: remote.path, identity: identity)
            _ = try conflictedManagement.handle(method: "bootstrap")
            try rejects("Conflicted affected articles must block the category batch") { _ = try conflictedManagement.handle(method: "renameCategory", params: categoryPayload(conflictedManagement, from: "Target", to: "Blocked")) }

            // Templates are local reusable source, survive restart/backups, and never replace collisions.
            let templatesRoot = root.appendingPathComponent("template-data")
            let templatesStore = RepositoryStore(root: templatesRoot, remoteURL: remote.path, seedRepo: source, identity: identity)
            let legacyTemplateBoot = try templatesStore.handle(method: "bootstrap")
            try expect(legacyTemplateBoot["templates"] as? [[String: String]] == [], "Old storage without templates must load with an empty list")
            let templateRaw = "---\nauthor: Yuyang Liu\ncategory: Articles\ntags: [notes]\n---\n## Notes\n\n```cpp\n// Code goes here\n```\n"
            let savedTemplate = try templatesStore.handle(method: "saveTemplate", params: ["name": "  Café notes  ", "rawContent": templateRaw])["template"] as! [String: Any]
            let templateID = savedTemplate["id"] as! String
            try expect(savedTemplate["name"] as? String == "Café notes", "Template names must normalize whitespace")
            try expect(savedTemplate["rawContent"] as? String == templateRaw, "Template source must be preserved exactly")
            try rejects("Duplicate case-insensitive template names must be rejected") { _ = try templatesStore.handle(method: "saveTemplate", params: ["name": "CAFÉ NOTES", "rawContent": "other"]) }
            try rejects("Template contents must respect the size limit") { _ = try templatesStore.handle(method: "saveTemplate", params: ["name": "Too big", "rawContent": String(repeating: "x", count: 5 * 1024 * 1024 + 1)]) }
            try rejects("Template names must reject line breaks") { _ = try templatesStore.handle(method: "saveTemplate", params: ["name": "Bad\nname", "rawContent": "text"]) }
            let templateBackup = try templatesStore.exportBackup()
            try expect(try templatesStore.inspectBackup(templateBackup)["templateCount"] as? Int == 1, "Backup inspection must count templates")
            let templateRestart = RepositoryStore(root: templatesRoot, remoteURL: remote.path, identity: identity)
            let restoredTemplates = try templateRestart.handle(method: "listTemplates")["templates"] as! [[String: Any]]
            try expect(restoredTemplates.count == 1 && restoredTemplates[0]["rawContent"] as? String == templateRaw, "Templates must survive relaunch")
            _ = try templateRestart.handle(method: "saveTemplate", params: ["id": templateID, "name": "Café notes", "rawContent": "A newer local template"])
            _ = try templateRestart.restoreBackup(templateBackup)
            let collisionTemplates = try templateRestart.handle(method: "listTemplates")["templates"] as! [[String: Any]]
            try expect(collisionTemplates.count == 2, "Conflicting backup templates must be recovered separately")
            try expect(collisionTemplates.first { $0["id"] as? String == templateID }?["rawContent"] as? String == "A newer local template", "Import cannot overwrite an existing template")
            try expect(collisionTemplates.contains { $0["rawContent"] as? String == templateRaw }, "Imported conflicting template source must remain available")
            _ = try templateRestart.restoreBackup(templateBackup)
            try expect((try templateRestart.handle(method: "listTemplates")["templates"] as! [[String: Any]]).count == 2, "Repeated backup import must deduplicate recovered templates")
            let recoveredTemplateID = collisionTemplates.first { $0["id"] as? String != templateID }!["id"] as! String
            _ = try templateRestart.handle(method: "saveTemplate", params: ["id": recoveredTemplateID, "name": "Renamed recovered template", "rawContent": templateRaw])
            _ = try templateRestart.restoreBackup(templateBackup)
            try expect((try templateRestart.handle(method: "listTemplates")["templates"] as! [[String: Any]]).count == 2, "Renaming a recovered template must retain its import lineage for deduplication")
            var oversizedTemplateBackup = try JSONSerialization.jsonObject(with: templateBackup) as! [String: Any]
            var oversizedTemplateState = oversizedTemplateBackup["state"] as! [String: Any]
            var oversizedTemplates = oversizedTemplateState["templates"] as! [String: Any]
            var oversizedEntry = oversizedTemplates[templateID] as! [String: Any]
            oversizedEntry["rawContent"] = String(repeating: "x", count: 5 * 1024 * 1024 + 1)
            oversizedTemplates[templateID] = oversizedEntry; oversizedTemplateState["templates"] = oversizedTemplates; oversizedTemplateBackup["state"] = oversizedTemplateState
            try rejects("Backup template contents must obey the same5MiB limit") { _ = try templateRestart.inspectBackup(JSONSerialization.data(withJSONObject: oversizedTemplateBackup)) }
            _ = try templateRestart.handle(method: "removeTemplate", params: ["id": templateID])
            try expect((try templateRestart.handle(method: "listTemplates")["templates"] as! [[String: Any]]).count == 1, "Template deletion must remove only the chosen template")
            try rejects("A deleted template cannot silently reappear from a stale update") { _ = try templateRestart.handle(method: "saveTemplate", params: ["id": templateID, "name": "Old", "rawContent": "old"]) }
            let limitStore = RepositoryStore(root: root.appendingPathComponent("template-limit-data"), remoteURL: remote.path, seedRepo: source, identity: identity)
            _ = try limitStore.handle(method: "bootstrap")
            for index in 0..<100 { _ = try limitStore.handle(method: "saveTemplate", params: ["name": "Starter \(index)", "rawContent": ""]) }
            try rejects("More than100 templates must be rejected") { _ = try limitStore.handle(method: "saveTemplate", params: ["name": "Overflow", "rawContent": ""]) }
            try rejects("Backup import cannot exceed the merged template limit") { _ = try limitStore.restoreBackup(templateBackup) }
            try expect((try limitStore.handle(method: "listTemplates")["templates"] as! [[String: Any]]).count == 100, "Failed template import must leave existing templates intact")
            try expect(try git(["rev-parse", "main"], at: remote) == unchangedRemote, "Template management and import must never publish")
        }

        try selectedQueueTests(root)
        try deletionTests(root)

        print("RepositoryStore integration tests passed: \(assertions) assertions")
        print("Covered offline drafts and snapshots, conflicts, assets and paths, state migration, bounded history, safe backup import/export, automatic backups, publication verification, publish-time validation, atomic category management, reusable local templates, two-stage removal, and crash-safe explicit GitHub deletion.")
    }
}
