import XCTest
@testable import CmdMD

final class EditorTabKindTests: XCTestCase {
    func testDefaultKindIsMarkdown() {
        let tab = EditorTab()
        XCTAssertEqual(tab.kind, .markdown)
    }

    func testRoundTripPreservesImageKind() throws {
        let tab = EditorTab(fileURL: URL(fileURLWithPath: "/tmp/a.png"),
                            title: "a", kind: .image)
        let data = try JSONEncoder().encode(tab)
        let decoded = try JSONDecoder().decode(EditorTab.self, from: data)
        XCTAssertEqual(decoded.kind, .image)
    }

    func testLegacyJSONWithoutKindDecodesAsMarkdown() throws {
        // kind 키가 없는 구버전 세션 JSON
        let json = """
        {
          "id": "00000000-0000-0000-0000-000000000001",
          "documentId": "00000000-0000-0000-0000-000000000002",
          "title": "legacy",
          "isPinned": false,
          "isDirty": false,
          "scrollPosition": 0,
          "cursorPosition": 0
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(EditorTab.self, from: json)
        XCTAssertEqual(decoded.kind, .markdown)
        XCTAssertEqual(decoded.title, "legacy")
    }
}
