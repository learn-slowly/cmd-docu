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

    // MARK: - Bug 1: 부분 undo 실패 시 로그 보존

    /// undo 도중 복원 대상 파일이 없으면(failed > 0) 배치가 로그에서 제거되지 않아야 한다.
    func testPartialUndoFailureKeepsBatchInLog() async {
        let root = tempDir(); defer { try? FileManager.default.removeItem(at: root) }
        let src = write("보고서.pdf", in: root)
        let scheme = [CleanupBucket(id: "문서", name: "문서", hint: "", relativePath: "문서")]
        let move = CleanupMove(id: UUID(), source: src, bucketId: "문서", reason: "x", confidence: 0.9, approved: true)
        let store = MoveLogStore(directory: root)
        let exec = MoveExecutor(store: store)

        let outcome = await exec.apply(plan: plan(scheme: scheme, moves: [move]), mode: .subfolder(root: root))
        XCTAssertEqual(outcome.moved, 1)

        // 이동된 파일을 직접 삭제해 undo 복원이 실패하도록 만든다.
        try? FileManager.default.removeItem(at: outcome.batch.records[0].to)

        let result = await exec.undo(outcome.batch)
        XCTAssertEqual(result.restored, 0)
        XCTAssertEqual(result.failed, 1)

        // 실패가 있었으므로 배치 로그는 여전히 남아 있어야 한다.
        let remaining = await store.load()
        XCTAssertTrue(remaining.contains(where: { $0.id == outcome.batch.id }),
                      "부분 undo 실패 시 배치 로그가 삭제되면 안 됩니다")
    }

    // MARK: - Bug 2: 중간 디렉터리 생성 후 undo 시 고아 폴더 없음

    /// 중첩 relativePath("a/b")로 이동 후 undo하면 a/b도 a도 남지 않아야 한다.
    func testNestedRelativePathLeavesNoOrphanAfterUndo() async {
        let root = tempDir(); defer { try? FileManager.default.removeItem(at: root) }
        let src = write("회의록.txt", in: root)

        // a/b 모두 사전에 없음을 확인.
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("a").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("a/b").path))

        let scheme = [CleanupBucket(id: "ab", name: "ab", hint: "", relativePath: "a/b")]
        let move = CleanupMove(id: UUID(), source: src, bucketId: "ab", reason: "", confidence: 1, approved: true)
        let store = MoveLogStore(directory: root)
        let exec = MoveExecutor(store: store)

        let outcome = await exec.apply(plan: plan(scheme: scheme, moves: [move]), mode: .subfolder(root: root))
        XCTAssertEqual(outcome.moved, 1)
        // 파일이 root/a/b/<name>에 있어야 한다.
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("a/b/회의록.txt").path))

        let result = await exec.undo(outcome.batch)
        XCTAssertEqual(result.restored, 1)

        // 파일이 원위치에 돌아와야 한다.
        XCTAssertTrue(FileManager.default.fileExists(atPath: src.path))

        // 중간 폴더 a/b와 a가 모두 제거되어야 한다(고아 폴더 없음).
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("a/b").path),
                       "undo 후 a/b 폴더가 남으면 안 됩니다")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("a").path),
                       "undo 후 중간 폴더 a가 남으면 안 됩니다")
    }
}
