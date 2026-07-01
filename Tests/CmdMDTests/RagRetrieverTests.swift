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

    func testTopFilesRecoversMixedLengthKoreanQuestion() async {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmddocu-ret4-\(UUID().uuidString)").appendingPathExtension("sqlite")
        let idx = SearchIndex(dbURL: url)
        await idx.upsert(path: "/d/a.md", filename: "a.md", body: "지방선거 결과 분석", mtime: 1, ext: "md")
        // "지방선거 결과" → 토큰 [지방선거(4), 결과(2)] 혼합. 확장 없이도 .or 백스톱이 회수해야 한다(C1 회귀).
        let paths = await RagRetriever(index: idx).topFiles(question: "지방선거 결과", expandedTerms: [])
        XCTAssertTrue(paths.contains("/d/a.md"))
    }

    // 회귀 가드(RED 아님): trigram이라 "평가서"→"평가서에" 부분일치가 리팩터 전후 모두 통과한다.
    func testTopFilesMatchesKoreanParticleSubstring() async {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmddocu-ret3-\(UUID().uuidString)").appendingPathExtension("sqlite")
        let idx = SearchIndex(dbURL: url)
        // 문서엔 조사 붙은 "평가서에". 질의는 bare "평가서"(3글자) → 부분일치로 회수.
        await idx.upsert(path: "/d/p.md", filename: "p.md", body: "정의당 평가서에 총평", mtime: 1, ext: "md")
        let paths = await RagRetriever(index: idx).topFiles(question: "평가서", expandedTerms: [])
        XCTAssertTrue(paths.contains("/d/p.md"))
    }
}
