import XCTest
@testable import CmdMD

final class SearchIndexerTests: XCTestCase {
    private func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("cmddocu-idxr-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    private func tempDBURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("cmddocu-idxr-\(UUID().uuidString).sqlite")
    }

    func testIndexFolderIndexesTextFilesAndSearches() async throws {
        let dir = tempDir()
        try "사과 바나나".write(to: dir.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
        try "포도 수박".write(to: dir.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        let index = SearchIndex(dbURL: tempDBURL())
        let indexer = SearchIndexer(index: index, kordoc: KordocService())
        await indexer.indexFolder(dir, progress: nil)
        // XCTAssertEqual은 autoclosure라 await를 직접 받지 못하므로 미리 추출.
        let count = await index.count()
        XCTAssertEqual(count, 2)
        let hits = await index.search(query: "바나나")
        // enumerator는 정규 경로(/private/var/...)를 반환하므로 기대값도 맞춰 준다.
        let expectedPath = (try? dir.appendingPathComponent("a.md")
            .resourceValues(forKeys: [.canonicalPathKey]).canonicalPath)
            ?? dir.appendingPathComponent("a.md").path
        XCTAssertEqual(hits.first?.path, expectedPath)
    }

    func testIndexFolderRemovesDeletedFiles() async throws {
        let dir = tempDir()
        let a = dir.appendingPathComponent("a.md")
        try "사과".write(to: a, atomically: true, encoding: .utf8)
        let index = SearchIndex(dbURL: tempDBURL())
        let indexer = SearchIndexer(index: index, kordoc: KordocService())
        await indexer.indexFolder(dir, progress: nil)
        let count1 = await index.count()
        XCTAssertEqual(count1, 1)
        try FileManager.default.removeItem(at: a)        // 파일 삭제
        await indexer.indexFolder(dir, progress: nil)    // 재인덱싱 → 사라진 파일 제거
        let count2 = await index.count()
        XCTAssertEqual(count2, 0)
    }

    func testReindexSingleFileAndDeletion() async throws {
        let dir = tempDir()
        let a = dir.appendingPathComponent("a.md")
        try "사과".write(to: a, atomically: true, encoding: .utf8)
        let index = SearchIndex(dbURL: tempDBURL())
        let indexer = SearchIndexer(index: index, kordoc: KordocService())
        await indexer.reindex(path: a.path)
        let count1 = await index.count()
        XCTAssertEqual(count1, 1)
        try FileManager.default.removeItem(at: a)
        await indexer.reindex(path: a.path)              // 삭제된 파일 → remove
        let count2 = await index.count()
        XCTAssertEqual(count2, 0)
    }
}
