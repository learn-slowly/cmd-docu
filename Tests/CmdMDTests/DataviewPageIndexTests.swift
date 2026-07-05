import XCTest
@testable import CmdMD

final class DataviewPageIndexTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dv-index-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: root.appendingPathComponent("Calendar/2025"),
                                                 withIntermediateDirectories: true)
        write("Calendar/2026-07-05.md", "---\ntags: [daily]\n---\n- 항목")
        write("Calendar/2025/2025-12-01.md", "# 옛날")
        write("Calendar/2026-W27.md", "# 주간")
        write("루트노트.md", "#inline_tag 본문")
        write("Calendar/.hidden.md", "숨김")
        write("Calendar/ignore.txt", "md 아님")
    }

    override func tearDown() { try? FileManager.default.removeItem(at: root); super.tearDown() }

    private func write(_ rel: String, _ content: String) {
        let url = root.appendingPathComponent(rel)
        try! content.write(to: url, atomically: true, encoding: .utf8)
    }

    func testAllPagesRecursiveMdOnlyNoHidden() {
        let idx = DataviewPageIndex(root: root)
        XCTAssertEqual(Set(idx.allPages().map(\.path)),
                       ["Calendar/2026-07-05.md", "Calendar/2025/2025-12-01.md",
                        "Calendar/2026-W27.md", "루트노트.md"])
    }

    func testFolderQueryIsRecursiveWithSlashBoundary() {
        let idx = DataviewPageIndex(root: root)
        XCTAssertEqual(idx.pages(inFolder: "Calendar").count, 3, "하위 연도 폴더 포함")
        XCTAssertEqual(idx.pages(inFolder: "Cal").count, 0, "'/' 경계 — 접두사 오매칭 금지")
    }

    func testTagQueryNormalizesHash() {
        let idx = DataviewPageIndex(root: root)
        XCTAssertEqual(idx.pages(withTag: "#daily").map(\.name), ["2026-07-05"])
        XCTAssertEqual(idx.pages(withTag: "inline_tag").map(\.name), ["루트노트"])
    }

    func testPageLookupByPathAndName() {
        let idx = DataviewPageIndex(root: root)
        XCTAssertNotNil(idx.page(at: "Calendar/2026-W27.md"))
        XCTAssertNotNil(idx.page(at: "Calendar/2026-W27"))
        XCTAssertNotNil(idx.page(at: "2026-W27"), "파일명만으로도")
        XCTAssertNil(idx.page(at: "없는노트"))
    }

    func testMtimeCacheInvalidation() throws {
        let idx = DataviewPageIndex(root: root)
        XCTAssertFalse(idx.allPages().first { $0.name == "2026-07-05" }!.lists.contains { $0.text == "새 항목" })
        // mtime을 확실히 바꾼다(초 단위 해상도 방어).
        let url = root.appendingPathComponent("Calendar/2026-07-05.md")
        try "---\ntags: [daily]\n---\n- 새 항목".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(10)],
                                              ofItemAtPath: url.path)
        XCTAssertTrue(idx.allPages().first { $0.name == "2026-07-05" }!.lists.contains { $0.text == "새 항목" })
    }

    func testSharedRegistryReturnsSameInstance() {
        XCTAssertTrue(DataviewPageIndex.shared(for: root) === DataviewPageIndex.shared(for: root))
    }

    func testEmptyFolderQueryReturnsAllRecursive() {
        // 회귀(리뷰 확증): ""(루트) 질의가 prefix "/" 오조립으로 루트 직속만 반환하던 결함.
        let idx = DataviewPageIndex(root: root)
        XCTAssertEqual(idx.pages(inFolder: "").count, idx.allPages().count,
                       "루트 폴더는 전체 재귀 반환")
    }
}
