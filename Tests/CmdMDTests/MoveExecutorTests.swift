import XCTest
@testable import CmdMD

final class MoveExecutorTests: XCTestCase {
    private func tempDir() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mv-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private func write(_ name: String, in dir: URL) -> URL {
        let url = dir.appendingPathComponent(name)
        try? "x".write(to: url, atomically: true, encoding: .utf8)
        return url
    }
    private func plan(scheme: CleanupScheme, moves: [CleanupMove]) -> CleanupPlan {
        CleanupPlan(scheme: scheme, moves: moves)
    }

    func testApplyMovesApprovedFilesAndLogsBatch() async {
        let root = tempDir(); defer { try? FileManager.default.removeItem(at: root) }
        let src = write("세금.pdf", in: root)
        let scheme = [CleanupBucket(id: "문서", name: "문서", hint: "", relativePath: "문서")]
        let move = CleanupMove(id: UUID(), source: src, bucketId: "문서", reason: "x", confidence: 0.9, approved: true)
        let store = MoveLogStore(directory: root)
        let exec = MoveExecutor(store: store)

        let outcome = await exec.apply(plan: plan(scheme: scheme, moves: [move]), mode: .subfolder(root: root))

        XCTAssertEqual(outcome.moved, 1)
        XCTAssertTrue(outcome.failed.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: src.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("문서/세금.pdf").path))
        let loaded = await store.load()
        XCTAssertEqual(loaded.count, 1)
    }

    func testUnapprovedAndUnclassifiedNotMoved() async {
        let root = tempDir(); defer { try? FileManager.default.removeItem(at: root) }
        let src1 = write("a.png", in: root)
        let src2 = write("b.txt", in: root)
        let scheme = [CleanupBucket(id: "img", name: "img", hint: "", relativePath: "img")]
        let m1 = CleanupMove(id: UUID(), source: src1, bucketId: "img", reason: "", confidence: 0.9, approved: false)
        let m2 = CleanupMove(id: UUID(), source: src2, bucketId: "", reason: "", confidence: 0.1, approved: true)
        let exec = MoveExecutor(store: MoveLogStore(directory: root))
        let outcome = await exec.apply(plan: plan(scheme: scheme, moves: [m1, m2]), mode: .subfolder(root: root))
        XCTAssertEqual(outcome.moved, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: src1.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: src2.path))
    }

    func testCollisionUniquifiesNoOverwrite() async {
        let root = tempDir(); defer { try? FileManager.default.removeItem(at: root) }
        // 목적지에 동명 파일을 미리 둔다
        let destDir = root.appendingPathComponent("문서")
        try? FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        try? "old".write(to: destDir.appendingPathComponent("x.pdf"), atomically: true, encoding: .utf8)
        let src = write("x.pdf", in: root)
        let scheme = [CleanupBucket(id: "문서", name: "문서", hint: "", relativePath: "문서")]
        let move = CleanupMove(id: UUID(), source: src, bucketId: "문서", reason: "", confidence: 1, approved: true)
        let exec = MoveExecutor(store: MoveLogStore(directory: root))
        let outcome = await exec.apply(plan: plan(scheme: scheme, moves: [move]), mode: .subfolder(root: root))
        XCTAssertEqual(outcome.moved, 1)
        // 기존 x.pdf는 그대로, 새 파일은 uniquify된 이름으로
        XCTAssertEqual(try? String(contentsOf: destDir.appendingPathComponent("x.pdf"), encoding: .utf8), "old")
        let count = (try? FileManager.default.contentsOfDirectory(atPath: destDir.path))?.count
        XCTAssertEqual(count, 2)
    }

    func testUndoRestoresFilesAndRemovesCreatedEmptyDir() async {
        let root = tempDir(); defer { try? FileManager.default.removeItem(at: root) }
        let src = write("세금.pdf", in: root)
        let scheme = [CleanupBucket(id: "문서", name: "문서", hint: "", relativePath: "문서")]
        let move = CleanupMove(id: UUID(), source: src, bucketId: "문서", reason: "", confidence: 1, approved: true)
        let exec = MoveExecutor(store: MoveLogStore(directory: root))
        let outcome = await exec.apply(plan: plan(scheme: scheme, moves: [move]), mode: .subfolder(root: root))

        let result = await exec.undo(outcome.batch)
        XCTAssertEqual(result.restored, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: src.path)) // 원위치 복귀
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("문서").path)) // 빈 생성폴더 제거
    }

    func testEscapingBucketIsFailedNotMoved() async {
        let root = tempDir(); defer { try? FileManager.default.removeItem(at: root) }
        let src = write("x.txt", in: root)
        let scheme = [CleanupBucket(id: "e", name: "e", hint: "", relativePath: "../../etc")]
        let move = CleanupMove(id: UUID(), source: src, bucketId: "e", reason: "", confidence: 1, approved: true)
        let exec = MoveExecutor(store: MoveLogStore(directory: root))
        let outcome = await exec.apply(plan: plan(scheme: scheme, moves: [move]), mode: .subfolder(root: root))
        XCTAssertEqual(outcome.moved, 0)
        XCTAssertEqual(outcome.failed, [src])
        XCTAssertTrue(FileManager.default.fileExists(atPath: src.path))
    }
}
