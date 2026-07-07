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

    func testExcludesRuleFilesFromTargets() {
        // 루트 CLAUDE.md·templates/는 "규칙 소스"(규칙 파악이 읽는 파일)지 병합 대상이 아니다 —
        // Picker에 노출되면 규칙 파일에 실수로 병합하는 사고를 유인한다.
        touch("CLAUDE.md")
        touch("templates/summary.md")
        touch("templates/concept.md")
        touch("pages/주제/문서.md")
        touch("sub/CLAUDE.md")                   // 루트가 아닌 CLAUDE.md는 일반 페이지 취급
        touch("sub/templates/x.md")              // 루트가 아닌 templates도 일반 폴더 취급
        let pages = WikiPageLister.relativePages(under: root)
        // 혼합 문자 정렬은 로캘 종속이라 순서 대신 집합으로 비교(T2 로캘 함정 회피).
        XCTAssertEqual(Set(pages), ["pages/주제/문서.md", "sub/CLAUDE.md", "sub/templates/x.md"])
        XCTAssertEqual(pages.count, 3)
    }

    func testExcludesRuleFilesCaseInsensitively() {
        // collectRuleSources는 파일시스템 대소문자 무시 해석으로 소문자 규칙파일도 규칙 소스로
        // 읽는다 — 제외도 같은 시맨틱이어야 Picker에 새지 않는다(case-insensitive FS 방어).
        touch("claude.md")               // 소문자 CLAUDE.md
        touch("Templates/summary.md")    // 대문자 templates/
        touch("pages/문서.md")
        let pages = WikiPageLister.relativePages(under: root)
        XCTAssertEqual(pages, ["pages/문서.md"])
    }
}
