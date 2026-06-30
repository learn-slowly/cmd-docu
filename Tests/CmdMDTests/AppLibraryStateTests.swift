import XCTest
@testable import CmdMD

final class AppLibraryStateTests: XCTestCase {

    // MARK: - 기본값

    @MainActor
    func testDefaultMainModeIsReader() {
        let app = AppState()
        XCTAssertEqual(app.mainMode, .reader, "초기 mainMode는 reader여야 한다")
    }

    @MainActor
    func testDefaultLibraryLayoutIsGrid() {
        let app = AppState()
        XCTAssertEqual(app.libraryLayout, .grid, "초기 libraryLayout은 grid여야 한다")
    }

    @MainActor
    func testDefaultSelectedFolderMatchesCurrentFolder() {
        let app = AppState()
        // 세션 복원 후 selectedFolder는 currentFolder와 같거나 둘 다 nil이어야 한다.
        XCTAssertEqual(app.selectedFolder, app.currentFolder,
                       "초기 selectedFolder는 currentFolder와 같아야 한다")
    }

    // MARK: - selectFolderForLibrary

    @MainActor
    func testSelectFolderForLibrarySetsSelectedFolder() {
        let app = AppState()
        let url = URL(fileURLWithPath: "/tmp/TestVault")
        app.selectFolderForLibrary(url)
        XCTAssertEqual(app.selectedFolder, url, "selectFolderForLibrary 호출 후 selectedFolder가 설정돼야 한다")
    }

    @MainActor
    func testSelectFolderForLibrarySwitchesToLibraryMode() {
        let app = AppState()
        XCTAssertEqual(app.mainMode, .reader)
        let url = URL(fileURLWithPath: "/tmp/TestVault")
        app.selectFolderForLibrary(url)
        XCTAssertEqual(app.mainMode, .library, "selectFolderForLibrary 호출 후 mainMode는 library여야 한다")
    }

    // MARK: - openDocument → mainMode = .reader

    @MainActor
    func testOpenDocumentSetsMainModeToReader() {
        let app = AppState()
        // 라이브러리 모드로 먼저 전환
        app.selectFolderForLibrary(URL(fileURLWithPath: "/tmp/TestVault"))
        XCTAssertEqual(app.mainMode, .library)

        // 파일 열기 → reader로 전환
        app.openDocument(at: URL(fileURLWithPath: "/tmp/nonexistent.md"))
        XCTAssertEqual(app.mainMode, .reader, "openDocument 호출 즉시 mainMode가 reader로 바뀌어야 한다")
    }

    // MARK: - currentFolder 변경 → selectedFolder 리셋

    @MainActor
    func testLoadFileTreeResetsSelectedFolderToCurrentFolder() {
        let app = AppState()

        // currentFolder와 다른 selectedFolder를 먼저 설정
        let folder = URL(fileURLWithPath: "/tmp")
        let otherFolder = URL(fileURLWithPath: "/private/tmp/other")
        app.currentFolder = folder
        app.selectedFolder = otherFolder
        XCTAssertEqual(app.selectedFolder, otherFolder)

        // loadFileTree 호출 → selectedFolder = currentFolder
        app.loadFileTree()
        XCTAssertEqual(app.selectedFolder, folder,
                       "loadFileTree 후 selectedFolder는 currentFolder로 리셋돼야 한다")
    }

    @MainActor
    func testLoadFileTreeDoesNotChangeSelectedFolderWhenCurrentFolderNil() {
        let app = AppState()
        let url = URL(fileURLWithPath: "/tmp/TestVault")
        app.selectedFolder = url
        app.currentFolder = nil

        // currentFolder가 nil이면 loadFileTree는 아무것도 하지 않는다
        app.loadFileTree()
        XCTAssertEqual(app.selectedFolder, url,
                       "currentFolder가 nil이면 selectedFolder는 변경되지 않아야 한다")
    }
}
