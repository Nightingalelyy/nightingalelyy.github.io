import Foundation
import AppKit
import Darwin

/// The helper never restores old draft data. It swaps only its own verified app
/// bundle, while keeping a private portable backup and exact pre-change state.
enum UpdateInstaller {
    static func processExists(_ pid: Int32) -> Bool {
        guard pid > 1 else { return false }
        return kill(pid, 0) == 0 || errno == EPERM
    }
    static func appIsRunning(_ app: URL) -> Bool {
        NSRunningApplication.runningApplications(withBundleIdentifier: UpdateFiles.product).contains {
            $0.processIdentifier != getpid() && $0.bundleURL.map { UpdateFiles.canonical($0) == UpdateFiles.canonical(app) } == true
        }
    }
    static func waitForExit(_ pid: Int32) throws {
        let deadline = Date().addingTimeInterval(120)
        while processExists(pid) {
            guard Date() < deadline else { throw UpdateFiles.error("The app did not close. No app bundle was replaced.") }
            Thread.sleep(forTimeInterval: 0.1)
        }
    }
    private static func loadPlan(_ supplied: URL, app: URL) throws -> (UpdateInstallPlan, UpdateManager, URL) {
        let bytes = try UpdateFiles.read(supplied, maximum: 128 * 1024)
        let plan = try JSONDecoder().decode(UpdateInstallPlan.self, from: bytes)
        let expectedApp = UpdateFiles.canonical(app), root = UpdateFiles.canonical(URL(fileURLWithPath: plan.dataRootPath, isDirectory: true))
        guard plan.schemaVersion == 1, UpdateFiles.validToken(plan.token), ["install", "rollback"].contains(plan.operation), plan.parentPID > 1,
              plan.targetAppPath == expectedApp.path, expectedApp.pathExtension == "app", plan.expectedBuild > 0,
              root.path == plan.dataRootPath, plan.currentBundleHash.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil else { throw UpdateFiles.error("The installer plan does not target this app.") }
        let manager = UpdateManager(resources: expectedApp.appendingPathComponent("Contents/Resources"), appURL: expectedApp, dataRoot: root)
        try UpdateFiles.directory(manager.updatesRoot)
        let job = try UpdateFiles.child(manager.updatesRoot.appendingPathComponent("jobs"), token: plan.token)
        guard UpdateFiles.canonical(supplied) == UpdateFiles.canonical(job.appendingPathComponent("plan.json")) else { throw UpdateFiles.error("The installer plan is outside private update storage.") }
        return (plan, manager, job)
    }
    private static func lockOwner(_ lock: URL) -> (Int32, String)? {
        guard let bytes = try? UpdateFiles.read(lock.appendingPathComponent("owner.json"), maximum: 8192),
              let object = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any], let pid = object["pid"] as? Int32,
              let token = object["token"] as? String else { return nil }
        return (pid, token)
    }
    private static func acquire(_ lock: URL, token: String) throws {
        guard mkdir(lock.path, 0o700) == 0 else { throw UpdateFiles.error("Another app installer is already running or needs recovery.") }
        do { try UpdateFiles.write(JSONSerialization.data(withJSONObject: ["pid": getpid(), "token": token]), to: lock.appendingPathComponent("owner.json")) }
        catch { try? UpdateFiles.fm.removeItem(at: lock); throw error }
    }
    private static func release(_ lock: URL, token: String) {
        if let owner = lockOwner(lock), owner.0 == getpid(), owner.1 == token { try? UpdateFiles.fm.removeItem(at: lock) }
    }
    static func clearStoppedLock(_ lock: URL, token: String, helperPID: Int32) throws {
        guard !processExists(helperPID) else { throw UpdateFiles.error("Wait for the stopped installer before cancelling its handoff.") }
        guard UpdateFiles.fm.fileExists(atPath: lock.path) else { return }
        guard let owner = lockOwner(lock), owner.0 == helperPID, owner.1 == token else { throw UpdateFiles.error("The installer lock cannot be safely attributed to the stopped helper.") }
        try UpdateFiles.fm.removeItem(at: lock)
    }
    private static func readState(_ manager: UpdateManager) throws -> UpdateDiskState {
        let state = try JSONDecoder().decode(UpdateDiskState.self, from: UpdateFiles.read(manager.stateURL, maximum: 256 * 1024))
        guard state.schemaVersion == 1 else { throw UpdateFiles.error("Unsupported saved updater state.") }; return state
    }
    private static func freshCandidate(_ plan: UpdateInstallPlan, manager: UpdateManager, job: URL, state: UpdateDiskState, runner: UpdateCommandRunner) throws -> (URL, URL?) {
        if plan.operation == "install" {
            guard let stage = plan.stage, plan.rollback == nil else { throw UpdateFiles.error("The installation proof is missing.") }
            let key = try manager.key(), manifest = try UpdateManager.manifest(stage.envelope, key: key)
            guard manifest.version == plan.expectedVersion, manifest.build == plan.expectedBuild,
                  manifest.build > plan.checkpoint.build, manifest.build >= state.highestSeenBuild,
                  UpdateManager.supportsSystem(manifest) else { throw UpdateFiles.error("The installation would replay an older or incompatible release.") }
            let staging = try manager.stageDirectory(stage.token)
            guard try UpdateFiles.read(staging.appendingPathComponent("manifest.json"), maximum: 64 * 1024) == stage.envelope else { throw UpdateFiles.error("The staged signature proof changed.") }
            let archive = try UpdateFiles.read(staging.appendingPathComponent("archive.zip"), maximum: manifest.archive.size)
            guard archive.count == manifest.archive.size, UpdateFiles.hash(archive) == manifest.archive.sha256 else { throw UpdateFiles.error("The staged archive no longer matches the signed checksum.") }
            // Never install the earlier extracted tree: an ad-hoc re-sign is not
            // proof that its contents correspond to the publisher's archive.
            let temporary = job.appendingPathComponent("verified-\(UUID().uuidString.lowercased())", isDirectory: true)
            let app = try UpdateArchive.extract(archive, to: temporary)
            do { _ = try UpdateFiles.verifyBundle(app, manifest: manifest, key: key, runner: runner) }
            catch { try? UpdateFiles.fm.removeItem(at: temporary); throw error }
            return (app, temporary)
        }
        guard let rollback = plan.rollback, plan.stage == nil, state.previous?.token == rollback.token,
              rollback.version == plan.expectedVersion, rollback.build == plan.expectedBuild else { throw UpdateFiles.error("The rollback review is stale.") }
        _ = try manager.verifiedCheckpoint(rollback)
        return (try manager.checkpointDirectory(rollback.token).appendingPathComponent(UpdateFiles.bundleName), nil)
    }
    private static func finish(_ plan: UpdateInstallPlan, manager: UpdateManager, job: URL, state original: UpdateDiskState) throws {
        var state = original
        state.previous = plan.checkpoint; state.prepared = nil; state.pendingJob = nil
        state.highestSeenBuild = max(state.highestSeenBuild, plan.expectedBuild)
        state.state = "current"
        state.message = plan.operation == "install" ? "The verified app update was installed. Your draft data was preserved." : "The previous verified app was restored. Your current draft data was preserved."
        try UpdateFiles.writeJSON(state, to: manager.stateURL)
        // The state transition is already durable. A missing optional result file
        // cannot make a successful swap look uncommitted or trigger another swap.
        try? UpdateFiles.write(JSONSerialization.data(withJSONObject: ["ok": true, "message": state.message]), to: job.appendingPathComponent("result.json"))
    }
    private static func prune(_ manager: UpdateManager, retaining token: String) {
        let checkpoints = manager.updatesRoot.appendingPathComponent("checkpoints", isDirectory: true)
        if let items = try? UpdateFiles.fm.contentsOfDirectory(at: checkpoints, includingPropertiesForKeys: [.isSymbolicLinkKey]) {
            for item in items where item.lastPathComponent != token && UpdateFiles.validToken(item.lastPathComponent) {
                if (try? item.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false { try? UpdateFiles.fm.removeItem(at: item) }
            }
        }
    }
    static func apply(planURL: URL, helperAppURL: URL, wait: ((Int32) throws -> Void)? = nil,
                      running: ((URL) -> Bool)? = nil, reopen: Bool = true,
                      runner: UpdateCommandRunner = UpdateFiles.command, beforeSwap: (() throws -> Void)? = nil, afterSwap: (() throws -> Void)? = nil) throws {
        let (plan, manager, job) = try loadPlan(planURL, app: helperAppURL)
        let lock = manager.updatesRoot.appendingPathComponent("install.lock", isDirectory: true)
        try acquire(lock, token: plan.token); defer { release(lock, token: plan.token) }
        var incoming: URL?, extracted: URL?, swapped = false, committed = false
        do {
            var state = try readState(manager)
            guard state.pendingJob == plan.token else { throw UpdateFiles.error("This installer request is no longer active.") }
            _ = try manager.verifiedCheckpoint(plan.checkpoint)
            guard try UpdateFiles.fingerprint(manager.appURL) == plan.currentBundleHash,
                  plan.currentBundleHash == plan.checkpoint.bundleHash else { throw UpdateFiles.error("The installed app changed after the update was reviewed.") }
            try UpdateFiles.write(JSONSerialization.data(withJSONObject: ["token": plan.token, "pid": getpid()]), to: job.appendingPathComponent("ready.json"))
            try (wait ?? waitForExit)(plan.parentPID)
            guard !(running ?? appIsRunning)(manager.appURL) else { throw UpdateFiles.error("Another copy of this app is running. Close it before retrying the update.") }
            state = try readState(manager)
            guard state.pendingJob == plan.token, try UpdateFiles.fingerprint(manager.appURL) == plan.currentBundleHash else { throw UpdateFiles.error("The app or installer review changed before installation.") }
            let candidate = try freshCandidate(plan, manager: manager, job: job, state: state, runner: runner)
            extracted = candidate.1
            let sibling = manager.appURL.deletingLastPathComponent().appendingPathComponent(".Nightingale-Writer-update-\(plan.token).app", isDirectory: true)
            guard !UpdateFiles.fm.fileExists(atPath: sibling.path) else { throw UpdateFiles.error("An installation staging bundle already exists beside the app.") }
            try UpdateFiles.fm.copyItem(at: candidate.0, to: sibling); incoming = sibling
            let candidateHash = try UpdateFiles.fingerprint(candidate.0)
            _ = try UpdateFiles.verifyBundle(sibling, runner: runner)
            guard try UpdateFiles.fingerprint(sibling) == candidateHash,
                  try UpdateFiles.fingerprint(manager.appURL) == plan.currentBundleHash,
                  !(running ?? appIsRunning)(manager.appURL) else { throw UpdateFiles.error("The copied update or installed app changed, or the app restarted before installation.") }
            // Both paths are on the same volume. RENAME_SWAP leaves no interval
            // where the app is missing, and retains the old original at sibling.
            try beforeSwap?()
            guard renameatx_np(AT_FDCWD, sibling.path, AT_FDCWD, manager.appURL.path, UInt32(RENAME_SWAP)) == 0 else { throw UpdateFiles.error("macOS could not atomically swap the app bundles. The installed app is unchanged.") }
            swapped = true
            guard try UpdateFiles.fingerprint(sibling) == plan.currentBundleHash else { throw UpdateFiles.error("The displaced app changed at the swap boundary. Its exact bytes will be restored.") }
            try afterSwap?()
            guard try UpdateFiles.fingerprint(manager.appURL) == candidateHash else { throw UpdateFiles.error("The installed bundle failed its final integrity check.") }
            try finish(plan, manager: manager, job: job, state: state); committed = true
            try? UpdateFiles.fm.removeItem(at: sibling); incoming = nil
            prune(manager, retaining: plan.checkpoint.token)
            if reopen { _ = try? runner("/usr/bin/open", [manager.appURL.path]) }
        } catch {
            var message = error.localizedDescription
            if swapped && !committed, let sibling = incoming {
                if renameatx_np(AT_FDCWD, sibling.path, AT_FDCWD, manager.appURL.path, UInt32(RENAME_SWAP)) == 0 {
                    swapped = false
                    message += " The previous app was restored automatically. Draft data was not changed."
                } else { message += " Both app copies and the private backup were preserved for recovery; the final app state could not be confirmed." }
            }
            if !swapped {
                if var state = try? readState(manager), state.pendingJob == plan.token {
                    state.pendingJob = nil; state.state = "error"; state.message = message
                    try? UpdateFiles.writeJSON(state, to: manager.stateURL)
                }
            }
            try? UpdateFiles.write(JSONSerialization.data(withJSONObject: ["ok": false, "message": message]), to: job.appendingPathComponent("result.json"))
            if !swapped, let incoming { try? UpdateFiles.fm.removeItem(at: incoming) }
            if let extracted { try? UpdateFiles.fm.removeItem(at: extracted) }
            if reopen && !swapped { _ = try? runner("/usr/bin/open", [manager.appURL.path]) }
            throw UpdateFiles.error(message)
        }
        if let extracted { try? UpdateFiles.fm.removeItem(at: extracted) }
    }

    /// Recover an abandoned handoff under the same exclusion lock used by the
    /// helper. Never alter the app here: prove old/current bytes or a signed
    /// completed installation before repairing only the updater journal.
    static func recoverPending(manager: UpdateManager, state: inout UpdateDiskState, runner: UpdateCommandRunner = UpdateFiles.command) throws {
        guard let token = state.pendingJob else { return }
        let job = try UpdateFiles.child(manager.updatesRoot.appendingPathComponent("jobs"), token: token)
        let (plan, _, _) = try loadPlan(job.appendingPathComponent("plan.json"), app: manager.appURL)
        let lock = manager.updatesRoot.appendingPathComponent("install.lock", isDirectory: true)
        if UpdateFiles.fm.fileExists(atPath: lock.path) {
            guard let owner = lockOwner(lock) else { throw UpdateFiles.error("An interrupted installer left an incomplete lock. The app and private backups are preserved; update recovery needs review before another install.") }
            guard owner.1 == token else { throw UpdateFiles.error("The installer lock belongs to a different request. No recovery change was made.") }
            guard !processExists(owner.0) else { return }
            // Only a lock whose recorded helper is no longer alive is abandoned.
            try UpdateFiles.fm.removeItem(at: lock)
        }
        guard !processExists(plan.parentPID) else { return }
        do { try acquire(lock, token: token) } catch { return }
        defer { release(lock, token: token) }
        let latest = try readState(manager)
        guard latest.pendingJob == token else { state = latest; return }
        let currentHash = try UpdateFiles.fingerprint(manager.appURL)
        if currentHash == plan.currentBundleHash {
            var recovered = latest; recovered.pendingJob = nil; recovered.state = recovered.prepared == nil ? "idle" : "staged"
            recovered.message = "The previous installer was interrupted before changing this app. Review the verified download again when ready."
            try UpdateFiles.writeJSON(recovered, to: manager.stateURL); state = recovered
            try? UpdateFiles.write(JSONSerialization.data(withJSONObject: ["ok": false, "message": recovered.message]), to: job.appendingPathComponent("result.json"))
            return
        }
        _ = try manager.verifiedCheckpoint(plan.checkpoint)
        let candidate = try freshCandidate(plan, manager: manager, job: job, state: latest, runner: runner)
        defer { if let temporary = candidate.1 { try? UpdateFiles.fm.removeItem(at: temporary) } }
        guard try UpdateFiles.fingerprint(candidate.0) == currentHash else { throw UpdateFiles.error("An interrupted app change needs manual review. Both backups are preserved and no further swap was attempted.") }
        try finish(plan, manager: manager, job: job, state: latest)
        state = try readState(manager)
        prune(manager, retaining: plan.checkpoint.token)
    }

    static func runHelper(arguments: [String]) throws {
        guard arguments.count == 3, arguments[1] == "--apply-plan" else { throw UpdateFiles.error("Use the app's reviewed update or rollback action to start its helper.") }
        let executable = UpdateFiles.canonical(URL(fileURLWithPath: arguments[0]))
        guard executable.lastPathComponent == "NightingaleUpdateHelper", executable.deletingLastPathComponent().lastPathComponent == "Helpers" else { throw UpdateFiles.error("The updater helper must run from its installed app bundle.") }
        let app = executable.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let planURL = URL(fileURLWithPath: arguments[2])
        let plan = try JSONDecoder().decode(UpdateInstallPlan.self, from: UpdateFiles.read(planURL, maximum: 128 * 1024))
        guard plan.parentPID == getppid(), plan.parentPID != getpid() else { throw UpdateFiles.error("The updater must be launched by the app that is closing.") }
        try apply(planURL: planURL, helperAppURL: app)
    }
}

#if UPDATE_INSTALLER
@main
struct NightingaleUpdateHelperMain {
    static func main() {
        do { try UpdateInstaller.runHelper(arguments: CommandLine.arguments) }
        catch { FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8)); exit(1) }
    }
}
#endif
