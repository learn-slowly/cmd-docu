import XCTest
@testable import CmdMD

final class AppPdfTabTests: XCTestCase {
    func testCurrentTabKindReflectsActivePdfTab() {
        let appState = AppState()
        let tab = EditorTab(fileURL: URL(fileURLWithPath: "/tmp/paper.pdf"),
                            title: "paper", kind: .pdf)
        appState.tabs = [tab]
        appState.activeTabId = tab.id

        XCTAssertEqual(appState.currentTabKind, .pdf)
        XCTAssertEqual(appState.currentTabFileURL,
                       URL(fileURLWithPath: "/tmp/paper.pdf"))
    }

    func testWindowTitleUsesFilenameForPdfTab() {
        let appState = AppState()
        let tab = EditorTab(fileURL: URL(fileURLWithPath: "/tmp/report.pdf"),
                            title: "report", kind: .pdf)
        appState.tabs = [tab]
        appState.activeTabId = tab.id

        XCTAssertEqual(appState.windowTitle, "report")
    }
}
