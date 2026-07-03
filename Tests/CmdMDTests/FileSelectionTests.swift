import XCTest
@testable import CmdMD

final class FileSelectionTests: XCTestCase {

    private func u(_ p: String) -> URL { URL(fileURLWithPath: p) }

    // MARK: resolve — 클릭 시맨틱(스펙 §3.1)

    func testPlainClickReplacesSelection() {
        let ordered = [u("/f/a"), u("/f/b"), u("/f/c")]
        let r = FileSelectionHelper.resolve(current: [u("/f/a"), u("/f/b")], anchor: u("/f/a"),
                                            clicked: u("/f/c"), modifier: .none, ordered: ordered)
        XCTAssertEqual(r.selection, [u("/f/c")])
        XCTAssertEqual(r.anchor, u("/f/c"))
    }

    func testCommandClickToggles() {
        let ordered = [u("/f/a"), u("/f/b")]
        let added = FileSelectionHelper.resolve(current: [u("/f/a")], anchor: u("/f/a"),
                                                clicked: u("/f/b"), modifier: .command, ordered: ordered)
        XCTAssertEqual(added.selection, [u("/f/a"), u("/f/b")])
        XCTAssertEqual(added.anchor, u("/f/b"))
        let removed = FileSelectionHelper.resolve(current: added.selection, anchor: added.anchor,
                                                  clicked: u("/f/a"), modifier: .command, ordered: ordered)
        XCTAssertEqual(removed.selection, [u("/f/b")])
    }

    func testShiftClickSelectsRangeFromAnchor() {
        let ordered = [u("/f/a"), u("/f/b"), u("/f/c"), u("/f/d")]
        let r = FileSelectionHelper.resolve(current: [u("/f/b")], anchor: u("/f/b"),
                                            clicked: u("/f/d"), modifier: .shift, ordered: ordered)
        XCTAssertEqual(r.selection, [u("/f/b"), u("/f/c"), u("/f/d")])
        XCTAssertEqual(r.anchor, u("/f/b"), "⇧클릭은 앵커 유지")
        // 역방향(앵커 위쪽 클릭)도 연속 구간.
        let up = FileSelectionHelper.resolve(current: r.selection, anchor: r.anchor,
                                             clicked: u("/f/a"), modifier: .shift, ordered: ordered)
        XCTAssertEqual(up.selection, [u("/f/a"), u("/f/b")], "범위는 교체 — 이전 범위 잔존 없음")
    }

    func testShiftClickWithoutAnchorActsAsSingleSelect() {
        let ordered = [u("/f/a"), u("/f/b")]
        let r = FileSelectionHelper.resolve(current: [], anchor: nil,
                                            clicked: u("/f/b"), modifier: .shift, ordered: ordered)
        XCTAssertEqual(r.selection, [u("/f/b")])
        XCTAssertEqual(r.anchor, u("/f/b"))
    }

    func testShiftClickWithStaleAnchorFallsBackToSingle() {
        // 앵커가 ordered에 없음(재열거로 사라짐) — 단일 선택 폴백.
        let ordered = [u("/f/a"), u("/f/b")]
        let r = FileSelectionHelper.resolve(current: [u("/f/x")], anchor: u("/f/x"),
                                            clicked: u("/f/a"), modifier: .shift, ordered: ordered)
        XCTAssertEqual(r.selection, [u("/f/a")])
    }

    // MARK: ancestorsOnly — 중첩 정규화(스펙 §4.3)

    func testAncestorsOnlyDropsDescendants() {
        let input: Set<URL> = [u("/r/parent"), u("/r/parent/child.md"), u("/r/other.md")]
        let out = FileSelectionHelper.ancestorsOnly(input)
        XCTAssertEqual(Set(out), [u("/r/parent"), u("/r/other.md")])
    }

    func testAncestorsOnlyKeepsSiblingsWithPrefixNames() {
        // '/' 경계 — "/r/ab"는 "/r/a"의 하위가 아니다.
        let input: Set<URL> = [u("/r/a"), u("/r/ab")]
        let out = FileSelectionHelper.ancestorsOnly(input)
        XCTAssertEqual(Set(out), input)
    }

    func testAncestorsOnlyReturnsSortedPaths() {
        let input: Set<URL> = [u("/r/b.md"), u("/r/a.md")]
        XCTAssertEqual(FileSelectionHelper.ancestorsOnly(input).map(\.path), ["/r/a.md", "/r/b.md"])
    }
}
