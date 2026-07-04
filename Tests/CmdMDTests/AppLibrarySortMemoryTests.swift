import XCTest
@testable import CmdMD

/// F3: selectedFolder/librarySort didSet 정렬 기억 테스트(AppLibraryLayoutMemoryTests 동형).
/// 차이: 정렬은 기억 없으면 .default(PARA)로 **복귀**한다(레이아웃은 유지).
final class AppLibrarySortMemoryTests: XCTestCase {

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

    @MainActor
    func testDefaultsToParaWhenNoMemory() {
        let app = AppState(dataDirectory: tempDir)
        app.selectedFolder = URL(fileURLWithPath: "/v/photos-\(UUID().uuidString)")
        XCTAssertEqual(app.librarySort, .default, "기억 없으면 기본(PARA) 정렬")
    }

    @MainActor
    func testRestoresSortWhenMemoryExists() {
        let app = AppState(dataDirectory: tempDir)
        let url = URL(fileURLWithPath: "/v/docs-\(UUID().uuidString)")
        app.settings.librarySorts[AppState.folderMemoryKey(for: url)] =
            LibrarySort(key: .date, ascending: false)
        app.selectedFolder = url
        XCTAssertEqual(app.librarySort, LibrarySort(key: .date, ascending: false),
                       "기억된 정렬이 selectedFolder 설정 시 복원돼야 한다")
    }

    @MainActor
    func testRevertsToDefaultWhenLeavingRememberedFolder() {
        let app = AppState(dataDirectory: tempDir)
        let remembered = URL(fileURLWithPath: "/v/docs-\(UUID().uuidString)")
        let plain = URL(fileURLWithPath: "/v/photos-\(UUID().uuidString)")
        app.settings.librarySorts[AppState.folderMemoryKey(for: remembered)] =
            LibrarySort(key: .size, ascending: false)
        app.selectedFolder = remembered
        XCTAssertEqual(app.librarySort.key, .size)
        app.selectedFolder = plain
        XCTAssertEqual(app.librarySort, .default,
                       "기억 없는 폴더로 이동하면 기본(PARA)으로 복귀 — 레이아웃(유지)과 다른 점")
    }

    @MainActor
    func testPersistsSortOnChange() {
        let app = AppState(dataDirectory: tempDir)
        let url = URL(fileURLWithPath: "/v/docs-\(UUID().uuidString)")
        app.selectedFolder = url
        app.librarySort = LibrarySort(key: .name, ascending: false)
        XCTAssertEqual(app.settings.librarySorts[AppState.folderMemoryKey(for: url)],
                       LibrarySort(key: .name, ascending: false),
                       "정렬 변경 시 해당 폴더 키로 settings에 저장돼야 한다")
    }

    @MainActor
    func testRestoreDoesNotCreateOtherKeys() {
        let app = AppState(dataDirectory: tempDir)
        let remembered = URL(fileURLWithPath: "/v/docs-\(UUID().uuidString)")
        let plain = URL(fileURLWithPath: "/v/photos-\(UUID().uuidString)")
        app.settings.librarySorts[AppState.folderMemoryKey(for: remembered)] =
            LibrarySort(key: .date, ascending: false)

        app.selectedFolder = plain      // 기억 없음 → default 복귀(복원 경로)
        app.selectedFolder = remembered // 기억 복원
        XCTAssertNil(app.settings.librarySorts[AppState.folderMemoryKey(for: plain)],
                     "복원이 다른 폴더 키를 새로 생성하면 안 된다")
        XCTAssertEqual(app.settings.librarySorts.count, 1)
    }

    @MainActor
    func testSortForFolderReadsMemory() {
        let app = AppState(dataDirectory: tempDir)
        let url = URL(fileURLWithPath: "/v/docs-\(UUID().uuidString)")
        XCTAssertEqual(app.sortForFolder(url), .default)
        app.settings.librarySorts[AppState.folderMemoryKey(for: url)] =
            LibrarySort(key: .kind, ascending: true)
        XCTAssertEqual(app.sortForFolder(url), LibrarySort(key: .kind, ascending: true))
        XCTAssertEqual(app.sortForFolder(nil), .default)
    }
}
