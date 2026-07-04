import XCTest
import AppKit
@testable import CmdMD

/// F3: AppState 히스토리 배선 테스트 — 실제 임시 폴더로 존재 검사까지 검증.
/// didSet 단일 초크포인트가 기록하고, 뒤로/앞으로·세션 복원·강제 재조준은 기록하지 않는다.
final class AppNavigationHistoryTests: XCTestCase {

    private var tempDir: URL!   // AppState 데이터 디렉터리
    private var root: URL!      // 작업 폴더 역할(실존)
    private var sub: URL!       // 하위 폴더(실존)

    override func setUp() {
        super.setUp()
        tempDir = TempDataDirectory.make()
        root = TempDataDirectory.make()
        sub = root.appendingPathComponent("sub")
        try? FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
    }

    override func tearDown() {
        TempDataDirectory.cleanup(tempDir)
        TempDataDirectory.cleanup(root)
        tempDir = nil; root = nil; sub = nil
        super.tearDown()
    }

    /// currentFolder+selectedFolder를 seed 상태로 준비(openFolder의 무거운 부수효과 없이).
    @MainActor
    private func makeApp() -> AppState {
        let app = AppState(dataDirectory: tempDir)
        app.currentFolder = root
        app.selectedFolder = root   // didSet → seed 기록
        return app
    }

    // MARK: - 기록: 드릴인이 히스토리에 쌓인다

    @MainActor
    func testDrillInRecordsHistory() {
        let app = makeApp()
        XCTAssertFalse(app.navHistory.canGoBack, "seed만으로는 뒤로 갈 곳이 없다")
        app.selectedFolder = sub    // 드릴인과 동일 경로(didSet 초크포인트)
        XCTAssertTrue(app.navHistory.canGoBack)
    }

    // MARK: - 뒤로: 위치 복원 + 라이브러리 모드 강제 + 재기록 없음

    @MainActor
    func testGoBackRestoresFolderAndLibraryMode() {
        let app = makeApp()
        app.selectedFolder = sub
        app.mainMode = .reader      // 파일을 열어 리더로 나간 상황 재현
        app.goBackInHistory()
        XCTAssertEqual(app.selectedFolder?.standardizedFileURL.path,
                       root.standardizedFileURL.path)
        XCTAssertEqual(app.mainMode, .library, "뒤로는 항상 라이브러리 모드로(스펙 §3.2)")
        XCTAssertTrue(app.navHistory.canGoForward)
        XCTAssertFalse(app.navHistory.canGoBack, "뒤로 실행 자체가 새 항목을 쌓으면 안 된다(되먹임)")
    }

    @MainActor
    func testGoForwardAfterBack() {
        let app = makeApp()
        app.selectedFolder = sub
        app.goBackInHistory()
        app.goForwardInHistory()
        XCTAssertEqual(app.selectedFolder?.standardizedFileURL.path,
                       sub.standardizedFileURL.path)
        XCTAssertFalse(app.navHistory.canGoForward)
    }

    // MARK: - 죽은 폴더: 뒤로가 건너뛴다

    @MainActor
    func testGoBackSkipsDeletedFolder() {
        let app = makeApp()
        let doomed = root.appendingPathComponent("doomed")
        try? FileManager.default.createDirectory(at: doomed, withIntermediateDirectories: true)
        app.selectedFolder = doomed
        app.selectedFolder = sub
        try? FileManager.default.removeItem(at: doomed)
        app.goBackInHistory()   // doomed 건너뛰고 root로
        XCTAssertEqual(app.selectedFolder?.standardizedFileURL.path,
                       root.standardizedFileURL.path)
    }

    // MARK: - 상위 이동(AppState 이전분)

    @MainActor
    func testGoUpInLibraryClampsAtRoot() {
        let app = makeApp()
        app.mainMode = .library
        app.selectedFolder = sub
        XCTAssertTrue(app.canGoUpInLibrary)
        app.goUpInLibrary()
        XCTAssertEqual(app.selectedFolder?.standardizedFileURL.path,
                       root.standardizedFileURL.path)
        XCTAssertFalse(app.canGoUpInLibrary, "루트에서는 상위 이동 불가(하한 클램프)")
        app.goUpInLibrary()   // no-op
        XCTAssertEqual(app.selectedFolder?.standardizedFileURL.path,
                       root.standardizedFileURL.path)
    }

    @MainActor
    func testGoUpRequiresLibraryMode() {
        let app = makeApp()
        app.selectedFolder = sub
        app.mainMode = .reader
        app.goUpInLibrary()   // 가드 — 리더 모드에선 무동작(⌘↑ 충돌 방지, 스펙 §6)
        XCTAssertEqual(app.selectedFolder?.standardizedFileURL.path,
                       sub.standardizedFileURL.path)
    }

    // MARK: - stale selectedFolder 재조준(F1a 잔여, 스펙 §5) — 기록 없음

    @MainActor
    func testRetargetStaleSelectedFolderClimbsToExistingAncestor() {
        let app = makeApp()
        let doomed = sub.appendingPathComponent("doomed")
        try? FileManager.default.createDirectory(at: doomed, withIntermediateDirectories: true)
        app.selectedFolder = doomed
        try? FileManager.default.removeItem(at: doomed)
        let backCountBefore = app.navHistory.backStack.count
        app.retargetStaleSelectedFolder()
        XCTAssertEqual(app.selectedFolder?.standardizedFileURL.path,
                       sub.standardizedFileURL.path, "가장 가까운 존재 조상으로 재조준")
        XCTAssertEqual(app.navHistory.backStack.count, backCountBefore,
                       "강제 재조준은 사용자 내비게이션이 아니므로 기록하지 않는다")
    }

    // MARK: - 세션 복원: seed만(뒤로 불가)

    @MainActor
    func testSessionRestoreSeedsHistoryWithoutBack() throws {
        // 세션 파일을 미리 심고 AppState를 생성 → 복원 경로가 히스토리를 seed로만 기록.
        let session = SessionState(openFiles: [], activeFileIndex: nil, viewMode: .split,
                                   currentFolder: root, sidebarVisible: true, inspectorVisible: false)
        let data = try JSONEncoder().encode(session)
        try data.write(to: tempDir.appendingPathComponent("session.json"))

        let app = AppState(dataDirectory: tempDir)
        XCTAssertEqual(app.currentFolder?.standardizedFileURL.path,
                       root.standardizedFileURL.path)
        XCTAssertFalse(app.navHistory.canGoBack, "세션 복원은 seed만 — 가짜 뒤로 항목 금지")
        XCTAssertNotNil(app.navHistory.current)
    }

    // MARK: - ⌘↑ 메뉴 진입점: 텍스트 포커스에 양보(강탈 방지 — 최종 리뷰 Important)

    @MainActor
    func testGoUpFromMenuYieldsToTextResponder() {
        let app = makeApp()
        app.mainMode = .library
        app.selectedFolder = sub
        // 텍스트 입력 포커스 재현 — 헤드리스 NSTextView(F1b responderYieldsFileKeys 테스트 패턴)
        app.goUpInLibraryFromMenu(firstResponder: NSTextView())
        XCTAssertEqual(app.selectedFolder?.standardizedFileURL.path,
                       sub.standardizedFileURL.path,
                       "텍스트 포커스 중 ⌘↑ 메뉴는 폴더를 이동시키면 안 된다(캐럿 이동 양보)")
        app.goUpInLibraryFromMenu(firstResponder: nil)
        XCTAssertEqual(app.selectedFolder?.standardizedFileURL.path,
                       root.standardizedFileURL.path,
                       "텍스트 포커스가 없으면 정상 상위 이동")
    }
}
