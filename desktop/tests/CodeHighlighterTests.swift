import Foundation

private struct HighlightTestFailure: Error, CustomStringConvertible {
    let description: String
}

@main
struct CodeHighlighterTests {
    static var assertions = 0
    static func expect(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        assertions += 1
        if try !value() { throw HighlightTestFailure(description: message) }
    }
    static func rejects(_ message: String, _ body: () throws -> Void) throws {
        do { try body() } catch { assertions += 1; return }
        throw HighlightTestFailure(description: message)
    }
    static func blocks(_ result: [String: Any]) -> [[String: Any]] { result["blocks"] as! [[String: Any]] }
    static func decodedText(_ html: String) -> String {
        let withoutSpans = html.replacingOccurrences(of: "</?span(?: class=\"[a-zA-Z0-9_ -]+\")?>", with: "", options: .regularExpression)
        // Decode ampersands last, so authored entity-looking text remains literal.
        return withoutSpans.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">").replacingOccurrences(of: "&amp;", with: "&")
    }
    static func fixture(_ root: URL, script: String) throws -> CodeHighlighter {
        let fm = FileManager.default
        try fm.createDirectory(at: root.appendingPathComponent("preview"), withIntermediateDirectories: true)
        try fm.createDirectory(at: root.appendingPathComponent("vendor/rouge/lib"), withIntermediateDirectories: true)
        try Data(script.utf8).write(to: root.appendingPathComponent("preview/highlight.rb"))
        try Data().write(to: root.appendingPathComponent("vendor/rouge/lib/rouge.rb"))
        return CodeHighlighter(resources: root)
    }

    static func main() throws {
        guard CommandLine.arguments.count == 2 else { throw HighlightTestFailure(description: "Pass the desktop resource directory as the first argument") }
        let resources = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let highlighter = CodeHighlighter(resources: resources)
        let cpp = "int answer() { return 42; }\n"
        let expected = "<span class=\"kt\">int</span> <span class=\"nf\">answer</span><span class=\"p\">()</span> <span class=\"p\">{</span> <span class=\"k\">return</span> <span class=\"mi\">42</span><span class=\"p\">;</span> <span class=\"p\">}</span>\n"
        let result = try highlighter.highlight(["blocks": [["code": cpp, "language": "c++"], ["code": cpp, "language": "cpp?linenums"], ["code": cpp, "lang": "c++?linenums"]]])
        try expect(result["version"] as? String == "3.30.0", "Highlighting must use the pinned Rouge version")
        try expect(blocks(result).count == 3, "Batch order and count must be preserved")
        for block in blocks(result) {
            try expect(block["html"] as? String == expected, "C++ tokens must match the live Rouge formatter without line-number wrappers")
            try expect(block["highlighted"] as? Bool == true, "Known C++ languages should be highlighted")
        }
        try expect(blocks(result)[1]["language"] as? String == "cpp", "Legacy query options must be stripped from the returned language")
        let literal = "<script>alert('x')</script> &lt;tag&gt; & text\n中文与 emoji 🐦\n"
        let plain = try highlighter.highlight(["blocks": [["code": literal, "language": "not-a-language"]]])
        let plainHTML = blocks(plain)[0]["html"] as! String
        try expect(blocks(plain)[0]["highlighted"] as? Bool == false, "Unknown languages need a plain escaped fallback")
        try expect(!plainHTML.contains("<script>"), "Authored HTML must never become executable markup")
        try expect(decodedText(plainHTML) == literal, "Unknown-language fallback must retain text, UTF-8, and authored entities exactly")
        let htmlCode = try highlighter.highlight(["blocks": [["code": "<img src=x onerror=alert(1)>\n", "language": "html"]]])
        let htmlTokens = blocks(htmlCode)[0]["html"] as! String
        try expect(!htmlTokens.contains("<img"), "Even HTML-language lexing must escape authored HTML")
        try expect(decodedText(htmlTokens) == "<img src=x onerror=alert(1)>\n", "HTML-language highlighting must preserve code text")
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("nightingale-highlighter-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        let marker = temp.appendingPathComponent("authored-code-executed")
        let ruby = "File.write(\"\(marker.path)\", \"should never run\")\n"
        let rubyTokens = try highlighter.highlight(["blocks": [["code": ruby, "language": "ruby"]]])
        try expect(!FileManager.default.fileExists(atPath: marker.path), "Authored Ruby must only be lexed, never executed")
        try expect(decodedText(blocks(rubyTokens)[0]["html"] as! String) == ruby, "Ruby lexing must retain authored text")
        let empty = try highlighter.highlight(["blocks": []])
        try expect(blocks(empty).isEmpty, "An empty batch must succeed without spawning a process")
        let sixtyFour = Array(repeating: ["code": "x\n", "language": "plaintext"], count: 64)
        try expect(blocks(try highlighter.highlight(["blocks": sixtyFour])).count == 64, "The supported 64-block boundary must work")
        try rejects("65 blocks must be rejected") { _ = try highlighter.highlight(["blocks": sixtyFour + [["code": "x", "language": "plaintext"]]]) }
        try rejects("Non-text code must be rejected") { _ = try highlighter.highlight(["blocks": [["code": 1]]]) }
        try rejects("Non-text language must be rejected") { _ = try highlighter.highlight(["blocks": [["code": cpp, "language": 1]]]) }
        try rejects("Oversized languages must be rejected") { _ = try highlighter.highlight(["blocks": [["code": cpp, "language": String(repeating: "x", count: 129)]]]) }
        try rejects("Individual code blocks over256KiB must be rejected") { _ = try highlighter.highlight(["blocks": [["code": String(repeating: "x", count: 256 * 1024 + 1)]]]) }
        let maximumBlock = String(repeating: "x", count: 256 * 1024)
        let maximumBatch: [[String: String]] = [["code": maximumBlock, "language": "plaintext"], ["code": maximumBlock, "language": "plaintext"]]
        try expect(blocks(try highlighter.highlight(["blocks": maximumBatch])).allSatisfy { ($0["html"] as? String)?.utf8.count == 256 * 1024 }, "512KiB input must not deadlock a pipe")
        try rejects("Batches over512KiB must be rejected") { _ = try highlighter.highlight(["blocks": maximumBatch + [["code": "x"]]]) }
        let oversizedOutput = try fixture(temp.appendingPathComponent("large-output"), script: "STDOUT.write('x' * (8 * 1024 * 1024 + 1))\n")
        try rejects("Output above8MiB must be rejected before loading JSON") { _ = try oversizedOutput.highlight(["blocks": [["code": "x"]]]) }
        let stalled = try fixture(temp.appendingPathComponent("stalled"), script: "sleep 30\n")
        let start = Date()
        try rejects("A stalled highlighter must time out") { _ = try stalled.highlight(["blocks": [["code": "x"]]]) }
        try expect(Date().timeIntervalSince(start) < 11, "Timeout must terminate the process promptly")
        print("CodeHighlighter tests passed: \(assertions) assertions")
    }
}
