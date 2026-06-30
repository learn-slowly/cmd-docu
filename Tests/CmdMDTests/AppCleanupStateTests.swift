import XCTest
@testable import CmdMD

@MainActor
final class AppCleanupStateTests: XCTestCase {
    func testCleanupDefaults() {
        let state = AppState()
        XCTAssertFalse(state.showFolderCleanup)
        XCTAssertNil(state.cleanupPlan)
        XCTAssertTrue(state.cleanupScheme.isEmpty)
        XCTAssertFalse(state.cleanupBusy)
    }

    func testStartCleanupSetsSubfolderModeAndShows() {
        let state = AppState()
        let folder = URL(fileURLWithPath: "/Users/x/Downloads")
        state.startCleanup(folder: folder)
        XCTAssertTrue(state.showFolderCleanup)
        if case .subfolder(let root)? = state.cleanupMode {
            XCTAssertEqual(root, folder)
        } else { XCTFail("subfolder 모드여야 함") }
    }
}
