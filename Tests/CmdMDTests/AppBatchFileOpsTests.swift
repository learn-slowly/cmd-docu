import XCTest
@testable import CmdMD

@MainActor
final class AppBatchFileOpsTests: XCTestCase {

    private var tempData: URL!
    private var work: URL!
    private var appState: AppState!

    override func setUpWithError() throws {
        tempData = TempDataDirectory.make()
        work = FileManager.default.temporaryDirectory
            .appendingPathComponent("batch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        appState = AppState(dataDirectory: tempData)
    }

    override func tearDown() {
        TempDataDirectory.cleanup(tempData)
        try? FileManager.default.removeItem(at: work)
        tempData = nil; work = nil; appState = nil
        super.tearDown()
    }

    private func makeFile(_ relative: String) throws -> URL {
        let url = work.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("본문".utf8).write(to: url)
        return url
    }

    private func makeFolder(_ relative: String) throws -> URL {
        let url = work.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func openTab(at url: URL) -> EditorTab {
        appState.createNewTab()
        let index = appState.tabs.count - 1
        appState.tabs[index].fileURL = url
        appState.documents[appState.tabs[index].documentId]?.fileURL = url
        return appState.tabs[index]
    }

    // MARK: 배치 이동

    func testBatchMoveMovesAllAndLogsOneBatch() async throws {
        let a = try makeFile("a.md"); let b = try makeFile("b.md")
        let dest = try makeFolder("대상")
        let result = await appState.performBatchMove(urls: [a, b], to: dest)
        XCTAssertEqual(result.succeeded, 2)
        XCTAssertEqual(result.failed, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.appendingPathComponent("a.md").path))
        let entries = await appState.fileOpsLogStore.load()
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(Set(entries.compactMap(\.batchId)).count, 1, "한 배치 = 한 batchId")
    }

    func testBatchMoveRetargetsOpenTabs() async throws {
        let a = try makeFile("a.md")
        let dest = try makeFolder("대상")
        let tab = openTab(at: a)
        _ = await appState.performBatchMove(urls: [a], to: dest)
        let updated = appState.tabs.first(where: { $0.id == tab.id })
        XCTAssertEqual(updated?.fileURL, dest.appendingPathComponent("a.md"))
    }

    func testBatchMoveSkipsItemsAlreadyInDestination() async throws {
        let dest = try makeFolder("대상")
        let inside = try makeFile("대상/이미.md")
        let outside = try makeFile("밖.md")
        let result = await appState.performBatchMove(urls: [inside, outside], to: dest)
        XCTAssertEqual(result.succeeded, 1, "이미 그 폴더에 있는 항목은 skip(실패 아님)")
        XCTAssertEqual(result.failed, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: inside.path), "제자리 항목 불변 — 복제 개명 없음")
        let entries = await appState.fileOpsLogStore.load()
        XCTAssertEqual(entries.count, 1)
    }

