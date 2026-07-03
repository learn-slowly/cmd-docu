import XCTest
@testable import CmdMD

@MainActor
final class AppOpenFolderAtTests: XCTestCase {
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

    func testOpenFolderAt_switchesWorkspaceState() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("openFolderAt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        appState.openFolder(at: folder)

        XCTAssertEqual(appState.currentFolder, folder)
        XCTAssertEqual(appState.selectedFolder, folder)
        XCTAssertEqual(appState.selectedSidebarTab, .files)
        XCTAssertTrue(appState.sidebarVisible)
    }
}
