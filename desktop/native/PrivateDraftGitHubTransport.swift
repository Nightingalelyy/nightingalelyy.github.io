import Foundation
import CryptoKit
import Darwin

struct PrivateDraftRemoteSnapshot {
    let revision: String?
    let data: Data?
}

protocol PrivateDraftTransport {
    func verify(repository: String) throws
    func read(repository: String) throws -> PrivateDraftRemoteSnapshot
    func write(repository: String, data: Data, expectedRevision: String?) throws -> String
    func write(repository: String, data: Data, expectedRevision: String?, beforeUpload: (() throws -> Void)?) throws -> String
}

extension PrivateDraftTransport {
    func write(repository: String, data: Data, expectedRevision: String?, beforeUpload: (() throws -> Void)?) throws -> String {
        try beforeUpload?()
        return try write(repository: repository, data: data, expectedRevision: expectedRevision)
    }
}

struct PrivateDraftCommandResult {
    let status: Int32
    let output: Data
    let error: Data
    var text: String { String(data: output, encoding: .utf8) ?? "" }
}

typealias PrivateDraftCommandRunner = (_ executable: String, _ arguments: [String], _ input: Data?, _ network: Bool) throws -> PrivateDraftCommandResult

struct PrivateDraftTransportError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Uses a separate bare cache and branch. No checkout, hook, template, or content
/// from the private repository is executed. Credentials remain with GitHub CLI.
final class PrivateDraftGitHubTransport: PrivateDraftTransport {
    static let owner = "Nightingalelyy"
    static let branch = "refs/heads/private-drafts"
    static let maxBytes = 64 * 1024 * 1024
    private let root: URL
    private let runner: PrivateDraftCommandRunner
    private let gh: String
    private let fm = FileManager.default

    init(root: URL, runner: PrivateDraftCommandRunner? = nil) {
        self.root = root
        gh = ["/opt/homebrew/bin/gh", "/usr/local/bin/gh"].first { FileManager.default.isExecutableFile(atPath: $0) } ?? "/opt/homebrew/bin/gh"
        self.runner = runner ?? Self.run
    }

    private func fail(_ message: String) -> PrivateDraftTransportError { PrivateDraftTransportError(message: message) }

    static func canonicalRepository(_ supplied: String) throws -> String {
        let value = supplied.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, String(parts[0]).lowercased() == owner.lowercased(),
              String(parts[1]).range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$", options: .regularExpression) != nil,
              ![".", "..", "nightingalelyy.github.io"].contains(String(parts[1]).lowercased()),
              !parts[1].hasSuffix(".git") else {
            throw PrivateDraftTransportError(message: "Enter a separate private repository as Nightingalelyy/repository-name. The public website repository cannot store private drafts.")
        }
        return owner + "/" + parts[1]
    }

    private func api(_ endpoint: String) throws -> Any {
        let result = try runner(gh, ["api", "--hostname", "github.com", "--method", "GET", endpoint], nil, true)
        guard result.status == 0, result.output.count <= 2 * 1024 * 1024,
              let json = try? JSONSerialization.jsonObject(with: result.output) else {
            throw fail("Cannot verify private repository access. Check your connection and GitHub CLI sign-in (gh auth login), then try again. No drafts were uploaded.")
        }
        return json
    }

    func verify(repository supplied: String) throws {
        let repository = try Self.canonicalRepository(supplied)
        guard let account = try api("user") as? [String: Any],
              (account["login"] as? String)?.lowercased() == Self.owner.lowercased() else {
            throw fail("Sign in to GitHub CLI as Nightingalelyy before syncing private drafts.")
        }
        guard let metadata = try api("repos/" + repository) as? [String: Any],
              (metadata["full_name"] as? String)?.lowercased() == repository.lowercased(),
              metadata["private"] as? Bool == true, metadata["visibility"] as? String == "private",
              metadata["fork"] as? Bool == false, metadata["archived"] as? Bool == false,
              metadata["disabled"] as? Bool == false, metadata["has_pages"] as? Bool == false,
              let owner = metadata["owner"] as? [String: Any], owner["type"] as? String == "User",
              (owner["login"] as? String)?.lowercased() == Self.owner.lowercased(),
              let permissions = metadata["permissions"] as? [String: Any],
              permissions["admin"] as? Bool == true, permissions["push"] as? Bool == true else {
            throw fail("Draft sync requires your own private, writable repository with no website hosting. Public, shared organization, forked, and archived repositories are not supported.")
        }
        // Two entries are sufficient: any account besides the owner is rejected.
        guard let collaborators = try api("repos/" + repository + "/collaborators?affiliation=all&per_page=2") as? [[String: Any]],
              collaborators.count <= 1,
              collaborators.allSatisfy({ ($0["login"] as? String)?.lowercased() == Self.owner.lowercased() }),
              let invitations = try api("repos/" + repository + "/invitations?per_page=1") as? [Any], invitations.isEmpty else {
            throw fail("This draft repository has collaborators or pending invitations. Use an owner-only private repository.")
        }
    }

