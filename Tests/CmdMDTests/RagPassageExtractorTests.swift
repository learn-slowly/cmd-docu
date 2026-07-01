import XCTest
@testable import CmdMD

final class RagPassageExtractorTests: XCTestCase {
    func testReturnsParagraphWithMatchAndLine() {
        let body = "머리말\n\n둘째 문단 선거 분석 내용\n\n셋째 문단"
        let p = RagPassageExtractor.passage(inText: body, terms: ["선거"])
        XCTAssertEqual(p.text, "둘째 문단 선거 분석 내용")
        XCTAssertEqual(p.location, .line(3))
    }

    func testCaseInsensitiveMatch() {
        let body = "intro\n\nSee the Budget report here"
        let p = RagPassageExtractor.passage(inText: body, terms: ["budget"])
        XCTAssertEqual(p.text, "See the Budget report here")
        XCTAssertEqual(p.location, .line(3))
    }

    func testNoMatchReturnsPrefixLineOne() {
        let body = "관계 없는 첫 문단\n\n관계 없는 둘째 문단"
        let p = RagPassageExtractor.passage(inText: body, terms: ["없는단어"], maxChars: 8)
        XCTAssertEqual(p.location, .line(1))
        XCTAssertLessThanOrEqual(p.text.count, 8)
        XCTAssertEqual(p.text, "관계 없는 첫")
    }

    func testLongParagraphCappedToMaxChars() {
        let long = String(repeating: "가", count: 500) + "선거" + String(repeating: "나", count: 500)
        let p = RagPassageExtractor.passage(inText: long, terms: ["선거"], maxChars: 100)
        XCTAssertLessThanOrEqual(p.text.count, 100)
        XCTAssertTrue(p.text.contains("선거"))
    }

    func testEmptyTermsReturnsPrefixLineOne() {
        let p = RagPassageExtractor.passage(inText: "본문 내용", terms: [], maxChars: 100)
        XCTAssertEqual(p.location, .line(1))
        XCTAssertEqual(p.text, "본문 내용")
    }
}
