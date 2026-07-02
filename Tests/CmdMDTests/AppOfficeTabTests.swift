import XCTest
@testable import CmdMD

final class AppOfficeTabTests: XCTestCase {

    // 각 테스트에 빈 임시 데이터 디렉터리를 주입해 세션 복원·디스크 의존성을 제거한다.
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

    func testCurrentTabKindReflectsActiveOfficeTab() {
        let appState = AppState(dataDirectory: tempDir)
        let tab = EditorTab(fileURL: URL(fileURLWithPath: "/tmp/report.hwp"),
                            title: "report", kind: .office)
        appState.tabs = [tab]
        appState.activeTabId = tab.id

        XCTAssertEqual(appState.currentTabKind, .office)
        XCTAssertEqual(appState.currentTabFileURL, URL(fileURLWithPath: "/tmp/report.hwp"))
    }

    func testWindowTitleUsesFilenameForOfficeTab() {
        let appState = AppState(dataDirectory: tempDir)
        let tab = EditorTab(fileURL: URL(fileURLWithPath: "/tmp/평가서.hwp"),
                            title: "평가서", kind: .office)
        appState.tabs = [tab]
        appState.activeTabId = tab.id
        XCTAssertEqual(appState.windowTitle, "평가서")
    }
}
