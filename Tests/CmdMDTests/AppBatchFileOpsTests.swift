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

    // MARK: 짝꿍 노트 media: 필드 정합(F1b 배치 — uniquify 개명·사본)

    /// frontmatter media: 필드가 현재 미디어 이름을 가리키는 짝꿍 노트를 만든다.
    private func makeCompanionNote(for media: URL) throws -> URL {
        let note = CompanionNote.noteURL(for: media)
        let content = "---\nmedia: \(CompanionNote.yamlQuoted(media.lastPathComponent))\n"
            + "duration: \"3:41\"\nsummary: \"메모\"\ntags: []\n---\n\n# 제목\n\n본문\n"
        try Data(content.utf8).write(to: note)
        return note
    }

    func testBatchMoveUniquifySyncsCompanionMediaField() async throws {
        let media = try makeFile("노래.mp3")
        _ = try makeCompanionNote(for: media)
        let dest = try makeFolder("대상")
        _ = try makeFile("대상/노래.mp3")   // 선점 → 이동 시 본체 uniquify 개명

        _ = await appState.performBatchMove(urls: [media], to: dest)

        let entries = await appState.fileOpsLogStore.load()
        let movedMedia = try XCTUnwrap(entries.first {
            $0.kind == .move && $0.originalURL.lastPathComponent == "노래.mp3"
        }).resultURL
        XCTAssertNotEqual(movedMedia.lastPathComponent, "노래.mp3", "선점으로 개명돼야 전제 성립")
        let content = try String(contentsOf: CompanionNote.noteURL(for: movedMedia),
                                 encoding: .utf8)
        XCTAssertTrue(content.contains("media: \(CompanionNote.yamlQuoted(movedMedia.lastPathComponent))"),
                      "media: 필드가 개명된 이름: \(content)")
    }

    func testBatchCopySyncsCopiedNoteAndKeepsOriginal() async throws {
        let media = try makeFile("노래.mp3")
        let note = try makeCompanionNote(for: media)

        // 같은 폴더 복사 = 사본(본체 uniquify 개명)
        _ = await appState.performBatchCopy(urls: [media], to: work)

        let entries = await appState.fileOpsLogStore.load()
        let copiedMedia = try XCTUnwrap(entries.first {
            $0.kind == .copy && $0.originalURL.lastPathComponent == "노래.mp3"
        }).resultURL
        XCTAssertNotEqual(copiedMedia.lastPathComponent, "노래.mp3")
        let copiedContent = try String(contentsOf: CompanionNote.noteURL(for: copiedMedia),
                                       encoding: .utf8)
        XCTAssertTrue(copiedContent.contains("media: \(CompanionNote.yamlQuoted(copiedMedia.lastPathComponent))"),
                      "사본 노트는 사본 이름: \(copiedContent)")
        let originalContent = try String(contentsOf: note, encoding: .utf8)
        XCTAssertTrue(originalContent.contains("media: \"노래.mp3\""), "원본 노트 불변")
    }

    func testUndoBatchMoveRestoresMediaField() async throws {
        // uniquify 개명 이동 배치를 통째로 되돌리면 media: 필드도 원 이름으로 복귀
        let media = try makeFile("노래.mp3")
        _ = try makeCompanionNote(for: media)
        let dest = try makeFolder("대상")
        _ = try makeFile("대상/노래.mp3")
        _ = await appState.performBatchMove(urls: [media], to: dest)
        let logged = await appState.fileOpsLogStore.load()
        let batchId = try XCTUnwrap(logged.first?.batchId)

        let ok = await appState.undoFileOpBatch(batchId: batchId)
        XCTAssertTrue(ok)

        let content = try String(contentsOf: work.appendingPathComponent("노래.mp3.md"),
                                 encoding: .utf8)
        XCTAssertTrue(content.contains("media: \"노래.mp3\""), "배치 undo 후 media: 원복: \(content)")
    }

    func testBatchMoveNoteAlignFailureKeepsBodyNameInField() async throws {
        // 파생 노트 이름이 목적지에 선점돼 이름 정렬이 실패하면 노트는 uniquify 이름으로
        // 남고, media: 필드는 본체(미디어) 실제 이름을 가리킨다 — 파일명 규칙상 고아가 된
        // 노트가 원 미디어를 되찾을 단서로서 의도된 시맨틱(스펙 §4.3 연결 끊김 기록과 짝).
        let media = try makeFile("노래.mp3")
        _ = try makeCompanionNote(for: media)
        let dest = try makeFolder("대상")
        _ = try makeFile("대상/노래.mp3.md")   // 노트 파생명만 선점(미디어는 미선점)

        _ = await appState.performBatchMove(urls: [media], to: dest)

        let entries = await appState.fileOpsLogStore.load()
        let movedNote = try XCTUnwrap(entries.first {
            $0.kind == .move && $0.originalURL.lastPathComponent == "노래.mp3.md"
        }).resultURL
        XCTAssertNotEqual(movedNote.lastPathComponent, "노래.mp3.md", "정렬 실패로 uniquify 이름 잔존")
        let content = try String(contentsOf: movedNote, encoding: .utf8)
        XCTAssertTrue(content.contains("media: \"노래.mp3\""),
                      "필드는 본체 실제 이름 유지: \(content)")
    }

    func testUndoBatchPartialFailureKeepsNoteContent() async throws {
        // 배치 undo 부분 실패: 미디어 원경로가 선점돼 미디어 복원만 실패해도, 복원된
        // 노트의 내용은 변조되지 않는다(쌍 미완성 — 훅이 잘못된 이름을 쓰면 안 된다).
        let media = try makeFile("노래.mp3")
        _ = try makeCompanionNote(for: media)
        let dest = try makeFolder("대상")
        _ = await appState.performBatchMove(urls: [media], to: dest)
        let logged = await appState.fileOpsLogStore.load()
        let batchId = try XCTUnwrap(logged.first?.batchId)
        _ = try makeFile("노래.mp3")   // 미디어 원경로 선점 → 미디어 복원 실패 유도

        let ok = await appState.undoFileOpBatch(batchId: batchId)
        XCTAssertFalse(ok, "미디어 복원 실패 → 부분 실패")

        let content = try String(contentsOf: work.appendingPathComponent("노래.mp3.md"),
                                 encoding: .utf8)
        XCTAssertTrue(content.contains("media: \"노래.mp3\""), "복원된 노트 내용 불변: \(content)")
        XCTAssertTrue(content.contains("summary: \"메모\""))
    }
}
