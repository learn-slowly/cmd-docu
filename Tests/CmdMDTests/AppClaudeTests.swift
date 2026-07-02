import XCTest
@testable import CmdMD

final class AppClaudeTests: XCTestCase {
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
}
