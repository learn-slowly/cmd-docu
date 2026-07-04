import XCTest
@testable import CmdMD

/// F3: LibrarySort 모델·AppSettings.librarySorts 라운드트립·하위호환 테스트.
final class LibrarySortSettingsTests: XCTestCase {

    // MARK: - 모델: 키별 기본 방향

    func testDefaultAscendingPerKey() {
        XCTAssertTrue(LibrarySort.defaultAscending(for: .para))
        XCTAssertTrue(LibrarySort.defaultAscending(for: .name))
        XCTAssertTrue(LibrarySort.defaultAscending(for: .kind))
        XCTAssertFalse(LibrarySort.defaultAscending(for: .date), "날짜는 최신 먼저(내림차순)가 기본")
        XCTAssertFalse(LibrarySort.defaultAscending(for: .size), "크기는 큰 것 먼저(내림차순)가 기본")
    }

    // MARK: - 모델: selecting 전이 (새 키=기본 방향, 같은 키=방향 토글, para=토글 없음)

    func testSelectingNewKeyUsesDefaultDirection() {
        let s = LibrarySort.default.selecting(.date)
        XCTAssertEqual(s, LibrarySort(key: .date, ascending: false))
    }

    func testSelectingSameKeyTogglesDirection() {
        let s = LibrarySort(key: .name, ascending: true).selecting(.name)
        XCTAssertEqual(s, LibrarySort(key: .name, ascending: false))
    }

    func testSelectingParaNeverToggles() {
        let s = LibrarySort.default.selecting(.para)
        XCTAssertEqual(s, LibrarySort.default, "para는 방향 개념이 없어 재선택해도 그대로")
    }

    // MARK: - DocumentKind 정렬 순위: 문서(markdown) → office → pdf → image → media

    func testDocumentKindSortRankOrder() {
        let ranks = [DocumentKind.markdown, .office, .pdf, .image, .media].map(\.sortRank)
        XCTAssertEqual(ranks, ranks.sorted(), "선언된 종류 순서대로 순위가 증가해야 한다")
        XCTAssertEqual(Set(ranks).count, ranks.count, "순위가 겹치면 안 된다")
    }

    // MARK: - settings: librarySorts 키 없는 JSON → 빈 dict (하위호환)

    func testDecodesEmptyDictWhenKeyAbsent() throws {
        let json = #"{"fontSize":14}"#.data(using: .utf8)!
        let s = try JSONDecoder().decode(AppSettings.self, from: json)
        XCTAssertEqual(s.librarySorts, [:],
                       "librarySorts 키가 없으면 빈 dict로 디코드돼야 한다(구 settings.json 호환)")
    }

    // MARK: - settings: 라운드트립

    func testRoundTripsLibrarySorts() throws {
        var s = AppSettings()
        s.librarySorts = ["/v/photos": LibrarySort(key: .date, ascending: false),
                          "/v/docs": LibrarySort(key: .name, ascending: true)]
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertEqual(back.librarySorts["/v/photos"], LibrarySort(key: .date, ascending: false))
        XCTAssertEqual(back.librarySorts["/v/docs"], LibrarySort(key: .name, ascending: true))
        XCTAssertEqual(back.librarySorts.count, 2)
    }
}
