import XCTest
@testable import CmdMD

final class AppImageTabTests: XCTestCase {

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

    func testCurrentTabKindReflectsActiveImageTab() {
        let appState = AppState(dataDirectory: tempDir)
        let tab = EditorTab(fileURL: URL(fileURLWithPath: "/tmp/pic.png"),
                            title: "pic", kind: .image)
        appState.tabs = [tab]
        appState.activeTabId = tab.id

        XCTAssertEqual(appState.currentTabKind, .image)
        XCTAssertEqual(appState.currentTabFileURL,
                       URL(fileURLWithPath: "/tmp/pic.png"))
    }

    func testWindowTitleUsesFilenameForImageTab() {
        let appState = AppState(dataDirectory: tempDir)
        let tab = EditorTab(fileURL: URL(fileURLWithPath: "/tmp/sunset.jpg"),
                            title: "sunset", kind: .image)
        appState.tabs = [tab]
        appState.activeTabId = tab.id

        // 이미지 탭은 currentDocument 가 없으므로 파일명으로 제목.
        XCTAssertEqual(appState.windowTitle, "sunset")
    }

    func testCurrentTabKindDefaultsToMarkdownWhenNoTab() {
        let appState = AppState(dataDirectory: tempDir)
        XCTAssertEqual(appState.currentTabKind, .markdown)
    }
}
