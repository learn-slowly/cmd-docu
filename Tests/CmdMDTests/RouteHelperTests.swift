import XCTest
@testable import CmdMD

final class RouteHelperTests: XCTestCase {
    private func dests() -> [ParaFolder] {
        [
            ParaFolder(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, label: "Projects", folder: "10000_Projects", hint: "진행 프로젝트"),
            ParaFolder(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, label: "Resources", folder: "30000_Resources", hint: "참고 자료"),
        ]
    }

    func testBuildRoutePromptIncludesEveryDestinationAndJSONInstruction() {
        let p = RouteHelper.buildRoutePrompt(destinations: dests())
        XCTAssertTrue(p.contains("00000000-0000-0000-0000-000000000001"))
        XCTAssertTrue(p.contains("Projects"))
        XCTAssertTrue(p.contains("진행 프로젝트"))
        XCTAssertTrue(p.contains("00000000-0000-0000-0000-000000000002"))
        XCTAssertTrue(p.contains("Resources"))
        XCTAssertTrue(p.lowercased().contains("json"))
        XCTAssertTrue(p.contains("\"id\""))
        XCTAssertTrue(p.contains("\"reason\""))
    }

    func testBuildRouteContextTruncatesLongBody() {
        let body = String(repeating: "가", count: 5000)
        let ctx = RouteHelper.buildRouteContext(noteBody: body, maxChars: 100)
        XCTAssertLessThan(ctx.count, body.count)
        XCTAssertTrue(ctx.contains("생략"))
    }

    func testBuildRouteContextKeepsShortBody() {
        let ctx = RouteHelper.buildRouteContext(noteBody: "짧은 본문", maxChars: 100)
        XCTAssertEqual(ctx, "짧은 본문")
    }

    func testParseValidJSONResolvesFolder() {
        let out = #"{"id":"00000000-0000-0000-0000-000000000002","reason":"참고용 자료라서"}"#
        let s = RouteHelper.parseRouteSuggestion(out, destinations: dests())
        XCTAssertEqual(s?.folder.folder, "30000_Resources")
        XCTAssertEqual(s?.reason, "참고용 자료라서")
    }

    func testParseExtractsJSONFromProseAndCodeFence() {
        let out = """
        제 판단은 다음과 같습니다:
        ```json
        {"id":"00000000-0000-0000-0000-000000000001","reason":"진행 중인 프로젝트 문서"}
        ```
        """
        let s = RouteHelper.parseRouteSuggestion(out, destinations: dests())
        XCTAssertEqual(s?.folder.folder, "10000_Projects")
    }

    func testParseUnknownIdReturnsNil() {
        let out = #"{"id":"99999999-9999-9999-9999-999999999999","reason":"x"}"#
        XCTAssertNil(RouteHelper.parseRouteSuggestion(out, destinations: dests()))
    }

    func testParseMalformedReturnsNil() {
        XCTAssertNil(RouteHelper.parseRouteSuggestion("도무지 JSON이 아님", destinations: dests()))
    }
}
