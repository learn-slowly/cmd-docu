import XCTest
@testable import CmdMD

final class AppOfficeTabTests: XCTestCase {
    func testCurrentTabKindReflectsActiveOfficeTab() {
        let appState = AppState()
        let tab = EditorTab(fileURL: URL(fileURLWithPath: "/tmp/report.hwp"),
                            title: "report", kind: .office)
        appState.tabs = [tab]
        appState.activeTabId = tab.id

        XCTAssertEqual(appState.currentTabKind, .office)
        XCTAssertEqual(appState.currentTabFileURL, URL(fileURLWithPath: "/tmp/report.hwp"))
    }

    func testWindowTitleUsesFilenameForOfficeTab() {
        let appState = AppState()
        let tab = EditorTab(fileURL: URL(fileURLWithPath: "/tmp/평가서.hwp"),
                            title: "평가서", kind: .office)
        appState.tabs = [tab]
        appState.activeTabId = tab.id
        XCTAssertEqual(appState.windowTitle, "평가서")
    }
}
