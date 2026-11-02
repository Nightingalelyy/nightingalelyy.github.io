import Foundation
import CryptoKit
import Darwin
import zlib

struct WriterUpdateError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

typealias UpdateLoader = (_ url: URL, _ maximumBytes: Int) throws -> Data
typealias UpdateCommandRunner = (_ executable: String, _ arguments: [String]) throws -> Data

struct UpdateManifest: Codable {
    struct Archive: Codable { let url: String; let sha256: String; let size: Int }
    let schemaVersion: Int
    let product: String
    let version: String
    let build: Int
    let minimumSystemVersion: String
    let architecture: String
    let archive: Archive
    let releaseURL: String
    let publishedAt: String
    let notes: String?
}

struct UpdateStage: Codable {
    let token: String
    let envelope: Data
}

struct UpdateCheckpoint: Codable {
    let token: String
    let version: String
    let build: Int
    let bundleHash: String
    let backupHash: String
}

struct UpdateDiskState: Codable {
    var schemaVersion = 1
    var highestSeenBuild = 0
    var available: Data?
    var prepared: UpdateStage?
    var previous: UpdateCheckpoint?
    var pendingJob: String?
    var state = "idle"
    var message = "Check for a signed update when you are ready."
}

struct UpdateInstallPlan: Codable {
    let schemaVersion: Int
    let token: String
    let operation: String
    let parentPID: Int32
    let targetAppPath: String
    let dataRootPath: String
    let currentBundleHash: String
    let expectedVersion: String
    let expectedBuild: Int
    let stage: UpdateStage?
    let rollback: UpdateCheckpoint?
    let checkpoint: UpdateCheckpoint
}

struct UpdateHandoff {
    let helperURL: URL
    let planURL: URL
    let status: [String: Any]
}

struct UpdateBundleInfo {
    let version: String
    let build: Int
    let executable: String
}