    private func cache(_ repository: String) throws -> URL {
        let name = SHA256.hash(data: Data(repository.lowercased().utf8)).map { String(format: "%02x", $0) }.joined()
        let directory = root.appendingPathComponent(name + ".git", isDirectory: true)
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let rootInfo = try root.resourceValues(forKeys: [.isSymbolicLinkKey])
        guard rootInfo.isSymbolicLink != true else { throw fail("Private draft cache cannot be a symbolic link.") }
        if fm.fileExists(atPath: directory.path) {
            let values = try directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { throw fail("Private draft cache is not a safe directory.") }
        } else {
            _ = try git(["init", "--bare", "--template=", directory.path])
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }
        return directory
    }

    private func git(_ arguments: [String], at directory: URL? = nil, input: Data? = nil, network: Bool = false, allowFailure: Bool = false) throws -> PrivateDraftCommandResult {
        var args = ["-c", "core.hooksPath=/dev/null", "-c", "credential.interactive=never", "-c", "credential.helper=", "-c", "credential.helper=!\(gh) auth git-credential", "-c", "http.followRedirects=false", "-c", "protocol.allow=never", "-c", "protocol.https.allow=always"]
        if let directory { args += ["-C", directory.path] }
        let result = try runner("/usr/bin/git", args + arguments, input, network)
        guard allowFailure || result.status == 0 else {
            throw fail(network ? "Private draft sync could not complete. Check the connection and repository access, then sync again. Your local writing is safe." : "The private draft cache could not be read or updated. Your local writing is safe.")
        }
        return result
    }

    private func remote(_ repository: String) -> String { "https://github.com/" + repository + ".git" }
    private func validRevision(_ value: String) -> Bool { value.range(of: "^[a-f0-9]{40}$", options: .regularExpression) != nil }

    private func remoteHead(_ repository: String, at directory: URL) throws -> String? {
        let result = try git(["ls-remote", "--refs", remote(repository), Self.branch], at: directory, network: true)
        let lines = result.text.split(separator: "\n")
        if lines.isEmpty { return nil }
        guard lines.count == 1 else { throw fail("The private draft branch returned an unexpected response.") }
        let fields = lines[0].split(separator: "\t")
        guard fields.count == 2, fields[1] == Substring(Self.branch), validRevision(String(fields[0])) else { throw fail("The private draft branch is invalid.") }
        return String(fields[0])
    }

    func read(repository supplied: String) throws -> PrivateDraftRemoteSnapshot {
        let repository = try Self.canonicalRepository(supplied)
        try verify(repository: repository)
        let directory = try cache(repository)
        guard let head = try remoteHead(repository, at: directory) else { return PrivateDraftRemoteSnapshot(revision: nil, data: nil) }
        _ = try git(["fetch", "--no-tags", "--no-recurse-submodules", remote(repository), head], at: directory, network: true)
        let tree = try git(["ls-tree", head], at: directory).text
        guard tree.split(separator: "\n").count == 1, tree.hasPrefix("100644 blob "), tree.hasSuffix("\tdrafts.json\n") else { throw fail("This branch does not contain a supported private draft snapshot, or has unrelated files. It was left unchanged.") }
        let sizeText = try git(["cat-file", "-s", head + ":drafts.json"], at: directory).text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let size = Int(sizeText), size > 0, size <= Self.maxBytes else { throw fail("Private drafts exceed the 64 MB sync limit. Your local writing is safe.") }
        let data = try git(["cat-file", "blob", head + ":drafts.json"], at: directory).output
        guard data.count == size else { throw fail("Private drafts could not be downloaded completely. Please sync again.") }
        return PrivateDraftRemoteSnapshot(revision: head, data: data)
    }

    func write(repository supplied: String, data: Data, expectedRevision: String?) throws -> String {
        try write(repository: supplied, data: data, expectedRevision: expectedRevision, beforeUpload: nil)
    }

