import XCTest
@testable import CmdMD

final class RagContextBuilderTests: XCTestCase {
    private func pass(_ t: String, _ l: RagLocation) -> RagPassageExtractor.Passage {
        RagPassageExtractor.Passage(text: t, location: l)
    }

    func testNumbersSourcesAndBuildsContext() {
        let built = RagContextBuilder.build(
            paths: ["/d/a.md", "/d/b.pdf"],
            passages: [pass("첫 근거", .line(3)), pass("둘째 근거", .page(2))])
        XCTAssertEqual(built.sources.count, 2)
        XCTAssertEqual(built.sources[0].index, 1)
        XCTAssertEqual(built.sources[0].path, "/d/a.md")
        XCTAssertEqual(built.sources[0].location, .line(3))
        XCTAssertEqual(built.sources[1].index, 2)
        XCTAssertTrue(built.context.contains("[1] a.md (줄 3)"))
        XCTAssertTrue(built.context.contains("첫 근거"))
        XCTAssertTrue(built.context.contains("[2] b.pdf (p.2)"))
    }

    func testBudgetTruncatesButKeepsAtLeastOne() {
        let big = String(repeating: "가", count: 1000)
        let built = RagContextBuilder.build(
            paths: ["/d/a.md", "/d/b.md"],
            passages: [pass(big, .line(1)), pass(big, .line(1))],
            budget: 200)
        XCTAssertEqual(built.sources.count, 1)          // 예산 초과분 버림
        XCTAssertTrue(built.context.contains("[1]"))
        XCTAssertFalse(built.context.contains("[2]"))
    }

    func testEmptyInput() {
        let built = RagContextBuilder.build(paths: [], passages: [])
        XCTAssertTrue(built.sources.isEmpty)
        XCTAssertEqual(built.context, "")
    }
}
