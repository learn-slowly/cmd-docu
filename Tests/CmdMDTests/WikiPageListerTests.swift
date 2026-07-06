import XCTest
@testable import CmdMD

/// 위키 재귀 페이지 목록(스펙 §2.6) — 하위 폴더 포함·숨김 제외·상대경로·이름순.
final class WikiPageListerTests: XCTestCase {
    var root: URL!

    override func setUp() {
        super.setUp()
        root = TempDataDirectory.make()
    }
    override func tearDown() {
        TempDataDirectory.cleanup(root)
        super.tearDown()
    }

    private func touch(_ rel: String) {
        let url = root.appendingPathComponent(rel)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? "x".write(to: url, atomically: true, encoding: .utf8)
    }

    func testListsRecursivelyWithRelativePathsSorted() {
        touch("index.md")
        touch("references/신진욱2011.md")
        touch("references/Baker_1993.md")
        touch("claims/c1.md")
        touch("notes.txt")                       // 비md 제외
        let pages = WikiPageLister.relativePages(under: root)
        XCTAssertEqual(pages, ["claims/c1.md",
                               "index.md",
                               "references/신진욱2011.md",
                               "references/Baker_1993.md"])
    }

    func testExcludesHiddenDirectoriesAndFiles() {
        touch(".git/objects/a.md")
        touch(".obsidian/config.md")
        touch(".hidden.md")
        touch("visible.md")
        XCTAssertEqual(WikiPageLister.relativePages(under: root), ["visible.md"])
    }

    func testHiddenFileDoesNotDropSiblingPages() {
        // .DS_Store(숨김 파일)가 낀 보이는 폴더의 페이지가 전부 반환돼야 한다 —
        // 숨김 파일에서 skipDescendants()를 부르면 감싸는 폴더 하강이 취소되는 회귀(Critical).
        // APFS 열거 순서 비결정 대비 .md를 여러 개 두어 skip 발화 후속 항목을 보장한다.
        touch("docs/.DS_Store")
        for name in ["a", "b", "c", "d", "e"] { touch("docs/\(name).md") }
        touch("visible.md")
        let pages = WikiPageLister.relativePages(under: root)
        XCTAssertEqual(pages, ["docs/a.md", "docs/b.md", "docs/c.md",
                               "docs/d.md", "docs/e.md", "visible.md"])
    }

    func testEmptyOrMissingRootReturnsEmpty() {
        XCTAssertEqual(WikiPageLister.relativePages(under: root), [])
        XCTAssertEqual(WikiPageLister.relativePages(
            under: root.appendingPathComponent("없는폴더")), [])
    }
}
