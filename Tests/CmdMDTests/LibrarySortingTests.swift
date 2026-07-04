import XCTest
@testable import CmdMD

/// F3: LibrarySorting 순수 정렬 헬퍼 테스트.
/// para 위임(ParaLens 동일 결과)·키별 정렬·방향·폴더 먼저·nil 처리·tie-break을 고정한다.
final class LibrarySortingTests: XCTestCase {

    // MARK: - 헬퍼

    private func item(_ name: String, dir: Bool = false,
                      size: Int64? = nil, date: Date? = nil) -> FileTreeItem {
        FileTreeItem(url: URL(fileURLWithPath: "/t/\(name)"), isDirectory: dir,
                     fileSize: size, modifiedAt: date)
    }

    private func names(_ items: [FileTreeItem]) -> [String] { items.map(\.name) }

    private let d1 = Date(timeIntervalSince1970: 1_000)
    private let d2 = Date(timeIntervalSince1970: 2_000)
    private let d3 = Date(timeIntervalSince1970: 3_000)

    // MARK: - para = ParaLens 완전 위임

    func testParaDelegatesToParaLens() {
        let root = URL(fileURLWithPath: "/t")
        let items = [item("40000_Archive", dir: true), item("10000_Projects", dir: true),
                     item("b.md"), item("a.md")]
        let ours = LibrarySorting.sorted(items, by: .default, under: root)
        let lens = ParaLens.sorted(items, under: root)
        XCTAssertEqual(names(ours), names(lens), "para 키는 ParaLens.sorted와 동일해야 한다")
        XCTAssertEqual(names(ours).first, "10000_Projects")
        XCTAssertEqual(names(ours).last, "40000_Archive")
    }

    // MARK: - 폴더 먼저 (para 외 전 키·방향 무관)

    func testFoldersFirstRegardlessOfDirection() {
        let items = [item("zzz.md", date: d3), item("aaa", dir: true, date: d1)]
        for asc in [true, false] {
            let sorted = LibrarySorting.sorted(items, by: LibrarySort(key: .date, ascending: asc), under: nil as URL?)
            XCTAssertTrue(sorted.first!.isDirectory, "방향과 무관하게 폴더가 먼저여야 한다 (asc=\(asc))")
        }
    }

    // MARK: - 이름 정렬 (자연 정렬·방향)

    func testNameSortAscendingIsNatural() {
        let items = [item("note10.md"), item("note2.md"), item("가나.md")]
        let sorted = LibrarySorting.sorted(items, by: LibrarySort(key: .name, ascending: true), under: nil as URL?)
        XCTAssertEqual(names(sorted).firstIndex(of: "note2.md")! < names(sorted).firstIndex(of: "note10.md")!,
                       true, "localizedStandardCompare 자연 정렬 — note2 < note10")
    }

    func testNameSortDescending() {
        let items = [item("a.md"), item("c.md"), item("b.md")]
        let sorted = LibrarySorting.sorted(items, by: LibrarySort(key: .name, ascending: false), under: nil as URL?)
        XCTAssertEqual(names(sorted), ["c.md", "b.md", "a.md"])
    }

    // MARK: - 날짜 정렬 (내림차순 기본·nil=distantPast)

    func testDateSortDescendingPutsNewestFirst() {
        let items = [item("old.md", date: d1), item("new.md", date: d3), item("mid.md", date: d2)]
        let sorted = LibrarySorting.sorted(items, by: LibrarySort(key: .date, ascending: false), under: nil as URL?)
        XCTAssertEqual(names(sorted), ["new.md", "mid.md", "old.md"])
    }

    func testDateNilTreatedAsOldest() {
        let items = [item("dated.md", date: d1), item("undated.md", date: nil)]
        let sorted = LibrarySorting.sorted(items, by: LibrarySort(key: .date, ascending: false), under: nil as URL?)
        XCTAssertEqual(names(sorted), ["dated.md", "undated.md"], "nil 날짜는 항상 가장 오래된 쪽")
    }

    // MARK: - 크기 정렬 (파일만 크기 비교·폴더 구간은 이름순·nil=0)

    func testSizeSortDescending() {
        let items = [item("small.md", size: 10), item("big.md", size: 3_000), item("mid.md", size: 500)]
        let sorted = LibrarySorting.sorted(items, by: LibrarySort(key: .size, ascending: false), under: nil as URL?)
        XCTAssertEqual(names(sorted), ["big.md", "mid.md", "small.md"])
    }

    func testSizeSortFoldersStayNameOrderedEvenDescending() {
        let items = [item("bfolder", dir: true), item("afolder", dir: true), item("file.md", size: 5)]
        let sorted = LibrarySorting.sorted(items, by: LibrarySort(key: .size, ascending: false), under: nil as URL?)
        XCTAssertEqual(names(sorted), ["afolder", "bfolder", "file.md"],
                       "폴더는 크기 미계산 — 크기 정렬에서도 폴더 구간은 이름 오름차순 고정")
    }

    func testSizeNilTreatedAsZero() {
        let items = [item("sized.md", size: 100), item("unsized.md", size: nil)]
        let sorted = LibrarySorting.sorted(items, by: LibrarySort(key: .size, ascending: true), under: nil as URL?)
        XCTAssertEqual(names(sorted), ["unsized.md", "sized.md"], "nil 크기는 0 취급")
    }

    // MARK: - 종류 정렬 (DocumentKind rank → 확장자 → 이름)

    func testKindSortGroupsByRankThenExtension() {
        let items = [item("photo.png"), item("doc.pdf"), item("note.md"),
                     item("song.mp3"), item("sheet.xlsx"), item("plain.txt")]
        let sorted = LibrarySorting.sorted(items, by: LibrarySort(key: .kind, ascending: true), under: nil as URL?)
        // markdown(md, txt) → office(xlsx) → pdf → image(png) → media(mp3)
        // 같은 markdown 안에서는 확장자 사전순: md < txt
        XCTAssertEqual(names(sorted), ["note.md", "plain.txt", "sheet.xlsx",
                                       "doc.pdf", "photo.png", "song.mp3"])
    }

    // MARK: - tie-break: 키 동률이면 이름 오름차순 고정(방향 무관)

    func testTieBreakIsNameAscendingEvenWhenDescending() {
        let items = [item("b.md", size: 100), item("a.md", size: 100)]
        let sorted = LibrarySorting.sorted(items, by: LibrarySort(key: .size, ascending: false), under: nil as URL?)
        XCTAssertEqual(names(sorted), ["a.md", "b.md"], "동률은 이름 오름차순 — 방향 반전 비적용")
    }
}
