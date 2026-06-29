import XCTest
@testable import CmdMD

final class SearchResultKindTests: XCTestCase {
    private func rangeIn(_ s: String) -> Range<String.Index> {
        s.startIndex..<s.index(after: s.startIndex)
    }

    func testDefaultKindIsLine() {
        let r = SearchResult(fileURL: URL(fileURLWithPath: "/tmp/a.md"),
                             lineNumber: 3, lineContent: "hello", matchRange: rangeIn("hello"))
        XCTAssertEqual(r.kind, .line)
    }

    func testExplicitKindPreserved() {
        let name = "photo.png"
        let r = SearchResult(fileURL: URL(fileURLWithPath: "/tmp/\(name)"),
                             lineNumber: 0, lineContent: name, matchRange: rangeIn(name),
                             kind: .filename)
        XCTAssertEqual(r.kind, .filename)

        let p = SearchResult(fileURL: URL(fileURLWithPath: "/tmp/doc.pdf"),
                             lineNumber: 5, lineContent: "orange", matchRange: rangeIn("orange"),
                             kind: .pdfPage)
        XCTAssertEqual(p.kind, .pdfPage)
        XCTAssertEqual(p.lineNumber, 5)
    }

    func testOfficeBodyKindPreserved() {
        let s = SearchResult(fileURL: URL(fileURLWithPath: "/tmp/report.hwp"),
                             lineNumber: 7, lineContent: "예산 내용 줄",
                             matchRange: rangeIn("예산 내용 줄"), kind: .officeBody)
        XCTAssertEqual(s.kind, .officeBody)
        XCTAssertEqual(s.lineNumber, 7)
    }
}
