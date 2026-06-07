import XCTest
@testable import CmdMD

final class MarkdownRendererTests: XCTestCase {
    func testWikiLinkAmpersandIsPercentEncodedInInternalLinkQuery() {
        let html = MarkdownRenderer().renderToHTML(markdown: "[[A & B]]")
        let href = firstHref(in: html)

        XCTAssertEqual(href, "cmdmd://open?note=A%20%26%20B")
        XCTAssertFalse(href.contains("&amp;%20B"))
    }

    private func firstHref(in html: String) -> String {
        guard let start = html.range(of: "href=\"")?.upperBound,
              let end = html[start...].firstIndex(of: "\"") else {
            return ""
        }
        return String(html[start..<end])
    }
}
