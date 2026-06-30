import XCTest
@testable import CmdMD

/// Phase 8.5-③: AppSettings.libraryLayouts 라운드트립·하위호환 테스트.
final class LibraryLayoutSettingsTests: XCTestCase {

    // MARK: - libraryLayouts 키 없는 JSON → 빈 dict (하위호환)

    func testDecodesEmptyDictWhenKeyAbsent() throws {
        let json = #"{"fontSize":14}"#.data(using: .utf8)!
        let s = try JSONDecoder().decode(AppSettings.self, from: json)
        XCTAssertEqual(s.libraryLayouts, [:],
                       "libraryLayouts 키가 없으면 빈 dict로 디코드돼야 한다")
    }

    // MARK: - libraryLayouts 라운드트립

    func testRoundTripsLibraryLayouts() throws {
        var s = AppSettings()
        s.libraryLayouts = ["/v/photos": .grid, "/v/docs": .list]
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertEqual(back.libraryLayouts["/v/photos"], .grid,
                       "photos 폴더 레이아웃이 grid로 복원돼야 한다")
        XCTAssertEqual(back.libraryLayouts["/v/docs"], .list,
                       "docs 폴더 레이아웃이 list로 복원돼야 한다")
        XCTAssertEqual(back.libraryLayouts.count, 2,
                       "두 항목 모두 유지돼야 한다")
    }
}
