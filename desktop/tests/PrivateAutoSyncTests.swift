import Foundation

private struct AutoTestError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

private final class AutoTestTransport: PrivateDraftTransport {
    private let lock = NSLock()
    private var storedData: Data?
    private var storedRevision: String?
    private var writeCount = 0
    private var readCount = 0
    private var pauseRead = false
    var failRead = false
    let readEntered = DispatchSemaphore(value: 0)
    let releaseRead = DispatchSemaphore(value: 0)
    var writes: Int { lock.lock(); defer { lock.unlock() }; return writeCount }
    var reads: Int { lock.lock(); defer { lock.unlock() }; return readCount }
    var data: Data? { lock.lock(); defer { lock.unlock() }; return storedData }
    func verify(repository: String) throws {}
    func blockNextRead() { lock.lock(); pauseRead = true; lock.unlock() }
    func read(repository: String) throws -> PrivateDraftRemoteSnapshot {
        lock.lock(); readCount += 1; let blocked = pauseRead; pauseRead = false; let failure = failRead; lock.unlock()
        if blocked {
            readEntered.signal()
            guard releaseRead.wait(timeout: .now() + 10) == .success else { throw AutoTestError(message: "Blocked fake network timed out") }
        }
        if failure { throw AutoTestError(message: "Offline fake network") }
        lock.lock(); defer { lock.unlock() }
        return PrivateDraftRemoteSnapshot(revision: storedRevision, data: storedData)
    }
    func write(repository: String, data: Data, expectedRevision: String?) throws -> String {
        lock.lock(); defer { lock.unlock() }
        guard expectedRevision == storedRevision else { throw AutoTestError(message: "Private CAS rejected") }
        writeCount += 1; storedData = data; storedRevision = "private-auto-\(writeCount)"
        return storedRevision!
    }
}

private final class AutoResultBox {
    private let lock = NSLock()
    private var result: PrivateAutoSyncResult?
    let done = DispatchSemaphore(value: 0)
    func store(_ value: PrivateAutoSyncResult) { lock.lock(); result = value; lock.unlock(); done.signal() }
    func get() -> PrivateAutoSyncResult? { lock.lock(); defer { lock.unlock() }; return result }
}

