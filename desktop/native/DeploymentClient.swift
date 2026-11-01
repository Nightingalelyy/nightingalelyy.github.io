import Foundation

/// Public, read-only status checks; never reads credentials or sends draft content.
/// Call from one background queue. A successful workflow alone is not proof of a live article.
final class DeploymentClient {
    typealias Loader = (URL) throws -> [String: Any]
    private let load: Loader
    private let clock: () -> Date
    private var manifest: [String: Any]?
    private var manifestCheckedAt = Date.distantPast
    private var runs: [String: (Date, [String: Any])] = [:]
    private var manifestRetryAfter = Date.distantPast
    private var apiRetryAfter = Date.distantPast
    private var manifestReachable = false

    init(load: Loader? = nil, clock: @escaping () -> Date = Date.init) {
        self.load = load ?? Self.download
        self.clock = clock
    }

    func poll(_ snapshot: [String: Any]) -> [String: Any] {
        let targets = snapshot["targets"] as? [[String: Any]] ?? []
        let now = clock()
        if now >= manifestRetryAfter && now.timeIntervalSince(manifestCheckedAt) >= 30 {
            do {
                let commit = snapshot["remoteCommit"] as? String ?? ""
                let revision = Self.validCommit(commit) ? "?revision=\(commit)" : ""
                let fetched = try load(URL(string: "https://nightingalelyy.github.io/publication-manifest.json\(revision)")!)
                guard fetched["version"] as? Int == 1, fetched["commit"] is String,
                      fetched["articles"] is [String: [String: Any]] else { throw Self.error("The website has not provided a publication record yet.") }
                manifest = fetched; manifestCheckedAt = now; manifestReachable = true
            } catch {
                manifestReachable = false
                manifestRetryAfter = now.addingTimeInterval(60)
            }
        }
        let articles = manifest?["articles"] as? [String: [String: Any]] ?? [:]
        let checkedAt = ISO8601DateFormatter().string(from: now)
        var results: [[String: Any]] = []
        var requestedCommits = Set<String>()
        for target in targets {
            guard let path = target["path"] as? String, let sha = target["sourceSHA256"] as? String else { continue }
            var result: [String: Any] = ["path": path, "sourceSHA256": sha, "checkedAt": checkedAt]
            let deleting = target["operation"] as? String == "delete"
            if deleting { result["operation"] = "delete" }
            if let commit = target["commit"] as? String { result["commit"] = commit }
            if let url = target["liveURL"] as? String { result["liveURL"] = url }
            if deleting, articles[path] == nil, let deployedCommit = manifest?["commit"] as? String, Self.validCommit(deployedCommit) {
                // Absence alone is not proof: RepositoryStore must also verify
                // that this manifest commit contains the confirmed deletion.
                result["status"] = "deleted"
                result["manifestCommit"] = deployedCommit
                result["checkedAt"] = ISO8601DateFormatter().string(from: manifestCheckedAt)
                result["message"] = manifestReachable ? "Removed from the published website." : "Removed when last checked. Status could not be refreshed."
                results.append(result); continue
            }
            if !deleting, let published = articles[path], published["sha256"] as? String == sha {
                result["status"] = "live"
                result["checkedAt"] = ISO8601DateFormatter().string(from: manifestCheckedAt)
                if let route = published["url"] as? String, route.hasPrefix("/"), !route.hasPrefix("//"),
                   let url = URL(string: route, relativeTo: URL(string: "https://nightingalelyy.github.io")!)?.absoluteURL,
                   url.host == "nightingalelyy.github.io" { result["liveURL"] = url.absoluteString }
                result["message"] = manifestReachable ? "This version is live on your website." : "Live when last checked. Status could not be refreshed."
                results.append(result); continue
            }
            let commit = target["commit"] as? String ?? snapshot["remoteCommit"] as? String
            if let commit, Self.validCommit(commit), now >= apiRetryAfter {
                var response = runs[commit]?.1
                if (runs[commit] == nil || now.timeIntervalSince(runs[commit]!.0) >= 60), requestedCommits.count < 4 {
                    requestedCommits.insert(commit)
                    do {
                        let url = URL(string: "https://api.github.com/repos/Nightingalelyy/nightingalelyy.github.io/actions/workflows/pages.yml/runs?head_sha=\(commit)&per_page=5")!
                        response = try load(url)
                        runs[commit] = (now, response!)
                    } catch { apiRetryAfter = now.addingTimeInterval(60) }
                }
                if let response {
                    let state = Self.workflowState(response, commit: commit)
                    result.merge(state) { _, newer in newer }
                }
            }
            if result["status"] == nil {
                result["status"] = "uploaded"
                result["message"] = "Saved on GitHub. Waiting to verify the website deployment."
                if !manifestReachable { result["message"] = "Saved on GitHub. Deployment status is unavailable; your local work is safe." }
            }
            if deleting {
                switch result["status"] as? String {
                case "failed": result["message"] = "The website build failed. The source file was deleted, but the old page may still be online. Open build details."
                case "building": result["message"] = "The website is rebuilding. Waiting to verify that this item is removed."
                default: result["message"] = manifestReachable ? "Deleted from GitHub. Waiting to verify removal from the website." : "Deleted from GitHub. Website removal could not be checked yet."
                }
            }
            results.append(result)
        }
        if runs.count > 32 { runs = runs.filter { now.timeIntervalSince($0.value.0) < 3600 } }
        return ["results": results]
    }

