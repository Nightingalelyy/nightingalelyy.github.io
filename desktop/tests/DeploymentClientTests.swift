import Foundation

private struct TestFailure: Error { let message: String }
@main struct DeploymentClientTests {
    static var checks = 0
    static func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        checks += 1
        if !condition() { throw TestFailure(message: message) }
    }
    static func main() throws {
        let commit = String(repeating: "a", count: 40), later = String(repeating: "b", count: 40)
        let path = "_docs/check.md", sha = String(repeating: "c", count: 64)
        let target: [String: Any] = ["targets": [["path": path, "sourceSHA256": sha, "commit": commit]], "remoteCommit": commit]
        func manifest(_ hash: String) -> [String: Any] { ["version": 1, "commit": later, "articles": [path: ["sha256": hash, "url": "/check/"]]] }
        func workflow(_ conclusion: String?, _ status: String = "completed", head: String? = nil, branch: String = "main", file: String = ".github/workflows/pages.yml") -> [String: Any] {
            var run: [String: Any] = ["id": Int64(1), "head_sha": head ?? commit, "head_branch": branch, "path": file, "status": status, "html_url": "https://github.com/Nightingalelyy/nightingalelyy.github.io/actions/runs/1"]
            if let conclusion { run["conclusion"] = conclusion }
            return ["workflow_runs": [run]]
        }
        func first(_ report: [String: Any]) -> [String: Any] { (report["results"] as! [[String: Any]])[0] }
        var calls = 0
        var date = Date(timeIntervalSince1970: 10000)
        var online = true
        let liveClient = DeploymentClient(load: { url in
            calls += 1
            if !online { throw TestFailure(message: "offline") }
            try expect(url.host == "nightingalelyy.github.io", "Matching live content needs no GitHub API request")
            return manifest(sha)
        }, clock: { date })
        let live = first(liveClient.poll(target))
        try expect(live["status"] as? String == "live", "A matching live document hash proves publication even in a newer site commit")
        try expect(live["commit"] as? String == commit, "Keep the requested upload commit for stale-result rejection")
        try expect(live["liveURL"] as? String == "https://nightingalelyy.github.io/check/", "Use the published route")
        _ = liveClient.poll(target)
        try expect(calls == 1, "Repeated UI polls use the manifest cache")
        date.addTimeInterval(31); online = false
        let offline = first(liveClient.poll(target))
        try expect(offline["checkedAt"] as? String == live["checkedAt"] as? String, "Offline polls must not pretend a fresh verification")
        try expect((offline["message"] as? String)?.contains("last checked") == true, "Cached live status must say it is stale")
        let successfulBuild = DeploymentClient(load: { url in url.host == "nightingalelyy.github.io" ? manifest("old") : workflow("success") })
        try expect(first(successfulBuild.poll(target))["status"] as? String == "building", "A successful workflow does not prove that the new article is live")
        let failedBuild = DeploymentClient(load: { url in
            if url.host == "nightingalelyy.github.io" { throw TestFailure(message: "manifest missing") }
            return workflow("failure")
        })
        let failed = first(failedBuild.poll(target))
        try expect(failed["status"] as? String == "failed", "A missing manifest must not prevent checking the build failure")
        try expect(failed["workflowURL"] != nil, "Failed publication provides a valid build link")
        try expect(DeploymentClient.workflowState(workflow(nil, "in_progress"), commit: commit)["status"] as? String == "building", "Running builds are visible")
        try expect(DeploymentClient.workflowState(workflow("failure", head: later), commit: commit)["status"] as? String == "uploaded", "Ignore other commits")
        try expect(DeploymentClient.workflowState(workflow("failure", branch: "feature"), commit: commit)["status"] as? String == "uploaded", "Ignore checks on other branches")
        try expect(DeploymentClient.workflowState(workflow("failure", file: ".github/workflows/unrelated.yml"), commit: commit)["status"] as? String == "uploaded", "Ignore unrelated workflows")
        try expect(DeploymentClient.workflowState(workflow("cancelled"), commit: commit)["status"] as? String == "uploaded", "Cancelled builds may have been superseded")
        try expect(!DeploymentClient.validCommit("../../other?token=x"), "Commit parameters cannot alter the request URL")
        print("DeploymentClient tests passed: \(checks) assertions")
    }
}
