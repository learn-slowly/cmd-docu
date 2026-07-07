import XCTest
@testable import CmdMD

@MainActor
final class AppFileOpsTests: XCTestCase {

    private var tempData: URL!
    private var work: URL!
    private var appState: AppState!

    override func setUpWithError() throws {
        tempData = TempDataDirectory.make()
        work = FileManager.default.temporaryDirectory
            .appendingPathComponent("fileops-app-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        appState = AppState(dataDirectory: tempData)
    }

    override func tearDown() {
        TempDataDirectory.cleanup(tempData)
        try? FileManager.default.removeItem(at: work)
        tempData = nil
        work = nil
        appState = nil
        super.tearDown()
    }

    private func makeFile(_ relative: String) throws -> URL {
        let url = work.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("본문".utf8).write(to: url)
        return url
    }

    /// 지정 URL을 보는 탭을 하나 만든다(createNewTab 후 fileURL 주입).
    private func openTab(at url: URL) -> EditorTab {
        appState.createNewTab()
        let index = appState.tabs.count - 1
        appState.tabs[index].fileURL = url
        appState.documents[appState.tabs[index].documentId]?.fileURL = url
        return appState.tabs[index]
    }

    // MARK: performRename

    func testPerformRenameUpdatesTabAndDocument() async throws {
        let old = try makeFile("문서.md")
        let tab = openTab(at: old)

        let newURL = try await appState.performRename(at: old, to: "바뀐이름.md")

        XCTAssertEqual(newURL.lastPathComponent, "바뀐이름.md")
        let updated = appState.tabs.first(where: { $0.id == tab.id })
        XCTAssertEqual(updated?.fileURL, newURL)
        XCTAssertEqual(appState.documents[tab.documentId]?.fileURL, newURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: newURL.path))
    }

    func testPerformRenameFolderRetargetsNestedTabsWithBoundary() async throws {
        // /work/폴더/안.md 는 재조준, 형제 /work/폴더X/밖.md 는 불변('/' 경계 — 8.5-②a 교훈)
        let inner = try makeFile("폴더/안.md")
        let sibling = try makeFile("폴더X/밖.md")
        let innerTab = openTab(at: inner)
        let siblingTab = openTab(at: sibling)

        let newFolder = try await appState.performRename(at: work.appendingPathComponent("폴더"), to: "새폴더")

        XCTAssertEqual(appState.tabs.first(where: { $0.id == innerTab.id })?.fileURL,
                       newFolder.appendingPathComponent("안.md"))
        XCTAssertEqual(appState.tabs.first(where: { $0.id == siblingTab.id })?.fileURL, sibling)
    }

    func testPerformRenameCoRenamesCompanionNote() async throws {
        let media = try makeFile("노래.mp3")
        let note = try makeFile("노래.mp3.md")

        let newURL = try await appState.performRename(at: media, to: "새노래.mp3")

        XCTAssertEqual(newURL.lastPathComponent, "새노래.mp3")
        XCTAssertFalse(FileManager.default.fileExists(atPath: note.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: work.appendingPathComponent("새노래.mp3.md").path))
        // 로그에 미디어·노트 두 건 모두 기록(각각 되돌리기 가능)
        let entries = await appState.fileOpsLogStore.load()
        XCTAssertEqual(entries.count, 2)
        XCTAssertTrue(entries.allSatisfy { $0.kind == .rename })
    }

    func testPerformRenameConflictThrowsAndLeavesStateIntact() async throws {
        let src = try makeFile("a.md")
        _ = try makeFile("b.md")
        let tab = openTab(at: src)
        let generationBefore = appState.fileOpsGeneration

        do {
            _ = try await appState.performRename(at: src, to: "b.md")
            XCTFail("충돌인데 성공")
        } catch let error as FileOperationError {
            XCTAssertEqual(error, .alreadyExists("b.md"))
        }

        XCTAssertEqual(appState.tabs.first(where: { $0.id == tab.id })?.fileURL, src)
        XCTAssertEqual(appState.fileOpsGeneration, generationBefore)
        let entries = await appState.fileOpsLogStore.load()
        XCTAssertTrue(entries.isEmpty)
    }

    func testPerformRenameBumpsGeneration() async throws {
        let src = try makeFile("g.md")
        let before = appState.fileOpsGeneration
        _ = try await appState.performRename(at: src, to: "g2.md")
        XCTAssertEqual(appState.fileOpsGeneration, before + 1)
    }

    // MARK: performTrash

