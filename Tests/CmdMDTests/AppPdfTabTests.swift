import XCTest
@testable import CmdMD

final class AppPdfTabTests: XCTestCase {

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

    func testCurrentTabKindReflectsActivePdfTab() {
        let appState = AppState(dataDirectory: tempDir)
        let tab = EditorTab(fileURL: URL(fileURLWithPath: "/tmp/paper.pdf"),
                            title: "paper", kind: .pdf)
        appState.tabs = [tab]
        appState.activeTabId = tab.id

        XCTAssertEqual(appState.currentTabKind, .pdf)
        XCTAssertEqual(appState.currentTabFileURL,
                       URL(fileURLWithPath: "/tmp/paper.pdf"))
    }

    func testWindowTitleUsesFilenameForPdfTab() {
        let appState = AppState(dataDirectory: tempDir)
        let tab = EditorTab(fileURL: URL(fileURLWithPath: "/tmp/report.pdf"),
                            title: "report", kind: .pdf)
        appState.tabs = [tab]
        appState.activeTabId = tab.id

        XCTAssertEqual(appState.windowTitle, "report")
    }
}
