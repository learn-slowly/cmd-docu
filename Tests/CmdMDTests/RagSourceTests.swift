import XCTest
@testable import CmdMD

final class RagSourceTests: XCTestCase {
    func testIdentifiableUsesIndex() {
        let s = RagSource(index: 3, path: "/d/a.md", snippet: "…", location: .line(42))
        XCTAssertEqual(s.id, 3)
    }

    func testEquatable() {
        let a = RagSource(index: 1, path: "/d/a.md", snippet: "x", location: .page(2))
        let b = RagSource(index: 1, path: "/d/a.md", snippet: "x", location: .page(2))
        XCTAssertEqual(a, b)
        let c = RagSource(index: 1, path: "/d/a.md", snippet: "x", location: .unknown)
        XCTAssertNotEqual(a, c)
    }
}
