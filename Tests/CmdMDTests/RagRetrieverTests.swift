import XCTest
@testable import CmdMD

final class RagRetrieverTests: XCTestCase {
    private func hit(_ p: String) -> IndexHit { IndexHit(path: p, snippet: "", isFilenameMatch: false) }

    func testMergeKeepsPrimaryOrderThenNewSecondary() {
        let out = RagRetriever.mergePaths(
            primary: [hit("/a"), hit("/b")],
            secondary: [hit("/b"), hit("/c"), hit("/d")],
            limit: 3)
        XCTAssertEqual(out, ["/a", "/b", "/c"])
    }

    func testMergeDedupesWithinPrimary() {
        let out = RagRetriever.mergePaths(
            primary: [hit("/a"), hit("/a"), hit("/b")],
            secondary: [],
            limit: 8)
        XCTAssertEqual(out, ["/a", "/b"])
    }

    func testMergeRespectsLimit() {
        let out = RagRetriever.mergePaths(
            primary: [hit("/a"), hit("/b"), hit("/c")],
            secondary: [hit("/d")],
            limit: 2)
        XCTAssertEqual(out, ["/a", "/b"])
    }

    func testTopFilesMergesOriginalAndExpansion() async {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmddocu-ret-\(UUID().uuidString)").appendingPathExtension("sqlite")
        let idx = SearchIndex(dbURL: url)
        await idx.upsert(path: "/d/a.md", filename: "a.md", body: "지방선거 결과", mtime: 1, ext: "md")
        await idx.upsert(path: "/d/b.md", filename: "b.md", body: "평가서 내용", mtime: 1, ext: "md")
        let retriever = RagRetriever(index: idx)
        // 원질문 "지방선거"는 a만, 확장 "평가서"가 b를 추가.
        let paths = await retriever.topFiles(question: "지방선거", expandedTerms: ["평가서"])
        XCTAssertEqual(Set(paths), ["/d/a.md", "/d/b.md"])
    }

    func testTopFilesRecoversMultiWordQuestionWithoutExpansion() async {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmddocu-ret2-\(UUID().uuidString)").appendingPathExtension("sqlite")
        let idx = SearchIndex(dbURL: url)
        // 문서엔 질문의 일부 단어만 있다 — 문장 전체 AND(primary)로는 안 잡힌다.
        await idx.upsert(path: "/d/a.md", filename: "a.md", body: "정의당 평가서 초안", mtime: 1, ext: "md")
        let retriever = RagRetriever(index: idx)
        // 확장 없이(expandedTerms=[]) 자연어 질문 → 원질문 토큰 OR로 회수돼야 한다.
        let paths = await retriever.topFiles(question: "정의당 평가서에 뭐라고 썼더라", expandedTerms: [])
        XCTAssertTrue(paths.contains("/d/a.md"))
    }
}
