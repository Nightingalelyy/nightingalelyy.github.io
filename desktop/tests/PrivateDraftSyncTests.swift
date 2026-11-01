import Foundation

private struct SyncTestError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private final class FakePrivateTransport: PrivateDraftTransport {
    var data: Data?
    var revision: String?
    var writes = 0
    var reads = 0
    var failRead = false
    var failWrite = false
    var denyAccess = false
    var raceNextWrite = false
    var loseNextSuccess = false
    func verify(repository: String) throws {
        if denyAccess { throw SyncTestError(message: "Private repository verification denied") }
    }
    func read(repository: String) throws -> PrivateDraftRemoteSnapshot {
        try verify(repository: repository); reads += 1
        if failRead { throw SyncTestError(message: "Offline network connection") }
        return PrivateDraftRemoteSnapshot(revision: revision, data: data)
    }
    func write(repository: String, data: Data, expectedRevision: String?) throws -> String {
        try verify(repository: repository)
        if failWrite { throw SyncTestError(message: "Private write failed") }
        if raceNextWrite { raceNextWrite = false; revision = "competing-revision" }
        guard expectedRevision == revision else { throw SyncTestError(message: "Private revision changed; compare-and-swap rejected") }
        writes += 1; revision = "revision-\(writes)"; self.data = data
        if loseNextSuccess { loseNextSuccess = false; throw SyncTestError(message: "Network response lost after upload") }
        return revision!
    }
}