enum UpdateFiles {
    static let product = "io.github.nightingalelyy.writer"
    static let bundleName = "Nightingale Writer.app"
    static let archiveLimit = 256 * 1024 * 1024
    static let expandedLimit = 512 * 1024 * 1024
    static let fileLimit = 128 * 1024 * 1024
    static let fm = FileManager.default
    static func error(_ message: String) -> WriterUpdateError { WriterUpdateError(message: message) }
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func canonical(_ url: URL) -> URL { url.resolvingSymlinksInPath().standardizedFileURL }
    static func validToken(_ token: String) -> Bool { UUID(uuidString: token) != nil && token == token.lowercased() }
    static func directory(_ url: URL) throws {
        if fm.fileExists(atPath: url.path) {
            let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { throw error("Update storage must be a real directory.") }
        } else { try fm.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
    static func read(_ url: URL, maximum: Int) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? maximum + 1) <= maximum else { throw error("An update file is missing, unsafe, or too large.") }
        let data = try Data(contentsOf: url)
        guard data.count <= maximum else { throw error("An update file exceeded its size limit.") }; return data
    }
    static func write(_ data: Data, to url: URL) throws {
        try directory(url.deletingLastPathComponent())
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".update-\(UUID().uuidString).tmp")
        defer { try? fm.removeItem(at: temporary) }
        guard fm.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]), rename(temporary.path, url.path) == 0 else { throw error("Could not save update information safely.") }
    }
    static func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        try write(encoder.encode(value), to: url)
    }
    static func child(_ parent: URL, token: String) throws -> URL {
        guard validToken(token) else { throw error("Invalid update review token.") }
        try directory(parent)
        let target = parent.appendingPathComponent(token, isDirectory: true)
        if fm.fileExists(atPath: target.path), (try target.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink == true { throw error("Update storage cannot contain symbolic links.") }
        return target
    }
    static func command(_ executable: String, _ arguments: [String]) throws -> Data {
        let process = Process(); process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        let temporary = fm.temporaryDirectory.appendingPathComponent("writer-update-command-\(UUID().uuidString)")
        guard fm.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw error("Could not create update verification output.") }
        let output = try FileHandle(forUpdating: temporary); try fm.removeItem(at: temporary)
        defer { try? output.close() }
        process.standardOutput = output; process.standardError = output; process.standardInput = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0); process.terminationHandler = { _ in finished.signal() }
        try process.run()
        if finished.wait(timeout: .now() + 45) == .timedOut {
            process.terminate()
            if finished.wait(timeout: .now() + 2) == .timedOut { kill(process.processIdentifier, SIGKILL); _ = finished.wait(timeout: .now() + 2) }
            throw error("Update verification timed out. The installed app was not changed.")
        }
        try output.seek(toOffset: 0)
        let data = try output.read(upToCount: 1024 * 1024 + 1) ?? Data()
        guard data.count <= 1024 * 1024, process.terminationStatus == 0 else {
            throw error("Update verification failed: " + String((String(data: data, encoding: .utf8) ?? "Unknown tool error").prefix(1200)))
        }
        return data
    }
    static func bundleInfo(_ app: URL) throws -> UpdateBundleInfo {
        let data = try read(app.appendingPathComponent("Contents/Info.plist"), maximum: 1024 * 1024)
        guard let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              info["CFBundleIdentifier"] as? String == product, info["CFBundlePackageType"] as? String == "APPL",
              let version = info["CFBundleShortVersionString"] as? String, version.range(of: "^[0-9]+\\.[0-9]+\\.[0-9]+$", options: .regularExpression) != nil, version.count <= 32,
              let buildString = info["CFBundleVersion"] as? String, let build = Int(buildString), build > 0,
              let executable = info["CFBundleExecutable"] as? String, executable == "NightingaleWriter" else { throw error("This is not a supported Nightingale Writer app bundle.") }
        let binaryURL = app.appendingPathComponent("Contents/MacOS/" + executable)
        let binary = try read(binaryURL, maximum: fileLimit)
        guard binary.count >= 32, binary.u32(0) == 0xfeedfacf, binary.u32(4) == 0x0100000c, binary.u32(12) == 2,
              fm.isExecutableFile(atPath: binaryURL.path) else { throw error("The update must contain an Apple Silicon executable.") }
        return UpdateBundleInfo(version: version, build: build, executable: executable)
    }
    static func inventory(_ app: URL) throws -> [(String, URL, Int)] {
        let info = try app.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard info.isDirectory == true, info.isSymbolicLink != true else { throw error("The app bundle is not a real directory.") }
        guard let iterator = fm.enumerator(at: app, includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey, .fileSizeKey]) else { throw error("Could not inspect the app bundle.") }
        var files: [(String, URL, Int)] = [], total = 0, count = 0, seen = Set<String>()
        for case let file as URL in iterator {
            count += 1; guard count <= 20000 else { throw error("The app bundle has too many files.") }
            let values = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey, .fileSizeKey])
            guard values.isSymbolicLink != true else { throw error("Update app bundles cannot contain symbolic links.") }
            let basePath = canonical(app).path, filePath = canonical(file).path
            guard filePath.hasPrefix(basePath + "/") else { throw error("An app file is outside its bundle.") }
            let path = String(filePath.dropFirst(basePath.count + 1))
            let normalized = path.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            guard seen.insert(normalized).inserted else { throw error("App bundle paths collide on this Mac.") }
            if values.isDirectory == true { continue }
            guard values.isRegularFile == true, let size = values.fileSize, size >= 0, size <= fileLimit,
                  (try fm.attributesOfItem(atPath: file.path)[.referenceCount] as? NSNumber)?.intValue == 1 else { throw error("The app bundle contains an unsafe file.") }
            total += size; guard total <= expandedLimit else { throw error("The expanded app bundle is too large.") }
            files.append((path, file, size))
        }
        return files.sorted { $0.0 < $1.0 }
    }
    static func fingerprint(_ app: URL) throws -> String {
        var hash = SHA256()
        for (path, url, size) in try inventory(app) {
            hash.update(data: Data(path.utf8)); hash.update(data: Data([0]))
            hash.update(data: Data("\(size):\(fm.isExecutableFile(atPath: url.path) ? 1 : 0):".utf8))
            hash.update(data: Data(self.hash(try read(url, maximum: fileLimit)).utf8))
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    @discardableResult static func verifyBundle(_ app: URL, manifest: UpdateManifest? = nil, key: Data? = nil, runner: UpdateCommandRunner = command) throws -> UpdateBundleInfo {
        _ = try inventory(app)
        let info = try bundleInfo(app)
        if let manifest {
            guard info.version == manifest.version, info.build == manifest.build else { throw error("The app version does not match its signed release manifest.") }
            let plist = try PropertyListSerialization.propertyList(from: read(app.appendingPathComponent("Contents/Info.plist"), maximum: 1024 * 1024), format: nil) as! [String: Any]
            guard plist["LSMinimumSystemVersion"] as? String == manifest.minimumSystemVersion else { throw error("The update's system requirement does not match its signed manifest.") }
        }
        if let key {
            guard try read(app.appendingPathComponent("Contents/Resources/update-public-key.bin"), maximum: 32) == key else { throw error("The update would replace the trusted release-signing key.") }
        }
        _ = try runner("/usr/bin/codesign", ["--verify", "--deep", "--strict", "-R", "=identifier \"\(product)\"", app.path])
        return info
    }
}

private extension Data {
    func u16(_ offset: Int) -> UInt16 { UInt16(self[offset]) | UInt16(self[offset + 1]) << 8 }
    func u32(_ offset: Int) -> UInt32 { UInt32(self[offset]) | UInt32(self[offset + 1]) << 8 | UInt32(self[offset + 2]) << 16 | UInt32(self[offset + 3]) << 24 }
}

/// Strict classic ZIP extraction. Allocation and inflation are bounded by checked
/// sizes; unsupported metadata cannot redirect an extractor to another pathname.
enum UpdateArchive {
    struct Entry {
        let path: String
        let directory: Bool
        let method: UInt16
        let crc: UInt32
        let compressed: Int
        let expanded: Int
        let offset: Int
        let executable: Bool
    }
    static func entries(_ data: Data) throws -> [Entry] {
        func bad() -> WriterUpdateError { UpdateFiles.error("The update ZIP is malformed or contains unsafe paths or unsupported entries.") }
        guard data.count >= 22, data.count <= UpdateFiles.archiveLimit else { throw bad() }
        var end: Int?
        for offset in stride(from: data.count - 22, through: max(0, data.count - 65557), by: -1) {
            if data.u32(offset) == 0x06054b50, offset + 22 + Int(data.u16(offset + 20)) == data.count { end = offset; break }
        }
        guard let end, data.u16(end + 4) == 0, data.u16(end + 6) == 0,
              data.u16(end + 8) == data.u16(end + 10) else { throw bad() }
        let count = Int(data.u16(end + 10)), centralSize = Int(data.u32(end + 12)), central = Int(data.u32(end + 16))
        guard count > 0, count <= 20000, count != 65535, central <= end, centralSize == end - central else { throw bad() }
        func extras(_ offset: Int, _ length: Int) throws {
            var cursor = offset
            guard offset >= 0, length >= 0, offset + length <= data.count else { throw bad() }
            while cursor < offset + length {
                guard cursor + 4 <= offset + length else { throw bad() }
                let id = data.u16(cursor), size = Int(data.u16(cursor + 2))
                guard [UInt16(0x5855), 0x5455, 0x7875].contains(id), size <= 32, cursor + 4 + size <= offset + length else { throw bad() }
                cursor += 4 + size
            }
        }
        var cursor = central, result: [Entry] = [], ranges: [(Int, Int)] = [], names = Set<String>(), parents = Set<String>(), regular = Set<String>(), total = 0
        for _ in 0..<count {
            guard cursor + 46 <= end, data.u32(cursor) == 0x02014b50 else { throw bad() }
            let flags = data.u16(cursor + 8), method = data.u16(cursor + 10), crc = data.u32(cursor + 16)
            let compressed = Int(data.u32(cursor + 20)), expanded = Int(data.u32(cursor + 24))
            let nameSize = Int(data.u16(cursor + 28)), extraSize = Int(data.u16(cursor + 30)), commentSize = Int(data.u16(cursor + 32))
            let mode = data.u32(cursor + 38) >> 16, type = mode & 0o170000, local = Int(data.u32(cursor + 42))
            guard data.u16(cursor + 6) <= 20, data.u16(cursor + 34) == 0, flags & ~UInt16(0x080e) == 0,
                  method == 0 || method == 8, nameSize > 0, nameSize <= 2048,
                  cursor + 46 + nameSize + extraSize + commentSize <= end,
                  expanded <= UpdateFiles.fileLimit, compressed <= UpdateFiles.archiveLimit, mode & 0o7000 == 0,
                  type == 0 || type == 0o100000 || type == 0o040000 else { throw bad() }
            let nameData = data.subdata(in: cursor + 46..<cursor + 46 + nameSize)
            guard let name = String(data: nameData, encoding: .utf8), !name.hasPrefix("/"), !name.contains("\\"), !name.contains(":"),
                  !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw bad() }
            let directory = name.hasSuffix("/")
            let path = directory ? String(name.dropLast()) : name
            let parts = path.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.first == Substring(UpdateFiles.bundleName), parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.hasSuffix(".") && !$0.hasSuffix(" ") }),
                  (directory && (type == 0 || type == 0o040000)) || (!directory && (type == 0 || type == 0o100000)),
                  !directory || (expanded == 0 && compressed == 0 && method == 0 && flags & 8 == 0),
                  method != 0 || compressed == expanded else { throw bad() }
            let normalized = path.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            guard names.insert(normalized).inserted else { throw bad() }
            if !directory { regular.insert(normalized) }
            var prefix = ""
            for part in normalized.split(separator: "/").dropLast() { prefix = prefix.isEmpty ? String(part) : prefix + "/" + part; parents.insert(prefix) }
            try extras(cursor + 46 + nameSize, extraSize)
            guard local >= 0, local + 30 <= central, data.u32(local) == 0x04034b50,
                  data.u16(local + 6) == flags, data.u16(local + 8) == method, data.u16(local + 26) == nameSize else { throw bad() }
            let localExtra = Int(data.u16(local + 28)), start = local + 30 + nameSize + localExtra
            guard start <= central, data.subdata(in: local + 30..<local + 30 + nameSize) == nameData,
                  compressed <= central - start else { throw bad() }
            try extras(local + 30 + nameSize, localExtra)
            var finish = start + compressed
            if flags & 8 != 0 {
                guard [UInt32(0), crc].contains(data.u32(local + 14)), [UInt32(0), UInt32(compressed)].contains(data.u32(local + 18)), [UInt32(0), UInt32(expanded)].contains(data.u32(local + 22)), finish + 12 <= central else { throw bad() }
                if data.u32(finish) == 0x08074b50 { finish += 4 }
                guard finish + 12 <= central, data.u32(finish) == crc, data.u32(finish + 4) == compressed, data.u32(finish + 8) == expanded else { throw bad() }
                finish += 12
            } else {
                guard data.u32(local + 14) == crc, data.u32(local + 18) == compressed, data.u32(local + 22) == expanded else { throw bad() }
            }
            total += expanded; guard total <= UpdateFiles.expandedLimit else { throw bad() }
            ranges.append((local, finish)); result.append(Entry(path: path, directory: directory, method: method, crc: crc, compressed: compressed, expanded: expanded, offset: start, executable: mode & 0o111 != 0))
            cursor += 46 + nameSize + extraSize + commentSize
        }
        guard cursor == end, regular.isDisjoint(with: parents) else { throw bad() }
        var next = 0
        for range in ranges.sorted(by: { $0.0 < $1.0 }) { guard range.0 == next else { throw bad() }; next = range.1 }
        guard next == central else { throw bad() }
        return result
    }
    static func extract(_ data: Data, to directory: URL) throws -> URL {
        let entries = try self.entries(data)
        guard !UpdateFiles.fm.fileExists(atPath: directory.path) else { throw UpdateFiles.error("The update extraction directory already exists.") }
        try UpdateFiles.directory(directory)
        do {
            for entry in entries.sorted(by: { $0.path.split(separator: "/").count < $1.path.split(separator: "/").count }) {
                let target = directory.appendingPathComponent(entry.path, isDirectory: entry.directory)
                if entry.directory {
                    try UpdateFiles.fm.createDirectory(at: target, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755]); continue
                }
                try UpdateFiles.fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
                var decoded: Data
                if entry.method == 0 { decoded = data.subdata(in: entry.offset..<entry.offset + entry.compressed) }
                else {
                    decoded = Data(count: entry.expanded + 1)
                    var stream = z_stream()
                    guard inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else { throw UpdateFiles.error("Could not initialize bounded ZIP decompression.") }
                    defer { inflateEnd(&stream) }
                    let result: Int32 = data.withUnsafeBytes { source in
                        decoded.withUnsafeMutableBytes { destination in
                            stream.next_in = UnsafeMutablePointer(mutating: source.bindMemory(to: Bytef.self).baseAddress!.advanced(by: entry.offset)); stream.avail_in = uInt(entry.compressed)
                            stream.next_out = destination.bindMemory(to: Bytef.self).baseAddress!; stream.avail_out = uInt(entry.expanded + 1)
                            return inflate(&stream, Z_FINISH)
                        }
                    }
                    guard result == Z_STREAM_END, stream.total_in == entry.compressed, stream.total_out == entry.expanded else { throw UpdateFiles.error("ZIP contents do not match their bounded declared sizes.") }
                    decoded.removeLast()
                }
                let crc = decoded.withUnsafeBytes { crc32(0, $0.bindMemory(to: Bytef.self).baseAddress, uInt(decoded.count)) }
                guard UInt32(crc) == entry.crc else { throw UpdateFiles.error("ZIP content failed its integrity check.") }
                guard UpdateFiles.fm.createFile(atPath: target.path, contents: decoded, attributes: [.posixPermissions: entry.executable ? 0o755 : 0o644]) else { throw UpdateFiles.error("Could not stage an update file.") }
            }
            let app = directory.appendingPathComponent(UpdateFiles.bundleName, isDirectory: true)
            let actual = try UpdateFiles.inventory(app)
            let expected = entries.filter { !$0.directory }.map { String($0.path.dropFirst(UpdateFiles.bundleName.count + 1)) }
            guard Set(actual.map { $0.0 }) == Set(expected), actual.count == expected.count else { throw UpdateFiles.error("Extracted update files do not match the verified archive.") }
            return app
        } catch { try? UpdateFiles.fm.removeItem(at: directory); throw error }
    }
}