    func testPerformTrashClosesTabsAndLogs() async throws {
        let folder = work.appendingPathComponent("버릴폴더")
        let inner = try makeFile("버릴폴더/안.md")
        let outside = try makeFile("남는.md")
        let innerTab = openTab(at: inner)
        let outsideTab = openTab(at: outside)

        let ok = await appState.performTrash(at: folder)
        guard ok else { throw XCTSkip("휴지통 접근 불가 환경") }

        XCTAssertNil(appState.tabs.first(where: { $0.id == innerTab.id }))
        XCTAssertNotNil(appState.tabs.first(where: { $0.id == outsideTab.id }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        let entries = await appState.fileOpsLogStore.load()
        XCTAssertEqual(entries.map(\.kind), [.trash])
        // 테스트 픽스처 정리 — 휴지통에 들어간 사본 제거
        if let trashed = entries.first?.resultURL {
            try? FileManager.default.removeItem(at: trashed)
        }
    }

    func testPerformTrashTakesCompanionNoteAlong() async throws {
        let media = try makeFile("영상.mp4")
        _ = try makeFile("영상.mp4.md")

        let ok = await appState.performTrash(at: media)
        guard ok else { throw XCTSkip("휴지통 접근 불가 환경") }

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: work.appendingPathComponent("영상.mp4.md").path))
        let entries = await appState.fileOpsLogStore.load()
        XCTAssertEqual(entries.count, 2)
        for entry in entries { try? FileManager.default.removeItem(at: entry.resultURL) }
    }

    // MARK: undo

    func testUndoFileOpRestoresAndBumpsGeneration() async throws {
        let src = try makeFile("복귀.md")
        _ = try await appState.performRename(at: src, to: "임시.md")
        // XCTUnwrap은 autoclosure라 인자 안에 await를 둘 수 없다 — 먼저 받아온다.
        let entries = await appState.fileOpsLogStore.load()
        let entry = try XCTUnwrap(entries.first)
        let before = appState.fileOpsGeneration

        let ok = await appState.undoFileOp(entry)

        XCTAssertTrue(ok)
        XCTAssertTrue(FileManager.default.fileExists(atPath: src.path))
        XCTAssertEqual(appState.fileOpsGeneration, before + 1)
    }

    /// rename 되돌리기 시 그 경로를 보던 열린 탭도 옛 경로로 재조준되어야 한다(발견 1).
    func testUndoRenameRetargetsOpenTab() async throws {
        let old = try makeFile("되돌림.md")
        let tab = openTab(at: old)
        let newURL = try await appState.performRename(at: old, to: "새이름.md")
        XCTAssertEqual(appState.tabs.first(where: { $0.id == tab.id })?.fileURL, newURL)

        let entries = await appState.fileOpsLogStore.load()
        let entry = try XCTUnwrap(entries.first)   // rename 1건
        let ok = await appState.undoFileOp(entry)

        XCTAssertTrue(ok)
        XCTAssertTrue(FileManager.default.fileExists(atPath: old.path))
        XCTAssertEqual(appState.tabs.first(where: { $0.id == tab.id })?.fileURL, old)
    }

    /// 폴더 rename 되돌리기 시 하위 경로 탭도 옛 경로로 재조준(발견 1).
    func testUndoFolderRenameRetargetsNestedTab() async throws {
        let inner = try makeFile("묶음/속.md")
        let innerTab = openTab(at: inner)
        let folder = work.appendingPathComponent("묶음")
        let newFolder = try await appState.performRename(at: folder, to: "새묶음")
        XCTAssertEqual(appState.tabs.first(where: { $0.id == innerTab.id })?.fileURL,
                       newFolder.appendingPathComponent("속.md"))

        let entries = await appState.fileOpsLogStore.load()
        let entry = try XCTUnwrap(entries.first)   // 폴더 rename 1건(폴더라 짝꿍 없음)
        let ok = await appState.undoFileOp(entry)

        XCTAssertTrue(ok)
        XCTAssertEqual(appState.tabs.first(where: { $0.id == innerTab.id })?.fileURL, inner)
    }

    // MARK: 미디어 짝꿍 노트 flush 게시 (발견 3)

    /// 짝꿍 노트가 있는 미디어를 rename 하면, 이동 전에 옛 미디어 URL로 flush 알림이 게시된다.
    func testMediaRenameWithNotePostsFlush() async throws {
        let media = try makeFile("곡.mp3")
        _ = try makeFile("곡.mp3.md")

        let exp = expectation(forNotification: .flushMediaCompanionNote, object: nil) { note in
            (note.object as? URL) == media
        }
        _ = try await appState.performRename(at: media, to: "새곡.mp3")
        await fulfillment(of: [exp], timeout: 1.0)
    }

