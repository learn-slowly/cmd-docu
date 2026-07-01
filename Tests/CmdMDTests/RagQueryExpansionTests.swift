import XCTest
@testable import CmdMD

final class RagQueryExpansionTests: XCTestCase {
    func testPromptAsksForJSONArray() {
        let p = RagQueryExpansion.prompt()
        XCTAssertTrue(p.lowercased().contains("json"))
        XCTAssertTrue(p.contains("["))
    }

    func testParseValidArray() {
        XCTAssertEqual(RagQueryExpansion.parse(#"["지방선거","총평"]"#), ["지방선거", "총평"])
    }

    func testParseExtractsFromProse() {
        let out = """
        확장 검색어입니다:
        ["지방선거", "6·1 선거", "평가서"]
        """
        XCTAssertEqual(RagQueryExpansion.parse(out), ["지방선거", "6·1 선거", "평가서"])
    }

    func testParseDropsBlanksAndDuplicates() {
        XCTAssertEqual(RagQueryExpansion.parse(#"["a"," a ","","a"]"#), ["a"])
    }

    func testParseMalformedReturnsEmpty() {
        XCTAssertEqual(RagQueryExpansion.parse("JSON 아님"), [])
    }

    func testOrMatchQuotesAndEscapes() {
        XCTAssertEqual(RagQueryExpansion.orMatch(["선거", "평가"]), "\"선거\" OR \"평가\"")
        XCTAssertEqual(RagQueryExpansion.orMatch(["a\"b"]), "\"a\"\"b\"")
    }

    func testOrMatchEmptyIsNil() {
        XCTAssertNil(RagQueryExpansion.orMatch([]))
        XCTAssertNil(RagQueryExpansion.orMatch(["", "  "]))
    }
}
