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
}
