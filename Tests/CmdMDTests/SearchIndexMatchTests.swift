import XCTest
@testable import CmdMD

final class SearchIndexMatchTests: XCTestCase {
    private func tempDBURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("cmddocu-idxm-\(UUID().uuidString)")
            .appendingPathExtension("sqlite")
    }

    func testSearchMatchORFindsEitherTerm() async {
        let idx = SearchIndex(dbURL: tempDBURL())
        await idx.upsert(path: "/d/a.md", filename: "a.md", body: "지방선거 총평", mtime: 1, ext: "md")
        await idx.upsert(path: "/d/b.md", filename: "b.md", body: "평가서 초안", mtime: 1, ext: "md")
        await idx.upsert(path: "/d/c.md", filename: "c.md", body: "무관한 내용", mtime: 1, ext: "md")
        // "지방선거" OR "평가서" → a, b 만.
        let hits = await idx.searchMatch("\"지방선거\" OR \"평가서\"")
        let paths = Set(hits.map { $0.path })
        XCTAssertEqual(paths, ["/d/a.md", "/d/b.md"])
    }

    func testExistingSearchUnchangedRegression() async {
        // 기존 search()가 그대로 동작하는지 회귀 확인.
        let idx = SearchIndex(dbURL: tempDBURL())
        await idx.upsert(path: "/d/a.md", filename: "a.md", body: "선거 분석", mtime: 1, ext: "md")
        let hits = await idx.search(query: "선거")
        XCTAssertEqual(hits.first?.path, "/d/a.md")
    }
}
