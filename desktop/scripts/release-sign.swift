import Foundation
import CryptoKit
import Darwin

@main struct ReleaseSigningTool {
    static func main() throws {
        let args = CommandLine.arguments
        guard args.count >= 2 else { throw error("Use keygen <private-key> <public-key>, or sign <private-key> <payload.json> <envelope.json>.") }
        if args[1] == "keygen", args.count == 4 {
            let privateURL = URL(fileURLWithPath: args[2]), publicURL = URL(fileURLWithPath: args[3])
            let directory = privateURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let key: Curve25519.Signing.PrivateKey
            if FileManager.default.fileExists(atPath: privateURL.path) {
                key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(contentsOf: privateURL))
            } else {
                key = Curve25519.Signing.PrivateKey()
                guard FileManager.default.createFile(atPath: privateURL.path, contents: key.rawRepresentation, attributes: [.posixPermissions: 0o600]) else { throw error("Could not save the private release key.") }
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: privateURL.path)
            try key.publicKey.rawRepresentation.write(to: publicURL, options: .atomic)
            print("Release verification key saved. Private key bytes were not printed.")
        } else if args[1] == "sign", args.count == 5 {
            let key = try Curve25519.Signing.PrivateKey(rawRepresentation: Data(contentsOf: URL(fileURLWithPath: args[2])))
            let payload = try Data(contentsOf: URL(fileURLWithPath: args[3]))
            guard payload.count <= 64 * 1024 else { throw error("Release manifest is too large.") }
            let envelope = ["payload": payload.base64EncodedString(), "signature": try key.signature(for: payload).base64EncodedString()]
            try JSONSerialization.data(withJSONObject: envelope, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: args[4]), options: .atomic)
            print("Signed release manifest.")
        } else { throw error("Invalid release-sign arguments.") }
    }
    static func error(_ message: String) -> NSError { NSError(domain: "NightingaleRelease", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}