    /// 짝꿍 노트가 없는 미디어 rename은 flush 알림을 게시하지 않는다(불필요한 게시 방지).
    func testMediaRenameWithoutNotePostsNoFlush() async throws {
        let media = try makeFile("외톨이.mp3")   // 짝꿍 노트 없음

        let exp = expectation(forNotification: .flushMediaCompanionNote, object: nil)
        exp.isInverted = true
        _ = try await appState.performRename(at: media, to: "새외톨이.mp3")
        await fulfillment(of: [exp], timeout: 0.5)
    }

    // MARK: createNewFolder 위임

    func testCreateNewFolderUsesKoreanDefaultAndBumpsGeneration() {
        let before = appState.fileOpsGeneration
        appState.createNewFolder(in: work)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: work.appendingPathComponent("새 폴더").path))
        XCTAssertEqual(appState.fileOpsGeneration, before + 1)
    }

    // MARK: companion 판별

    func testCompanionNoteForOperation() throws {
        let media = try makeFile("m.mp3")
        XCTAssertNil(AppState.companionNoteForOperation(mediaURL: media))   // 노트 없음
        _ = try makeFile("m.mp3.md")
        XCTAssertEqual(AppState.companionNoteForOperation(mediaURL: media),
                       work.appendingPathComponent("m.mp3.md"))
        let plain = try makeFile("일반.md")
        XCTAssertNil(AppState.companionNoteForOperation(mediaURL: plain))   // 미디어 아님
    }

    // MARK: 정보 보기 대상 규칙 (스펙 §7.2)

    func testShowFileInfoTargetInReaderMode() throws {
        let file = try makeFile("정보대상.md")
        appState.mainMode = .reader
        appState.fileInfoRequest = nil
        appState.showFileInfoForCurrentContext()
        XCTAssertNil(appState.fileInfoRequest)          // 탭 없음 → 비활성(무동작)

        _ = openTab(at: file)
        appState.activeTabId = appState.tabs.last?.id
        appState.showFileInfoForCurrentContext()
        XCTAssertEqual(appState.fileInfoRequest?.url, file)
    }

    func testShowFileInfoTargetInLibraryMode() {
        appState.mainMode = .library
        appState.currentFolder = work
        appState.selectedFolder = nil
        appState.showFileInfoForCurrentContext()
        XCTAssertEqual(appState.fileInfoRequest?.url, work)   // selectedFolder 없으면 currentFolder

        let sub = work.appendingPathComponent("하위")
        try? FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        appState.selectedFolder = sub
        appState.showFileInfoForCurrentContext()
        XCTAssertEqual(appState.fileInfoRequest?.url, sub)
    }

    // MARK: 짝꿍 노트 media: 필드 정합(co-rename 후 frontmatter 갱신)

    /// frontmatter media: 필드가 현재 미디어 이름을 가리키는 짝꿍 노트를 만든다.
    private func makeCompanionNote(for media: URL) throws -> URL {
        let note = CompanionNote.noteURL(for: media)
        let content = "---\nmedia: \(CompanionNote.yamlQuoted(media.lastPathComponent))\n"
            + "duration: \"3:41\"\nsummary: \"메모\"\ntags: []\n---\n\n# 제목\n\n본문\n"
        try Data(content.utf8).write(to: note)
        return note
    }

    func testPerformRenameSyncsCompanionMediaField() async throws {
        let media = try makeFile("노래.mp3")
        _ = try makeCompanionNote(for: media)

        _ = try await appState.performRename(at: media, to: "새노래.mp3")

        let content = try String(contentsOf: work.appendingPathComponent("새노래.mp3.md"),
                                 encoding: .utf8)
        XCTAssertTrue(content.contains("media: \"새노래.mp3\""), "media: 필드가 새 이름: \(content)")
        XCTAssertFalse(content.contains("media: \"노래.mp3\""))
        XCTAssertTrue(content.contains("summary: \"메모\""), "다른 필드는 보존")
    }

    func testUndoMediaRenameRestoresMediaFieldNewestFirst() async throws {
        let media = try makeFile("노래.mp3")
        _ = try makeCompanionNote(for: media)
        _ = try await appState.performRename(at: media, to: "새노래.mp3")

        // 기록 시트 관례(최신부터): 노트 엔트리 → 미디어 엔트리 순
        let entries = await appState.fileOpsLogStore.load()
        let noteEntry = try XCTUnwrap(entries.first { $0.originalURL.lastPathComponent == "노래.mp3.md" })
        let mediaEntry = try XCTUnwrap(entries.first { $0.originalURL.lastPathComponent == "노래.mp3" })
        let noteOk = await appState.undoFileOp(noteEntry)
        let mediaOk = await appState.undoFileOp(mediaEntry)
        XCTAssertTrue(noteOk && mediaOk)

        let content = try String(contentsOf: work.appendingPathComponent("노래.mp3.md"),
                                 encoding: .utf8)
        XCTAssertTrue(content.contains("media: \"노래.mp3\""), "undo 후 media: 원복: \(content)")
    }

    func testUndoMediaRenameRestoresMediaFieldMediaFirst() async throws {
        // 역순(미디어 먼저)이라도 쌍이 완성되는 나중 undo가 정합을 잡는다.
        let media = try makeFile("노래.mp3")
        _ = try makeCompanionNote(for: media)
        _ = try await appState.performRename(at: media, to: "새노래.mp3")

        let entries = await appState.fileOpsLogStore.load()
        let noteEntry = try XCTUnwrap(entries.first { $0.originalURL.lastPathComponent == "노래.mp3.md" })
        let mediaEntry = try XCTUnwrap(entries.first { $0.originalURL.lastPathComponent == "노래.mp3" })
        let mediaOk = await appState.undoFileOp(mediaEntry)
        let noteOk = await appState.undoFileOp(noteEntry)
        XCTAssertTrue(mediaOk && noteOk)

        let content = try String(contentsOf: work.appendingPathComponent("노래.mp3.md"),
                                 encoding: .utf8)
        XCTAssertTrue(content.contains("media: \"노래.mp3\""), "undo 후 media: 원복: \(content)")
    }

    func testUndoFolderRenameDoesNotTouchLookalikeNote() async throws {
        // 미디어 확장자 이름의 '폴더'를 rename→undo 해도, 옆의 동명 수기 노트는 불가침 —
        // undo 훅의 짝꿍 판별이 확장자만 보면 폴더를 미디어로 오인한다(적대적 리뷰 실행 재현).
        let folder = work.appendingPathComponent("데모.mp3")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let note = work.appendingPathComponent("데모.mp3.md")
        let original = "---\nmedia: \"다른것.mp3\"\n---\n수기 메모\n"
        try Data(original.utf8).write(to: note)

        _ = try await appState.performRename(at: folder, to: "새데모.mp3")
        let logged = await appState.fileOpsLogStore.load()
        let entry = try XCTUnwrap(logged.first)
        let ok = await appState.undoFileOp(entry)
        XCTAssertTrue(ok)

        XCTAssertEqual(try String(contentsOf: note, encoding: .utf8), original,
                       "작업에 포함되지 않은 수기 노트가 변조되면 안 된다")
    }

    func testUndoOrphanNoteRenameKeepsContent() async throws {
        // 고아 노트(대응 미디어 없음)=일반 노트 불가침 — rename→undo가 media: 필드를
        // 파일명 파생값으로 무단 교체하면 안 된다(undo 훅의 미디어 실재 검사 고정).
        let note = work.appendingPathComponent("외톨이.mp3.md")
        let original = "---\nmedia: \"다른곳/외톨이.mp3\"\n---\n고아 메모\n"
        try Data(original.utf8).write(to: note)

        _ = try await appState.performRename(at: note, to: "새외톨이.mp3.md")
        let logged = await appState.fileOpsLogStore.load()
        let entry = try XCTUnwrap(logged.first)
        let ok = await appState.undoFileOp(entry)
        XCTAssertTrue(ok)

        XCTAssertEqual(try String(contentsOf: note, encoding: .utf8), original,
                       "고아 노트 내용이 그대로여야 한다")
    }

    func testPerformRenameCompanionFailureLeavesOldNoteFieldIntact() async throws {
        // 파생 노트 이름이 선점돼 짝꿍 rename이 실패하면 옛 노트는 이름·내용 모두 그대로
        // (성공 경로에만 sync — 실패 경로에서 필드를 미리 바꾸면 옛 이름 노트가 새 이름을 가리킴).
        let media = try makeFile("노래.mp3")
        let note = try makeCompanionNote(for: media)
        _ = try makeFile("새노래.mp3.md")   // 짝꿍 rename 목적지 선점

        _ = try await appState.performRename(at: media, to: "새노래.mp3")

        let content = try String(contentsOf: note, encoding: .utf8)
        XCTAssertTrue(content.contains("media: \"노래.mp3\""), "실패한 동반 rename에서 필드 불변: \(content)")
        let entries = await appState.fileOpsLogStore.load()
        XCTAssertEqual(entries.count, 1, "실패한 짝꿍 rename은 로그되지 않는다")
    }
}
