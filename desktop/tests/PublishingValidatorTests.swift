import Foundation

@main struct PublishingValidatorTests {
    static func main() throws {
        let validator = PublishingValidator(resources: URL(fileURLWithPath: CommandLine.arguments[1]))
        let header = "---\ntitle: Validation check\ndate: 2026-11-02\ncategory: Notes\n---\n"
        func validate(_ body: String) throws -> [String: Any] {
            try validator.validate(["schemaVersion": 1, "documents": [["path": "_docs/check.md", "rawContent": header + body]], "files": ["images/available.png"], "routes": ["/", "/check/"], "site": ["url": "https://nightingalelyy.github.io", "baseurl": ""]])
        }
        let valid = try validate("```cpp\nint value = 42;\n```\n")
        precondition(valid["ok"] as? Bool == true)
        let liquid = try validate("```cpp\nunordered_map<int,int> m{{0,-1}};\n```\n")
        precondition(liquid["ok"] as? Bool == false)
        let issues = liquid["issues"] as! [[String: Any]]
        precondition(issues.contains { ($0["line"] as? Int ?? 0) >= 7 && $0["message"] is String })
        let missing = try validate("![Photo](/images/missing.png)\n")
        precondition(missing["ok"] as? Bool == false)
        let available = try validate("![Photo](/images/available.png)\n")
        precondition(available["ok"] as? Bool == true)
        print("PublishingValidator native bridge passed: valid code, Liquid rejection with line numbers, and local asset checks")
    }
}
