import XCTest
@testable import CmdMD

/// Phase 8.5-③: selectedFolder/libraryLayout didSet 레이아웃 기억 테스트.
/// 실제 설정 파일 오염 없이 freshState(AppState())로만 검증.
/// AppState()가 디스크에서 설정을 읽으므로 각 테스트 초반에
/// libraryLayouts를 초기화해 이전 테스트의 saveUserData 잔재를 제거한다.
final class AppLibraryLayoutMemoryTests: XCTestCase {

    // MARK: - 기본: 기억 없으면 레이아웃 변동 없음

    @MainActor
    func testNoChangeWhenNoMemory() {
        let app = AppState()
        app.settings.libraryLayouts = [:]   // 디스크 잔재 제거
        app.selectedFolder = nil
        app.currentFolder = nil
        let fakePath = "/v/photos-\(UUID().uuidString)"
        // libraryLayouts 비어있는 상태에서 selectedFolder 설정
        app.selectedFolder = URL(fileURLWithPath: fakePath)
        // 기억 없으므로 기본 grid 유지
        XCTAssertEqual(app.libraryLayout, .grid,
                       "기억이 없으면 libraryLayout이 변동되지 않아야 한다")
    }

    // MARK: - 기억 복원: settings에 값이 있으면 selectedFolder 변경 시 복원

    @MainActor
    func testRestoresLayoutWhenMemoryExists() {
        let app = AppState()
        app.settings.libraryLayouts = [:]   // 디스크 잔재 제거
        let fakePath = "/v/docs-\(UUID().uuidString)"
        app.settings.libraryLayouts[URL(fileURLWithPath: fakePath).standardizedFileURL.path] = .list
        app.selectedFolder = URL(fileURLWithPath: fakePath)
        XCTAssertEqual(app.libraryLayout, .list,
                       "기억된 list 레이아웃이 selectedFolder 설정 시 복원돼야 한다")
    }

    // MARK: - 저장: selectedFolder 있는 상태에서 libraryLayout 변경 시 settings에 기록

    @MainActor
    func testPersistsLayoutOnChange() {
        let app = AppState()
        app.settings.libraryLayouts = [:]   // 디스크 잔재 제거
        let fakePath = "/v/docs-\(UUID().uuidString)"
        let url = URL(fileURLWithPath: fakePath)
        app.selectedFolder = url
        app.libraryLayout = .list
        let key = url.standardizedFileURL.path
        XCTAssertEqual(app.settings.libraryLayouts[key], .list,
                       "libraryLayout 변경 시 해당 폴더 키로 settings에 저장돼야 한다")
    }

    // MARK: - 복원이 저장을 유발하지 않음: 복원 시 다른 폴더 키 생성 안 됨

    @MainActor
    func testRestoreDoesNotTriggerSaveForOtherFolder() {
        let app = AppState()
        app.settings.libraryLayouts = [:]   // 디스크 잔재 제거
        let photosPath = "/v/photos-\(UUID().uuidString)"
        let docsPath = "/v/docs-\(UUID().uuidString)"
        let photosKey = URL(fileURLWithPath: photosPath).standardizedFileURL.path
        let docsKey = URL(fileURLWithPath: docsPath).standardizedFileURL.path

        // docs 폴더에 list 기억 저장
        app.settings.libraryLayouts[docsKey] = .list

        // photos 폴더 선택 (기억 없음 → 현재 grid 유지, 복원 없음)
        app.selectedFolder = URL(fileURLWithPath: photosPath)
        // photos 폴더에 새로운 키가 생성되면 안 됨
        XCTAssertNil(app.settings.libraryLayouts[photosKey],
                     "기억이 없는 폴더로 이동 시 새 키가 생성되면 안 된다")

        // docs 폴더 선택 → list 복원 — 이때 다른 키가 새로 생기면 안 됨
        app.selectedFolder = URL(fileURLWithPath: docsPath)
        XCTAssertEqual(app.libraryLayout, .list,
                       "docs 폴더로 이동하면 list가 복원돼야 한다")
        // 복원이 photos 폴더 키를 만들지 않아야 함
        XCTAssertNil(app.settings.libraryLayouts[photosKey],
                     "복원이 다른 폴더 키를 새로 생성하면 안 된다")
        // 원래 docs 키만 있어야 함 (디스크 잔재는 위에서 제거했으므로 1개)
        XCTAssertEqual(app.settings.libraryLayouts.count, 1,
                       "settings.libraryLayouts에는 docs 키 1개만 있어야 한다")
    }
}
