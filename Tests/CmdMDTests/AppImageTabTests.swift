import XCTest
@testable import CmdMD

final class AppImageTabTests: XCTestCase {
    func testCurrentTabKindReflectsActiveImageTab() {
        let appState = AppState()
        let tab = EditorTab(fileURL: URL(fileURLWithPath: "/tmp/pic.png"),
                            title: "pic", kind: .image)
        appState.tabs = [tab]
        appState.activeTabId = tab.id

        XCTAssertEqual(appState.currentTabKind, .image)
        XCTAssertEqual(appState.currentTabFileURL,
                       URL(fileURLWithPath: "/tmp/pic.png"))
    }

    func testWindowTitleUsesFilenameForImageTab() {
        let appState = AppState()
        let tab = EditorTab(fileURL: URL(fileURLWithPath: "/tmp/sunset.jpg"),
                            title: "sunset", kind: .image)
        appState.tabs = [tab]
        appState.activeTabId = tab.id

        // 이미지 탭은 currentDocument 가 없으므로 파일명으로 제목.
        XCTAssertEqual(appState.windowTitle, "sunset")
    }

    func testCurrentTabKindDefaultsToMarkdownWhenNoTab() {
        let appState = AppState()
        XCTAssertEqual(appState.currentTabKind, .markdown)
    }
}
