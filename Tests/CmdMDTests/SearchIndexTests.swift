import XCTest
@testable import CmdMD

final class SearchIndexTests: XCTestCase {
    private func tempDBURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("cmddocu-idx-\(UUID().uuidString)")
            .appendingPathExtension("sqlite")
    }

    func testSanitizeQuotesTermsAndPrefixesLast() {
        XCTAssertEqual(FTSQuery.sanitize("선거 분석"), "\"선거\" \"분석\"*")
        XCTAssertEqual(FTSQuery.sanitize("hello"), "\"hello\"*")
        XCTAssertNil(FTSQuery.sanitize("   "))
    }

    func testSanitizeEscapesEmbeddedQuotes() {
        // FTS5에서 따옴표는 ""로 이스케이프해야 구문 깨짐을 막는다.
        XCTAssertEqual(FTSQuery.sanitize("a\"b"), "\"a\"\"b\"*")
    }

    func testUpsertThenSearchFindsBodyHitWithSnippet() async {
        let idx = SearchIndex(dbURL: tempDBURL())
        await idx.upsert(path: "/d/a.hwp", filename: "a.hwp",
                         body: "정의당 평가서 선거 분석 보고", mtime: 1, ext: "hwp")
        let hits = await idx.search(query: "선거")
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.path, "/d/a.hwp")
        XCTAssertTrue(hits.first?.snippet.contains("선거") ?? false)
        XCTAssertFalse(hits.first?.isFilenameMatch ?? true)
    }

    func testFilenameMatchFlagged() async {
        let idx = SearchIndex(dbURL: tempDBURL())
        await idx.upsert(path: "/d/budget.md", filename: "budget.md",
                         body: "내용 없음", mtime: 1, ext: "md")
        let hits = await idx.search(query: "budget")
        XCTAssertEqual(hits.first?.path, "/d/budget.md")
        XCTAssertTrue(hits.first?.isFilenameMatch ?? false)
    }

    func testNeedsIndexTracksMtime() async {
        let idx = SearchIndex(dbURL: tempDBURL())
        // XCTAssertTrue/False는 autoclosure라 await를 직접 받지 못하므로 미리 추출.
        let needs1 = await idx.needsIndex(path: "/d/a.md", mtime: 10)
        XCTAssertTrue(needs1)   // 미인덱스
        await idx.upsert(path: "/d/a.md", filename: "a.md", body: "x", mtime: 10, ext: "md")
        let needs2 = await idx.needsIndex(path: "/d/a.md", mtime: 10)
        XCTAssertFalse(needs2)  // 동일 mtime
        let needs3 = await idx.needsIndex(path: "/d/a.md", mtime: 20)
        XCTAssertTrue(needs3)   // 변경됨
    }

    func testRemoveAndRemoveUnder() async {
        let idx = SearchIndex(dbURL: tempDBURL())
        await idx.upsert(path: "/d/x.md", filename: "x.md", body: "사과", mtime: 1, ext: "md")
        await idx.upsert(path: "/d/sub/y.md", filename: "y.md", body: "사과", mtime: 1, ext: "md")
        await idx.upsert(path: "/other/z.md", filename: "z.md", body: "사과", mtime: 1, ext: "md")
        // XCTAssertEqual은 autoclosure라 await를 직접 받지 못하므로 미리 추출.
        let count1 = await idx.count()
        XCTAssertEqual(count1, 3)
        await idx.remove(path: "/d/x.md")
        let count2 = await idx.count()
        XCTAssertEqual(count2, 2)
        let removed = await idx.removeUnder(folder: "/d")
        XCTAssertEqual(removed, 1)                 // /d/sub/y.md
        let count3 = await idx.count()
        XCTAssertEqual(count3, 1)                  // /other/z.md 만 남음
        let hits = await idx.search(query: "사과")
        XCTAssertEqual(hits.first?.path, "/other/z.md")
    }

    func testIndexedPathsUnder() async {
        let idx = SearchIndex(dbURL: tempDBURL())
        await idx.upsert(path: "/d/a.md", filename: "a.md", body: "x", mtime: 1, ext: "md")
        await idx.upsert(path: "/d/b.md", filename: "b.md", body: "x", mtime: 1, ext: "md")
        await idx.upsert(path: "/e/c.md", filename: "c.md", body: "x", mtime: 1, ext: "md")
        let under = await idx.indexedPaths(under: "/d").sorted()
        XCTAssertEqual(under, ["/d/a.md", "/d/b.md"])
    }
}