    func write(repository supplied: String, data: Data, expectedRevision: String?, beforeUpload: (() throws -> Void)?) throws -> String {
        let repository = try Self.canonicalRepository(supplied)
        guard !data.isEmpty, data.count <= Self.maxBytes, expectedRevision == nil || validRevision(expectedRevision!) else { throw fail("The private draft snapshot or revision is invalid.") }
        try verify(repository: repository)
        let directory = try cache(repository)
        guard try remoteHead(repository, at: directory) == expectedRevision else { throw fail("Another device changed the private drafts. Sync again to compare both versions; nothing was overwritten.") }
        if let expectedRevision {
            _ = try git(["fetch", "--no-tags", "--no-recurse-submodules", remote(repository), expectedRevision], at: directory, network: true)
            let entries = try git(["ls-tree", expectedRevision], at: directory).text
            guard entries.split(separator: "\n").count == 1, entries.hasPrefix("100644 blob "), entries.hasSuffix("\tdrafts.json\n") else { throw fail("The private draft branch has unrelated files. It was left unchanged.") }
        }
        let blob = try git(["hash-object", "-w", "--stdin"], at: directory, input: data).text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard validRevision(blob) else { throw fail("The private draft snapshot could not be stored.") }
        let tree = try git(["mktree"], at: directory, input: Data("100644 blob \(blob)\tdrafts.json\n".utf8)).text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard validRevision(tree) else { throw fail("The private draft tree could not be stored.") }
        var args = ["-c", "user.name=Nightingale Writer", "-c", "user.email=nightingale-writer@users.noreply.github.com", "commit-tree", tree]
        if let expectedRevision { args += ["-p", expectedRevision] }
        let commit = try git(args, at: directory, input: Data("Sync private drafts\n".utf8)).text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard validRevision(commit) else { throw fail("The private draft snapshot could not be committed.") }
        // Exact expected-ref lease rejects edits AND branch deletion/creation
        // races. The commit's sole parent is always expectedRevision, so this
        // cannot replace existing history with a non-fast-forward commit.
        let lease = "--force-with-lease=" + Self.branch + ":" + (expectedRevision ?? "")
        try verify(repository: repository)
        try beforeUpload?()
        _ = try git(["push", "--porcelain", lease, remote(repository), commit + ":" + Self.branch], at: directory, network: true)
        return commit
    }

    private static func run(_ executable: String, _ arguments: [String], _ input: Data?, _ network: Bool) throws -> PrivateDraftCommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("GIT_") && $0.key != "GH_DEBUG" }
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        env["GIT_CONFIG_GLOBAL"] = "/dev/null"; env["GIT_CONFIG_SYSTEM"] = "/dev/null"
        env["GIT_TERMINAL_PROMPT"] = "0"; env["GH_PROMPT_DISABLED"] = "1"; env["GH_HOST"] = "github.com"
        process.environment = env
        func file() throws -> FileHandle {
            var template = Array((NSTemporaryDirectory() + "nightingale-private-sync-XXXXXX").utf8CString)
            let fd = mkstemp(&template)
            guard fd >= 0 else { throw PrivateDraftTransportError(message: "Cannot create private sync temporary storage.") }
            _ = fchmod(fd, 0o600); _ = unlink(template)
            return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        }
        let stdout = try file(), stderr = try file(), stdin = try file()
        defer { try? stdout.close(); try? stderr.close(); try? stdin.close() }
        if let input { try stdin.write(contentsOf: input); try stdin.seek(toOffset: 0) }
        process.standardInput = stdin; process.standardOutput = stdout; process.standardError = stderr
        let done = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in done.signal() }
        do { try process.run() } catch { throw PrivateDraftTransportError(message: "GitHub CLI is required for private sync. Install it from cli.github.com and sign in as Nightingalelyy.") }
        if done.wait(timeout: .now() + (network ? 40 : 20)) == .timedOut {
            process.terminate()
            if done.wait(timeout: .now() + 2) == .timedOut { kill(process.processIdentifier, SIGKILL); _ = done.wait(timeout: .now() + 2) }
            throw PrivateDraftTransportError(message: "Private draft sync timed out. Your local writing is safe; try again when connected.")
        }
        try stdout.seek(toOffset: 0); try stderr.seek(toOffset: 0)
        let data = try stdout.read(upToCount: maxBytes + 1) ?? Data()
        guard data.count <= maxBytes else { throw PrivateDraftTransportError(message: "Private draft response exceeds the 64 MB limit.") }
        // Never expose arbitrary CLI output: it may contain remote content or credentials.
        return PrivateDraftCommandResult(status: process.terminationStatus, output: data, error: Data())
    }
}
