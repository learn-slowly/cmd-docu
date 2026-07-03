import XCTest
@testable import CmdMD

final class FileOpsLogStoreTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fileopslog-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        dir = nil
        super.tearDown()
    }

    private func makeFile(_ name: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data("본문".utf8).write(to: url)
        return url
    }

    func testAppendThenLoadRoundTrip() async throws {
        let store = FileOpsLogStore(directory: dir)
        let entry = FileOpEntry(kind: .rename,
                                originalURL: dir.appendingPathComponent("a.md"),
                                resultURL: dir.appendingPathComponent("b.md"))
        await store.append(entry)
        let loaded = await store.load()
        XCTAssertEqual(loaded, [entry])
    }

    func testLoadEmptyWhenNoFile() async {
        let store = FileOpsLogStore(directory: dir)
        let loaded = await store.load()
        XCTAssertTrue(loaded.isEmpty)
    }

    func testUndoRenameMovesBackAndRemovesEntry() async throws {
        // rename을 실제 수행한 상황을 재현: b.md만 존재, 로그는 a→b.
        let original = dir.appendingPathComponent("a.md")
        let renamed = try makeFile("b.md")
        let store = FileOpsLogStore(directory: dir)
        let entry = FileOpEntry(kind: .rename, originalURL: original, resultURL: renamed)
        await store.append(entry)

        let ok = await store.undo(entry)

        XCTAssertTrue(ok)
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: renamed.path))
        let remaining = await store.load()
        XCTAssertTrue(remaining.isEmpty)   // 성공한 엔트리는 제거
    }

    func testUndoFailsWhenOriginalOccupied() async throws {
        // 원위치에 다른 항목이 생겼으면 덮어쓰지 않고 실패, 로그 보존.
        let original = try makeFile("a.md")           // 점유자
        let renamed = try makeFile("b.md")
        let store = FileOpsLogStore(directory: dir)
        let entry = FileOpEntry(kind: .rename, originalURL: original, resultURL: renamed)
        await store.append(entry)

        let ok = await store.undo(entry)

        XCTAssertFalse(ok)
        XCTAssertTrue(FileManager.default.fileExists(atPath: renamed.path))   // 결과물 불변
        let remaining = await store.load()
        XCTAssertEqual(remaining, [entry])            // 실패한 엔트리는 보존
    }

    func testUndoFailsWhenResultMissing() async {
        // 휴지통이 비워졌거나 결과물이 사라진 경우.
        let store = FileOpsLogStore(directory: dir)
        let entry = FileOpEntry(kind: .trash,
                                originalURL: dir.appendingPathComponent("a.md"),
                                resultURL: dir.appendingPathComponent("휴지통에없음.md"))
        await store.append(entry)

        let ok = await store.undo(entry)

        XCTAssertFalse(ok)
        let remaining = await store.load()
        XCTAssertEqual(remaining, [entry])
    }

    func testUndoRealTrashRoundTrip() async throws {
        // 스펙 §5: 생성→trash→undo 복귀 통합 확인. 휴지통 접근 불가 환경이면 스킵.
        let src = try makeFile("왕복.md")
        let trashed: URL
        do {
            trashed = try FileOperations.trash(at: src)
        } catch {
            throw XCTSkip("휴지통 접근 불가 환경: \(error)")
        }
        let store = FileOpsLogStore(directory: dir)
        let entry = FileOpEntry(kind: .trash, originalURL: src, resultURL: trashed)
        await store.append(entry)

        let ok = await store.undo(entry)

        XCTAssertTrue(ok)
        XCTAssertTrue(FileManager.default.fileExists(atPath: src.path))
    }

    // MARK: F1b — batchId·배치

    func testDecodesLegacyEntriesWithoutBatchId() async throws {
        // F1a 시절 로그(batchId 필드 없음)가 그대로 읽혀야 한다 — 옵셔널 하위호환.
        let legacy = """
        [{"id":"11111111-1111-1111-1111-111111111111","kind":"rename",
          "originalURL":"file:///tmp/a.md","resultURL":"file:///tmp/b.md",
          "date":712345678.0}]
        """.replacingOccurrences(of: "\n", with: "")
        try Data(legacy.utf8).write(to: dir.appendingPathComponent("fileops-log.json"))
        let store = FileOpsLogStore(directory: dir)
        let loaded = await store.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertNil(loaded[0].batchId)
    }

    func testAppendBatchWritesAllEntries() async throws {
        let store = FileOpsLogStore(directory: dir)
        let batchId = UUID()
        let a = FileOpEntry(kind: .move, originalURL: URL(fileURLWithPath: "/tmp/a"),
                            resultURL: URL(fileURLWithPath: "/tmp/x/a"), batchId: batchId)
        let b = FileOpEntry(kind: .move, originalURL: URL(fileURLWithPath: "/tmp/b"),
                            resultURL: URL(fileURLWithPath: "/tmp/x/b"), batchId: batchId)
        await store.appendBatch([a, b])
        let loaded = await store.load()
        XCTAssertEqual(loaded.map(\.id), [a.id, b.id])
        XCTAssertEqual(loaded.compactMap(\.batchId), [batchId, batchId])
    }

    func testUndoBatchReversesInOrderAndRemovesSucceeded() async throws {
        // move 2건: b를 a 안으로, 그 다음 a를 dest로 — 역순(a 먼저 복원)이 아니면 b 복원이 실패한다.
        let fm = FileManager.default
        let root = dir.appendingPathComponent("undo-root")
        let folderA = root.appendingPathComponent("a")
        let dest = root.appendingPathComponent("dest")
        try fm.createDirectory(at: folderA, withIntermediateDirectories: true)
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        let fileB = root.appendingPathComponent("b.md")
        try Data("b".utf8).write(to: fileB)

        // 실행: b.md → a/b.md, 그 다음 a → dest/a (b는 dest/a/b.md가 됨)
        let movedB = try FileOperations.move(at: fileB, to: folderA)
        let movedA = try FileOperations.move(at: folderA, to: dest)

        let store = FileOpsLogStore(directory: dir)
        let batchId = UUID()
        // 연산 시점 경로로 기록(실제 로깅과 동일 — 각 연산 직후 FileOperations 반환 URL).
        // entryB.resultURL = root/a/b.md는 a가 dest로 간 지금은 존재하지 않으므로,
        // 역순(entryA 먼저 unwind)이 아니면 entryB 복원이 실패한다.
        let entryB = FileOpEntry(kind: .move, originalURL: fileB, resultURL: movedB, batchId: batchId)
        let entryA = FileOpEntry(kind: .move, originalURL: folderA, resultURL: movedA, batchId: batchId)
        await store.appendBatch([entryB, entryA])

        let result = await store.undoBatch(batchId: batchId)
        XCTAssertEqual(result.succeeded.count, 2)
        XCTAssertTrue(result.failed.isEmpty)
        XCTAssertTrue(fm.fileExists(atPath: fileB.path), "b.md가 원위치로")
        XCTAssertTrue(fm.fileExists(atPath: folderA.path), "a가 원위치로")
        let remaining = await store.load()
        XCTAssertTrue(remaining.isEmpty, "성공분은 로그에서 제거")
    }

    func testUndoBatchKeepsFailedEntries() async throws {
        let fm = FileManager.default
        let root = dir.appendingPathComponent("fail-root")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let store = FileOpsLogStore(directory: dir)
        let batchId = UUID()
        // resultURL이 실재하지 않는 유령 엔트리 — undo 실패해야 함.
        let ghost = FileOpEntry(kind: .move, originalURL: root.appendingPathComponent("g.md"),
                                resultURL: root.appendingPathComponent("없음.md"), batchId: batchId)
        await store.appendBatch([ghost])
        let result = await store.undoBatch(batchId: batchId)
        XCTAssertEqual(result.failed.map(\.id), [ghost.id])
        let remaining = await store.load()
        XCTAssertEqual(remaining.map(\.id), [ghost.id], "실패분은 보존")
    }

    func testUndoCopyTrashesTheCopy() async throws {
        // copy 되돌리기 = 사본을 휴지통으로(영구 삭제 없음 정책) — 원본은 불변.
        let fm = FileManager.default
        let root = dir.appendingPathComponent("copy-root")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let original = root.appendingPathComponent("원본.md")
        try Data("원본".utf8).write(to: original)
        let copyDest = root.appendingPathComponent("사본지")
        try fm.createDirectory(at: copyDest, withIntermediateDirectories: true)
        let copied = try FileOperations.copy(at: original, to: copyDest)

        let store = FileOpsLogStore(directory: dir)
        let entry = FileOpEntry(kind: .copy, originalURL: original, resultURL: copied)
        await store.append(entry)
        let ok = await store.undo(entry)
        XCTAssertTrue(ok)
        XCTAssertFalse(fm.fileExists(atPath: copied.path), "사본은 휴지통으로")
        XCTAssertTrue(fm.fileExists(atPath: original.path), "원본 불변")
        let remaining = await store.load()
        XCTAssertTrue(remaining.isEmpty)
    }
}