@main
struct PrivateDraftSyncTests {
    static let fm = FileManager.default
    static var checks = 0
    static let identity = (name: "Private Sync Tests", email: "private-sync@example.invalid")
    static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        checks += 1; if try !condition() { throw SyncTestError(message: message) }
    }
    static func rejects(_ message: String, _ block: () throws -> Void) throws {
        do { try block() } catch { checks += 1; return }; throw SyncTestError(message: message)
    }
    @discardableResult static func git(_ args: [String], at directory: URL? = nil) throws -> String {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false"] + (directory.map { ["-C", $0.path] } ?? []) + args
        let output = Pipe(); process.standardOutput = output; process.standardError = output
        try process.run(); let bytes = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        let text = String(data: bytes, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else { throw SyncTestError(message: "Git fixture failed: \(text)") }; return text
    }
    static func raw(_ text: String) -> String { "---\ntitle: Private draft\ncategory: Notes\ndate: 2026-11-02\n---\n\(text)\n" }
    static func article(_ store: RepositoryStore, _ path: String) throws -> [String: Any] { try store.handle(method: "readArticle", params: ["path": path]) }
    static func save(_ store: RepositoryStore, _ path: String, _ content: String) throws {
        let item = try article(store, path)
        _ = try store.handle(method: "saveDraft", params: ["path": path, "rawContent": content, "expectedRevision": item["revision"]!])
    }
    static func create(_ store: RepositoryStore, _ path: String, _ content: String) throws { _ = try store.handle(method: "createArticle", params: ["path": path, "rawContent": content]) }
    static func connect(_ store: RepositoryStore) throws { _ = try store.handle(method: "configurePrivateSync", params: ["repository": "Nightingalelyy/test-private-drafts", "confirmation": "CONNECT"]) }
    static func sync(_ store: RepositoryStore) throws -> [String: Any] { try store.handle(method: "syncPrivateDrafts") }
    static func status(_ result: [String: Any]) -> [String: Any] { result["privateSync"] as! [String: Any] }
    static func conflicts(_ result: [String: Any]) -> [[String: Any]] { status(result)["conflicts"] as! [[String: Any]] }
    static func resolve(_ store: RepositoryStore, _ conflict: [String: Any], choice: String) throws -> [String: Any] {
        try store.handle(method: "resolvePrivateSyncConflict", params: ["path": conflict["path"]!, "choice": choice, "expectedLocalRevision": conflict["localRevision"]!, "expectedRemoteRevision": conflict["remoteRevision"]!])
    }
    private static func payload(_ transport: FakePrivateTransport) throws -> [String: Any] { try JSONSerialization.jsonObject(with: transport.data!) as! [String: Any] }

    static func main() throws {
        let root = fm.temporaryDirectory.appendingPathComponent("nightingale-private-sync-tests-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true); defer { try? fm.removeItem(at: root) }
        let source = root.appendingPathComponent("source"), remote = root.appendingPathComponent("public.git")
        try fm.createDirectory(at: source.appendingPathComponent("_docs"), withIntermediateDirectories: true)
        try git(["init", "-b", "main"], at: source); try git(["config", "user.name", identity.name], at: source); try git(["config", "user.email", identity.email], at: source)
        let publishedPath = "_docs/published.md", publishedOriginal = raw("Published original")
        try Data(publishedOriginal.utf8).write(to: source.appendingPathComponent(publishedPath))
        try Data(raw("Home").utf8).write(to: source.appendingPathComponent("index.md"))
        try git(["add", "."], at: source); try git(["commit", "-m", "Public fixture"], at: source); try git(["clone", "--bare", source.path, remote.path]); try git(["remote", "add", "origin", remote.path], at: source)
        let initialPublicHead = try git(["rev-parse", "main"], at: remote)
        let transport = FakePrivateTransport(), aRoot = root.appendingPathComponent("device-a"), bRoot = root.appendingPathComponent("device-b")
        func make(_ path: URL, _ cloud: FakePrivateTransport = transport) -> RepositoryStore { RepositoryStore(root: path, remoteURL: remote.path, seedRepo: source, identity: identity, draftTransport: cloud) }
        let a = make(aRoot), b = make(bRoot)
        try expect(status(try a.handle(method: "bootstrap"))["enabled"] as? Bool == false, "Private sync must start disconnected")
        try rejects("Connection requires explicit confirmation") { _ = try a.handle(method: "configurePrivateSync", params: ["repository": "Nightingalelyy/test-private-drafts"]) }
        try rejects("The public site cannot be a private draft destination") { _ = try a.handle(method: "configurePrivateSync", params: ["repository": "Nightingalelyy/nightingalelyy.github.io", "confirmation": "CONNECT"]) }
        transport.denyAccess = true
        try rejects("Failed verification cannot enable sync") { try connect(a) }
        try expect(status(try a.handle(method: "bootstrap"))["enabled"] as? Bool == false, "Verification failure must leave local configuration unchanged")
        transport.denyAccess = false; try connect(a); try connect(b)
        try expect(transport.writes == 0 && transport.reads == 0, "Connecting only verifies access; it cannot transfer drafts")
        let path = "_docs/private.md", initial = raw("First private version")
        try create(a, path, initial)
        let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl6S6kAAAAASUVORK5CYII="
        let usedImage = try a.handle(method: "importImage", params: ["filename": "used.png", "base64": png])["path"] as! String
        let orphanImage = try a.handle(method: "importImage", params: ["filename": "discarded.png", "base64": png])["path"] as! String
        let withImage = raw("First private version\n\n![Image](\(usedImage))")
        try save(a, path, withImage)
        _ = try sync(a)
        let firstPayload = try payload(transport), images = firstPayload["assets"] as! [[String: Any]]
        try expect(images.count == 1 && images[0]["path"] as? String == String(usedImage.dropFirst()), "Only referenced local images may leave this Mac")
        try expect(!images.contains { $0["path"] as? String == String(orphanImage.dropFirst()) }, "Unreferenced screenshots must not enter private storage")
        try expect(Set(firstPayload.keys) == Set(["format", "formatVersion", "publicationRepository", "drafts", "assets"]), "Private sync must export a dedicated data-only whitelist")
        let received = try sync(b)
        try expect(try article(b, path)["rawContent"] as? String == withImage, "New draft must sync to another device")
        try expect(try b.handle(method: "readAsset", params: ["path": usedImage])["base64"] as? String == png, "Referenced image bytes must be available offline on the second device")
        try expect((received["status"] as! [String: Any])["queuedCount"] as? Int == 0 && (received["deletions"] as! [[String: Any]]).isEmpty, "Imported content must never queue publication or deletion")
        try expect(try git(["rev-parse", "main"], at: remote) == initialPublicHead, "Private sync cannot alter the public repository")
        let rootMode = try fm.attributesOfItem(atPath: bRoot.path)[.posixPermissions] as! NSNumber
        let stateMode = try fm.attributesOfItem(atPath: bRoot.appendingPathComponent("state.json").path)[.posixPermissions] as! NSNumber
        try expect(rootMode.intValue & 0o777 == 0o700 && stateMode.intValue & 0o777 == 0o600, "Private text storage must be owner-only")
        let bEdit = raw("Edited on device B\n\n![Image](\(usedImage))")
        try save(b, path, bEdit)
        try expect(status(try b.handle(method: "privateSyncStatus"))["state"] as? String == "ready", "Editing after sync must not claim the new revision is shared")
        _ = try sync(b); _ = try sync(a)
        try expect(try article(a, path)["rawContent"] as? String == bEdit, "Unchanged local version must receive the other device's edit")
        let local = raw("Divergent local edit"), other = raw("Divergent remote edit")
        try save(a, path, local); _ = try a.handle(method: "queuePublish", params: ["path": path])
        try save(b, path, other); _ = try sync(b)
        let conflictResult = try sync(a), conflict = conflicts(conflictResult).first!
        try expect(conflict["base"] as? String == bEdit && conflict["local"] as? String == local && conflict["remote"] as? String == other, "Private conflicts must preserve the actual common base and both edits")
        try expect(try article(a, path)["rawContent"] as? String == local, "A conflict cannot overwrite local work")
        try rejects("Private conflict must block a new website publication") { _ = try a.handle(method: "queuePublish", params: ["path": path]) }
        _ = try a.handle(method: "processQueue")
        try expect(try git(["rev-parse", "main"], at: remote) == initialPublicHead, "Existing queued publication must pause when private sync finds a conflict")
        try rejects("Remote choice cannot overwrite an actively queued path") { _ = try resolve(a, conflict, choice: "remote") }
        let latest = raw("Edited again while reviewing conflict")
        try save(a, path, latest)
        let currentConflict = conflicts(try a.handle(method: "privateSyncStatus")).first!
        try expect(currentConflict["local"] as? String == latest, "Conflict review must show the latest saved local text")
        try rejects("Stale local resolution cannot overwrite newer edits") { _ = try resolve(a, conflict, choice: "remote") }
        var wrongRemote = currentConflict; wrongRemote["remoteRevision"] = "stale"
        try rejects("Stale remote resolution token must be rejected") { _ = try resolve(a, wrongRemote, choice: "local") }
        let history = try a.handle(method: "listHistory", params: ["path": path])["entries"] as! [[String: Any]]
        let historicalRaw = try history.map { try a.handle(method: "readHistory", params: ["path": path, "id": $0["id"]!])["rawContent"] as! String }
        try expect(historicalRaw.contains(other), "The incoming conflicted version must be recoverable from History and backups")
        _ = try a.handle(method: "disconnectPrivateSync")
        try expect(!conflicts(try a.handle(method: "privateSyncStatus")).isEmpty, "Disconnect must not hide unresolved versions")
        _ = try a.handle(method: "cancelQueued", params: ["path": path])
        _ = try resolve(a, currentConflict, choice: "local")
        try expect(try article(a, path)["rawContent"] as? String == latest, "Offline local choice must retain the latest local work")
        let beforeReconnect = transport.writes
        try connect(a)
        try expect(transport.writes == beforeReconnect, "Reconnect cannot automatically share a resolved choice")
        _ = try sync(a); _ = try sync(b)
        try expect(try article(b, path)["rawContent"] as? String == latest, "An explicit later sync shares the local resolution")
        _ = try a.handle(method: "discardDraft", params: ["path": path]); _ = try sync(a)
        try rejects("An unchanged retained cloud copy cannot resurrect a discarded local draft") { _ = try article(a, path) }
        try expect((try payload(transport)["drafts"] as! [String: Any])[path] != nil, "Discarding locally must not delete the retained private copy")
        try save(b, path, raw("Remote edit after local discard")); _ = try sync(b)
        let afterDiscard = try sync(a), absentConflict = conflicts(afterDiscard).first!
        try expect(absentConflict["local"] is NSNull && absentConflict["localRevision"] as? String == "", "Remote edit after local removal must require an explicit choice")
        try rejects("Remote edit must not silently recreate a discarded draft") { _ = try article(a, path) }
        _ = try resolve(a, absentConflict, choice: "remote")
        try expect(try article(a, path)["rawContent"] as? String == raw("Remote edit after local discard"), "Explicit remote choice can recreate a draft locally")
        _ = try sync(a)
        let durable = try article(a, path)["rawContent"] as! String
        transport.failRead = true
        let offline = try sync(a); transport.failRead = false
        try expect(status(offline)["state"] as? String == "offline" && (try article(a, path)["rawContent"] as? String) == durable, "Offline sync must preserve local drafts")
        try save(a, path, raw("Local edit before failed write")); transport.failWrite = true
        let failed = try sync(a); transport.failWrite = false
        try expect(status(failed)["state"] as? String == "error", "Transport write failure must be reported")
        try expect(try article(a, path)["rawContent"] as? String == raw("Local edit before failed write"), "Write failure must preserve saved local work")
        transport.raceNextWrite = true
        let raced = try sync(a)
        try expect(status(raced)["state"] as? String == "error", "A competing private commit must reject the stale write")
        try expect(try article(a, path)["rawContent"] as? String == raw("Local edit before failed write"), "CAS race cannot overwrite local work")
        _ = try sync(a)
        let ambiguousRaw = raw("Saved before an ambiguous upload")
        try save(a, path, ambiguousRaw); transport.loseNextSuccess = true
        let ambiguous = try sync(a), writesAfterAmbiguous = transport.writes
        try expect(status(ambiguous)["state"] as? String == "offline", "Lost upload response must report uncertainty")
        try expect(try article(a, path)["rawContent"] as? String == ambiguousRaw, "Ambiguous upload cannot alter the local saved revision")
        try expect(((try payload(transport)["drafts"] as! [String: Any])[path] as! [String: Any])["rawContent"] as? String == ambiguousRaw, "Ambiguous fixture must actually retain the accepted remote snapshot")
        let acknowledged = try sync(a)
        try expect(conflicts(acknowledged).isEmpty && status(acknowledged)["state"] as? String == "synced", "Retry must acknowledge an already accepted identical version without conflict")
        try expect(transport.writes == writesAfterAmbiguous && (try git(["rev-parse", "main"], at: remote)) == initialPublicHead, "Acknowledgement must not duplicate the upload or publish anything")
        let backup = try a.exportBackup(), backupJSON = try JSONSerialization.jsonObject(with: backup) as! [String: Any]
        try expect((backupJSON["state"] as! [String: Any])["privateSync"] == nil, "Backups must exclude private settings and cursors")
        var forgedBackup = backupJSON, forgedState = backupJSON["state"] as! [String: Any]
        forgedState["privateSync"] = ["enabled": true, "repository": "Nightingalelyy/test-private-drafts"]
        forgedBackup["state"] = forgedState
        let fresh = make(root.appendingPathComponent("backup-device"))
        let imported = try fresh.restoreBackup(JSONSerialization.data(withJSONObject: forgedBackup))
        try expect(status(imported)["enabled"] as? Bool == false, "Restoring a backup cannot enable private sync")
        _ = try a.restoreBackup(backup)
        try expect(status(try a.handle(method: "privateSyncStatus"))["enabled"] as? Bool == true, "Backup restore must preserve this device's own connection")
        // Publication metadata is a different base: syncing cannot silently rebase it to newer public content.
        try save(a, publishedPath, raw("Unpublished edit based on old public source")); _ = try sync(a)
        try Data(raw("New public CMS edit").utf8).write(to: source.appendingPathComponent(publishedPath))
        try git(["add", publishedPath], at: source); try git(["commit", "-m", "CMS update"], at: source); try git(["push", "origin", "main"], at: source)
        _ = try b.handle(method: "refresh"); _ = try sync(b)
        _ = try b.handle(method: "queuePublish", params: ["path": publishedPath]); _ = try b.handle(method: "processQueue")
        try expect(try article(b, publishedPath)["conflict"] != nil, "Private import must preserve the older public base and reveal CMS conflict at publication")
        try expect(try git(["show", "main:\(publishedPath)"], at: remote) == raw("New public CMS edit"), "Private sync cannot mask and overwrite a public CMS edit")
        // External images and literal code examples are not private media dependencies.
        let examplePath = "_docs/image-code-example.md"
        try create(a, examplePath, raw("![External](https://example.org/images/uploads/external.png)\n\n```md\n![Example](/images/uploads/only-an-example.png)\n```"))
        try expect(status(try sync(a))["state"] as? String == "synced", "External image URLs and code literals must not block private draft sync")
        // Malformed execution fields and cross-device case collisions are rejected before transfer.
        let originalPayload = transport.data, originalRevision = transport.revision
        var malicious = try payload(transport); malicious["queue"] = [path: ["rawContent": raw("Do not publish")]]
        transport.data = try JSONSerialization.data(withJSONObject: malicious)
        let beforeBad = try article(a, path)["rawContent"] as! String, writesBeforeBad = transport.writes
        try expect(status(try sync(a))["state"] as? String == "error", "Remote execution state is not a supported private payload")
        try expect(transport.writes == writesBeforeBad && (try article(a, path)["rawContent"] as? String) == beforeBad, "Invalid payload cannot mutate drafts or upload")
        transport.data = originalPayload; transport.revision = originalRevision
        var collision = try payload(transport), collisionDrafts = try payload(transport)["drafts"] as! [String: Any]
        collisionDrafts["_docs/PUBLISHED.md"] = collisionDrafts.removeValue(forKey: publishedPath)
        collision["drafts"] = collisionDrafts; transport.data = try JSONSerialization.data(withJSONObject: collision)
        try expect(status(try sync(a))["state"] as? String == "error", "Incoming case-colliding filenames must not coexist with local articles")
        transport.data = originalPayload; transport.revision = originalRevision
        try create(a, "_docs/café.md", raw("Local composed filename"))
        var unicodeCollision = try payload(transport), unicodeDrafts = try payload(transport)["drafts"] as! [String: Any]
        unicodeDrafts["_docs/cafe\u{301}.md"] = ["rawContent": raw("Incoming decomposed filename"), "updatedAt": "2026-11-02T00:00:00Z"]
        unicodeCollision["drafts"] = unicodeDrafts; transport.data = try JSONSerialization.data(withJSONObject: unicodeCollision)
        try expect(status(try sync(a))["state"] as? String == "error", "Unicode-equivalent but byte-distinct incoming paths must not replace local filenames")
        try expect(try article(a, "_docs/café.md")["rawContent"] as? String == raw("Local composed filename"), "Unicode collision must preserve local source bytes")
        transport.data = originalPayload; transport.revision = originalRevision
        // Shared assets must be intact, and referenced local images cannot be silently omitted.
        var missingImage = try payload(transport), missingDrafts = missingImage["drafts"] as! [String: Any]
        missingDrafts["_docs/missing-image.md"] = ["rawContent": raw("![Missing](/images/uploads/missing.png)"), "updatedAt": "2026-11-02T00:00:00Z"]
        missingImage["drafts"] = missingDrafts; transport.data = try JSONSerialization.data(withJSONObject: missingImage)
        try expect(status(try sync(a))["state"] as? String == "error", "Missing required local image must block incomplete private import")
        transport.data = originalPayload; transport.revision = originalRevision
        let restarted = make(aRoot)
        try expect(status(try restarted.handle(method: "bootstrap"))["enabled"] as? Bool == true, "The verified private connection persists across relaunch")
        try expect(try article(restarted, path)["rawContent"] as? String == beforeBad, "Private sync errors and relaunch cannot erase local work")
        print("Private draft sync integration tests passed: \(checks) assertions. No real private or public repository was contacted.")
    }
}
