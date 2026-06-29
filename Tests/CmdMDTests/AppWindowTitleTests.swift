import XCTest
@testable import CmdMD

final class AppWindowTitleTests: XCTestCase {
    func testWindowTitleFallsBackToAppNameWithoutDocument() {
        let appState = AppState()

        XCTAssertEqual(appState.windowTitle, "cmd-docu")
    }

    func testWindowTitleUsesActiveDocumentDisplayTitle() {
        let appState = AppState()
        let document = MarkdownDocument(title: "A & B")
        let tab = EditorTab(documentId: document.id, title: document.displayTitle)

        appState.tabs = [tab]
        appState.activeTabId = tab.id
        appState.documents[document.id] = document

        XCTAssertEqual(appState.windowTitle, "A & B")
    }
}
