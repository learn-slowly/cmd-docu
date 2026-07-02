import XCTest
@testable import CmdMD

final class AppClaudeTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = TempDataDirectory.make()
    }

    override func tearDown() {
        TempDataDirectory.cleanup(tempDir)
        tempDir = nil
        super.tearDown()
    }

    func testContextPrefersSelectionWhenPresent() {
        let r = AppState.claudeContext(selection: "선택한 문장", markdown: "전체 본문", officeMarkdown: nil)
        XCTAssertEqual(r, "선택한 문장")
    }

    func testContextFallsBackToMarkdownWhenNoSelection() {
        let r = AppState.claudeContext(selection: "   ", markdown: "전체 본문", officeMarkdown: nil)
        XCTAssertEqual(r, "전체 본문")
    }

    func testContextUsesOfficeMarkdownWhenNoSelectionOrMarkdown() {
        let r = AppState.claudeContext(selection: "", markdown: nil, officeMarkdown: "# 한글 문서")
        XCTAssertEqual(r, "# 한글 문서")
    }

    func testContextEmptyWhenNothingAvailable() {
        let r = AppState.claudeContext(selection: "", markdown: nil, officeMarkdown: nil)
        XCTAssertEqual(r, "")
    }

    func testErrorMessageMapsToolNotFound() {
        let m = AppState.claudeErrorMessage(ClaudeError.toolNotFound)
        XCTAssertTrue(m.contains("claude"))
    }

    func testErrorMessageMapsNotLoggedIn() {
        let m = AppState.claudeErrorMessage(ClaudeError.notLoggedIn)
        XCTAssertTrue(m.contains("로그인"))
    }

    func testErrorMessageMapsCreditExhausted() {
        let m = AppState.claudeErrorMessage(ClaudeError.creditExhausted)
        XCTAssertTrue(m.contains("크레딧") || m.contains("사용량"))
    }

    func testAskClaudeShortcutExistsWithDefaultBinding() {
        XCTAssertTrue(AppShortcut.allCases.contains(.askClaude))
        let b = AppShortcut.askClaude.defaultBinding
        XCTAssertEqual(b.key, "a")
        XCTAssertTrue(b.command)
        XCTAssertTrue(b.shift)
    }

    func testAskClaudeShortcutHasTitle() {
        XCTAssertFalse(AppShortcut.askClaude.title.isEmpty)
    }

    func testSelectionUsedForMarkdownKind() {
        XCTAssertEqual(AppState.claudeSelection(forKind: .markdown, selection: "선택"), "선택")
    }

    func testSelectionIgnoredForOfficeKind() {
        XCTAssertEqual(AppState.claudeSelection(forKind: .office, selection: "선택"), "")
    }

    func testSelectionIgnoredForPdfKind() {
        XCTAssertEqual(AppState.claudeSelection(forKind: .pdf, selection: "선택"), "")
    }

    func testContextUsesMediaNoteWhenOthersEmpty() {
        let ctx = AppState.claudeContext(selection: "", markdown: nil, officeMarkdown: nil, mediaNote: "노트 본문")
        XCTAssertEqual(ctx, "노트 본문")
    }

    func testMediaNoteIgnoredWhenMarkdownPresent() {
        let ctx = AppState.claudeContext(selection: "", markdown: "md", officeMarkdown: nil, mediaNote: "노트")
        XCTAssertEqual(ctx, "md")
    }

    // MARK: - Task 11: 응답 저장(본문 삽입 + 노트로 저장)

    func testNoteTitleFromPromptTrimsAndCaps() {
        XCTAssertEqual(AppState.noteTitle(fromPrompt: "  이 문서를\n요약해줘  "), "이 문서를 요약해줘")
        XCTAssertEqual(AppState.noteTitle(fromPrompt: ""), "Claude 응답")
        XCTAssertEqual(AppState.noteTitle(fromPrompt: String(repeating: "가", count: 60)).count, 40)
    }

    @MainActor
    func testInsertClaudeResponseAppendsToContentInPreviewMode() {
        let app = AppState(dataDirectory: tempDir)
        let tab = EditorTab(kind: .markdown)
        app.tabs = [tab]
        app.activeTabId = tab.id
        app.documents[tab.documentId] = MarkdownDocument(content: "본문")
        app.viewMode = .preview
        app.claudeResponse = "응답 내용"

        app.insertClaudeResponseIntoCurrentNote()

        XCTAssertEqual(app.currentDocument?.content, "본문\n\n응답 내용\n")
    }

    @MainActor
    func testInsertClaudeResponsePostsNotificationInSourceMode() {
        let app = AppState(dataDirectory: tempDir)
        let tab = EditorTab(kind: .markdown)
        app.tabs = [tab]
        app.activeTabId = tab.id
        app.documents[tab.documentId] = MarkdownDocument(content: "본문")
        app.viewMode = .source
        app.claudeResponse = "응답 내용"

        let expectation = expectation(forNotification: .insertClaudeResponse, object: nil) { note in
            (note.object as? String) == "\n\n응답 내용\n"
        }

        app.insertClaudeResponseIntoCurrentNote()

        wait(for: [expectation], timeout: 1)
        // 알림으로 위임했을 뿐, AppState가 직접 본문을 바꾸지는 않는다(실제 삽입은 Coordinator 몫).
        XCTAssertEqual(app.currentDocument?.content, "본문")
    }

    @MainActor
    func testInsertClaudeResponseNoOpWhenNotMarkdownKind() {
        let app = AppState(dataDirectory: tempDir)
        let tab = EditorTab(kind: .office)
        app.tabs = [tab]
        app.activeTabId = tab.id
        app.documents[tab.documentId] = MarkdownDocument(content: "원본")
        app.claudeResponse = "응답"

        app.insertClaudeResponseIntoCurrentNote()

        XCTAssertEqual(app.currentDocument?.content, "원본")
    }

    @MainActor
    func testInsertClaudeResponseNoOpWhenResponseEmpty() {
        let app = AppState(dataDirectory: tempDir)
        let tab = EditorTab(kind: .markdown)
        app.tabs = [tab]
        app.activeTabId = tab.id
        app.documents[tab.documentId] = MarkdownDocument(content: "원본")
        app.claudeResponse = nil

        app.insertClaudeResponseIntoCurrentNote()

        XCTAssertEqual(app.currentDocument?.content, "원본")
    }

    @MainActor
    func testSaveClaudeResponseAsNoteSetsErrorWhenNoVault() async {
        let app = AppState(dataDirectory: tempDir)
        app.claudeResponse = "응답"

        await app.saveClaudeResponseAsNote()

        XCTAssertEqual(app.claudeError, "저장할 볼트가 없습니다. Vault Manager에서 볼트를 먼저 등록해 주세요.")
    }

    @MainActor
    func testSaveClaudeResponseAsNoteNoOpWhenResponseEmpty() async {
        let app = AppState(dataDirectory: tempDir)
        app.claudeResponse = nil

        await app.saveClaudeResponseAsNote()

        XCTAssertNil(app.claudeError)
    }

    @MainActor
    func testSaveClaudeResponseAsNoteWritesFileToDefaultVault() async {
        let vaultRoot = tempDir.appendingPathComponent("vault", isDirectory: true)
        try? FileManager.default.createDirectory(at: vaultRoot, withIntermediateDirectories: true)
        let app = AppState(dataDirectory: tempDir)
        let vault = Vault(name: "테스트볼트", rootPath: vaultRoot)
        app.vaults = [vault]
        app.claudePrompt = "이 문서를 요약해줘"
        app.claudeResponse = "요약된 응답 내용"

        await app.saveClaudeResponseAsNote()

        XCTAssertNil(app.claudeError)
        let inboxDir = vaultRoot.appendingPathComponent("Inbox", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: inboxDir.path)) ?? []
        XCTAssertEqual(files.count, 1)
        if let name = files.first {
            let content = try? String(contentsOf: inboxDir.appendingPathComponent(name), encoding: .utf8)
            XCTAssertTrue(content?.contains("요약된 응답 내용") ?? false)
            XCTAssertTrue(name.contains("이 문서를"))
        }
    }
}
