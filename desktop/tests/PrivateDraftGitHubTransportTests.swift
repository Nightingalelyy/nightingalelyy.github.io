import Foundation

private struct TransportTestFailure: Error, CustomStringConvertible { let description: String }
private struct Invocation {
    let executable: String
    let arguments: [String]
    let input: Data?
    let network: Bool
    let command: String
}

private final class FakePrivateGitHub {
    static let repository = "Nightingalelyy/private-draft-tests"
    static let old = String(repeating: "a", count: 40)
    static let blob = String(repeating: "b", count: 40)
    static let tree = String(repeating: "c", count: 40)
    static let commit = String(repeating: "d", count: 40)
    static let competing = String(repeating: "e", count: 40)
    let root: URL
    var calls: [Invocation] = []
    var account: [String: Any] = ["login": "Nightingalelyy"]
    var metadata: [String: Any] = [
        "full_name": repository, "private": true, "visibility": "private", "fork": false,
        "archived": false, "disabled": false, "has_pages": false,
        "owner": ["login": "Nightingalelyy", "type": "User"], "permissions": ["admin": true, "push": true]
    ]
    var collaborators: [[String: Any]] = [["login": "Nightingalelyy"]]
    var invitations: [[String: Any]] = []
    var remoteHead: String? = old
    var rawHead: String?
    var content = Data("{\"version\":1,\"drafts\":{}}".utf8)
    var declaredSize: String?
    var treeListing: String?
    var apiFailure: String?
    var apiOversize: String?
    var apiInvalidJSON: String?
    var failureCommand: String?
    var blobResult = blob
    var treeResult = tree
    var commitResult = commit
    var afterCommit: (() -> Void)?

    init(root: URL) { self.root = root }
    var gitCalls: [Invocation] { calls.filter { $0.executable == "/usr/bin/git" } }
    var pushes: [Invocation] { gitCalls.filter { $0.command == "push" } }
    func result(_ text: String = "", status: Int32 = 0) -> PrivateDraftCommandResult {
        PrivateDraftCommandResult(status: status, output: Data(text.utf8), error: status == 0 ? Data() : Data("SECRET-TOKEN and PRIVATE-DRAFT-TEXT".utf8))
    }
    func json(_ value: Any) throws -> PrivateDraftCommandResult {
        PrivateDraftCommandResult(status: 0, output: try JSONSerialization.data(withJSONObject: value), error: Data())
    }

