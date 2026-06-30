import XCTest
@testable import CmdMD

final class AppLibraryStateTests: XCTestCase {

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

    // MARK: - 기본값

    @MainActor
    func testDefaultMainModeIsReader() {
        let app = AppState(dataDirectory: tempDir)
        XCTAssertEqual(app.mainMode, .reader, "초기 mainMode는 reader여야 한다")
    }

    @MainActor
    func testDefaultLibraryLayoutIsGrid() {
        // 빈 임시 디렉터리에선 세션 복원이 없어 libraryLayout 기본값 .grid가 항상 성립한다.
        let app = AppState(dataDirectory: tempDir)
        XCTAssertEqual(app.libraryLayout, .grid, "초기 libraryLayout은 grid여야 한다")
    }

    @MainActor
    func testDefaultSelectedFolderMatchesCurrentFolder() {
        let app = AppState(dataDirectory: tempDir)
        // 세션 복원 후 selectedFolder는 currentFolder와 같거나 둘 다 nil이어야 한다.
        XCTAssertEqual(app.selectedFolder, app.currentFolder,
                       "초기 selectedFolder는 currentFolder와 같아야 한다")
    }

    // MARK: - selectFolderForLibrary

    @MainActor
    func testSelectFolderForLibrarySetsSelectedFolder() {
        let app = AppState(dataDirectory: tempDir)
        let url = URL(fileURLWithPath: "/tmp/TestVault")
        app.selectFolderForLibrary(url)
        XCTAssertEqual(app.selectedFolder, url, "selectFolderForLibrary 호출 후 selectedFolder가 설정돼야 한다")
    }

    @MainActor
    func testSelectFolderForLibrarySwitchesToLibraryMode() {
        let app = AppState(dataDirectory: tempDir)
        XCTAssertEqual(app.mainMode, .reader)
        let url = URL(fileURLWithPath: "/tmp/TestVault")
        app.selectFolderForLibrary(url)
        XCTAssertEqual(app.mainMode, .library, "selectFolderForLibrary 호출 후 mainMode는 library여야 한다")
    }

    // MARK: - openDocument → mainMode = .reader

    @MainActor
    func testOpenDocumentSetsMainModeToReader() {
        let app = AppState(dataDirectory: tempDir)
        // 라이브러리 모드로 먼저 전환
        app.selectFolderForLibrary(URL(fileURLWithPath: "/tmp/TestVault"))
        XCTAssertEqual(app.mainMode, .library)

        // 파일 열기 → reader로 전환
        app.openDocument(at: URL(fileURLWithPath: "/tmp/nonexistent.md"))
        XCTAssertEqual(app.mainMode, .reader, "openDocument 호출 즉시 mainMode가 reader로 바뀌어야 한다")
    }

    // MARK: - loadFileTree는 selectedFolder를 보존해야 함

    @MainActor
    func testLoadFileTreePreservesSelectedFolder() {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("lt-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let s = AppState(dataDirectory: tempDir)
        s.currentFolder = dir
        let sub = dir.appendingPathComponent("10000_Projects")
        s.selectedFolder = sub
        s.loadFileTree()   // 트리 새로고침 — currentFolder 불변
        XCTAssertEqual(s.selectedFolder, sub, "새로고침이 selectedFolder를 루트로 되돌리면 안 된다")
    }

    @MainActor
    func testLoadFileTreeDoesNotChangeSelectedFolderWhenCurrentFolderNil() {
        let app = AppState(dataDirectory: tempDir)
        let url = URL(fileURLWithPath: "/tmp/TestVault")
        app.selectedFolder = url
        app.currentFolder = nil

        // currentFolder가 nil이면 loadFileTree는 아무것도 하지 않는다
        app.loadFileTree()
        XCTAssertEqual(app.selectedFolder, url,
                       "currentFolder가 nil이면 selectedFolder는 변경되지 않아야 한다")
    }
}