final class UpdateHTTPDownloader: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate, @unchecked Sendable {
    private var bytes = Data()
    private var limit = 0
    private var failure: Error?
    private let completed = DispatchSemaphore(value: 0)
    private var task: URLSessionDataTask?
    static func allowed(_ url: URL) -> Bool {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false), parts.scheme == "https", parts.user == nil, parts.password == nil,
              parts.port == nil || parts.port == 443, let host = parts.host?.lowercased() else { return false }
        if host == "github.com" { return parts.path.lowercased().hasPrefix("/nightingalelyy/nightingalelyy.github.io/releases/") }
        return ["release-assets.githubusercontent.com", "objects.githubusercontent.com"].contains(host)
    }
    static func load(_ url: URL, maximum: Int) throws -> Data {
        guard allowed(url) else { throw UpdateFiles.error("The update URL is outside the trusted release origin.") }
        let worker = UpdateHTTPDownloader(); worker.limit = maximum
        let config = URLSessionConfiguration.ephemeral
        config.urlCredentialStorage = nil; config.httpCookieStorage = nil; config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 90
        let session = URLSession(configuration: config, delegate: worker, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url); request.setValue("NightingaleWriter-Updater", forHTTPHeaderField: "User-Agent")
        worker.task = session.dataTask(with: request); worker.task!.resume()
        guard worker.completed.wait(timeout: .now() + 95) == .success else { worker.task?.cancel(); throw UpdateFiles.error("Update download timed out. The installed app was not changed.") }
        if let error = worker.failure { throw error }
        return worker.bytes
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, Self.allowed(url) else { failure = UpdateFiles.error("The release redirected outside trusted HTTPS download hosts."); completionHandler(nil); return }
        var clean = request; clean.setValue(nil, forHTTPHeaderField: "Authorization"); clean.setValue(nil, forHTTPHeaderField: "Cookie"); completionHandler(clean)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let response = response as? HTTPURLResponse, response.statusCode == 200, response.expectedContentLength <= Int64(limit) else {
            failure = UpdateFiles.error("The release download was unavailable or exceeded its size limit."); completionHandler(.cancel); return
        }
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard bytes.count <= limit - data.count else { failure = UpdateFiles.error("The update download exceeded its size limit."); dataTask.cancel(); return }; bytes.append(data)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if failure == nil { failure = error }; completed.signal()
    }
}

