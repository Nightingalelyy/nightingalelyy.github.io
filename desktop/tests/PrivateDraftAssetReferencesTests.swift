import Foundation

@main struct PrivateDraftAssetReferencesTests {
    static func main() throws {
        let store = RepositoryStore(root: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("nightingale-image-parser-unused-" + UUID().uuidString))
        var assertions = 0
        func check(_ source: String, _ expected: [String], _ name: String) throws {
            let actual = try store.privateAssetPaths(source)
            guard actual == expected.sorted() else { fatalError("\(name): expected \(expected), got \(actual)") }
            assertions += 1
        }
        func rejects(_ source: String, _ name: String) {
            do { _ = try store.privateAssetPaths(source); fatalError("\(name): expected rejection") }
            catch { assertions += 1 }
        }
        try check("![Photo](/images/uploads/photo.png)", ["images/uploads/photo.png"], "app-generated image")
        try check("![](/images/uploads/b.png) ![same](/images/uploads/b.png) ![a](./images/uploads/a.png \"Title\")", ["images/uploads/a.png", "images/uploads/b.png"], "deduplicated sorted paths")
        try check("![nested [alt]](/images/uploads/a(b).png) ![escaped](/images/uploads/a\\(c\\).png)", ["images/uploads/a(b).png", "images/uploads/a(c).png"], "balanced and escaped parentheses")
        try check("![](</images/uploads/angle.png>) ![](</images/uploads/space%20name.png>)", ["images/uploads/angle.png", "images/uploads/space name.png"], "angle destinations")
        try check("![](/images/uploads/%E5%8C%97%E4%BA%AC.png?download=1#detail)", ["images/uploads/北京.png"], "encoded filename and query")
        try check("![Full][image label]\n![Image Label][]\n![image label]\n\n[Image   Label]: </images/uploads/ref.png> \"Title\"", ["images/uploads/ref.png"], "reference-style variants and normalized labels")
        try check("![ref]\n[ref]:\n  /images/uploads/multiline.png", ["images/uploads/multiline.png"], "multiline reference destination")
        try check("[ordinary link](/images/uploads/link.png)\n[unused]: /images/uploads/unused.png", [], "links and unused definitions are not images")
        try check("<IMG alt='a' SRC='/images/uploads/html.png'><img src=/images/uploads/bare.gif><img data-src='/images/uploads/lazy.png'>", ["images/uploads/html.png", "images/uploads/bare.gif"], "HTML src only")
        try check("<img src='/images/uploads/a&amp;b.png'><img src='/images/uploads/a&gt;b.png'><img src='/images/uploads/a&amp;quot;b.png'>", ["images/uploads/a&b.png", "images/uploads/a>b.png", "images/uploads/a&quot;b.png"], "HTML entity decoded once")
        try check("![<img src='/images/uploads/alt.png'>](/images/uploads/real.png)", ["images/uploads/real.png"], "HTML-like alt text is not an image")
        try check(#"\<img src='/images/uploads/escaped.png'> \![alt](/images/uploads/escaped2.png)"#, [], "escaped image syntax")
        try check("![external](https://example.org/images/uploads/external.png) <img src='//cdn.example.org/images/uploads/cdn.png'> ![](data:image/png;base64,a) ![](mailto:images/uploads/mail.png)", [], "external hosts and other schemes excluded")
        try check("![](https://nightingalelyy.github.io/images/uploads/own.png?x=1) ![](//NIGHTINGALELYY.github.io/images/uploads/own2.png) ![](https://nightingalelyy.github.io.evil.example/images/uploads/evil.png)", ["images/uploads/own.png", "images/uploads/own2.png"], "same-site absolute paths only")
        try check("```md\n![](/images/uploads/code.png)\n```\n~~~html\n<img src='/images/uploads/code2.png'>\n~~~\n![](/images/uploads/visible.png)", ["images/uploads/visible.png"], "fenced code excluded")
        try check("```markdown\n![](/images/uploads/unclosed.png)", [], "unclosed fence excluded")
        try check("`![](/images/uploads/code.png)` ``<img src='/images/uploads/code2.png'> `text` `` ![](/images/uploads/visible.png)", ["images/uploads/visible.png"], "inline code excluded")
        try check("    ![](/images/uploads/indented.png)\n\t<img src='/images/uploads/tab.png'>\n\n![](/images/uploads/visible.png)", ["images/uploads/visible.png"], "indented code excluded")
        try check("- An image\n    ![](/images/uploads/list.png)\n\n      ![](/images/uploads/list-code.png)\n\n> ![](/images/uploads/quote.png)", ["images/uploads/list.png", "images/uploads/quote.png"], "list images and blockquote image")
        try check("<!-- <img src='/images/uploads/comment.png'> -->\n<pre>![](/images/uploads/pre.png)</pre>\n<code><img src='/images/uploads/code.png'></code>\n<script>![](/images/uploads/script.png)</script>\n<textarea><img src='/images/uploads/textarea.png'></textarea>", [], "HTML code and comments excluded")
        try check("---\ntitle: \"![](/images/uploads/title.png)\"\n---\n![](/images/uploads/body.png)", ["images/uploads/body.png"], "frontmatter excluded")
        try check("\r\n```\r\n![](/images/uploads/code.png)\r\n```\r\n![](/images/uploads/crlf.png)", ["images/uploads/crlf.png"], "CRLF source")
        rejects("![](/images/uploads/%2e%2e/private.png)", "encoded traversal rejected")
        rejects("![](/images/uploads/bad%zz.png)", "malformed encoding rejected")
        rejects(String(repeating: "![", count: 1000), "malformed bracket scan bounded")
        rejects("Paragraph " + (1...200).map { String(repeating: "`", count: $0) }.joined(separator: " "), "unmatched backtick runs bounded")
        print("Private draft image references: \(assertions) assertions passed.")
    }
}
