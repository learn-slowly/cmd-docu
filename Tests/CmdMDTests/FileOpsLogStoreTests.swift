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
}
