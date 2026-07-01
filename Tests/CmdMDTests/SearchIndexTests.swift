import XCTest
@testable import CmdMD

final class SearchIndexTests: XCTestCase {
    private func tempDBURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("cmddocu-idx-\(UUID().uuidString)")
            .appendingPathExtension("sqlite")
    }

    func testSearchFindsBodyHitWithSnippet() async {
        let idx = SearchIndex(dbURL: tempDBURL())
        await idx.upsert(path: "/d/a.hwp", filename: "a.hwp",
                         body: "정의당 평가서 선거 분석 보고", mtime: 1, ext: "hwp")
        // ≥3글자 → MATCH + 스니펫.
        let hits = await idx.search(query: "평가서")
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.path, "/d/a.hwp")
        XCTAssertTrue(hits.first?.snippet.contains("평가서") ?? false)
        XCTAssertFalse(hits.first?.isFilenameMatch ?? true)
    }

    func testSearchMatchesKoreanParticleAndCompound() async {
        let idx = SearchIndex(dbURL: tempDBURL())
        await idx.upsert(path: "/d/p.md", filename: "p.md", body: "정의당 평가서에 대한 총평", mtime: 1, ext: "md")
        await idx.upsert(path: "/d/c.md", filename: "c.md", body: "지방선거 결과 분석", mtime: 1, ext: "md")
        // 조사: "평가서" → "평가서에" 매치.
        let h1 = await idx.search(query: "평가서")
        XCTAssertEqual(h1.first?.path, "/d/p.md")
        // 복합어(2글자 LIKE): "선거" → "지방선거" 매치.
        let h2 = await idx.search(query: "선거")
        XCTAssertEqual(h2.first?.path, "/d/c.md")
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
