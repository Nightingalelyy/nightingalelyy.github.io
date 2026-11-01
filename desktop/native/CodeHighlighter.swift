import Foundation
import Darwin

struct CodeHighlighterError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Run on the dedicated highlighting worker, independently of the Git/storage queue.
final class CodeHighlighter {
    static let version = "3.30.0"
    private let resources: URL
    private let maxBlockBytes = 256 * 1024
    private let maxTotalBytes = 512 * 1024
    private let maxOutputBytes = 8 * 1024 * 1024

    init(resources: URL) { self.resources = resources }

    func highlight(_ params: [String: Any]) throws -> [String: Any] {
        guard let blocks = params["blocks"] as? [[String: Any]], blocks.count <= 64 else {
            throw failure("Highlight at most 64 code blocks at once.")
        }
        var normalized: [[String: String]] = []
        var totalBytes = 0
        for block in blocks {
            guard let code = block["code"] as? String else { throw failure("Code blocks must contain text.") }
            let suppliedLanguage = block["language"] ?? block["lang"] ?? ""
            guard let language = suppliedLanguage as? String, language.utf8.count <= 128 else {
                throw failure("The code language is invalid.")
            }
            let bytes = code.utf8.count
            guard bytes <= maxBlockBytes else { throw failure("A code block is too large to highlight. The limit is 256 KiB.") }
            totalBytes += bytes
            guard totalBytes <= maxTotalBytes else { throw failure("The code batch is too large to highlight. The limit is 512 KiB.") }
            normalized.append(["code": code, "language": language])
        }
        if normalized.isEmpty { return ["blocks": [], "version": Self.version] }
        let helper = resources.appendingPathComponent("preview/highlight.rb")
        let library = resources.appendingPathComponent("vendor/rouge/lib/rouge.rb")
        guard FileManager.default.fileExists(atPath: helper.path), FileManager.default.fileExists(atPath: library.path) else {
            throw failure("The bundled code highlighter is missing. Code can still be shown without colors.")
        }
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/ruby") else {
            throw failure("This Mac's Ruby runtime is unavailable. Code can still be shown without colors.")
        }
        let input = try JSONSerialization.data(withJSONObject: ["blocks": normalized])
        guard input.count <= 4 * 1024 * 1024 else { throw failure("The highlighting request is too large.") }
        // Unlinked regular files bound I/O without pipe-buffer deadlocks on large batches.
        let stdin = try temporaryFile(), stdout = try temporaryFile(), stderr = try temporaryFile()
        defer { try? stdin.close(); try? stdout.close(); try? stderr.close() }
        try stdin.write(contentsOf: input); try stdin.seek(toOffset: 0)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ruby")
        process.arguments = ["--disable-gems", "-EUTF-8:UTF-8", helper.path]
        // Do not inherit RUBYOPT, RUBYLIB, Bundler, or credential environment variables.
        process.environment = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8"]
        process.standardInput = stdin; process.standardOutput = stdout; process.standardError = stderr
        let completed = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in completed.signal() }
        try process.run()
        if completed.wait(timeout: .now() + 8) == .timedOut {
            process.terminate()
            if completed.wait(timeout: .now() + 0.5) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = completed.wait(timeout: .now() + 0.5)
            }
            throw failure("Code highlighting timed out. Code can still be shown without colors.")
        }
        guard process.terminationStatus == 0 else {
            throw failure("Code highlighting is unavailable for this content. Code can still be shown without colors.")
        }
        let outputSize = try stdout.seekToEnd()
        guard outputSize <= UInt64(maxOutputBytes) else { throw failure("Highlighted code exceeded the output limit.") }
        try stdout.seek(toOffset: 0)
        let output = try stdout.readToEnd() ?? Data()
        guard let result = try JSONSerialization.jsonObject(with: output) as? [String: Any],
              result["version"] as? String == Self.version,
              let rendered = result["blocks"] as? [[String: Any]], rendered.count == blocks.count else {
            throw failure("The code highlighter returned an invalid response.")
        }
        for block in rendered {
            guard block["html"] is String, block["language"] is String, block["highlighted"] is Bool else {
                throw failure("The code highlighter returned an invalid block.")
            }
        }
        return result
    }

    private func failure(_ message: String) -> CodeHighlighterError { CodeHighlighterError(message: message) }

    private func temporaryFile() throws -> FileHandle {
        var template = Array((NSTemporaryDirectory() + "nightingale-highlight-XXXXXX").utf8CString)
        let descriptor = mkstemp(&template)
        guard descriptor >= 0 else { throw failure("Could not prepare temporary highlighting storage.") }
        unlink(template)
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }
}
