import XCTest
@testable import CmdMD

@MainActor
final class AppCleanupStateTests: XCTestCase {

    // 빈 임시 데이터 디렉터리를 주입해 디스크 상태에 의존하지 않게 한다(회귀 방지).
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

    func testCleanupDefaults() {
        let state = AppState(dataDirectory: tempDir)
        XCTAssertFalse(state.showFolderCleanup)
        XCTAssertNil(state.cleanupPlan)
        XCTAssertTrue(state.cleanupScheme.isEmpty)
        XCTAssertFalse(state.cleanupBusy)
        XCTAssertNil(state.cleanupError)
    }

    func testStartCleanupSetsSubfolderModeAndShows() {
        let state = AppState(dataDirectory: tempDir)
        let folder = URL(fileURLWithPath: "/Users/x/Downloads")
        state.startCleanup(folder: folder)
        XCTAssertTrue(state.showFolderCleanup)
        if case .subfolder(let root)? = state.cleanupMode {
            XCTAssertEqual(root, folder)
        } else { XCTFail("subfolder 모드여야 함") }
    }
}
