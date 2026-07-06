import XCTest
@testable import CmdMD

/// LCS 줄 diff — 위키 병합 미리보기 렌더용(스펙 §2.2).
final class LineDiffTests: XCTestCase {
    private func kinds(_ lines: [LineDiff.Line]) -> [LineDiff.Kind] { lines.map(\.kind) }

    func testIdenticalIsAllSame() {
        let r = LineDiff.diff(old: "a\nb", new: "a\nb")
        XCTAssertEqual(kinds(r), [.same, .same])
    }

    func testAddedLine() {
        let r = LineDiff.diff(old: "a\nc", new: "a\nb\nc")
        XCTAssertEqual(r, [
            LineDiff.Line(kind: .same, text: "a"),
            LineDiff.Line(kind: .added, text: "b"),
            LineDiff.Line(kind: .same, text: "c"),
        ])
    }

    func testRemovedLine() {
        let r = LineDiff.diff(old: "a\nb\nc", new: "a\nc")
        XCTAssertEqual(r, [
            LineDiff.Line(kind: .same, text: "a"),
            LineDiff.Line(kind: .removed, text: "b"),
            LineDiff.Line(kind: .same, text: "c"),
        ])
    }

    func testChangedLineIsRemovePlusAdd() {
        let r = LineDiff.diff(old: "a\nX\nc", new: "a\nY\nc")
        XCTAssertEqual(kinds(r), [.same, .removed, .added, .same])
    }

    func testEmptyOldIsAllAdded() {
        let r = LineDiff.diff(old: "", new: "a\nb")
        XCTAssertEqual(kinds(r), [.added, .added])
    }

    func testEmptyNewIsAllRemoved() {
        let r = LineDiff.diff(old: "a\nb", new: "")
        XCTAssertEqual(kinds(r), [.removed, .removed])
    }

    func testWholeReplacement() {
        let r = LineDiff.diff(old: "x\ny", new: "p\nq")
        XCTAssertEqual(kinds(r).filter { $0 == .removed }.count, 2)
        XCTAssertEqual(kinds(r).filter { $0 == .added }.count, 2)
        XCTAssertEqual(kinds(r).filter { $0 == .same }.count, 0)
    }
}