    lazy var run: PrivateDraftCommandRunner = { [unowned self] executable, arguments, input, network in
        let commands = ["init", "ls-remote", "fetch", "ls-tree", "cat-file", "hash-object", "mktree", "commit-tree", "push"]
        let command = executable == "/usr/bin/git" ? arguments.first(where: commands.contains) ?? "unknown" : "api"
        self.calls.append(Invocation(executable: executable, arguments: arguments, input: input, network: network, command: command))
        if command == "api" {
            guard arguments.first == "api", let endpoint = arguments.last else { throw TransportTestFailure(description: "Unexpected API invocation") }
            if endpoint == self.apiFailure { return self.result("SECRET-TOKEN PRIVATE-DRAFT-TEXT", status: 403) }
            if endpoint == self.apiOversize { return self.result(String(repeating: "x", count: 2 * 1024 * 1024 + 1)) }
            if endpoint == self.apiInvalidJSON { return self.result("not-json PRIVATE-DRAFT-TEXT") }
            if endpoint == "user" { return try self.json(self.account) }
            if endpoint == "repos/" + Self.repository { return try self.json(self.metadata) }
            if endpoint.hasSuffix("/collaborators?affiliation=all&per_page=2") { return try self.json(self.collaborators) }
            if endpoint.hasSuffix("/invitations?per_page=1") { return try self.json(self.invitations) }
            throw TransportTestFailure(description: "Unexpected fixed API endpoint")
        }
        if command == self.failureCommand { return self.result("PRIVATE-DRAFT-TEXT SECRET-TOKEN", status: 128) }
        switch command {
        case "init":
            guard let destination = arguments.last, destination.hasPrefix(self.root.path + "/") else { throw TransportTestFailure(description: "Cache escaped temporary root") }
            try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)
            return self.result()
        case "ls-remote":
            return self.result(self.rawHead ?? self.remoteHead.map { $0 + "\t" + PrivateDraftGitHubTransport.branch + "\n" } ?? "")
        case "fetch": return self.result()
        case "ls-tree": return self.result(self.treeListing ?? "100644 blob \(Self.blob)\tdrafts.json\n")
        case "cat-file":
            if arguments.contains("-s") { return self.result(self.declaredSize ?? String(self.content.count)) }
            return PrivateDraftCommandResult(status: 0, output: self.content, error: Data())
        case "hash-object": return self.result(self.blobResult + "\n")
        case "mktree": return self.result(self.treeResult + "\n")
        case "commit-tree":
            self.afterCommit?()
            return self.result(self.commitResult + "\n")
        case "push":
            let prefix = "--force-with-lease=" + PrivateDraftGitHubTransport.branch + ":"
            guard let lease = arguments.first(where: { $0.hasPrefix(prefix) }) else { return self.result("No atomic expected-ref lease", status: 1) }
            let expected = String(lease.dropFirst(prefix.count))
            guard expected == (self.remoteHead ?? "") else { return self.result("stale info SECRET-TOKEN", status: 1) }
            self.remoteHead = self.commitResult
            return self.result()
        default: throw TransportTestFailure(description: "Unexpected Git command")
        }
    }
}

