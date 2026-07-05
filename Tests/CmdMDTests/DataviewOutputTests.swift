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

    func testLinkTargetKeepsDottedNameWithoutKnownExtension() {
        // 회귀(리뷰 확증): 확장자 없는 점 든 경로를 deletingPathExtension이 "1.1"로 오절단
        // — LinkedNoteResolver 점-이름 버그(2026-07-01 수정)와 동일 패턴의 재유입 차단.
        let html = DataviewHTMLSerializer.html(for: [.list([
            .link(path: "Calendar/1.1.1_노트.md", display: nil),
            .link(path: "Calendar/2.2.2_이름", display: nil),
        ])])
        // md 확장자는 제거돼 "1.1.1_노트"가 마지막 컴포넌트
        XCTAssertTrue(html.contains("note=Calendar/1.1.1_") || html.contains("note=Calendar%2F1.1.1_"),
                      "md 확장자만 제거 후 점 든 이름 보존")
        // 확장자 없으면 그대로 유지 (2.2.2_이름 보존)
        XCTAssertTrue(html.contains("note=Calendar/2.2.2_") || html.contains("note=Calendar%2F2.2.2_"),
                      "확장자 없으면 점 든 이름 그대로")
        // 2.2로 오절단되지 않아야 함 (버그 증상 회귀 차단)
        XCTAssertFalse(html.contains("note=Calendar/1.1\"") || html.contains("note=Calendar%2F1.1%22"),
                       "1.1.1이 1.1로 오절단되면 안 됨")
        XCTAssertFalse(html.contains("note=Calendar/2.2\"") || html.contains("note=Calendar%2F2.2%22"),
                       "2.2.2가 2.2로 오절단되면 안 됨")
    }
}
