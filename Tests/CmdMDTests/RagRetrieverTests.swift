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
}
