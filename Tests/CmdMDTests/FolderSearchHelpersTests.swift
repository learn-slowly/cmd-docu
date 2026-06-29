import XCTest
@testable import CmdMD

final class FolderSearchHelpersTests: XCTestCase {
    private let img = URL(fileURLWithPath: "/tmp/Vacation_Orange.png")
    private let md  = URL(fileURLWithPath: "/tmp/note.md")

    // filenameMatch
    func testFilenameMatchCaseInsensitive() {
        let r = AppState.filenameMatch(img, query: "orange")
        XCTAssertNotNil(r)
        XCTAssertEqual(r?.kind, .filename)
        XCTAssertEqual(r?.lineContent, "Vacation_Orange.png")
        XCTAssertEqual(r?.lineNumber, 0)
    }

    func testFilenameNoMatchReturnsNil() {
        XCTAssertNil(AppState.filenameMatch(img, query: "banana"))
    }

    func testFilenameEmptyQueryReturnsNil() {
        XCTAssertNil(AppState.filenameMatch(img, query: ""))
    }

    // contentLineMatches
    func testContentLineMatchesFindsMatchingLinesWith1BasedNumbers() {
        let text = "alpha\nbeta orange\ngamma\nORANGE again"
        let hits = AppState.contentLineMatches(in: text, fileURL: md, query: "orange")
        XCTAssertEqual(hits.count, 2)
        XCTAssertEqual(hits[0].lineNumber, 2)
        XCTAssertEqual(hits[0].lineContent, "beta orange")
        XCTAssertEqual(hits[0].kind, .line)
        XCTAssertEqual(hits[1].lineNumber, 4)   // 대소문자 무시
    }

    func testContentLineMatchesNoMatchEmpty() {
        let hits = AppState.contentLineMatches(in: "nothing here", fileURL: md, query: "orange")
        XCTAssertTrue(hits.isEmpty)
    }
}