@main
struct PrivateAutoSyncTests {
    static let fm = FileManager.default
    static var checks = 0
    static let identity = (name: "Automatic Private Sync Tests", email: "auto-sync@example.invalid")
    static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        checks += 1; if try !condition() { throw AutoTestError(message: message) }
    }
    static func rejects(_ message: String, _ body: () throws -> Void) throws {
        do { try body() } catch { checks += 1; return }; throw AutoTestError(message: message)
    }
    @discardableResult static func git(_ arguments: [String], at directory: URL? = nil) throws -> String {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-c", "core.hooksPath=/dev/null", "-c", "commit.gpgsign=false"] + (directory.map { ["-C", $0.path] } ?? []) + arguments
        let output = Pipe(); process.standardOutput = output; process.standardError = output
        try process.run(); let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? ""
        guard process.terminationStatus == 0 else { throw AutoTestError(message: "Git fixture failed: \(text)") }; return text
    }
    static func raw(_ body: String) -> String { "---\ntitle: Automatic private draft\ncategory: Notes\ndate: 2026-11-02\n---\n\(body)\n" }
    static func article(_ store: RepositoryStore, _ path: String) throws -> [String: Any] { try store.handle(method: "readArticle", params: ["path": path]) }
    static func create(_ store: RepositoryStore, _ path: String, _ body: String) throws { _ = try store.handle(method: "createArticle", params: ["path": path, "rawContent": raw(body)]) }
    static func save(_ store: RepositoryStore, _ path: String, _ body: String) throws {
        let current = try article(store, path)
        _ = try store.handle(method: "saveDraft", params: ["path": path, "rawContent": raw(body), "expectedRevision": current["revision"]!])
    }
    static func status(_ snapshot: [String: Any]) -> [String: Any] { snapshot["privateSync"] as! [String: Any] }
    static func conflicts(_ snapshot: [String: Any]) -> [[String: Any]] { status(snapshot)["conflicts"] as! [[String: Any]] }
    static func connect(_ store: RepositoryStore, automatic: Bool = true) throws {
        _ = try store.handle(method: "configurePrivateSync", params: ["repository": "Nightingalelyy/automatic-private-test", "confirmation": "CONNECT"])
        if automatic { _ = try store.handle(method: "setPrivateAutoSync", params: ["enabled": true]) }
    }
    static func begin(_ store: RepositoryStore, protected: [String] = []) throws -> PrivateAutoSyncPlan {
        guard let plan = try store.beginPrivateAutoSync(["protectedPaths": protected]) else { throw AutoTestError(message: "Expected an eligible automatic sync plan") }; return plan
    }
    static func sync(_ store: RepositoryStore, protected: [String] = []) throws -> [String: Any] {
        let plan = try begin(store, protected: protected)
        return try store.finishPrivateAutoSync(store.runPrivateAutoSync(plan), protectedPaths: protected)
    }
    static func manual(_ store: RepositoryStore) throws -> [String: Any] { try store.handle(method: "syncPrivateDrafts") }
    private static func cloudDraft(_ cloud: AutoTestTransport, _ path: String) throws -> String? {
        guard let data = cloud.data else { return nil }
        let payload = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        return ((payload["drafts"] as? [String: Any])?[path] as? [String: Any])?["rawContent"] as? String
    }
    private static func runBlocked(_ store: RepositoryStore, _ plan: PrivateAutoSyncPlan, _ cloud: AutoTestTransport) throws -> AutoResultBox {
        cloud.blockNextRead(); let box = AutoResultBox()
        DispatchQueue.global(qos: .utility).async { box.store(store.runPrivateAutoSync(plan)) }
        try expect(cloud.readEntered.wait(timeout: .now() + 5) == .success, "Automatic transfer must start on the background queue")
        return box
    }
    private static func finishBlocked(_ box: AutoResultBox, _ cloud: AutoTestTransport) throws -> PrivateAutoSyncResult {
        cloud.releaseRead.signal()
        try expect(box.done.wait(timeout: .now() + 5) == .success, "Released transfer must finish")
        guard let result = box.get() else { throw AutoTestError(message: "Background result missing") }; return result
    }
    static func fileState(_ directory: URL) throws -> [String: String] {
        guard fm.fileExists(atPath: directory.path), let files = fm.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]) else { return [:] }
        var result: [String: String] = [:]
        for case let file as URL in files {
            guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            let info = try fm.attributesOfItem(atPath: file.path)
            result[String(file.path.dropFirst(directory.path.count))] = "\(info[.size]!)|\((info[.modificationDate] as! Date).timeIntervalSince1970)"
        }
        return result
    }

    static func main() throws {
        let root = fm.temporaryDirectory.appendingPathComponent("nightingale-private-auto-tests-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true); defer { try? fm.removeItem(at: root) }
        let source = root.appendingPathComponent("source"), remote = root.appendingPathComponent("public.git")
        try fm.createDirectory(at: source.appendingPathComponent("_docs"), withIntermediateDirectories: true)
        try git(["init", "-b", "main"], at: source); try git(["config", "user.name", identity.name], at: source); try git(["config", "user.email", identity.email], at: source)
        try Data(raw("Published original").utf8).write(to: source.appendingPathComponent("_docs/published.md"))
        try Data(raw("Home").utf8).write(to: source.appendingPathComponent("index.md"))
        try git(["add", "."], at: source); try git(["commit", "-m", "Public fixture"], at: source); try git(["clone", "--bare", source.path, remote.path])
        let publicHead = try git(["rev-parse", "main"], at: remote)
        func make(_ name: String, _ cloud: AutoTestTransport) -> RepositoryStore { RepositoryStore(root: root.appendingPathComponent(name), remoteURL: remote.path, seedRepo: source, identity: identity, draftTransport: cloud) }

        let cloud = AutoTestTransport(); var a = make("a", cloud)
        try expect(status(try a.handle(method: "bootstrap"))["autoSyncEnabled"] as? Bool == false, "Automatic sync must default off")
        try expect(try a.beginPrivateAutoSync(["protectedPaths": []]) == nil, "Disconnected storage cannot start an automatic transfer")
        try rejects("Cannot enable automatic sync before connecting privately") { _ = try a.handle(method: "setPrivateAutoSync", params: ["enabled": true]) }
        try connect(a, automatic: false)
        try expect(try a.beginPrivateAutoSync(["protectedPaths": []]) == nil, "A connection alone cannot authorize automatic transfer")
        try expect(cloud.reads == 0 && cloud.writes == 0, "Connection and disabled automatic checks cannot transfer content")
        _ = try a.handle(method: "setPrivateAutoSync", params: ["enabled": true]); a = make("a", cloud)
        try expect(status(try a.handle(method: "bootstrap"))["autoSyncEnabled"] as? Bool == true, "Explicit automatic setting must persist across launch")

        let path = "_docs/working.md"
        try create(a, path, "Captured version A")
        let plan = try begin(a)
        try expect(!plan.token.isEmpty, "Each automatic plan needs a correlation token")
        try expect((try? a.beginPrivateAutoSync(["protectedPaths": []])) == nil, "A second plan cannot overlap the active plan")
        let blocked = try runBlocked(a, plan, cloud)
        try save(a, path, "Newer local version B")
        try expect(blocked.get() == nil, "Local save must finish while the network is still blocked")
        try expect(try article(a, path)["rawContent"] as? String == raw("Newer local version B"), "The saved edit must be durable before transfer completion")
        let result = try finishBlocked(blocked, cloud)
        let finished = try a.finishPrivateAutoSync(result, protectedPaths: [path])
        try expect(try cloudDraft(cloud, path) == raw("Captured version A"), "Network work must upload only its captured snapshot")
        try expect(try article(a, path)["rawContent"] as? String == raw("Newer local version B"), "Completion cannot overwrite an edit made during transfer")
        try expect(conflicts(finished).isEmpty, "Acknowledging this device's older upload must not invent a conflict")
        try expect(status(finished)["state"] as? String == "ready", "A newer local draft must remain visibly pending")
        let beforeDuplicate = try Data(contentsOf: root.appendingPathComponent("a/state.json"))
        let duplicate = try a.finishPrivateAutoSync(result, protectedPaths: [])
        try expect((duplicate["privateSyncResult"] as? [String: Any])?["changed"] as? Bool == false, "A duplicate finish must not apply an old result again")
        try expect(try Data(contentsOf: root.appendingPathComponent("a/state.json")) == beforeDuplicate, "Duplicate completion cannot rewrite saved state")
        _ = try manual(a)
        try expect(try cloudDraft(cloud, path) == raw("Newer local version B"), "The acknowledged baseline must allow the newer draft to sync later")

        let b = make("b", cloud); try connect(b, automatic: false); _ = try manual(b)
        try save(b, path, "Incoming other-device version"); _ = try manual(b)
        let protected = try sync(a, protected: [path])
        try expect(try article(a, path)["rawContent"] as? String == raw("Newer local version B"), "A protected active path cannot be silently replaced")
        try expect(conflicts(protected).contains { $0["path"] as? String == path && $0["remote"] as? String == raw("Incoming other-device version") }, "Incoming active-path changes need recoverable conflict review")
        let entries = try a.handle(method: "listHistory", params: ["path": path])["entries"] as! [[String: Any]]
        let history = try entries.map { try a.handle(method: "readHistory", params: ["path": path, "id": $0["id"]!])["rawContent"] as! String }
        try expect(history.contains(raw("Incoming other-device version")), "Incoming protected content must be retained in History")
        try expect(try a.beginPrivateAutoSync(["protectedPaths": []]) == nil, "Unresolved private conflicts must pause automatic sync")

        let cancelCloud = AutoTestTransport(), cancel = make("cancel", cancelCloud)
        try connect(cancel); try create(cancel, path, "Must stay local after cancellation")
        let cancelPlan = try begin(cancel), cancelRun = try runBlocked(cancel, cancelPlan, cancelCloud)
        _ = try cancel.cancelPrivateAutoSync()
        let cancelled = try cancel.finishPrivateAutoSync(try finishBlocked(cancelRun, cancelCloud), protectedPaths: [])
        try expect(cancelCloud.writes == 0, "Cancellation before upload must prevent private writes")
        try expect(try article(cancel, path)["rawContent"] as? String == raw("Must stay local after cancellation"), "Cancellation cannot discard a local draft")
        try expect((cancelled["status"] as! [String: Any])["queuedCount"] as? Int == 0, "Cancellation cannot queue public work")

        let disableCloud = AutoTestTransport(), disable = make("disable", disableCloud)
        try connect(disable); try create(disable, path, "Disable during network")
        let disableRun = try runBlocked(disable, try begin(disable), disableCloud)
        _ = try disable.handle(method: "setPrivateAutoSync", params: ["enabled": false])
        _ = try disable.finishPrivateAutoSync(try finishBlocked(disableRun, disableCloud), protectedPaths: [])
        try expect(disableCloud.writes == 0, "Turning the setting off during fetch must prevent upload")
        try expect(status(try disable.handle(method: "bootstrap"))["autoSyncEnabled"] as? Bool == false, "Late completion cannot turn automatic sync back on")
        _ = try disable.handle(method: "setPrivateAutoSync", params: ["enabled": true]); _ = try disable.handle(method: "disconnectPrivateSync")
        try expect(status(try disable.handle(method: "bootstrap"))["autoSyncEnabled"] as? Bool == false, "Disconnect must disable automatic sync")

        let ackCloud = AutoTestTransport(), peer = make("ack-peer", ackCloud), ack = make("ack", ackCloud)
        let incomingPath = "_docs/cloud-only.md"
        try connect(peer, automatic: false); try create(peer, incomingPath, "Other device content"); _ = try manual(peer)
        try connect(ack); try create(ack, path, "Accepted upload A")
        let accepted = ack.runPrivateAutoSync(try begin(ack))
        try expect(try cloudDraft(ackCloud, path) == raw("Accepted upload A"), "The cancellation fixture must first complete its private upload")
        try save(ack, path, "Local version B after upload"); _ = try ack.cancelPrivateAutoSync()
        _ = try ack.finishPrivateAutoSync(accepted, protectedPaths: [])
        try rejects("Cancelling a completed transfer cannot import another device's draft") { _ = try article(ack, incomingPath) }
        try expect(try article(ack, path)["rawContent"] as? String == raw("Local version B after upload"), "Acknowledgement-only finish must retain newer local edits")
        let afterAck = try manual(ack)
        try expect(conflicts(afterAck).isEmpty && (try cloudDraft(ackCloud, path)) == raw("Local version B after upload"), "A cancelled accepted upload still needs its baseline acknowledged")

        let noOpCloud = AutoTestTransport(), noOp = make("no-op", noOpCloud)
        try connect(noOp); try create(noOp, path, "Unchanged draft"); _ = try sync(noOp)
        try expect(status(try noOp.handle(method: "bootstrap"))["lastAutoCheckedAt"] as? String != nil, "Successful automatic checks need a live timestamp")
        let stateFile = root.appendingPathComponent("no-op/state.json"), backupDirectory = root.appendingPathComponent("no-op/backups")
        let stateBytes = try Data(contentsOf: stateFile), beforeBackups = try fileState(backupDirectory), writes = noOpCloud.writes
        let sentinel = Date(timeIntervalSince1970: 1_000_000_000)
        try fm.setAttributes([.modificationDate: sentinel], ofItemAtPath: stateFile.path)
        _ = try sync(noOp); _ = try sync(noOp)
        try expect(try Data(contentsOf: stateFile) == stateBytes, "Repeated no-op sync cannot rewrite state contents")
        try expect(try fm.attributesOfItem(atPath: stateFile.path)[.modificationDate] as? Date == sentinel, "Repeated no-op sync cannot churn state file modification time")
        try expect(try fileState(backupDirectory) == beforeBackups, "Repeated no-op sync cannot create or rewrite backups")
        try expect(noOpCloud.writes == writes, "Repeated no-op sync cannot create duplicate private commits")
        noOpCloud.failRead = true
        let offline = try sync(noOp); noOpCloud.failRead = false
        try expect(["offline", "error"].contains(status(offline)["state"] as? String ?? ""), "Transport failure must remain visible without success claims")
        try expect(try article(noOp, path)["rawContent"] as? String == raw("Unchanged draft"), "Transport failure must preserve saved local text")
        _ = try sync(noOp)
        try expect(status(try noOp.handle(method: "bootstrap"))["autoSyncInProgress"] as? Bool == false, "Failure/retry must not leave the store permanently busy")
        try expect(status(try make("no-op", noOpCloud).handle(method: "bootstrap"))["lastAutoCheckedAt"] == nil, "Live automatic-check timestamps must not be persisted across relaunch")

        let recoveryCloud = AutoTestTransport(), recovery = make("recovery", recoveryCloud)
        try connect(recovery)
        try Data("unreadable-state".utf8).write(to: root.appendingPathComponent("recovery/state.json"))
        let recovering = make("recovery", recoveryCloud)
        try expect(try recovering.beginPrivateAutoSync(["protectedPaths": []]) == nil, "Corrupt-state recovery must prevent automatic network work")
        try expect(recoveryCloud.reads == 0 && recoveryCloud.writes == 0, "Recovery cannot send cached private work to the cloud")

        try expect(try git(["rev-parse", "main"], at: remote) == publicHead, "All automatic sync cases must leave the public repository unchanged")
        print("Private automatic sync tests passed: \(checks) checks")
    }
}
