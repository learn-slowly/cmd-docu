import XCTest
@testable import CmdMD

@MainActor
final class AppFileSelectionTests: XCTestCase {

    private var tempData: URL!
    private var work: URL!
    private var appState: AppState!

    override func setUpWithError() throws {
        tempData = TempDataDirectory.make()
        work = FileManager.default.temporaryDirectory
            .appendingPathComponent("selection-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        appState = AppState(dataDirectory: tempData)
    }

    override func tearDown() {
        TempDataDirectory.cleanup(tempData)
        try? FileManager.default.removeItem(at: work)
        tempData = nil; work = nil; appState = nil
        super.tearDown()
    }

    private func makeFile(_ name: String) throws -> URL {
        let url = work.appendingPathComponent(name)
        try Data("본문".utf8).write(to: url)
        return url
    }

    func testHandleFileClickReplacesAndToggles() throws {
        let a = try makeFile("a.md"); let b = try makeFile("b.md")
        appState.handleFileClick(a, modifier: .none, ordered: [a, b])
        XCTAssertEqual(appState.fileSelection, [a])
        appState.handleFileClick(b, modifier: .command, ordered: [a, b])
        XCTAssertEqual(appState.fileSelection, [a, b])
        appState.toggleFileSelection(a)
        XCTAssertEqual(appState.fileSelection, [b])
    }

    func testShiftClickUsesAnchor() throws {
        let a = try makeFile("a.md"); let b = try makeFile("b.md"); let c = try makeFile("c.md")
        appState.handleFileClick(a, modifier: .none, ordered: [a, b, c])
        appState.handleFileClick(c, modifier: .shift, ordered: [a, b, c])
        XCTAssertEqual(appState.fileSelection, [a, b, c])
    }

    func testSelectedFolderChangeClearsSelection() throws {
        let a = try makeFile("a.md")
        appState.handleFileClick(a, modifier: .none, ordered: [a])
        appState.selectedFolder = work  // 드릴인/폴더 클릭 상당
        XCTAssertTrue(appState.fileSelection.isEmpty, "폴더 이동 = 선택 해제(Finder 동일)")
        XCTAssertNil(appState.selectionAnchor)
    }

    func testFileOpPrunesVanishedSelection() async throws {
        // performRename 성공 → completeFileOperation → 옛 URL은 선택에서 제거돼야 함.
        let a = try makeFile("a.md"); let b = try makeFile("b.md")
        appState.handleFileClick(a, modifier: .none, ordered: [a, b])
        appState.handleFileClick(b, modifier: .command, ordered: [a, b])
        _ = try await appState.performRename(at: a, to: "바뀜.md")
        XCTAssertEqual(appState.fileSelection, [b], "사라진 URL prune, 남은 선택 유지")
    }
}
