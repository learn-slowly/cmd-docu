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

    // 스모크 발견(2026-07-02): 문서 앞머리의 스치는 언급(1개 용어)이 정답 문단(여러 용어 겹침)을 밀어냈다.
    // 첫 매치가 아니라 "서로 다른 질의어가 가장 많이 겹치는 줄"을 골라야 한다.
    func testPassagePrefersLineWithMostTermMatches() {
        let body = "검색 이야기로 시작하는 서문이다.\n\n한참 뒤의 문단.\n\ncmd-docu 검색 스모크의 비밀 코드는 홍시-42다."
        let p = RagPassageExtractor.passage(inText: body, terms: ["검색", "비밀", "코드는"])
        XCTAssertTrue(p.text.contains("홍시-42"), "질의어 3개가 겹치는 문단이 근거여야 한다")
        XCTAssertEqual(p.location, .line(5))
    }

    func testTieFallsBackToEarliestLine() {
        // 동률(각 1개 매치)이면 기존처럼 이른 줄.
        let body = "첫 문단 선거 언급\n\n둘째 문단 선거 언급"
        let p = RagPassageExtractor.passage(inText: body, terms: ["선거"])
        XCTAssertEqual(p.location, .line(1))
    }
}