    static func validCommit(_ commit: String) -> Bool { commit.range(of: "^[a-fA-F0-9]{40}$", options: .regularExpression) != nil }
    static func workflowState(_ response: [String: Any], commit: String) -> [String: Any] {
        let candidates = (response["workflow_runs"] as? [[String: Any]] ?? []).filter {
            ($0["head_sha"] as? String) == commit && ($0["head_branch"] as? String) == "main" &&
            ($0["path"] as? String) == ".github/workflows/pages.yml"
        }.sorted { ($0["id"] as? Int64 ?? 0) > ($1["id"] as? Int64 ?? 0) }
        guard let run = candidates.first else { return ["status": "uploaded", "message": "Saved on GitHub. Waiting for the website build."] }
        var result: [String: Any] = [:]
        if let raw = run["html_url"] as? String, let url = URL(string: raw), url.scheme == "https", url.host == "github.com",
           url.path.lowercased().hasPrefix("/nightingalelyy/nightingalelyy.github.io/actions/runs/") { result["workflowURL"] = raw }
        if run["status"] as? String == "completed", let conclusion = run["conclusion"] as? String,
           ["failure", "timed_out", "action_required", "startup_failure"].contains(conclusion) {
            result["status"] = "failed"; result["message"] = "The website build failed. Open the build details to see what needs fixing."
        } else if run["status"] as? String == "completed", ["cancelled", "skipped"].contains(run["conclusion"] as? String ?? "") {
            result["status"] = "uploaded"; result["message"] = "This build was skipped or replaced. Waiting to verify the website."
        } else {
            result["status"] = "building"; result["message"] = run["conclusion"] as? String == "success" ? "Build finished. Checking the live website." : "Your website is being built and deployed."
        }
        return result
    }

    private static func error(_ message: String) -> NSError { NSError(domain: "WriterDeployment", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    private static func download(_ url: URL) throws -> [String: Any] {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 15
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.setValue("Nightingale-Writer", forHTTPHeaderField: "User-Agent")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let completed = DispatchSemaphore(value: 0)
        var output: Result<[String: Any], Error> = .failure(error("Deployment status request timed out."))
        let task = session.dataTask(with: request) { data, response, failure in
            defer { completed.signal() }
            if let failure { output = .failure(failure); return }
            guard let response = response as? HTTPURLResponse, response.statusCode == 200,
                  response.url?.host == url.host, let data, data.count <= 2 * 1024 * 1024 else {
                output = .failure(error("Deployment status could not be retrieved.")); return
            }
            do {
                guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw error("Invalid deployment status.") }
                output = .success(json)
            } catch { output = .failure(error) }
        }
        task.resume()
        guard completed.wait(timeout: .now() + 16) == .success else { task.cancel(); throw error("Deployment status request timed out.") }
        return try output.get()
    }
}
