import XCTest
@testable import CmdMD

final class AppWindowTitleTests: XCTestCase {

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

    func testWindowTitleFallsBackToAppNameWithoutDocument() {
        let appState = AppState(dataDirectory: tempDir)

        XCTAssertEqual(appState.windowTitle, "cmd-docu")
    }

    func testWindowTitleUsesActiveDocumentDisplayTitle() {
        let appState = AppState(dataDirectory: tempDir)
        let document = MarkdownDocument(title: "A & B")
        let tab = EditorTab(documentId: document.id, title: document.displayTitle)

        appState.tabs = [tab]
        appState.activeTabId = tab.id
        appState.documents[document.id] = document

        XCTAssertEqual(appState.windowTitle, "A & B")
    }
}