    func testBatchMoveNormalizesNestedSelection() async throws {
        // 부모 폴더와 그 자식이 함께 선택 — 조상만 이동, 자식은 따라간다(이중 이동 없음).
        let parent = try makeFolder("부모")
        let child = try makeFile("부모/자식.md")
        let dest = try makeFolder("대상")
        let result = await appState.performBatchMove(urls: [parent, child], to: dest)
        XCTAssertEqual(result.succeeded, 1)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: dest.appendingPathComponent("부모/자식.md").path))
        let entries = await appState.fileOpsLogStore.load()
        XCTAssertEqual(entries.count, 1, "자식은 별도 엔트리 없음")
    }

    func testBatchMoveCompanionNoteFollowsWithDerivedName() async throws {
        // 미디어 이동 시 짝꿍 노트 동반 + 본체 결과 이름 파생(스펙 §4.3 이름 규칙).
        let media = try makeFile("노래.mp3")
        let note = try makeFile("노래.mp3.md")
        let dest = try makeFolder("대상")
        // 목적지에 같은 이름 미디어를 미리 두어 본체가 uniquify되게 한다.
        _ = try makeFile("대상/노래.mp3")
        let result = await appState.performBatchMove(urls: [media], to: dest)
        XCTAssertEqual(result.succeeded, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: note.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: dest.appendingPathComponent("노래 (1).mp3.md").path),
            "노트는 본체 결과 이름(노래 (1).mp3)에서 파생 — 단순 uniquify(노래.mp3 (1).md) 금지")
        let entries = await appState.fileOpsLogStore.load()
        XCTAssertEqual(entries.count, 2, "본체+노트 각 1건, 같은 배치")
        XCTAssertEqual(Set(entries.compactMap(\.batchId)).count, 1)
    }

    func testBatchMoveCompanionNotDoubleProcessedWhenBothSelected() async throws {
        // 미디어와 그 짝꿍 노트가 둘 다 선택에 들어와도 노트는 한 번만 처리.
        let media = try makeFile("노래.mp3")
        let note = try makeFile("노래.mp3.md")
        let dest = try makeFolder("대상")
        _ = await appState.performBatchMove(urls: [media, note], to: dest)
        let entries = await appState.fileOpsLogStore.load()
        XCTAssertEqual(entries.count, 2, "본체 1 + 노트 1 — 노트 이중 엔트리 없음")
    }

    // MARK: 배치 복사

    func testBatchCopyKeepsOriginalsAndLogs() async throws {
        let a = try makeFile("a.md")
        let dest = try makeFolder("대상")
        let result = await appState.performBatchCopy(urls: [a], to: dest)
        XCTAssertEqual(result.succeeded, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.path), "원본 불변")
        let entries = await appState.fileOpsLogStore.load()
        XCTAssertEqual(entries.map(\.kind), [.copy])
    }

    // MARK: 배치 휴지통

    func testBatchTrashClosesTabsAndLogsOneBatch() async throws {
        let a = try makeFile("a.md"); let b = try makeFile("b.md")
        _ = openTab(at: a)
        let before = appState.tabs.count
        let result = await appState.performBatchTrash(urls: [a, b])
        XCTAssertEqual(result.succeeded, 2)
        XCTAssertEqual(appState.tabs.count, before - 1, "대상 탭 선닫기")
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.path))
        let entries = await appState.fileOpsLogStore.load()
        XCTAssertEqual(Set(entries.compactMap(\.batchId)).count, 1)
    }

    func testBatchTrashPartialFailureContinues() async throws {
        let a = try makeFile("a.md")
        let ghost = work.appendingPathComponent("없음.md")
        let result = await appState.performBatchTrash(urls: [a, ghost])
        XCTAssertEqual(result.succeeded, 1)
        XCTAssertEqual(result.failed, 1)
        XCTAssertNotNil(appState.errorMessage, "부분 실패 요약")
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.path), "실패와 무관하게 계속 진행")
    }

    // MARK: 배치 되돌리기

    func testUndoFileOpBatchRestoresAllAndRetargets() async throws {
        let a = try makeFile("a.md"); let b = try makeFile("b.md")
        let dest = try makeFolder("대상")
        _ = await appState.performBatchMove(urls: [a, b], to: dest)
        let movedA = dest.appendingPathComponent("a.md")
        let tab = openTab(at: movedA)
        let batchId = await appState.fileOpsLogStore.load().first!.batchId!

        let ok = await appState.undoFileOpBatch(batchId: batchId)
        XCTAssertTrue(ok)
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: b.path))
        let updated = appState.tabs.first(where: { $0.id == tab.id })
        XCTAssertEqual(updated?.fileURL, a, "move undo도 탭 재조준(.move 분기 필수)")
        let remaining = await appState.fileOpsLogStore.load()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testUndoSingleCopyClosesCopyTab() async throws {
        let a = try makeFile("a.md")
        let dest = try makeFolder("대상")
        _ = await appState.performBatchCopy(urls: [a], to: dest)
        let copied = dest.appendingPathComponent("a.md")
        _ = openTab(at: copied)
        let entry = await appState.fileOpsLogStore.load().first!
        let before = appState.tabs.count
        let ok = await appState.undoFileOp(entry)
        XCTAssertTrue(ok)
        XCTAssertEqual(appState.tabs.count, before - 1, "사본 탭 선닫기 후 사본 휴지통")
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.path))
    }
}
