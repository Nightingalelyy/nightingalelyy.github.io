import Foundation
import CryptoKit
import Darwin
import zlib

private struct UpdateTestFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

@main
struct UpdateManagerTests {
    static var checks = 0
    static let fm = FileManager.default
    static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        checks += 1; if try !condition() { throw UpdateTestFailure(message: message) }
    }
    static func rejects(_ message: String, _ work: () throws -> Void) throws {
        do { try work() } catch { checks += 1; return }; throw UpdateTestFailure(message: message)
    }
    static func write(_ text: String, _ file: URL) throws { try Data(text.utf8).write(to: file) }
    @discardableResult static func run(_ executable: String, _ arguments: [String]) throws -> Data { try UpdateFiles.command(executable, arguments) }
    static func sign(_ app: URL) throws {
        _ = try run("/usr/bin/codesign", ["--force", "--sign", "-", app.appendingPathComponent("Contents/Helpers/NightingaleUpdateHelper").path])
        _ = try run("/usr/bin/codesign", ["--force", "--deep", "--sign", "-", app.path])
    }
    static func makeApp(_ root: URL, version: String, build: Int, key: Data, binary: URL, helper: URL) throws -> URL {
        let app = root.appendingPathComponent(UpdateFiles.bundleName)
        for path in ["Contents/MacOS", "Contents/Resources", "Contents/Helpers"] { try fm.createDirectory(at: app.appendingPathComponent(path), withIntermediateDirectories: true) }
        try fm.copyItem(at: binary, to: app.appendingPathComponent("Contents/MacOS/NightingaleWriter"))
        try fm.copyItem(at: helper, to: app.appendingPathComponent("Contents/Helpers/NightingaleUpdateHelper"))
        try key.write(to: app.appendingPathComponent("Contents/Resources/update-public-key.bin"))
        try write("Signed payload \(version)\n", app.appendingPathComponent("Contents/Resources/payload.txt"))
        let plist: [String: Any] = ["CFBundleIdentifier": UpdateFiles.product, "CFBundlePackageType": "APPL", "CFBundleExecutable": "NightingaleWriter",
                                  "CFBundleShortVersionString": version, "CFBundleVersion": String(build), "LSMinimumSystemVersion": "13.0"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: app.appendingPathComponent("Contents/Info.plist"))
        try sign(app); return app
    }
    static func envelope(_ archive: Data, key: Curve25519.Signing.PrivateKey, version: String = "0.6.0", build: Int = 10, edit: ((inout [String: Any]) -> Void)? = nil) throws -> Data {
        var payload: [String: Any] = ["schemaVersion": 1, "product": UpdateFiles.product, "version": version, "build": build,
            "minimumSystemVersion": "13.0", "architecture": "arm64", "publishedAt": "2026-11-02T12:00:00Z", "notes": "Fixture release",
            "releaseURL": "https://github.com/Nightingalelyy/nightingalelyy.github.io/releases/tag/writer-v\(version)",
            "archive": ["url": "https://github.com/Nightingalelyy/nightingalelyy.github.io/releases/download/writer-v\(version)/Nightingale-Writer-\(version)-arm64.zip", "size": archive.count, "sha256": UpdateFiles.hash(archive)]]
        edit?(&payload)
        let bytes = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        return try JSONSerialization.data(withJSONObject: ["payload": bytes.base64EncodedString(), "signature": key.signature(for: bytes).base64EncodedString()], options: [.sortedKeys])
    }
    static func zip(_ app: URL, to path: URL) throws -> Data {
        _ = try run("/usr/bin/ditto", ["-c", "-k", "--norsrc", "--noextattr", "--keepParent", app.path, path.path]); return try Data(contentsOf: path)
    }
    static func bytes(_ value: UInt32, count: Int) -> [UInt8] { (0..<count).map { UInt8((value >> ($0 * 8)) & 255) } }
    static func set32(_ data: inout Data, _ offset: Int, _ value: UInt32) { data.replaceSubrange(offset..<offset + 4, with: bytes(value, count: 4)) }
    struct ZipItem { var path: String; var content = Data("hello".utf8); var mode: UInt32 = 0o100644; var flags: UInt16 = 0; var method: UInt16 = 0; var size: Int? }
    static func smallZip(_ items: [ZipItem]) -> Data {
        var local = Data(), central = Data()
        func add(_ value: UInt32, _ count: Int, to data: inout Data) { data.append(contentsOf: bytes(value, count: count)) }
        for item in items {
            let name = Data(item.path.utf8), offset = local.count, expanded = item.size ?? item.content.count
            let crc = UInt32(item.content.withUnsafeBytes { crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt(item.content.count)) })
            add(0x04034b50,4,to:&local); add(20,2,to:&local); add(UInt32(item.flags),2,to:&local); add(UInt32(item.method),2,to:&local)
            add(0,4,to:&local); add(item.flags & 8 == 0 ? crc : 0,4,to:&local); add(item.flags & 8 == 0 ? UInt32(item.content.count) : 0,4,to:&local); add(item.flags & 8 == 0 ? UInt32(expanded) : 0,4,to:&local)
            add(UInt32(name.count),2,to:&local); add(0,2,to:&local); local.append(name); local.append(item.content)
            if item.flags & 8 != 0 { for value in [UInt32(0x08074b50), crc, UInt32(item.content.count), UInt32(expanded)] { add(value,4,to:&local) } }
            add(0x02014b50,4,to:&central); add(0x0314,2,to:&central); add(20,2,to:&central); add(UInt32(item.flags),2,to:&central); add(UInt32(item.method),2,to:&central)
            add(0,4,to:&central); add(crc,4,to:&central); add(UInt32(item.content.count),4,to:&central); add(UInt32(expanded),4,to:&central)
            add(UInt32(name.count),2,to:&central); add(0,2,to:&central); add(0,2,to:&central); add(0,2,to:&central); add(0,2,to:&central); add(item.mode << 16,4,to:&central); add(UInt32(offset),4,to:&central); central.append(name)
        }
        let offset = local.count; local.append(central)
        add(0x06054b50,4,to:&local); add(0,2,to:&local); add(0,2,to:&local); add(UInt32(items.count),2,to:&local); add(UInt32(items.count),2,to:&local)
        add(UInt32(central.count),4,to:&local); add(UInt32(offset),4,to:&local); add(0,2,to:&local); return local
    }
    static func rawDeflate(_ input: Data) throws -> Data {
        var stream = z_stream(); guard deflateInit2_(&stream, Z_BEST_COMPRESSION, Z_DEFLATED, -MAX_WBITS, 8, Z_DEFAULT_STRATEGY, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw UpdateTestFailure(message: "Fixture compression failed") }
        defer { deflateEnd(&stream) }
        var result = Data(count: Int(compressBound(uLong(input.count))))
        let capacity = result.count
        let code = input.withUnsafeBytes { source in result.withUnsafeMutableBytes { target in
            stream.next_in = UnsafeMutablePointer(mutating: source.bindMemory(to: Bytef.self).baseAddress!); stream.avail_in = uInt(input.count)
            stream.next_out = target.bindMemory(to: Bytef.self).baseAddress!; stream.avail_out = uInt(capacity)
            return deflate(&stream, Z_FINISH)
        } }
        guard code == Z_STREAM_END else { throw UpdateTestFailure(message: "Fixture compression failed") }; result.count = Int(stream.total_out); return result
    }
    static func main() throws {
        let root = fm.temporaryDirectory.appendingPathComponent("writer-update-tests-\(UUID().uuidString)")
        try fm.createDirectory(at: root, withIntermediateDirectories: true); defer { try? fm.removeItem(at: root) }
        let desktop = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let binary = root.appendingPathComponent("fixture-binary"), helper = root.appendingPathComponent("fixture-helper")
        let c = root.appendingPathComponent("fixture.c"); try write("int main(void) { return 0; }\n", c)
        _ = try run("/usr/bin/clang", ["-arch", "arm64", "-mmacosx-version-min=13.0", c.path, "-o", binary.path])
        _ = try run("/usr/bin/swiftc", ["-swift-version", "5", "-target", "arm64-apple-macos13.0", "-parse-as-library", "-D", "UPDATE_INSTALLER", "-module-cache-path", desktop.appendingPathComponent(".build/module-cache").path,
            desktop.appendingPathComponent("native/UpdateManager.swift").path, desktop.appendingPathComponent("native/UpdateInstaller.swift").path, "-o", helper.path])
        // Ephemeral fixture key only. The production signing key is never read.
        let signing = Curve25519.Signing.PrivateKey(), publicKey = signing.publicKey.rawRepresentation
        let old = try makeApp(root.appendingPathComponent("old"), version: "0.5.0", build: 9, key: publicKey, binary: binary, helper: helper)
        let next = try makeApp(root.appendingPathComponent("next"), version: "0.6.0", build: 10, key: publicKey, binary: binary, helper: helper)
        let archive = try zip(next, to: root.appendingPathComponent("release.zip")), signed = try envelope(archive, key: signing)
        try expect(try UpdateManager.manifest(signed, key: publicKey).build == 10, "Valid pinned release signature must verify")
        try rejects("Wrong signing key must be rejected") { _ = try UpdateManager.manifest(signed, key: Curve25519.Signing.PrivateKey().publicKey.rawRepresentation) }
        var badSignature = try JSONSerialization.jsonObject(with: signed) as! [String: Any]; badSignature["signature"] = Data(repeating: 0, count: 64).base64EncodedString()
        try rejects("Corrupt signatures must be rejected") { _ = try UpdateManager.manifest(JSONSerialization.data(withJSONObject: badSignature), key: publicKey) }
        for (field, value) in [("architecture", "x86_64"), ("product", "another.app"), ("releaseURL", "https://evil.invalid/release")] {
            try rejects("Signed wrong \(field) must be rejected") { _ = try UpdateManager.manifest(envelope(archive, key: signing) { $0[field] = value }, key: publicKey) }
        }
        try expect(!UpdateHTTPDownloader.allowed(URL(string: "http://github.com/Nightingalelyy/nightingalelyy.github.io/releases/latest")!), "Plain HTTP must be refused")
        try expect(!UpdateHTTPDownloader.allowed(URL(string: "https://github.com/attacker/project/releases/latest")!), "Another GitHub repository must not be an update origin")
        try expect(!UpdateHTTPDownloader.allowed(URL(string: "https://github.com.evil.invalid/Nightingalelyy/nightingalelyy.github.io/releases/latest")!), "Lookalike hosts must be refused")
        try expect(UpdateHTTPDownloader.allowed(URL(string: "https://release-assets.githubusercontent.com/a?token=public")!), "Official release asset redirects are supported")
        let extracted = try UpdateArchive.extract(archive, to: root.appendingPathComponent("aliased-extraction"))
        _ = try UpdateFiles.verifyBundle(extracted, key: publicKey)
        try expect(try UpdateFiles.fingerprint(extracted) == UpdateFiles.fingerprint(next), "Real ditto archive must round-trip exactly, including aliased macOS temporary paths")
        let prefix = UpdateFiles.bundleName + "/Contents/"
        for name in ["../outside", "/absolute", UpdateFiles.bundleName + "/../outside", prefix + "a/../../outside", prefix + "a\\b", prefix + "a:b", prefix + "trailing. "] {
            try rejects("Unsafe ZIP path must be rejected: \(name)") { _ = try UpdateArchive.entries(smallZip([ZipItem(path: name)])) }
        }
        for items in [[ZipItem(path: prefix + "a"), ZipItem(path: prefix + "A")], [ZipItem(path: prefix + "café"), ZipItem(path: prefix + "cafe\u{301}")], [ZipItem(path: prefix + "a"), ZipItem(path: prefix + "a/b")]] {
            try rejects("Colliding ZIP paths must be rejected") { _ = try UpdateArchive.entries(smallZip(items)) }
        }
        for mode: UInt32 in [0o120777, 0o010644, 0o104755] { try rejects("Links, special files and privileged modes must be rejected") { _ = try UpdateArchive.entries(smallZip([ZipItem(path: prefix + "unsafe", mode: mode)])) } }
        try rejects("Encrypted ZIP entries must be rejected") { _ = try UpdateArchive.entries(smallZip([ZipItem(path: prefix + "encrypted", flags: 1)])) }
        var badOffset = smallZip([ZipItem(path: prefix + "offset")]); set32(&badOffset, badOffset.count - 6, UInt32.max)
        try rejects("Overflowing central directory offsets must be rejected") { _ = try UpdateArchive.entries(badOffset) }
        var badLocal = smallZip([ZipItem(path: prefix + "local")]); badLocal[30] ^= 1
        try rejects("Local and central names must match") { _ = try UpdateArchive.entries(badLocal) }
        var badDescriptor = smallZip([ZipItem(path: prefix + "descriptor", flags: 8)])
        let descriptorOffset = 30 + (prefix + "descriptor").utf8.count + 5
        badDescriptor[descriptorOffset + 4] ^= 1
        try rejects("Data descriptor CRC must match") { _ = try UpdateArchive.entries(badDescriptor) }
        var corruptContents = smallZip([ZipItem(path: prefix + "crc")]); corruptContents[30 + (prefix + "crc").utf8.count] ^= 1
        try rejects("Extracted bytes must pass CRC") { _ = try UpdateArchive.extract(corruptContents, to: root.appendingPathComponent("bad-crc")) }
        let compressedBomb = try rawDeflate(Data(repeating: 65, count: 1024 * 1024))
        try rejects("Inflation cannot exceed the declared bounded output") { _ = try UpdateArchive.extract(smallZip([ZipItem(path: prefix + "bomb", content: compressedBomb, method: 8, size: 1)]), to: root.appendingPathComponent("bomb")) }
        try expect(!fm.fileExists(atPath: root.appendingPathComponent("bomb").path), "Failed extraction must clean only its disposable output directory")
        let backup = try JSONSerialization.data(withJSONObject: ["format": "nightingale-writer-backup", "formatVersion": 1, "marker": "private fixture only"])
        func fixture(_ name: String) throws -> (URL, URL, UpdateManager) {
            let base = root.appendingPathComponent(name), app = base.appendingPathComponent(UpdateFiles.bundleName), data = base.appendingPathComponent("data")
            try fm.createDirectory(at: base, withIntermediateDirectories: true); try fm.copyItem(at: old, to: app); try fm.createDirectory(at: data, withIntermediateDirectories: true)
            try write("current private draft bytes", data.appendingPathComponent("state.json"))
            let manager = UpdateManager(resources: app.appendingPathComponent("Contents/Resources"), appURL: app, dataRoot: data, loader: { url, _ in url == UpdateManager.feedURL ? signed : archive })
            return (app, data, manager)
        }
        func stage(_ manager: UpdateManager) throws -> String {
            let available = try manager.handle(method: "checkForUpdates")
            try expect(available["state"] as? String == "available", "A newer signed release should be offered")
            let downloaded = try manager.handle(method: "downloadUpdate", params: ["version": "0.6.0", "build": 10])
            try expect(downloaded["canInstall"] as? Bool == true, "Validated download must be ready for explicit install")
            return (downloaded["prepared"] as! [String: Any])["token"] as! String
        }
        let (app, data, manager) = try fixture("successful-install")
        let token = try stage(manager)
        try expect(try UpdateFiles.bundleInfo(app).build == 9, "Checking and staging must not replace the installed app")
        let stagedApp = try manager.stageDirectory(token).appendingPathComponent("extracted/" + UpdateFiles.bundleName)
        try write("Tampered but ad-hoc re-signed", stagedApp.appendingPathComponent("Contents/Resources/payload.txt")); try sign(stagedApp)
        let handoff = try manager.prepareInstall(token: token, backup: backup, parentPID: Int32.max)
        try UpdateInstaller.apply(planURL: handoff.planURL, helperAppURL: app, wait: { _ in }, running: { _ in false }, reopen: false)
        try expect(try UpdateFiles.bundleInfo(app).build == 10, "Installer must swap the selected newer app")
        try expect(try String(contentsOf: app.appendingPathComponent("Contents/Resources/payload.txt")) == "Signed payload 0.6.0\n", "Installer must use fresh signed-archive extraction, not the re-signed staging tree")
        try expect(try String(contentsOf: data.appendingPathComponent("state.json")) == "current private draft bytes", "Installation must preserve live draft data")
        let installedStatus = try manager.status(), previous = installedStatus["rollback"] as! [String: Any]
        try expect(installedStatus["canRollback"] as? Bool == true && previous["build"] as? Int == 9, "A verified previous app must remain available")
        let checkpoint = try manager.checkpointDirectory(previous["token"] as! String)
        try expect(try Data(contentsOf: checkpoint.appendingPathComponent("writer-backup.json")) == backup, "The private portable backup must be retained beside the prior app")
        try write("newer draft after update", data.appendingPathComponent("state.json"))
        let rollback = try manager.prepareRollback(token: previous["token"] as! String, backup: backup, parentPID: Int32.max)
        try UpdateInstaller.apply(planURL: rollback.planURL, helperAppURL: app, wait: { _ in }, running: { _ in false }, reopen: false)
        try expect(try UpdateFiles.bundleInfo(app).build == 9, "Explicit rollback must restore the retained previous app")
        try expect(try String(contentsOf: data.appendingPathComponent("state.json")) == "newer draft after update", "Rollback must never restore older draft data automatically")
        let checkpoints = try fm.contentsOfDirectory(at: manager.updatesRoot.appendingPathComponent("checkpoints"), includingPropertiesForKeys: nil)
        try expect(checkpoints.count == 1, "Only one successful previous app/data checkpoint should be retained")
        let (failedApp, failedData, failedManager) = try fixture("post-swap-failure")
        let failedToken = try stage(failedManager), beforeFailure = try UpdateFiles.fingerprint(failedApp)
        let failedHandoff = try failedManager.prepareInstall(token: failedToken, backup: backup, parentPID: Int32.max)
        try rejects("Post-swap failure must be reported") { try UpdateInstaller.apply(planURL: failedHandoff.planURL, helperAppURL: failedApp, wait: { _ in }, running: { _ in false }, reopen: false, afterSwap: { throw UpdateTestFailure(message: "Simulated finalization failure") }) }
        try expect(try UpdateFiles.fingerprint(failedApp) == beforeFailure, "Post-swap failure must atomically restore the prior app")
        try expect(try String(contentsOf: failedData.appendingPathComponent("state.json")) == "current private draft bytes", "Failure rollback cannot alter draft storage")
        let (racedApp, _, racedManager) = try fixture("target-race")
        let racedToken = try stage(racedManager), racedHandoff = try racedManager.prepareInstall(token: racedToken, backup: backup, parentPID: Int32.max)
        var changedTarget = false
        let racingRunner: UpdateCommandRunner = { executable, args in
            let output = try UpdateFiles.command(executable, args)
            if !changedTarget && args.last?.contains(".Nightingale-Writer-update-") == true {
                changedTarget = true; try write("Manual replacement must survive", racedApp.appendingPathComponent("Contents/Resources/payload.txt")); try sign(racedApp)
            }
            return output
        }
        try rejects("A target changed during candidate verification must not be overwritten") { try UpdateInstaller.apply(planURL: racedHandoff.planURL, helperAppURL: racedApp, wait: { _ in }, running: { _ in false }, reopen: false, runner: racingRunner) }
        try expect(changedTarget && (try String(contentsOf: racedApp.appendingPathComponent("Contents/Resources/payload.txt"))) == "Manual replacement must survive", "Concurrent target bytes must remain intact")
        let (boundaryApp, _, boundaryManager) = try fixture("swap-boundary-race")
        let boundaryToken = try stage(boundaryManager), boundaryHandoff = try boundaryManager.prepareInstall(token: boundaryToken, backup: backup, parentPID: Int32.max)
        try rejects("A replacement after the last check must be restored rather than deleted") {
            try UpdateInstaller.apply(planURL: boundaryHandoff.planURL, helperAppURL: boundaryApp, wait: { _ in }, running: { _ in false }, reopen: false, beforeSwap: {
                try write("Replacement at atomic swap boundary", boundaryApp.appendingPathComponent("Contents/Resources/payload.txt")); try sign(boundaryApp)
            })
        }
        try expect(try String(contentsOf: boundaryApp.appendingPathComponent("Contents/Resources/payload.txt")) == "Replacement at atomic swap boundary", "Swap-back must restore the actual displaced manual replacement, not an older checkpoint")
        let (crashApp, crashData, crashManager) = try fixture("crash-after-swap")
        let crashToken = try stage(crashManager), crashHandoff = try crashManager.prepareInstall(token: crashToken, backup: backup, parentPID: Int32.max)
        let crashPlan = try JSONDecoder().decode(UpdateInstallPlan.self, from: Data(contentsOf: crashHandoff.planURL))
        let crashSibling = crashApp.deletingLastPathComponent().appendingPathComponent(".Nightingale-Writer-update-\(crashPlan.token).app")
        try fm.copyItem(at: next, to: crashSibling)
        try expect(renameatx_np(AT_FDCWD, crashSibling.path, AT_FDCWD, crashApp.path, UInt32(RENAME_SWAP)) == 0, "Crash fixture must complete exactly one atomic bundle swap")
        let crashLock = crashManager.updatesRoot.appendingPathComponent("install.lock")
        try fm.createDirectory(at: crashLock, withIntermediateDirectories: false)
        try UpdateFiles.write(JSONSerialization.data(withJSONObject: ["pid": Int32.max, "token": crashPlan.token]), to: crashLock.appendingPathComponent("owner.json"))
        let afterCrashHash = try UpdateFiles.fingerprint(crashApp), afterCrash = try crashManager.status()
        try expect(afterCrash["state"] as? String == "current" && afterCrash["canRollback"] as? Bool == true, "A proven completed swap must recover its journal and previous checkpoint after power loss")
        try expect(try UpdateFiles.fingerprint(crashApp) == afterCrashHash, "Journal recovery must not swap the installed app again")
        try expect(try String(contentsOf: crashData.appendingPathComponent("state.json")) == "current private draft bytes", "Crash recovery must preserve current draft data")
        let (_, _, abandonedManager) = try fixture("abandoned-handoff")
        let abandonedToken = try stage(abandonedManager)
        _ = try abandonedManager.prepareInstall(token: abandonedToken, backup: backup, parentPID: Int32.max)
        let recoveredStatus = try abandonedManager.status()
        try expect(recoveredStatus["state"] as? String == "staged" && recoveredStatus["canInstall"] as? Bool == true, "Power loss before helper start must recover to reviewable staging instead of being stuck")
        let (_, _, malformedLockManager) = try fixture("malformed-lock")
        let lockToken = try stage(malformedLockManager)
        _ = try malformedLockManager.prepareInstall(token: lockToken, backup: backup, parentPID: Int32.max)
        try fm.createDirectory(at: malformedLockManager.updatesRoot.appendingPathComponent("install.lock"), withIntermediateDirectories: false)
        try expect(try malformedLockManager.status()["state"] as? String == "error", "Incomplete installer locks must surface recovery errors, not indefinite installing status")
        let (_, _, diskManager) = try fixture("prepare-disk-failure")
        let diskToken = try stage(diskManager), saved = diskManager.updatesRoot.appendingPathComponent("saved-state.json")
        try fm.moveItem(at: diskManager.stateURL, to: saved); try fm.createDirectory(at: diskManager.stateURL, withIntermediateDirectories: false)
        try rejects("Failed pending-state persistence must reject handoff") { _ = try diskManager.prepareInstall(token: diskToken, backup: backup, parentPID: Int32.max) }
        try fm.removeItem(at: diskManager.stateURL); try fm.moveItem(at: saved, to: diskManager.stateURL)
        let retried = try diskManager.prepareInstall(token: diskToken, backup: backup, parentPID: getpid())
        try diskManager.cancelHandoff(retried)
        try expect(try diskManager.status()["canInstall"] as? Bool == true, "A failed prepare must not leave an in-memory pending request blocking retry")
        // Real child helper readiness: parent deliberately remains alive, so no app swap occurs.
        let (readyApp, _, readyManager) = try fixture("helper-readiness")
        let readyToken = try stage(readyManager), readyHandoff = try readyManager.prepareInstall(token: readyToken, backup: backup, parentPID: getpid())
        let child = Process(); child.executableURL = readyHandoff.helperURL; child.arguments = ["--apply-plan", readyHandoff.planURL.path]
        child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
        try child.run()
        do { try readyManager.waitForHelperReady(readyHandoff, helperPID: child.processIdentifier) }
        catch { child.terminate(); child.waitUntilExit(); throw error }
        try expect(child.isRunning && (try UpdateFiles.bundleInfo(readyApp).build) == 9, "Helper must acknowledge readiness then wait for its still-live parent")
        child.terminate(); child.waitUntilExit()
        try readyManager.cancelHandoff(readyHandoff, helperPID: child.processIdentifier)
        try expect(!fm.fileExists(atPath: readyManager.updatesRoot.appendingPathComponent("install.lock").path), "Cancelled stopped helper must release only its own stale lock")
        try expect(try readyManager.status()["canInstall"] as? Bool == true, "Readiness cancellation must preserve the verified stage for retry")
        print("Update manager and installer tests passed: \(checks) assertions. Only disposable bundles were modified; no release network request was made.")
    }
}
