import XCTest
@testable import CmdMD

final class DataviewOutputTests: XCTestCase {

    func testTableHTMLWithLinkAndBr() {
        let items: [DataviewOutputItem] = [.table(
            headers: [.text("날짜"), .text("메모")],
            rows: [[.link(path: "Calendar/2026-07-05.md", display: "2026-07-05"),
                    .text("줄1<br>줄2")]])]
        let html = DataviewHTMLSerializer.html(for: items)
        XCTAssertTrue(html.contains("<table class=\"dataview\">"))
        XCTAssertTrue(html.contains("<th>날짜</th>"))
        XCTAssertTrue(html.contains("줄1<br>줄2"), "셀 HTML 통과(<br> 실사용)")
        XCTAssertTrue(html.contains("class=\"wiki-link\""))
        XCTAssertTrue(html.contains("cmdmd://open?note="), "기존 위키링크 스킴 재사용")
        XCTAssertTrue(html.contains(">2026-07-05</a>"))
    }

    func testListParagraphHeaderSpan() {
        let html = DataviewHTMLSerializer.html(for: [
            .list([.text("a"), .link(path: "b.md", display: nil)]),
            .paragraph(.text("문단")),
            .header(level: 3, .text("헤딩")),
            .span(.text("스팬")),
        ])
        XCTAssertTrue(html.contains("<ul class=\"dataview\">"))
        XCTAssertTrue(html.contains("<li>a</li>"))
        XCTAssertTrue(html.contains("<p class=\"dataview\">문단</p>"))
        XCTAssertTrue(html.contains("<h3 class=\"dataview\">헤딩</h3>"))
        XCTAssertTrue(html.contains("<span class=\"dataview\">스팬</span>"))
    }

    func testNestedCellJoinsWithBr() {
        let html = DataviewHTMLSerializer.html(for: [.table(
            headers: [.text("h")], rows: [[.nested([.text("x"), .text("y")])]])])
        XCTAssertTrue(html.contains("x<br>y"))
    }

    func testErrorCardEscapesAndFoldsCode() {
        let card = DataviewHTMLSerializer.errorCard(message: "타임아웃", code: "<script>x</script>")
        XCTAssertTrue(card.contains("타임아웃"))
        XCTAssertTrue(card.contains("<details>"))
        XCTAssertTrue(card.contains("&lt;script&gt;"), "오류 카드의 코드는 이스케이프")
        XCTAssertFalse(card.contains("<script>x"))
    }

    func testRunButtonCardPostsMessage() {
        let card = DataviewHTMLSerializer.runButtonCard(blockId: 2, code: "dv.x()")
        XCTAssertTrue(card.contains("dataviewRun"))
        XCTAssertTrue(card.contains("\"id\":2") || card.contains("id: 2") || card.contains("id:2"))
        XCTAssertTrue(card.contains("dv.x()"))
    }

    func testWikiLinkHrefMatchesRendererBehavior() {
        // processWikiLinks 추출 리팩터가 동작 불변임을 고정: 렌더러 산출과 동일 href.
        let renderer = MarkdownRenderer()
        let html = renderer.renderToHTML(markdown: "[[한글 노트]]", baseURL: nil, theme: .github)
        XCTAssertTrue(html.contains(MarkdownRenderer.wikiLinkHref(target: "한글 노트").replacingOccurrences(of: "&", with: "&amp;"))
                      || html.contains(MarkdownRenderer.wikiLinkHref(target: "한글 노트")))
    }
}
