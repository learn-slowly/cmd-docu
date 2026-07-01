import XCTest
@testable import CmdMD

final class TrigramQueryTests: XCTestCase {
    func testMatchOnlyForLongTerm() {
        let b = TrigramQuery.build(terms: ["평가서"], mode: .and)
        XCTAssertEqual(b?.whereClause, "docs MATCH ?")
        XCTAssertEqual(b?.matchArg, "\"평가서\"")
        XCTAssertEqual(b?.likeArgs, [])
        XCTAssertEqual(b?.hasMatch, true)
    }

    func testLikeOnlyForShortTerm() {
        let b = TrigramQuery.build(terms: ["선거"], mode: .and)
        XCTAssertEqual(b?.whereClause, "body LIKE ? ESCAPE '\\'")
        XCTAssertNil(b?.matchArg)
        XCTAssertEqual(b?.likeArgs, ["%선거%"])
        XCTAssertEqual(b?.hasMatch, false)
    }

    func testMixedAndCombinesWithParens() {
        let b = TrigramQuery.build(terms: ["평가서", "선거"], mode: .and)
        XCTAssertEqual(b?.whereClause, "(docs MATCH ?) AND (body LIKE ? ESCAPE '\\')")
        XCTAssertEqual(b?.matchArg, "\"평가서\"")
        XCTAssertEqual(b?.likeArgs, ["%선거%"])
        XCTAssertEqual(b?.hasMatch, true)
    }

    func testOrModeJoinsMatchPhrasesWithOR() {
        let b = TrigramQuery.build(terms: ["평가서", "지방선거"], mode: .or)
        XCTAssertEqual(b?.whereClause, "docs MATCH ?")
        XCTAssertEqual(b?.matchArg, "\"평가서\" OR \"지방선거\"")
        XCTAssertEqual(b?.hasMatch, true)
    }

    func testMixedOrConnector() {
        let b = TrigramQuery.build(terms: ["평가서", "선거"], mode: .or)
        XCTAssertEqual(b?.whereClause, "(docs MATCH ?) OR (body LIKE ? ESCAPE '\\')")
    }

    func testEscaping() {
        // MATCH 구의 " 는 "" 로, LIKE의 % _ \ 는 이스케이프.
        let m = TrigramQuery.build(terms: ["평가\"서X"], mode: .and)   // 4글자 → MATCH
        XCTAssertEqual(m?.matchArg, "\"평가\"\"서X\"")
        let l = TrigramQuery.build(terms: ["a%"], mode: .and)          // 2글자 → LIKE
        XCTAssertEqual(l?.likeArgs, ["%a\\%%"])
    }

    func testEmptyReturnsNil() {
        XCTAssertNil(TrigramQuery.build(terms: [], mode: .and))
        XCTAssertNil(TrigramQuery.build(terms: ["", "  "], mode: .and))
    }
}
