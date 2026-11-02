import Foundation
import Darwin

@main struct VerifyReleaseArchive {
    static func main() {
        do {
            guard CommandLine.arguments.count == 3 else { throw UpdateFiles.error("Pass the built app and its ZIP archive.") }
            let app = UpdateFiles.canonical(URL(fileURLWithPath: CommandLine.arguments[1]))
            let archiveURL = URL(fileURLWithPath: CommandLine.arguments[2])
            let key = try UpdateFiles.read(app.appendingPathComponent("Contents/Resources/update-public-key.bin"), maximum: 32)
            let info = try UpdateFiles.verifyBundle(app, key: key)
            let archive = try UpdateFiles.read(archiveURL, maximum: UpdateFiles.archiveLimit)
            let entries = try UpdateArchive.entries(archive)
            let temporary = UpdateFiles.canonical(FileManager.default.temporaryDirectory).appendingPathComponent("writer-archive-verification-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: temporary) }
            let extracted = try UpdateArchive.extract(archive, to: temporary)
            _ = try UpdateFiles.verifyBundle(extracted, key: key)
            guard try UpdateFiles.fingerprint(app) == UpdateFiles.fingerprint(extracted) else { throw UpdateFiles.error("The release ZIP differs from the verified app bundle.") }
            print("Release archive verified: \(info.version), \(entries.count) entries, exact bundle fingerprint and signature.")
        } catch {
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }
}