/// Called on a dedicated serial maintenance queue. Network operations are explicit;
/// constructing the manager or reading status never contacts a release server.
final class UpdateManager {
    static let feedURL = URL(string: "https://github.com/Nightingalelyy/nightingalelyy.github.io/releases/latest/download/nightingale-writer-update.json")!
    let resources: URL
    let appURL: URL
    let dataRoot: URL
    let updatesRoot: URL
    let loader: UpdateLoader
    let runner: UpdateCommandRunner
    private var state = UpdateDiskState()
    private var durableState = UpdateDiskState()
    private var loaded = false
    private var configurationFailure: String?

    init(resources: URL, appURL: URL, dataRoot: URL, loader: UpdateLoader? = nil, runner: UpdateCommandRunner? = nil) {
        self.resources = UpdateFiles.canonical(resources)
        self.appURL = UpdateFiles.canonical(appURL)
        self.dataRoot = UpdateFiles.canonical(dataRoot)
        updatesRoot = self.dataRoot.appendingPathComponent("updates", isDirectory: true)
        self.loader = loader ?? UpdateHTTPDownloader.load
        self.runner = runner ?? UpdateFiles.command
    }
    var stateURL: URL { updatesRoot.appendingPathComponent("state.json") }
    func key() throws -> Data {
        let value = try UpdateFiles.read(resources.appendingPathComponent("update-public-key.bin"), maximum: 32)
        guard value.count == 32 else { throw UpdateFiles.error("Signed app updates are not configured for this build.") }
        _ = try Curve25519.Signing.PublicKey(rawRepresentation: value)
        return value
    }
    private func initialize() throws {
        if loaded { return }
        try UpdateFiles.directory(dataRoot); try UpdateFiles.directory(updatesRoot)
        if UpdateFiles.fm.fileExists(atPath: stateURL.path) {
            do {
                state = try JSONDecoder().decode(UpdateDiskState.self, from: UpdateFiles.read(stateURL, maximum: 256 * 1024))
                guard state.schemaVersion == 1, state.highestSeenBuild >= 0 else { throw UpdateFiles.error("Unsupported updater state.") }
            } catch {
                configurationFailure = "Saved update information could not be read. The installed app and draft data have not been changed."
            }
        }
        durableState = state
        loaded = true
    }
    private func save() throws {
        do { try UpdateFiles.writeJSON(state, to: stateURL); durableState = state }
        catch { state = durableState; throw error }
    }
    static func manifest(_ envelope: Data, key: Data) throws -> UpdateManifest {
        struct Envelope: Decodable { let payload: String; let signature: String }
        guard envelope.count <= 64 * 1024, key.count == 32 else { throw UpdateFiles.error("The signed update manifest has an invalid size.") }
        let wrapper = try JSONDecoder().decode(Envelope.self, from: envelope)
        guard let payload = Data(base64Encoded: wrapper.payload), payload.count <= 32 * 1024,
              let signature = Data(base64Encoded: wrapper.signature), signature.count == 64,
              try Curve25519.Signing.PublicKey(rawRepresentation: key).isValidSignature(signature, for: payload) else { throw UpdateFiles.error("The release signature could not be verified. Nothing was downloaded or installed.") }
        let manifest = try JSONDecoder().decode(UpdateManifest.self, from: payload)
        let version = manifest.version
        let tag = "writer-v" + version
        let origin = "https://github.com/Nightingalelyy/nightingalelyy.github.io/releases/"
        guard manifest.schemaVersion == 1, manifest.product == UpdateFiles.product, manifest.architecture == "arm64",
              version.count <= 32, version.range(of: "^[0-9]+\\.[0-9]+\\.[0-9]+$", options: .regularExpression) != nil,
              manifest.build > 0, manifest.build <= 1_000_000_000,
              manifest.minimumSystemVersion.range(of: "^[0-9]+\\.[0-9]+(?:\\.[0-9]+)?$", options: .regularExpression) != nil, manifest.minimumSystemVersion.count <= 20,
              manifest.archive.url == origin + "download/" + tag + "/Nightingale-Writer-" + version + "-arm64.zip",
              manifest.releaseURL == origin + "tag/" + tag,
              manifest.archive.sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
              manifest.archive.size > 0, manifest.archive.size <= UpdateFiles.archiveLimit, (manifest.notes?.utf8.count ?? 0) <= 8192,
              manifest.publishedAt.count <= 64 else { throw UpdateFiles.error("The signed release manifest does not describe a supported app update.") }
        let formatter = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter(); fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard formatter.date(from: manifest.publishedAt) != nil || fractional.date(from: manifest.publishedAt) != nil else { throw UpdateFiles.error("The signed release date is invalid.") }
        return manifest
    }
    static func supportsSystem(_ manifest: UpdateManifest) -> Bool {
        let required = manifest.minimumSystemVersion.split(separator: ".").compactMap { Int($0) }
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let actual = [os.majorVersion, os.minorVersion, os.patchVersion]
        for index in 0..<3 {
            let expected = index < required.count ? required[index] : 0
            if actual[index] != expected { return actual[index] > expected }
        }
        return true
    }
    func stageDirectory(_ token: String) throws -> URL { try UpdateFiles.child(updatesRoot.appendingPathComponent("staging", isDirectory: true), token: token) }
    func checkpointDirectory(_ token: String) throws -> URL { try UpdateFiles.child(updatesRoot.appendingPathComponent("checkpoints", isDirectory: true), token: token) }
    private func descriptor(_ manifest: UpdateManifest) -> [String: Any] {
        ["version": manifest.version, "build": manifest.build, "releaseURL": manifest.releaseURL, "notes": manifest.notes ?? ""]
    }
    private func verifiedStage(_ stage: UpdateStage, current: UpdateBundleInfo, key: Data) throws -> UpdateManifest {
        let manifest = try Self.manifest(stage.envelope, key: key)
        guard manifest.build > current.build, manifest.build >= state.highestSeenBuild, Self.supportsSystem(manifest) else { throw UpdateFiles.error("The staged release is older than the installed or previously reviewed build, or needs a newer macOS version.") }
        let directory = try stageDirectory(stage.token)
        guard try UpdateFiles.read(directory.appendingPathComponent("manifest.json"), maximum: 64 * 1024) == stage.envelope else { throw UpdateFiles.error("The staged release proof changed.") }
        let archive = try UpdateFiles.read(directory.appendingPathComponent("archive.zip"), maximum: manifest.archive.size)
        guard archive.count == manifest.archive.size, UpdateFiles.hash(archive) == manifest.archive.sha256 else { throw UpdateFiles.error("The staged download no longer matches its signed checksum.") }
        _ = try UpdateArchive.entries(archive)
        _ = try UpdateFiles.verifyBundle(directory.appendingPathComponent("extracted/" + UpdateFiles.bundleName), manifest: manifest, key: key, runner: runner)
        return manifest
    }
    @discardableResult func verifiedCheckpoint(_ checkpoint: UpdateCheckpoint) throws -> UpdateBundleInfo {
        let directory = try checkpointDirectory(checkpoint.token)
        let recorded = try JSONDecoder().decode(UpdateCheckpoint.self, from: UpdateFiles.read(directory.appendingPathComponent("receipt.json"), maximum: 16 * 1024))
        guard recorded.token == checkpoint.token, recorded.bundleHash == checkpoint.bundleHash, recorded.backupHash == checkpoint.backupHash,
              recorded.version == checkpoint.version, recorded.build == checkpoint.build else { throw UpdateFiles.error("The retained app checkpoint no longer matches its receipt.") }
        let app = directory.appendingPathComponent(UpdateFiles.bundleName)
        let info = try UpdateFiles.verifyBundle(app, runner: runner)
        guard info.version == checkpoint.version, info.build == checkpoint.build, try UpdateFiles.fingerprint(app) == checkpoint.bundleHash,
              UpdateFiles.hash(try UpdateFiles.read(directory.appendingPathComponent("writer-backup.json"), maximum: 256 * 1024 * 1024)) == checkpoint.backupHash else { throw UpdateFiles.error("The retained app or private backup failed verification.") }
        return info
    }
    func status() throws -> [String: Any] {
        try initialize()
        let current = try UpdateFiles.bundleInfo(appURL)
        var result: [String: Any] = ["state": state.state, "message": state.message, "currentVersion": current.version, "currentBuild": current.build, "canInstall": false, "canRollback": false]
        if let failure = configurationFailure { result["state"] = "error"; result["message"] = failure; return result }
        let publicKey: Data
        do { publicKey = try key() }
        catch { result["state"] = "unsupported"; result["message"] = "Signed app updates are not configured for this build."; return result }
        if state.pendingJob != nil {
            if let refreshed = try? JSONDecoder().decode(UpdateDiskState.self, from: UpdateFiles.read(stateURL, maximum: 256 * 1024)), refreshed.pendingJob != state.pendingJob {
                state = refreshed; durableState = refreshed
                result["state"] = state.state; result["message"] = state.message
            }
            do {
                try UpdateInstaller.recoverPending(manager: self, state: &state, runner: runner)
                durableState = state
            } catch {
                result["state"] = "error"; result["message"] = error.localizedDescription
                return result
            }
            result["state"] = state.state; result["message"] = state.message
        }
        if let token = state.pendingJob {
            let job = try UpdateFiles.child(updatesRoot.appendingPathComponent("jobs"), token: token)
            if let data = try? UpdateFiles.read(job.appendingPathComponent("result.json"), maximum: 32 * 1024),
               let report = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let message = report["message"] as? String {
                // The helper's durable state is authoritative after a completed handoff.
                if let refreshed = try? JSONDecoder().decode(UpdateDiskState.self, from: UpdateFiles.read(stateURL, maximum: 256 * 1024)) { state = refreshed; durableState = refreshed }
                result["state"] = report["ok"] as? Bool == true ? "current" : "error"; result["message"] = message
            } else {
                result["state"] = "installing"; result["message"] = "An app change is awaiting completion. Draft data is preserved."
                return result
            }
        }
        if let bytes = state.available, let manifest = try? Self.manifest(bytes, key: publicKey), manifest.build > current.build, manifest.build >= state.highestSeenBuild {
            result["available"] = descriptor(manifest)
        }
        if let staged = state.prepared, let manifest = try? verifiedStage(staged, current: current, key: publicKey) {
            result["canInstall"] = true
            result["prepared"] = ["token": staged.token, "version": manifest.version, "build": manifest.build]
            result["available"] = descriptor(manifest)
        }
        if let previous = state.previous, (try? verifiedCheckpoint(previous)) != nil, previous.build != current.build {
            result["canRollback"] = true; result["rollback"] = ["token": previous.token, "version": previous.version, "build": previous.build]
        }
        return result
    }
    func handle(method: String, params: [String: Any] = [:]) throws -> [String: Any] {
        try initialize()
        if method == "getUpdateStatus" { return try status() }
        guard configurationFailure == nil, state.pendingJob == nil else { throw UpdateFiles.error("Finish or recover the pending app change before starting another update.") }
        do {
            let publicKey = try key(), current = try UpdateFiles.bundleInfo(appURL)
            switch method {
            case "checkForUpdates":
                let envelope = try loader(Self.feedURL, 64 * 1024)
                let manifest = try Self.manifest(envelope, key: publicKey)
                guard manifest.build >= state.highestSeenBuild else { throw UpdateFiles.error("The server returned an older release than one already verified on this Mac.") }
                state.highestSeenBuild = max(state.highestSeenBuild, manifest.build)
                state.available = envelope
                if manifest.build <= current.build { state.state = "current"; state.message = "No newer signed release is available." }
                else if !Self.supportsSystem(manifest) { state.state = "unsupported"; state.message = "This release requires macOS \(manifest.minimumSystemVersion) or later." }
                else { state.state = "available"; state.message = "A signed app update is available. Download it when you are ready." }
                try save()
            case "downloadUpdate":
                guard let envelope = state.available else { throw UpdateFiles.error("Check for a signed release before downloading.") }
                let manifest = try Self.manifest(envelope, key: publicKey)
                guard params["version"] as? String == manifest.version, params["build"] as? Int == manifest.build,
                      manifest.build > current.build, manifest.build >= state.highestSeenBuild, Self.supportsSystem(manifest) else { throw UpdateFiles.error("The selected update is stale or is not compatible with this Mac.") }
                let token = UUID().uuidString.lowercased(), directory = try stageDirectory(token)
                try UpdateFiles.directory(directory)
                do {
                    let archive = try loader(URL(string: manifest.archive.url)!, manifest.archive.size)
                    guard archive.count == manifest.archive.size, UpdateFiles.hash(archive) == manifest.archive.sha256 else { throw UpdateFiles.error("The downloaded app does not match its signed SHA-256 checksum.") }
                    _ = try UpdateArchive.entries(archive)
                    try UpdateFiles.write(archive, to: directory.appendingPathComponent("archive.zip"))
                    try UpdateFiles.write(envelope, to: directory.appendingPathComponent("manifest.json"))
                    let app = try UpdateArchive.extract(archive, to: directory.appendingPathComponent("extracted"))
                    _ = try UpdateFiles.verifyBundle(app, manifest: manifest, key: publicKey, runner: runner)
                    state.prepared = UpdateStage(token: token, envelope: envelope)
                    state.state = "staged"; state.message = "The signed download is verified. Install and restart when your work is saved."
                    try save()
                } catch { try? UpdateFiles.fm.removeItem(at: directory); throw error }
            default: throw UpdateFiles.error("Unknown update operation.")
            }
        } catch {
            state.state = "error"; state.message = error.localizedDescription
            try? save()
        }
        return try status()
    }
    func prepareInstall(token: String, backup: Data, parentPID: Int32) throws -> UpdateHandoff {
        try prepare(operation: "install", token: token, backup: backup, parentPID: parentPID)
    }
    func prepareRollback(token: String, backup: Data, parentPID: Int32) throws -> UpdateHandoff {
        try prepare(operation: "rollback", token: token, backup: backup, parentPID: parentPID)
    }
    private func prepare(operation: String, token: String, backup: Data, parentPID: Int32) throws -> UpdateHandoff {
        try initialize()
        guard configurationFailure == nil, state.pendingJob == nil, parentPID > 1,
              backup.count <= 256 * 1024 * 1024, let backupObject = try JSONSerialization.jsonObject(with: backup) as? [String: Any],
              backupObject["format"] as? String == "nightingale-writer-backup", backupObject["formatVersion"] as? Int == 1 else { throw UpdateFiles.error("A complete private backup and a fresh update review are required before changing the app.") }
        let publicKey = try key()
        let current = try UpdateFiles.verifyBundle(appURL, runner: runner)
        let helper = appURL.appendingPathComponent("Contents/Helpers/NightingaleUpdateHelper")
        guard (try helper.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])).isRegularFile == true,
              (try helper.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true, UpdateFiles.fm.isExecutableFile(atPath: helper.path) else { throw UpdateFiles.error("This installed app does not contain a verified update helper. Install the updater-enabled release first.") }
        let expectedVersion: String, expectedBuild: Int
        var stage: UpdateStage?, rollback: UpdateCheckpoint?
        if operation == "install" {
            guard let value = state.prepared, value.token == token else { throw UpdateFiles.error("Download and review this update again before installing.") }
            let manifest = try verifiedStage(value, current: current, key: publicKey)
            expectedVersion = manifest.version; expectedBuild = manifest.build; stage = value
        } else {
            guard let value = state.previous, value.token == token else { throw UpdateFiles.error("The reviewed rollback is no longer available.") }
            let info = try verifiedCheckpoint(value)
            guard info.build != current.build else { throw UpdateFiles.error("The retained app is already installed.") }
            expectedVersion = info.version; expectedBuild = info.build; rollback = value
        }
        guard !UpdateFiles.fm.fileExists(atPath: updatesRoot.appendingPathComponent("install.lock").path) else { throw UpdateFiles.error("Another app installer is still running.") }
        let checkpointToken = UUID().uuidString.lowercased(), checkpointDirectory = try self.checkpointDirectory(checkpointToken)
        try UpdateFiles.directory(checkpointDirectory)
        let originalHash = try UpdateFiles.fingerprint(appURL)
        let previousCopy = checkpointDirectory.appendingPathComponent(UpdateFiles.bundleName)
        try UpdateFiles.fm.copyItem(at: appURL, to: previousCopy)
        _ = try UpdateFiles.verifyBundle(previousCopy, runner: runner)
        guard try UpdateFiles.fingerprint(previousCopy) == originalHash else { throw UpdateFiles.error("The installed app changed while its rollback copy was being prepared.") }
        try UpdateFiles.write(backup, to: checkpointDirectory.appendingPathComponent("writer-backup.json"))
        let rawState = dataRoot.appendingPathComponent("state.json")
        if UpdateFiles.fm.fileExists(atPath: rawState.path) {
            try UpdateFiles.write(UpdateFiles.read(rawState, maximum: 256 * 1024 * 1024), to: checkpointDirectory.appendingPathComponent("state-before-update.json"))
        }
        let checkpoint = UpdateCheckpoint(token: checkpointToken, version: current.version, build: current.build, bundleHash: originalHash, backupHash: UpdateFiles.hash(backup))
        try UpdateFiles.writeJSON(checkpoint, to: checkpointDirectory.appendingPathComponent("receipt.json"))
        let jobToken = UUID().uuidString.lowercased(), job = try UpdateFiles.child(updatesRoot.appendingPathComponent("jobs"), token: jobToken)
        try UpdateFiles.directory(job)
        let plan = UpdateInstallPlan(schemaVersion: 1, token: jobToken, operation: operation, parentPID: parentPID,
            targetAppPath: appURL.path, dataRootPath: dataRoot.path, currentBundleHash: originalHash, expectedVersion: expectedVersion, expectedBuild: expectedBuild,
            stage: stage, rollback: rollback, checkpoint: checkpoint)
        let planURL = job.appendingPathComponent("plan.json")
        try UpdateFiles.writeJSON(plan, to: planURL)
        state.pendingJob = jobToken; state.state = "installing"; state.message = "The app will restart after the verified bundle is installed. Draft data stays in place."
        try save()
        return UpdateHandoff(helperURL: helper, planURL: planURL, status: ["state": "installing", "message": state.message, "restarting": true])
    }
    func waitForHelperReady(_ handoff: UpdateHandoff, helperPID: Int32, timeout: TimeInterval = 15) throws {
        try initialize()
        let token = handoff.planURL.deletingLastPathComponent().lastPathComponent
        guard state.pendingJob == token, helperPID > 1 else { throw UpdateFiles.error("The update handoff is no longer active.") }
        let job = try UpdateFiles.child(updatesRoot.appendingPathComponent("jobs"), token: token)
        guard UpdateFiles.canonical(handoff.planURL) == UpdateFiles.canonical(job.appendingPathComponent("plan.json")) else { throw UpdateFiles.error("Invalid update handoff location.") }
        let deadline = Date().addingTimeInterval(max(0.1, min(timeout, 30)))
        while Date() < deadline {
            if let bytes = try? UpdateFiles.read(job.appendingPathComponent("ready.json"), maximum: 8192),
               let ready = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
               ready["token"] as? String == token, ready["pid"] as? Int32 == helperPID,
               UpdateInstaller.processExists(helperPID) { return }
            guard UpdateInstaller.processExists(helperPID) else { throw UpdateFiles.error("The update helper exited before it was ready. The app remains open.") }
            Thread.sleep(forTimeInterval: 0.05)
        }
        throw UpdateFiles.error("The update helper did not become ready in time. Stop it and retry after reviewing the diagnostics; the app remains open.")
    }
    func cancelHandoff(_ handoff: UpdateHandoff, helperPID: Int32? = nil) throws {
        try initialize()
        let token = handoff.planURL.deletingLastPathComponent().lastPathComponent
        let lock = updatesRoot.appendingPathComponent("install.lock", isDirectory: true)
        if let helperPID { try UpdateInstaller.clearStoppedLock(lock, token: token, helperPID: helperPID) }
        guard state.pendingJob == token, !UpdateFiles.fm.fileExists(atPath: lock.path) else { return }
        state.pendingJob = nil; state.state = state.prepared == nil ? "idle" : "staged"
        state.message = "The installer could not start. The installed app and draft data are unchanged."
        try save()
    }
}