@main struct PrivateDraftGitHubTransportTests {
    static var assertions = 0
    static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        assertions += 1
        if try !condition() { throw TransportTestFailure(description: message) }
    }
    @discardableResult static func rejects(_ message: String, _ action: () throws -> Void) throws -> String {
        do { try action() } catch {
            if error is TransportTestFailure { throw error }
            let explanation = error.localizedDescription
            try expect(!explanation.contains("SECRET-TOKEN") && !explanation.contains("PRIVATE-DRAFT-TEXT"), "Errors must not reveal command output")
            assertions += 1
            return explanation
        }
        throw TransportTestFailure(description: message)
    }

    static func main() throws {
        let fm = FileManager.default
        let directory = fm.temporaryDirectory.appendingPathComponent("nightingale-private-transport-tests-" + UUID().uuidString)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: directory) }
        var number = 0
        func fixture() -> (FakePrivateGitHub, PrivateDraftGitHubTransport) {
            number += 1
            let fake = FakePrivateGitHub(root: directory.appendingPathComponent("case-\(number)"))
            return (fake, PrivateDraftGitHubTransport(root: fake.root, runner: fake.run))
        }
        let repository = FakePrivateGitHub.repository

        try expect(try PrivateDraftGitHubTransport.canonicalRepository("  nightingalelyy/private-draft-tests ") == repository, "Repository normalization must preserve the fixed owner")
        for invalid in ["Nightingalelyy/nightingalelyy.github.io", "Other/private", "Nightingalelyy/../private", "Nightingalelyy/private.git", "https://github.com/Nightingalelyy/private", "Nightingalelyy/private;echo", "Nightingalelyy/$(echo)", "Nightingalelyy/private\nother", "Nightingalelyy/--force"] {
            let (fake, transport) = fixture()
            try rejects("Unsafe repository accepted") { _ = try transport.read(repository: invalid) }
            try expect(fake.calls.isEmpty, "Invalid repository must fail before any command")
        }

        do {
            let (fake, transport) = fixture()
            try transport.verify(repository: repository)
            try expect(fake.calls.count == 4 && fake.gitCalls.isEmpty, "Connect verification must not fetch, write, or publish")
            try expect(fake.calls.allSatisfy { $0.network && $0.arguments.contains("--hostname") && $0.arguments.contains("github.com") && $0.arguments.contains("GET") }, "Verification must use fixed-host read-only API calls")
            fake.collaborators = []
            try transport.verify(repository: repository)
        }
        let invalidMetadata: [(String, Any)] = [
            ("private", false), ("visibility", "public"), ("fork", true), ("archived", true), ("disabled", true), ("has_pages", true),
            ("full_name", "Nightingalelyy/other"), ("owner", ["login": "Nightingalelyy", "type": "Organization"]),
            ("owner", ["login": "Other", "type": "User"]), ("permissions", ["admin": false, "push": true]), ("permissions", ["admin": true, "push": false])
        ]
        for (key, value) in invalidMetadata {
            let (fake, transport) = fixture(); fake.metadata[key] = value
            try rejects("An unsafe repository policy was accepted") { _ = try transport.read(repository: repository) }
            try expect(fake.gitCalls.isEmpty, "Policy rejection must happen before any Git operation")
        }
        do {
            let (fake, transport) = fixture(); fake.account = ["login": "Other"]
            try rejects("Wrong GitHub account accepted") { try transport.verify(repository: repository) }
            try expect(fake.calls.count == 1, "Wrong account must stop before repository access")
        }
        for collaborators in [[["login": "Other"]], [["login": "Nightingalelyy"], ["login": "Other"]]] {
            let (fake, transport) = fixture(); fake.collaborators = collaborators
            try rejects("Shared repository accepted") { _ = try transport.read(repository: repository) }
            try expect(fake.gitCalls.isEmpty, "No private data transfer before collaborator rejection")
        }
        do {
            let (fake, transport) = fixture(); fake.invitations = [["id": 1]]
            try rejects("Pending invitation accepted") { _ = try transport.read(repository: repository) }
            try expect(fake.gitCalls.isEmpty, "Pending invitations must prevent data transfer")
        }
        for mode in ["failure", "oversize", "invalidJSON"] {
            let (fake, transport) = fixture()
            if mode == "failure" { fake.apiFailure = "user" }
            if mode == "oversize" { fake.apiOversize = "user" }
            if mode == "invalidJSON" { fake.apiInvalidJSON = "user" }
            try rejects("Invalid API response accepted") { _ = try transport.read(repository: repository) }
            try expect(fake.gitCalls.isEmpty, "Unverified API responses must prevent Git access")
        }

        do {
            let (fake, transport) = fixture(); fake.remoteHead = nil
            let snapshot = try transport.read(repository: repository)
            try expect(snapshot.revision == nil && snapshot.data == nil, "Missing private branch should return an empty snapshot")
            try expect(!fake.gitCalls.contains { ["fetch", "hash-object", "push"].contains($0.command) }, "Read must not create a remote branch")
        }
        do {
            let (fake, transport) = fixture()
            let snapshot = try transport.read(repository: repository)
            try expect(snapshot.revision == FakePrivateGitHub.old && snapshot.data == fake.content, "Read must preserve exact private bytes and revision")
            try expect(fake.pushes.isEmpty, "Read must never push")
            let fetch = fake.gitCalls.first { $0.command == "fetch" }!
            try expect(fetch.arguments.contains("--no-tags") && fetch.arguments.contains("--no-recurse-submodules") && fetch.arguments.last == FakePrivateGitHub.old, "Fetch only the reviewed object without submodules")
            let mode = try fm.attributesOfItem(atPath: fake.root.path)[.posixPermissions] as! NSNumber
            try expect(mode.intValue & 0o777 == 0o700, "Private cache root must be owner-only")
            fake.metadata["private"] = false
            let count = fake.gitCalls.count
            try rejects("Visibility changes between read and write accepted") { _ = try transport.write(repository: repository, data: fake.content, expectedRevision: snapshot.revision) }
            try expect(fake.gitCalls.count == count, "Write must reverify privacy even after a successful read")
        }
        for listing in ["", "120000 blob \(FakePrivateGitHub.blob)\tdrafts.json\n", "100755 blob \(FakePrivateGitHub.blob)\tdrafts.json\n", "100644 blob \(FakePrivateGitHub.blob)\tdrafts.json\n100644 blob \(FakePrivateGitHub.blob)\tunrelated.md\n"] {
            let (fake, transport) = fixture(); fake.treeListing = listing
            try rejects("Unexpected branch tree accepted for read") { _ = try transport.read(repository: repository) }
            try rejects("Unexpected branch tree accepted for replacement") { _ = try transport.write(repository: repository, data: fake.content, expectedRevision: FakePrivateGitHub.old) }
            try expect(fake.pushes.isEmpty && !fake.gitCalls.contains { $0.command == "hash-object" }, "Unrelated branch contents must never be overwritten")
        }
        for size in ["0", "-1", "not-a-size", String(PrivateDraftGitHubTransport.maxBytes + 1)] {
            let (fake, transport) = fixture(); fake.declaredSize = size
            try rejects("Invalid remote data size accepted") { _ = try transport.read(repository: repository) }
            try expect(!fake.gitCalls.contains { $0.command == "cat-file" && $0.arguments.contains("blob") }, "Reject oversized data before loading the blob")
        }
        do {
            let (fake, transport) = fixture(); fake.declaredSize = String(fake.content.count + 1)
            try rejects("Truncated remote data accepted") { _ = try transport.read(repository: repository) }
        }
        for head in ["wrong\trefs/heads/private-drafts\n", "\(FakePrivateGitHub.old)\trefs/heads/main\n", "\(FakePrivateGitHub.old)\trefs/heads/private-drafts\n\(FakePrivateGitHub.competing)\trefs/heads/private-drafts\n"] {
            let (fake, transport) = fixture(); fake.rawHead = head
            try rejects("Ambiguous or invalid branch response accepted") { _ = try transport.read(repository: repository) }
        }

        let privateBytes = Data("{\"body\":\"PRIVATE-DRAFT-TEXT $(echo unsafe); `echo unsafe`\"}".utf8)
        for expected in [nil, FakePrivateGitHub.old] as [String?] {
            let (fake, transport) = fixture(); fake.remoteHead = expected
            let revision = try transport.write(repository: repository, data: privateBytes, expectedRevision: expected)
            try expect(revision == FakePrivateGitHub.commit && fake.remoteHead == revision, "Successful write must return its exact revision")
            let commit = fake.gitCalls.first { $0.command == "commit-tree" }!
            if let expected {
                try expect(commit.arguments.suffix(2) == ["-p", expected], "Existing branch commit must have only its expected parent")
                try expect(fake.gitCalls.contains { $0.command == "fetch" && $0.arguments.last == expected }, "Write must fetch its parent independently")
            } else { try expect(!commit.arguments.contains("-p"), "New branch has no fabricated parent") }
            let push = fake.pushes.first!
            try expect(push.arguments.contains("--force-with-lease=" + PrivateDraftGitHubTransport.branch + ":" + (expected ?? "")), "Push must compare exact previous ref, including absence")
            try expect(push.arguments.last == FakePrivateGitHub.commit + ":" + PrivateDraftGitHubTransport.branch, "Only the private draft branch may be pushed")
            try expect(!push.arguments.contains("--force") && !push.arguments.contains("-f"), "No unrestricted force push is allowed")
            try expect(fake.gitCalls.first { $0.command == "hash-object" }?.input == privateBytes, "Authored bytes belong on stdin")
            try expect(!fake.calls.flatMap(\.arguments).contains { $0.contains("PRIVATE-DRAFT-TEXT") || $0.contains("$(echo") }, "Private source must never enter process arguments")
            try expect(fake.calls.allSatisfy { $0.executable != "/bin/sh" && $0.executable != "/bin/bash" }, "Transport must not invoke a command shell")
            try expect(fake.gitCalls.allSatisfy { $0.arguments.contains("core.hooksPath=/dev/null") && $0.arguments.contains("credential.interactive=never") && $0.arguments.contains("http.followRedirects=false") }, "Git must disable hooks, prompts and redirects")
            try expect(fake.calls.filter { $0.command == "api" && $0.arguments.last == "user" }.count == 2, "Reverify policy immediately before upload")
        }
        for expected in [nil, FakePrivateGitHub.old] as [String?] {
            let (fake, transport) = fixture(); fake.remoteHead = FakePrivateGitHub.competing
            try rejects("A stale expected revision accepted") { _ = try transport.write(repository: repository, data: privateBytes, expectedRevision: expected) }
            try expect(!fake.gitCalls.contains { $0.command == "hash-object" } && fake.pushes.isEmpty, "Detected conflicts cannot write content or push")
        }
        for race in ["created", "edited", "deleted"] {
            let (fake, transport) = fixture()
            let expected: String? = race == "created" ? nil : FakePrivateGitHub.old
            fake.remoteHead = expected
            fake.afterCommit = { fake.remoteHead = race == "deleted" ? nil : FakePrivateGitHub.competing }
            try rejects("A concurrent branch race bypassed the lease") { _ = try transport.write(repository: repository, data: privateBytes, expectedRevision: expected) }
            try expect(fake.pushes.count == 1, "A rejected push is attempted once, never automatically retried")
            try expect(fake.remoteHead != FakePrivateGitHub.commit, "Competing branch state must remain unchanged")
        }
        do {
            let (fake, transport) = fixture(); fake.afterCommit = { fake.metadata["private"] = false }
            try rejects("Visibility changed during preparation but upload proceeded") { _ = try transport.write(repository: repository, data: privateBytes, expectedRevision: FakePrivateGitHub.old) }
            try expect(fake.pushes.isEmpty, "Last privacy check must block the upload")
        }
        do {
            let (fake, transport) = fixture()
            var authorized = true
            fake.afterCommit = { authorized = false }
            try rejects("Disabling automatic sync during preparation must cancel the upload") {
                _ = try transport.write(repository: repository, data: privateBytes, expectedRevision: FakePrivateGitHub.old, beforeUpload: {
                    guard authorized else { throw PrivateDraftTransportError(message: "Automatic sync disabled") }
                })
            }
            try expect(fake.pushes.isEmpty && fake.remoteHead == FakePrivateGitHub.old, "The late authorization gate must prevent every push")
            try expect(fake.calls.filter { $0.command == "api" && $0.arguments.last == "user" }.count == 2, "The cancellation gate must run after the final privacy verification")
        }
        for failure in ["fetch", "hash-object", "mktree", "commit-tree", "push"] {
            let (fake, transport) = fixture(); fake.failureCommand = failure
            try rejects("Command failure accepted") { _ = try transport.write(repository: repository, data: privateBytes, expectedRevision: FakePrivateGitHub.old) }
            try expect(fake.pushes.count <= 1, "Transport failures must not trigger hidden retries")
        }
        for invalid in [Data(), Data(repeating: 0, count: PrivateDraftGitHubTransport.maxBytes + 1)] {
            let (fake, transport) = fixture()
            try rejects("Invalid local snapshot size accepted") { _ = try transport.write(repository: repository, data: invalid, expectedRevision: nil) }
            try expect(fake.calls.isEmpty, "Reject invalid payloads before any API or Git request")
        }
        do {
            let (fake, transport) = fixture()
            try rejects("Malformed revision accepted") { _ = try transport.write(repository: repository, data: privateBytes, expectedRevision: "main;echo") }
            try expect(fake.calls.isEmpty, "Malformed revisions cannot reach processes")
        }
        print("PrivateDraftGitHubTransport: \(assertions) assertions passed; only injected commands and temporary caches used")
    }
}
