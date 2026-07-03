import XCTest
@testable import CmdMD

@MainActor
final class AppCloseAllTabsTests: XCTestCase {
    private var tempDir: URL!
    private var appState: AppState!

    override func setUp() {
        super.setUp()
        tempDir = TempDataDirectory.make()
        appState = AppState(dataDirectory: tempDir)
    }

    override func tearDown() {
        TempDataDirectory.cleanup(tempDir)
        tempDir = nil
        appState = nil
        super.tearDown()
    }

    func testCloseAllTabs_closesEverythingWhenNothingPinned() {
        appState.createNewTab()
        appState.createNewTab()
        appState.createNewTab()
        XCTAssertEqual(appState.tabs.count, 3)

        appState.closeAllTabs()

        XCTAssertTrue(appState.tabs.isEmpty)
        XCTAssertNil(appState.activeTabId)
    }

    func testCloseAllTabs_keepsPinnedTabs() {
        appState.createNewTab()
        appState.createNewTab()
        appState.createNewTab()
        let pinned = appState.tabs[1]
        appState.toggleTabPin(pinned)

        appState.closeAllTabs()

        XCTAssertEqual(appState.tabs.map(\.id), [pinned.id])
        XCTAssertEqual(appState.activeTabId, pinned.id)
    }

    func testCloseAllTabs_dirtyTabClosesWithoutAlertWhenConfirmOff() {
        appState.settings.confirmBeforeClosingDirtyTabs = false
        appState.createNewTab()
        // 활성 문서를 편집해 더티로 만든다(fullText 기준선과 어긋나게).
        if var doc = appState.currentDocument {
            doc.content += "\n편집됨"
            appState.currentDocument = doc
        }
        XCTAssertTrue(appState.tabs.contains(where: { appState.isTabDirty($0) }))

        appState.closeAllTabs()

        XCTAssertTrue(appState.tabs.isEmpty)
    }

    func testCloseAllTabs_noTabsIsNoOp() {
        XCTAssertTrue(appState.tabs.isEmpty)
        appState.closeAllTabs()   // 크래시·알림 없이 조용히 반환
        XCTAssertTrue(appState.tabs.isEmpty)
    }
}
