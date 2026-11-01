import Foundation
import Darwin

/// Runs the same offline checks as the deployment workflow, with authored text as JSON data.
final class PublishingValidator {
    private let resources: URL
    init(resources: URL) { self.resources = resources }

    func validate(_ payload: [String: Any]) throws -> [String: Any] {
        let input = try JSONSerialization.data(withJSONObject: payload)
        guard input.count <= 16 * 1024 * 1024 else { throw failure("The validation request is too large.") }
        let helper = resources.appendingPathComponent("publishing/validate_request.rb")
        guard FileManager.default.fileExists(atPath: helper.path) else { throw failure("Publishing checks are missing from this app. Reinstall the app before publishing.") }
        let stdin = try temporaryFile(), stdout = try temporaryFile(), stderr = try temporaryFile()
        defer { try? stdin.close(); try? stdout.close(); try? stderr.close() }
        try stdin.write(contentsOf: input); try stdin.seek(toOffset: 0)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ruby")
        process.arguments = ["--disable-gems", "-EUTF-8:UTF-8", helper.path]
        process.environment = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8"]
        process.standardInput = stdin; process.standardOutput = stdout; process.standardError = stderr
        let completed = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in completed.signal() }
        try process.run()
        if completed.wait(timeout: .now() + 20) == .timedOut {
            process.terminate()
            if completed.wait(timeout: .now() + 1) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = completed.wait(timeout: .now() + 1)
            }
            throw failure("Publishing checks timed out. Your draft is saved; retry before publishing.")
        }
        guard process.terminationStatus == 0 else { throw failure("Publishing checks could not finish. Your draft is saved; retry before publishing.") }
        guard try stdout.seekToEnd() <= 4 * 1024 * 1024 else { throw failure("Publishing checks returned too much data.") }
        try stdout.seek(toOffset: 0)
        guard let data = try stdout.readToEnd(),
              let result = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              result["schemaVersion"] as? Int == 1, result["ok"] is Bool,
              result["issues"] is [[String: Any]] else { throw failure("Publishing checks returned an invalid result.") }
        return result
    }

    private func failure(_ message: String) -> NSError { NSError(domain: "WriterValidation", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    private func temporaryFile() throws -> FileHandle {
        var template = Array((NSTemporaryDirectory() + "nightingale-validation-XXXXXX").utf8CString)
        let descriptor = mkstemp(&template)
        guard descriptor >= 0 else { throw failure("Could not prepare publishing checks.") }
        unlink(template)
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }
}
