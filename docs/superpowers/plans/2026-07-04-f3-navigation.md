# F3 탐색 강화 구현 계획 (경로 바·히스토리·정렬)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 라이브러리를 "폴더를 실제로 돌아다니는 공간"으로 완성 — 클릭 가능 경로 바(공용), 뒤로/앞으로 폴더 히스토리, 정렬 옵션(이름/날짜/크기/종류, 폴더별 기억, 트리 포함).

**Architecture:** 순수 헬퍼 3종(`LibrarySorting`·`NavigationHistory`·`PathBarModel`)을 별도 파일로 신설하고, AppState에 상태(didSet 영속/복원/기록)와 배선을 가산한다. 정렬 기본값은 기존 `ParaLens.sorted` 위임(원본 불변), 히스토리 기록은 `selectedFolder` didSet 단일 초크포인트+억제 플래그, 경로 바는 리더·라이브러리 공용 `PathBarView` 하나로 통일한다.

**Tech Stack:** Swift 5.9+/SwiftUI, SPM, macOS 14+. 새 패키지 의존성 0.

**Spec:** `docs/superpowers/specs/2026-07-04-f3-navigation-design.md` (사용자 결정 6건·함정 체크리스트 11건 — 각 태스크가 참조)

## Global Constraints

- 비샌드박스 유지. 새 패키지 의존성 추가 금지.
- 코드 주석·커밋 메시지는 한국어. '박다/박는다/박았다' 계열 표현 금지.
- `ParaLens.sorted`·`ParaCategory` **원본 불변**(ParaLensTests 18개 보호). `SessionState` **무변경**(합성 Codable — 필드 추가 시 구 session.json 복원이 통째로 무산됨).
- 이 기능은 읽기/탐색 전용 — 파일 이동·삭제 없음(설정 저장 `saveUserData()`만).
- 경로 비교는 전부 `standardizedFileURL.path` + `'/'` 경계(`rootStd + "/"` prefix). raw `hasPrefix` 금지.
- 테스트 실행엔 정식 Xcode 필요(`swift test`). 빌드만이면 `swift build`.
- 각 태스크 완료 시점에 `swift build` 경고 0 유지.

## 파일 구조 (신규/수정 전도)

| 파일 | 역할 |
|---|---|
| 신규 `Sources/Models/LibrarySort.swift` | `LibrarySortKey`·`LibrarySort`(키+방향, `selecting()` 전이) |
| 신규 `Sources/Services/LibrarySorting.swift` | 정렬 순수 헬퍼 — para는 ParaLens 위임, 그 외 폴더먼저→키→이름 |
| 신규 `Sources/Services/NavigationHistory.swift` | `FolderLocation`·`NavigationHistory`(back/forward 스택, 순수) |
| 신규 `Sources/Services/PathBarModel.swift` | `PathSegment`·세그먼트 분해(순수, '/' 경계) |
| 신규 `Sources/Views/PathBarView.swift` | 공용 경로 바(‹ › + 브레드크럼 + 트레일링) |
| 수정 `Sources/Models/DocumentKind.swift` | `sortRank` 추가(종류 정렬 순위) |
| 수정 `Sources/Models/Settings.swift` | `librarySorts: [String: LibrarySort]` 선언+디코드 |
| 수정 `Sources/App/AppState.swift` | librarySort 상태·기억, folderMemoryKey 통일, navHistory 배선, goUp 이전, stale selectedFolder 재조준, buildFileTree 메타 |
| 수정 `Sources/Views/LibraryView.swift` | applySort/onChange, 헤더→PathBarView, 리스트 열 헤더 |
| 수정 `Sources/Views/SidebarView.swift` | 트리 정렬을 LibrarySorting으로 교체(폴더별) |
| 수정 `Sources/Views/MainEditorView.swift` | SimpleBreadcrumbView → PathBarView 교체(구 뷰 삭제) |
| 수정 `Sources/Views/ContentView.swift` | 라이브러리 툴바에 LibrarySortMenu |
| 수정 `Sources/Models/Shortcuts.swift` | `.navigateBack`(⌘[)·`.navigateForward`(⌘])·`.navigateUp`(⌘↑) |
| 수정 `Sources/App/CmdMDApp.swift` | View 메뉴 뒤로/앞으로/상위 |
| 수정 `Sources/Views/CommandPaletteView.swift` | 팔레트 명령 3건 |
| 수정 `Sources/Models/Workspace.swift` | FileTreeItem 메타 주석 갱신(줄 128-129) |

---

### Task 1: LibrarySort 모델 + DocumentKind.sortRank + Settings 영속

**Files:**
- Create: `Sources/Models/LibrarySort.swift`
- Modify: `Sources/Models/DocumentKind.swift` (extension 끝에 sortRank 추가)
- Modify: `Sources/Models/Settings.swift:109` 근처(선언) + `:164` 근처(디코드)
- Test: `Tests/CmdMDTests/LibrarySortSettingsTests.swift` (신규)

**Interfaces:**
- Produces: `enum LibrarySortKey: String, Codable, CaseIterable { case para, name, date, size, kind }` + `var title: String`; `struct LibrarySort: Codable, Equatable, Hashable { var key: LibrarySortKey; var ascending: Bool }` + `static let default`/`static func defaultAscending(for:) -> Bool`/`func selecting(_:) -> LibrarySort`; `DocumentKind.sortRank: Int`; `AppSettings.librarySorts: [String: LibrarySort]`

- [ ] **Step 1: 실패하는 테스트 작성**

`Tests/CmdMDTests/LibrarySortSettingsTests.swift`:

```swift
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
```

- [ ] **Step 2: 테스트 실패 확인**

Run: `swift test --filter LibrarySortSettingsTests 2>&1 | tail -5`
Expected: 컴파일 실패 — "cannot find 'LibrarySort' in scope"

- [ ] **Step 3: 최소 구현**

`Sources/Models/LibrarySort.swift` (신규):

```swift
import Foundation

// MARK: - LibrarySortKey

/// 라이브러리·트리 정렬 키. para = 기존 PARA 렌즈 정렬(기본값).
enum LibrarySortKey: String, Codable, CaseIterable {
    case para, name, date, size, kind

    /// 정렬 메뉴 표시명.
    var title: String {
        switch self {
        case .para: return "PARA (기본)"
        case .name: return "이름"
        case .date: return "수정일"
        case .size: return "크기"
        case .kind: return "종류"
        }
    }
}

// MARK: - LibrarySort

/// 정렬 상태(키+방향). 폴더별로 settings.librarySorts에 기억된다(스펙 §2.3).
struct LibrarySort: Codable, Equatable, Hashable {
    var key: LibrarySortKey
    var ascending: Bool

    static let `default` = LibrarySort(key: .para, ascending: true)

    /// 키별 기본 방향 — 이름·종류는 오름차순, 날짜·크기는 내림차순(최신·큰 것 먼저).
    static func defaultAscending(for key: LibrarySortKey) -> Bool {
        switch key {
        case .date, .size: return false
        case .para, .name, .kind: return true
        }
    }

    /// 키 선택 전이 — 새 키면 그 키의 기본 방향, 같은 키 재선택이면 방향 토글(para는 방향 없음).
    /// 툴바 메뉴·리스트 열 헤더가 공유한다.
    func selecting(_ newKey: LibrarySortKey) -> LibrarySort {
        if newKey == key, newKey != .para {
            return LibrarySort(key: key, ascending: !ascending)
        }
        return LibrarySort(key: newKey, ascending: Self.defaultAscending(for: newKey))
    }
}
```

`Sources/Models/DocumentKind.swift` — extension 끝(`isVideo` 아래, `init(from:)` 위)에 추가:

```swift
    /// 종류 정렬 순위(F3) — 문서(markdown) → office → pdf → image → media.
    /// 비문서 확장자는 init(from:)이 .markdown으로 폴백하므로 같은 종류 안에서는
    /// pathExtension 사전순이 2차 키(LibrarySorting 몫).
    var sortRank: Int {
        switch self {
        case .markdown: return 0
        case .office:   return 1
        case .pdf:      return 2
        case .image:    return 3
        case .media:    return 4
        }
    }
```

`Sources/Models/Settings.swift` — 선언(`libraryLayouts` 바로 아래, :109 뒤):

```swift
    /// 키 = 폴더 표준화 경로(`standardizedFileURL.path`), 값 = 기억된 정렬(F3).
    var librarySorts: [String: LibrarySort] = [:]
```

디코드(`init(from:)`의 libraryLayouts 줄(:164) 바로 아래 — **이 줄을 빠뜨리면 컴파일은 통과하지만 재실행 시 항상 기본값으로 무음 리셋된다(스펙 함정 #4)**):

```swift
        librarySorts = try c.decodeIfPresent([String: LibrarySort].self, forKey: .librarySorts) ?? d.librarySorts
```

- [ ] **Step 4: 테스트 통과 확인**

Run: `swift test --filter LibrarySortSettingsTests 2>&1 | tail -5`
Expected: `Executed 7 tests, with 0 failures`

- [ ] **Step 5: 커밋**

```bash
git add Sources/Models/LibrarySort.swift Sources/Models/DocumentKind.swift Sources/Models/Settings.swift Tests/CmdMDTests/LibrarySortSettingsTests.swift
git commit -m "기능(F3): LibrarySort 모델·DocumentKind.sortRank·settings.librarySorts 영속(하위호환 디코드)"
```

---

### Task 2: LibrarySorting 순수 정렬 헬퍼

**Files:**
- Create: `Sources/Services/LibrarySorting.swift`
- Test: `Tests/CmdMDTests/LibrarySortingTests.swift` (신규)

**Interfaces:**
- Consumes: `LibrarySort`/`LibrarySortKey`(Task 1), `ParaLens.sorted(_:under:)`(기존), `FileTreeItem`(기존 — `name`/`isDirectory`/`fileSize: Int64?`/`modifiedAt: Date?`/`url`), `DocumentKind.sortRank`(Task 1)
- Produces: `LibrarySorting.sorted(_ items: [FileTreeItem], by sort: LibrarySort, under root: URL?) -> [FileTreeItem]`

- [ ] **Step 1: 실패하는 테스트 작성**

`Tests/CmdMDTests/LibrarySortingTests.swift`:

```swift
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
        XCTAssertEqual(names(ours).last, "b.md")
    }

    // MARK: - 폴더 먼저 (para 외 전 키·방향 무관)

    func testFoldersFirstRegardlessOfDirection() {
        let items = [item("zzz.md", date: d3), item("aaa", dir: true, date: d1)]
        for asc in [true, false] {
            let sorted = LibrarySorting.sorted(items, by: LibrarySort(key: .date, ascending: asc), under: nil)
            XCTAssertTrue(sorted.first!.isDirectory, "방향과 무관하게 폴더가 먼저여야 한다 (asc=\(asc))")
        }
    }

    // MARK: - 이름 정렬 (자연 정렬·방향)

    func testNameSortAscendingIsNatural() {
        let items = [item("note10.md"), item("note2.md"), item("가나.md")]
        let sorted = LibrarySorting.sorted(items, by: LibrarySort(key: .name, ascending: true), under: nil)
        XCTAssertEqual(names(sorted).firstIndex(of: "note2.md")! < names(sorted).firstIndex(of: "note10.md")!,
                       true, "localizedStandardCompare 자연 정렬 — note2 < note10")
    }

    func testNameSortDescending() {
        let items = [item("a.md"), item("c.md"), item("b.md")]
        let sorted = LibrarySorting.sorted(items, by: LibrarySort(key: .name, ascending: false), under: nil)
        XCTAssertEqual(names(sorted), ["c.md", "b.md", "a.md"])
    }

    // MARK: - 날짜 정렬 (내림차순 기본·nil=distantPast)

    func testDateSortDescendingPutsNewestFirst() {
        let items = [item("old.md", date: d1), item("new.md", date: d3), item("mid.md", date: d2)]
        let sorted = LibrarySorting.sorted(items, by: LibrarySort(key: .date, ascending: false), under: nil)
        XCTAssertEqual(names(sorted), ["new.md", "mid.md", "old.md"])
    }

    func testDateNilTreatedAsOldest() {
        let items = [item("dated.md", date: d1), item("undated.md", date: nil)]
        let sorted = LibrarySorting.sorted(items, by: LibrarySort(key: .date, ascending: false), under: nil)
        XCTAssertEqual(names(sorted), ["dated.md", "undated.md"], "nil 날짜는 항상 가장 오래된 쪽")
    }

    // MARK: - 크기 정렬 (파일만 크기 비교·폴더 구간은 이름순·nil=0)

    func testSizeSortDescending() {
        let items = [item("small.md", size: 10), item("big.md", size: 3_000), item("mid.md", size: 500)]
        let sorted = LibrarySorting.sorted(items, by: LibrarySort(key: .size, ascending: false), under: nil)
        XCTAssertEqual(names(sorted), ["big.md", "mid.md", "small.md"])
    }

    func testSizeSortFoldersStayNameOrderedEvenDescending() {
        let items = [item("bfolder", dir: true), item("afolder", dir: true), item("file.md", size: 5)]
        let sorted = LibrarySorting.sorted(items, by: LibrarySort(key: .size, ascending: false), under: nil)
        XCTAssertEqual(names(sorted), ["afolder", "bfolder", "file.md"],
                       "폴더는 크기 미계산 — 크기 정렬에서도 폴더 구간은 이름 오름차순 고정")
    }

    func testSizeNilTreatedAsZero() {
        let items = [item("sized.md", size: 100), item("unsized.md", size: nil)]
        let sorted = LibrarySorting.sorted(items, by: LibrarySort(key: .size, ascending: true), under: nil)
        XCTAssertEqual(names(sorted), ["unsized.md", "sized.md"], "nil 크기는 0 취급")
    }

    // MARK: - 종류 정렬 (DocumentKind rank → 확장자 → 이름)

    func testKindSortGroupsByRankThenExtension() {
        let items = [item("photo.png"), item("doc.pdf"), item("note.md"),
                     item("song.mp3"), item("sheet.xlsx"), item("plain.txt")]
        let sorted = LibrarySorting.sorted(items, by: LibrarySort(key: .kind, ascending: true), under: nil)
        // markdown(md, txt) → office(xlsx) → pdf → image(png) → media(mp3)
        // 같은 markdown 안에서는 확장자 사전순: md < txt
        XCTAssertEqual(names(sorted), ["note.md", "plain.txt", "sheet.xlsx",
                                       "doc.pdf", "photo.png", "song.mp3"])
    }

    // MARK: - tie-break: 키 동률이면 이름 오름차순 고정(방향 무관)

    func testTieBreakIsNameAscendingEvenWhenDescending() {
        let items = [item("b.md", size: 100), item("a.md", size: 100)]
        let sorted = LibrarySorting.sorted(items, by: LibrarySort(key: .size, ascending: false), under: nil)
        XCTAssertEqual(names(sorted), ["a.md", "b.md"], "동률은 이름 오름차순 — 방향 반전 비적용")
    }
}
```

- [ ] **Step 2: 테스트 실패 확인**

Run: `swift test --filter LibrarySortingTests 2>&1 | tail -5`
Expected: 컴파일 실패 — "cannot find 'LibrarySorting' in scope"

- [ ] **Step 3: 최소 구현**

`Sources/Services/LibrarySorting.swift` (신규):

```swift
import Foundation

// MARK: - LibrarySorting

/// 라이브러리·트리 공용 정렬 — 순수 헬퍼(스펙 §2.2).
/// para(기본)는 기존 ParaLens.sorted에 완전 위임(원본 불변 — ParaLensTests 보호).
/// 그 외 키: ①폴더 먼저(방향 무관) → ②선택 키(방향 반영) → ③이름 오름차순 tie-break(방향 무관).
enum LibrarySorting {

    static func sorted(_ items: [FileTreeItem], by sort: LibrarySort, under root: URL?) -> [FileTreeItem] {
        guard sort.key != .para else { return ParaLens.sorted(items, under: root) }

        return items.sorted { lhs, rhs in
            // 폴더 먼저 — 방향과 무관하게 항상.
            let ld = lhs.isDirectory ? 0 : 1, rd = rhs.isDirectory ? 0 : 1
            if ld != rd { return ld < rd }

            var primary = ComparisonResult.orderedSame
            switch sort.key {
            case .para:
                break // 도달 불가(위에서 선분기)
            case .name:
                primary = lhs.name.localizedStandardCompare(rhs.name)
            case .date:
                primary = compare(lhs.modifiedAt ?? .distantPast, rhs.modifiedAt ?? .distantPast)
            case .size:
                // 폴더는 크기 미계산(리스트 표기 "--") — 폴더 구간은 키 동률로 두어
                // 이름 tie-break이 정렬한다(방향 반전 비적용).
                if !(lhs.isDirectory && rhs.isDirectory) {
                    primary = compare(lhs.fileSize ?? 0, rhs.fileSize ?? 0)
                }
            case .kind:
                if !lhs.isDirectory {  // 폴더 구간은 동률 → 이름순
                    primary = compare(DocumentKind(from: lhs.url).sortRank,
                                      DocumentKind(from: rhs.url).sortRank)
                    if primary == .orderedSame {
                        primary = compare(lhs.url.pathExtension.lowercased(),
                                          rhs.url.pathExtension.lowercased())
                    }
                }
            }

            if primary != .orderedSame {
                return sort.ascending ? primary == .orderedAscending
                                      : primary == .orderedDescending
            }
            // 키 동률 — 이름 오름차순 고정(안정된 2차 질서).
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private static func compare<T: Comparable>(_ l: T, _ r: T) -> ComparisonResult {
        if l == r { return .orderedSame }
        return l < r ? .orderedAscending : .orderedDescending
    }
}
```

- [ ] **Step 4: 테스트 통과 확인**

Run: `swift test --filter LibrarySortingTests 2>&1 | tail -5`
Expected: `Executed 11 tests, with 0 failures`

- [ ] **Step 5: 커밋**

```bash
git add Sources/Services/LibrarySorting.swift Tests/CmdMDTests/LibrarySortingTests.swift
git commit -m "기능(F3): LibrarySorting 순수 정렬 헬퍼 — para는 ParaLens 위임, 폴더먼저·키·이름 tie-break"
```

---

### Task 3: AppState 정렬 상태·폴더별 기억 + folderMemoryKey 통일

**Files:**
- Modify: `Sources/App/AppState.swift:42-54`(didSet 배선·프로퍼티), `:819-842`(기억 함수들 — folderMemoryKey 통일 포함)
- Test: `Tests/CmdMDTests/AppLibrarySortMemoryTests.swift` (신규)

**Interfaces:**
- Consumes: `LibrarySort`(Task 1)
- Produces: `AppState.librarySort: LibrarySort`(didSet 영속), `AppState.sortForFolder(_ url: URL?) -> LibrarySort`, `static AppState.folderMemoryKey(for: URL) -> String`

**주의(스펙 §2.3):** 정렬 복원은 레이아웃과 달리 **기억 없으면 `.default`(PARA)로 복귀**한다(정렬은 폴더 속성 — 기억 없는 폴더는 항상 기본). 복원/저장 기준 폴더는 둘 다 `selectedFolder ?? currentFolder`로 통일(기존 restore가 selectedFolder만 보던 비대칭 해소 — libraryLayouts에도 동일 적용).

- [ ] **Step 1: 실패하는 테스트 작성**

`Tests/CmdMDTests/AppLibrarySortMemoryTests.swift`:

```swift
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
```

- [ ] **Step 2: 테스트 실패 확인**

Run: `swift test --filter AppLibrarySortMemoryTests 2>&1 | tail -5`
Expected: 컴파일 실패 — "value of type 'AppState' has no member 'librarySort'"

- [ ] **Step 3: 구현**

`Sources/App/AppState.swift` — ① `selectedFolder`/`libraryLayout` 프로퍼티 블록(:42-54)을 다음으로 교체:

```swift
    /// 라이브러리 뷰가 보여줄 폴더. 기본·리셋값은 currentFolder.
    var selectedFolder: URL? = nil {
        didSet {
            restoreLibraryLayoutForSelectedFolder()
            restoreLibrarySortForSelectedFolder()
            // 폴더 이동 = 선택 해제(Finder 동일, F1b 스펙 §2). 같은 값 재대입은 무시.
            if oldValue != selectedFolder { clearFileSelection() }
        }
    }
    /// 라이브러리 뷰 레이아웃(grid/list). 폴더별 기억 포함.
    var libraryLayout: LibraryLayout = .grid {
        didSet { persistLibraryLayoutForCurrentFolder(oldValue: oldValue) }
    }
    /// 복원 중 libraryLayout didSet이 재저장하지 않도록 막는 플래그.
    private var isRestoringLayout = false

    /// 라이브러리·트리 정렬(F3). 폴더별 기억 포함 — 기억 없으면 PARA 기본.
    var librarySort: LibrarySort = .default {
        didSet { persistLibrarySortForCurrentFolder(oldValue: oldValue) }
    }
    /// 복원 중 librarySort didSet이 재저장하지 않도록 막는 플래그.
    private var isRestoringSort = false
```

② 기억 함수 블록(:819-842)을 다음으로 교체(공용 키 헬퍼 + 정렬 함수 추가 + 기존 레이아웃 함수의 키 산출 통일):

```swift
    // MARK: - 폴더별 기억 (레이아웃 Phase 8.5-③ · 정렬 F3)

    /// 폴더별 기억(레이아웃·정렬) 딕셔너리 키 — 두 기능이 같은 규약을 쓴다.
    /// 심링크(/var↔/private/var)까지는 해소하지 않는다(libraryLayouts·F1b 관례, 스펙 §2.3).
    static func folderMemoryKey(for url: URL) -> String {
        url.standardizedFileURL.path
    }

    /// 폴더별 기억의 기준 폴더 — 복원·저장이 같은 폴백을 쓴다(기존 restore가
    /// selectedFolder만 보던 비대칭 해소, 스펙 §2.3).
    private var folderMemoryTarget: URL? { selectedFolder ?? currentFolder }

    /// selectedFolder가 바뀔 때 해당 폴더의 기억된 레이아웃을 복원한다.
    /// 기억이 없으면 현재 레이아웃을 그대로 유지한다.
    private func restoreLibraryLayoutForSelectedFolder() {
        guard let url = folderMemoryTarget else { return }
        guard let remembered = settings.libraryLayouts[Self.folderMemoryKey(for: url)] else { return }
        guard remembered != libraryLayout else { return }
        isRestoringLayout = true
        libraryLayout = remembered
        isRestoringLayout = false
    }

    /// libraryLayout이 바뀔 때 현재 폴더에 레이아웃을 기억하고 즉시 영속한다.
    private func persistLibraryLayoutForCurrentFolder(oldValue: LibraryLayout) {
        guard !isRestoringLayout else { return }
        guard oldValue != libraryLayout else { return }
        guard let url = folderMemoryTarget else { return }
        settings.libraryLayouts[Self.folderMemoryKey(for: url)] = libraryLayout
        saveUserData()
    }

    /// selectedFolder가 바뀔 때 해당 폴더의 기억된 정렬을 복원한다.
    /// 레이아웃과 달리 기억이 없으면 **기본(PARA)으로 복귀**한다 — 정렬은 폴더 속성(스펙 §2.3).
    private func restoreLibrarySortForSelectedFolder() {
        guard let url = folderMemoryTarget else { return }
        let remembered = settings.librarySorts[Self.folderMemoryKey(for: url)] ?? .default
        guard remembered != librarySort else { return }
        isRestoringSort = true
        librarySort = remembered
        isRestoringSort = false
    }

    /// librarySort가 바뀔 때 현재 폴더에 정렬을 기억하고 즉시 영속한다.
    private func persistLibrarySortForCurrentFolder(oldValue: LibrarySort) {
        guard !isRestoringSort else { return }
        guard oldValue != librarySort else { return }
        guard let url = folderMemoryTarget else { return }
        settings.librarySorts[Self.folderMemoryKey(for: url)] = librarySort
        saveUserData()
    }

    /// 임의 폴더의 기억된 정렬(없으면 PARA 기본) — 사이드바 트리가 폴더별 렌더 정렬에 사용(스펙 §2.5).
    func sortForFolder(_ url: URL?) -> LibrarySort {
        guard let url else { return .default }
        return settings.librarySorts[Self.folderMemoryKey(for: url)] ?? .default
    }
```

- [ ] **Step 4: 테스트 통과 + 기존 기억 테스트 회귀 확인**

Run: `swift test --filter "AppLibrarySortMemoryTests|AppLibraryLayoutMemoryTests|LibraryLayoutSettingsTests" 2>&1 | tail -5`
Expected: `Executed 12 tests, with 0 failures` (신규 6 + 기존 레이아웃 6)

- [ ] **Step 5: 커밋**

```bash
git add Sources/App/AppState.swift Tests/CmdMDTests/AppLibrarySortMemoryTests.swift
git commit -m "기능(F3): librarySort 폴더별 기억(didSet 복원·영속) + folderMemoryKey 공용화(복원/저장 폴백 비대칭 해소)"
```

---

### Task 4: 정렬 적용 배선 — buildFileTree 메타 + 트리·라이브러리

**Files:**
- Modify: `Sources/App/AppState.swift:1377-1414` (buildFileTree — 메타 키 추가)
- Modify: `Sources/Models/Workspace.swift:128-129` (주석 갱신)
- Modify: `Sources/Views/SidebarView.swift:168, 410` (LibrarySorting 교체)
- Modify: `Sources/Views/LibraryView.swift:34-52` (applySort/onChange)
- Test: `Tests/CmdMDTests/FileTreeBuildTests.swift` (확장)

**Interfaces:**
- Consumes: `LibrarySorting.sorted(_:by:under:)`(Task 2), `AppState.sortForFolder(_:)`(Task 3)
- Produces: `buildFileTree`가 fileSize/modifiedAt을 채운 `FileTreeItem` 반환. LibraryView 내부 `applySort()`(entries 재정렬 + libraryOrderedURLs 원자 갱신)

- [ ] **Step 1: 실패하는 테스트 작성** — `FileTreeBuildTests.swift` 끝에 추가:

```swift
    // MARK: - F3: 정렬용 메타 채움 (파일 크기·수정일, 폴더는 수정일만)

    func testBuildFillsFileMetadata() throws {
        let url = makeFile("meta.md")
        try Data("hello".utf8).write(to: url)

        let items = AppState.buildFileTree(at: tempDir, expanded: [])
        let file = items.first { $0.name == "meta.md" }
        XCTAssertNotNil(file)
        XCTAssertEqual(file?.fileSize, 5, "파일 크기가 채워져야 한다(F3 정렬용)")
        XCTAssertNotNil(file?.modifiedAt, "파일 수정일이 채워져야 한다")
    }

    func testBuildFillsDirectoryModifiedAtOnly() {
        makeDir("SubFolder")

        let items = AppState.buildFileTree(at: tempDir, expanded: [])
        let dir = items.first { $0.isDirectory }
        XCTAssertNotNil(dir?.modifiedAt, "폴더 수정일이 채워져야 한다")
        XCTAssertNil(dir?.fileSize, "폴더 크기는 미계산(nil) 유지 — 리스트 표기 '--'")
    }
```

- [ ] **Step 2: 테스트 실패 확인**

Run: `swift test --filter FileTreeBuildTests 2>&1 | tail -5`
Expected: FAIL — `testBuildFillsFileMetadata`에서 fileSize nil

- [ ] **Step 3: buildFileTree 메타 채움 구현**

`Sources/App/AppState.swift` buildFileTree 안에서 세 곳 수정:

```swift
        // (1) contentsOfDirectory 키 확장 — F3 정렬용 메타(사용자 결정: 트리도 정렬 적용, 스캔 비용 감수)
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
```

```swift
            // (2) resourceValues 키 확장 + 수정일 추출
            guard let resourceValues = try? itemURL.resourceValues(
                forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]) else { continue }
            let isDirectory = resourceValues.isDirectory ?? false
            let modifiedAt = resourceValues.contentModificationDate
```

```swift
            // (3) FileTreeItem 생성 두 곳에 메타 전달
            if isDirectory {
                let isExpanded = expanded.contains(itemURL)
                let children = isExpanded ? buildFileTree(at: itemURL, expanded: expanded, depth: depth + 1) : []
                items.append(FileTreeItem(url: itemURL, isDirectory: true, isExpanded: isExpanded,
                                          children: children, modifiedAt: modifiedAt))
            } else {
                if isListableInFileTree(itemURL) {
                    // 짝꿍 노트는 목록에서 숨긴다 — 미디어 행이 대표(배지로 존재 표시).
                    if CompanionNote.isCompanionNote(itemURL, siblingKeys: siblingKeys) { continue }
                    let hasNote = CompanionNote.hasCompanionNote(for: itemURL, siblingKeys: siblingKeys)
                    items.append(FileTreeItem(url: itemURL, isDirectory: false, hasCompanionNote: hasNote,
                                              fileSize: resourceValues.fileSize.map(Int64.init),
                                              modifiedAt: modifiedAt))
                }
            }
```

`Sources/Models/Workspace.swift:128-129` 주석 교체:

```swift
    /// 리스트 열·정렬용 메타 — 라이브러리 열거(LibraryListing)와 트리 스캔(buildFileTree) 모두 채운다(F3).
    /// 폴더의 fileSize는 항상 nil(크기 미계산 — 리스트 표기 "--").
```

- [ ] **Step 4: 테스트 통과 확인**

Run: `swift test --filter FileTreeBuildTests 2>&1 | tail -5`
Expected: `Executed 12 tests, with 0 failures`

- [ ] **Step 5: 사이드바 트리 정렬 교체**

`Sources/Views/SidebarView.swift:168` (트리 루트):

```swift
                        ForEach(LibrarySorting.sorted(appState.fileTree,
                                                      by: appState.sortForFolder(appState.currentFolder),
                                                      under: appState.currentFolder)) { item in
                            FileTreeItemRow(item: item)
                        }
```

`Sources/Views/SidebarView.swift:410` (펼친 자식 — 부모 폴더의 기억을 따름):

```swift
                if appState.expandedFolders.contains(item.url) {
                    ForEach(LibrarySorting.sorted(item.children,
                                                  by: appState.sortForFolder(item.url),
                                                  under: appState.currentFolder)) { child in
                        FileTreeItemRow(item: child)
                            .padding(.leading, 12)
                            .padding(.vertical, 3)
                    }
                }
```

- [ ] **Step 6: 라이브러리 applySort/onChange 배선**

`Sources/Views/LibraryView.swift` — `reloadEntries()`(:34-43)를 교체하고 `applySort()` 추가:

```swift
    private func reloadEntries() {
        guard let folder = displayFolder else {
            entries = []
            appState.libraryOrderedURLs = []
            return
        }
        entries = LibraryListing.entries(of: folder)
        applySort()
    }

    /// 현재 정렬로 entries를 재정렬하고 표시 순서 진실원을 **원자적으로** 동기 갱신한다.
    /// entries와 libraryOrderedURLs가 어긋나면 ⌘A·⇧범위 선택이 화면과 불일치(스펙 함정 #2).
    private func applySort() {
        entries = LibrarySorting.sorted(entries, by: appState.librarySort, under: appState.currentFolder)
        appState.libraryOrderedURLs = entries.map(\.url)
    }
```

`body`(:45-53)에 onChange 추가 — 정렬은 folderKey에 없어(디스크 재열거 방지, 스펙 §2.4) 별도 트리거가 필요하다:

```swift
    var body: some View {
        VStack(spacing: 0) {
            libraryHeader
            Divider()
            libraryBody
        }
        // 폴더가 바뀔 때만 1회 열거 — 매 렌더 동기 FS 호출 제거.
        .task(id: folderKey) { reloadEntries() }
        // 정렬 변경은 캐시 재정렬만(재열거 없음). 폴더 전환 직후엔 옛 entries에 한 번 적용된 뒤
        // .task(id: folderKey)가 새 폴더를 다시 열거한다(일시적 중복 — 무해).
        .onChange(of: appState.librarySort) { _, _ in applySort() }
    }
```

- [ ] **Step 7: 빌드·전체 테스트**

Run: `swift build 2>&1 | tail -3` → 경고 0, `swift test 2>&1 | tail -3` → 전체 통과
Expected: `Executed 5XX tests, with 0 failures` (기존 503 + Task 1~4 신규)

- [ ] **Step 8: 커밋**

```bash
git add Sources/App/AppState.swift Sources/Models/Workspace.swift Sources/Views/SidebarView.swift Sources/Views/LibraryView.swift Tests/CmdMDTests/FileTreeBuildTests.swift
git commit -m "기능(F3): 정렬 적용 배선 — buildFileTree 메타 채움(트리 정렬 데이터)·사이드바 폴더별 정렬·라이브러리 applySort(진실원 원자 갱신)"
```

---

### Task 5: 정렬 UI — 툴바 메뉴 + 리스트 열 헤더

**Files:**
- Modify: `Sources/Views/ContentView.swift:45-53`(툴바)·`:216-235` 근처(LibrarySortMenu 신설)
- Modify: `Sources/Views/LibraryView.swift` (libraryBody list 분기에 열 헤더 행)

**Interfaces:**
- Consumes: `appState.librarySort`·`LibrarySort.selecting(_:)`(Task 1·3), `LibrarySortKey.title`(Task 1)
- Produces: `LibrarySortMenu`(툴바), LibraryView 내부 `listHeader`

- [ ] **Step 1: LibrarySortMenu 구현** — `ContentView.swift`의 `LibraryLayoutPicker` struct 아래에 추가:

```swift
/// 라이브러리 정렬 메뉴(라이브러리 모드 전용) — 키 선택·방향 토글(스펙 §2.6).
/// 상태는 appState.librarySort 하나 — 리스트 열 헤더와 공유(영속은 didSet 전담).
struct LibrarySortMenu: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Menu {
            ForEach(LibrarySortKey.allCases, id: \.self) { key in
                Button {
                    appState.librarySort = appState.librarySort.selecting(key)
                } label: {
                    if appState.librarySort.key == key {
                        Label(key.title, systemImage: "checkmark")
                    } else {
                        Text(key.title)
                    }
                }
            }
            Divider()
            Button {
                appState.librarySort.ascending = true
            } label: {
                if appState.librarySort.key != .para && appState.librarySort.ascending {
                    Label("오름차순", systemImage: "checkmark")
                } else {
                    Text("오름차순")
                }
            }
            .disabled(appState.librarySort.key == .para)
            Button {
                appState.librarySort.ascending = false
            } label: {
                if appState.librarySort.key != .para && !appState.librarySort.ascending {
                    Label("내림차순", systemImage: "checkmark")
                } else {
                    Text("내림차순")
                }
            }
            .disabled(appState.librarySort.key == .para)
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
        .fixedSize()
        .help("정렬")
    }
}
```

- [ ] **Step 2: 툴바 배치** — `ContentView.swift:45-53`의 라이브러리 분기에 병치:

```swift
            ToolbarItemGroup(placement: .navigation) {
                MainModePicker()
                if appState.mainMode == .reader {
                    ViewModePicker()
                } else {
                    LibraryLayoutPicker()
                    LibrarySortMenu()
                }
            }
```

- [ ] **Step 3: 리스트 열 헤더 행** — `LibraryView.swift`의 `libraryBody`(:90-115) list 분기를 교체하고 헤더 뷰 추가:

```swift
                switch appState.libraryLayout {
                case .grid:
                    gridView(entries: entries)
                case .list:
                    VStack(spacing: 0) {
                        listHeader
                        Divider()
                        listView(entries: entries)
                    }
                }
```

`listView` 함수 위에 추가:

```swift
    // MARK: - 리스트 열 헤더 (F3 — 클릭 정렬)

    /// 열 헤더 행 — 스크롤 영역 **밖**(배경 탭 선택 해제 제스처와 히트 경합 없음, 스펙 §2.6).
    /// 폭·간격은 셀(HStack spacing 8, 수정일 92pt·크기 68pt, listRowInsets 좌우 8)과 수동 동기.
    /// 종류 정렬은 열이 없으므로 툴바 메뉴로만.
    private var listHeader: some View {
        HStack(spacing: 8) {
            sortHeaderButton(title: "이름", key: .name)
                .frame(maxWidth: .infinity, alignment: .leading)
            sortHeaderButton(title: "수정일", key: .date)
                .frame(width: 92, alignment: .trailing)
            sortHeaderButton(title: "크기", key: .size)
                .frame(width: 68, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    /// 헤더 버튼 — 클릭=키 선택, 같은 키 재클릭=방향 토글(LibrarySort.selecting 공용 전이).
    private func sortHeaderButton(title: String, key: LibrarySortKey) -> some View {
        Button {
            appState.librarySort = appState.librarySort.selecting(key)
        } label: {
            HStack(spacing: 2) {
                Text(title)
                if appState.librarySort.key == key {
                    Image(systemName: appState.librarySort.ascending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                }
            }
            .font(.caption)
            .foregroundStyle(appState.librarySort.key == key ? Color.cmdsAccent : Color.secondary)
        }
        .buttonStyle(.plain)
    }
```

- [ ] **Step 4: 빌드·전체 테스트**

Run: `swift build 2>&1 | tail -3` → 경고 0, `swift test 2>&1 | tail -3` → 전체 통과

- [ ] **Step 5: 커밋**

```bash
git add Sources/Views/ContentView.swift Sources/Views/LibraryView.swift
git commit -m "기능(F3): 정렬 UI — 툴바 정렬 메뉴(키 체크마크·방향, para 방향 비활성)·리스트 열 헤더 클릭 정렬(▲▼)"
```

---

### Task 6: NavigationHistory 순수 모델

**Files:**
- Create: `Sources/Services/NavigationHistory.swift`
- Test: `Tests/CmdMDTests/NavigationHistoryTests.swift` (신규)

**Interfaces:**
- Produces: `struct FolderLocation: Equatable { let root: URL; let display: URL }` + `func isSameLocation(as:) -> Bool`; `struct NavigationHistory { var canGoBack/canGoForward: Bool; private(set) var backStack/forwardStack: [FolderLocation]; private(set) var current: FolderLocation?; mutating func record(_:); mutating func goBack(isValid:) -> FolderLocation?; mutating func goForward(isValid:) -> FolderLocation?; mutating func prune(isValid:) }`

- [ ] **Step 1: 실패하는 테스트 작성**

`Tests/CmdMDTests/NavigationHistoryTests.swift`:

```swift
import XCTest
@testable import CmdMD

/// F3: NavigationHistory 순수 모델 테스트 — FS 접근 없음(존재 검사는 클로저 주입).
final class NavigationHistoryTests: XCTestCase {

    private func loc(_ display: String, root: String = "/root") -> FolderLocation {
        FolderLocation(root: URL(fileURLWithPath: root), display: URL(fileURLWithPath: display))
    }
    private let alwaysValid: (FolderLocation) -> Bool = { _ in true }

    // MARK: - seed: 첫 record는 current만 채우고 스택 불변

    func testFirstRecordSeedsWithoutPush() {
        var h = NavigationHistory()
        h.record(loc("/root"))
        XCTAssertFalse(h.canGoBack, "첫 기록(seed)은 뒤로 갈 곳을 만들지 않는다")
        XCTAssertEqual(h.current, loc("/root"))
    }

    // MARK: - record: 이동 시 push + forward 클리어, 연속 중복 무시

    func testRecordPushesAndClearsForward() {
        var h = NavigationHistory()
        h.record(loc("/root"))
        h.record(loc("/root/a"))
        h.record(loc("/root/b"))
        XCTAssertNotNil(h.goBack(isValid: alwaysValid))
        XCTAssertTrue(h.canGoForward)
        h.record(loc("/root/c"))
        XCTAssertFalse(h.canGoForward, "새 이동은 forwardStack을 버린다(브라우저 규약)")
    }

    func testConsecutiveDuplicateIsIgnored() {
        var h = NavigationHistory()
        h.record(loc("/root"))
        h.record(loc("/root/a"))
        h.record(loc("/root/a"))   // didSet 재발화 등 — standardized 동등이면 무시
        XCTAssertEqual(h.backStack.count, 1, "연속 중복은 병합돼야 한다")
    }

    // MARK: - goBack/goForward 왕복

    func testBackForwardRoundTrip() {
        var h = NavigationHistory()
        h.record(loc("/root"))
        h.record(loc("/root/a"))
        XCTAssertEqual(h.goBack(isValid: alwaysValid), loc("/root"))
        XCTAssertEqual(h.current, loc("/root"))
        XCTAssertEqual(h.goForward(isValid: alwaysValid), loc("/root/a"))
        XCTAssertEqual(h.current, loc("/root/a"))
        XCTAssertFalse(h.canGoForward)
    }

    func testGoBackOnEmptyReturnsNil() {
        var h = NavigationHistory()
        XCTAssertNil(h.goBack(isValid: alwaysValid))
        h.record(loc("/root"))
        XCTAssertNil(h.goBack(isValid: alwaysValid), "seed만 있으면 뒤로 갈 곳이 없다")
    }

    // MARK: - skip-pop: 죽은 항목은 건너뛰며 계속 pop

    func testGoBackSkipsInvalidEntries() {
        var h = NavigationHistory()
        h.record(loc("/root"))
        h.record(loc("/root/dead"))
        h.record(loc("/root/b"))
        let result = h.goBack { !$0.display.path.contains("dead") }
        XCTAssertEqual(result, loc("/root"), "죽은 항목(dead)은 건너뛰고 그 아래 항목으로")
    }

    func testGoBackAllInvalidReturnsNil() {
        var h = NavigationHistory()
        h.record(loc("/root"))
        h.record(loc("/root/a"))
        XCTAssertNil(h.goBack { _ in false })
        XCTAssertFalse(h.canGoBack, "전부 무효면 스택이 비워지고 nil")
    }

    // MARK: - prune

    func testPruneRemovesInvalidFromBothStacks() {
        var h = NavigationHistory()
        h.record(loc("/root"))
        h.record(loc("/root/dead"))
        h.record(loc("/root/b"))
        _ = h.goBack(isValid: alwaysValid)   // dead가 forward로
        h.prune { !$0.display.path.contains("dead") }
        XCTAssertFalse(h.backStack.contains(loc("/root/dead")))
        XCTAssertFalse(h.forwardStack.contains(loc("/root/dead")))
    }

    // MARK: - cap: backStack 상한 100

    func testBackStackCapped() {
        var h = NavigationHistory()
        for i in 0...150 { h.record(loc("/root/\(i)")) }
        XCTAssertEqual(h.backStack.count, NavigationHistory.capacity,
                       "backStack은 상한(\(NavigationHistory.capacity))을 넘지 않는다")
        XCTAssertEqual(h.backStack.last, loc("/root/149"), "최신 항목이 보존돼야 한다")
    }
}
```

- [ ] **Step 2: 테스트 실패 확인**

Run: `swift test --filter NavigationHistoryTests 2>&1 | tail -5`
Expected: 컴파일 실패 — "cannot find 'NavigationHistory' in scope"

- [ ] **Step 3: 최소 구현**

`Sources/Services/NavigationHistory.swift` (신규):

```swift
import Foundation

// MARK: - FolderLocation

/// 폴더 히스토리 한 항목 — (작업 폴더 루트, 표시 폴더) 쌍(스펙 §3.1, 사용자 결정 4).
struct FolderLocation: Equatable {
    let root: URL
    let display: URL

    /// standardized 경로 기준 동등성(연속 중복 병합용).
    /// 심링크(/var↔/private/var)까지는 해소하지 않는다(F1b 관례).
    func isSameLocation(as other: FolderLocation) -> Bool {
        root.standardizedFileURL.path == other.root.standardizedFileURL.path
            && display.standardizedFileURL.path == other.display.standardizedFileURL.path
    }
}

// MARK: - NavigationHistory

/// 뒤로/앞으로 폴더 히스토리 — 순수 구조체. FS 접근 없음(존재 검사는 클로저 주입 — 테스트 결정성).
/// 세션 내 휘발(영속 없음 — SessionState 무변경, 스펙 §3).
struct NavigationHistory {
    private(set) var backStack: [FolderLocation] = []
    private(set) var forwardStack: [FolderLocation] = []
    private(set) var current: FolderLocation?

    /// backStack 상한 — 무한 누적 방지.
    static let capacity = 100

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    /// 새 위치 기록. current가 없으면 seed(스택 불변). 직전과 같은 위치면 무시(didSet 재발화 흡수).
    /// 새 위치로 이동하면 forwardStack은 버린다(브라우저 규약).
    mutating func record(_ loc: FolderLocation) {
        guard let cur = current else { current = loc; return }
        guard !cur.isSameLocation(as: loc) else { return }
        backStack.append(cur)
        if backStack.count > Self.capacity {
            backStack.removeFirst(backStack.count - Self.capacity)
        }
        forwardStack = []
        current = loc
    }

    /// 뒤로 — 죽은 항목(isValid false)은 버리며 계속 pop(skip-pop). 성공 시 current를 forward로.
    mutating func goBack(isValid: (FolderLocation) -> Bool) -> FolderLocation? {
        while let loc = backStack.popLast() {
            if isValid(loc) {
                if let cur = current { forwardStack.append(cur) }
                current = loc
                return loc
            }
        }
        return nil
    }

    /// 앞으로 — goBack의 대칭.
    mutating func goForward(isValid: (FolderLocation) -> Bool) -> FolderLocation? {
        while let loc = forwardStack.popLast() {
            if isValid(loc) {
                if let cur = current { backStack.append(cur) }
                current = loc
                return loc
            }
        }
        return nil
    }

    /// 죽은 경로 제거(파일 작업 후 호출). current는 건드리지 않는다(호출부가 재조준 담당 — 스펙 §5).
    mutating func prune(isValid: (FolderLocation) -> Bool) {
        backStack.removeAll { !isValid($0) }
        forwardStack.removeAll { !isValid($0) }
    }
}
```

- [ ] **Step 4: 테스트 통과 확인**

Run: `swift test --filter NavigationHistoryTests 2>&1 | tail -5`
Expected: `Executed 9 tests, with 0 failures`

- [ ] **Step 5: 커밋**

```bash
git add Sources/Services/NavigationHistory.swift Tests/CmdMDTests/NavigationHistoryTests.swift
git commit -m "기능(F3): NavigationHistory 순수 모델 — (루트,표시폴더) 스택·중복 병합·skip-pop·prune·cap 100"
```

---

### Task 7: AppState 히스토리 배선 + goUp 이전 + stale selectedFolder 동반 수정

**Files:**
- Modify: `Sources/App/AppState.swift` — ①프로퍼티(:56 근처)·②selectedFolder didSet(:42-48)·③네비게이션 함수 신설(openFolder 근처)·④restoreSessionIfNeeded(:3041-3047)·⑤completeFileOperation(:2291-2296)
- Modify: `Sources/Views/LibraryView.swift:24-32, 178-188` (canGoUp/goUp → AppState 위임)
- Test: `Tests/CmdMDTests/AppNavigationHistoryTests.swift` (신규)

**Interfaces:**
- Consumes: `NavigationHistory`/`FolderLocation`(Task 6)
- Produces: `AppState.navHistory: NavigationHistory`, `func goBackInHistory()`, `func goForwardInHistory()`, `var canGoUpInLibrary: Bool`, `func goUpInLibrary()`, `func retargetStaleSelectedFolder()`(internal — 테스트 접근)

- [ ] **Step 1: 실패하는 테스트 작성**

`Tests/CmdMDTests/AppNavigationHistoryTests.swift`:

```swift
import XCTest
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
}
```

- [ ] **Step 2: 테스트 실패 확인**

Run: `swift test --filter AppNavigationHistoryTests 2>&1 | tail -5`
Expected: 컴파일 실패 — "no member 'navHistory'"

주의: `SessionState`의 멤버와 순서가 다르면(멤버와이즈 init) 테스트 컴파일이 깨진다 — `Sources/Models/Workspace.swift:231-238`의 실제 필드 순서를 확인해 맞출 것(**SessionState 자체는 수정 금지**).

- [ ] **Step 3: 구현**

`Sources/App/AppState.swift` — ① 프로퍼티(`isRestoringSort` 아래):

```swift
    // MARK: - 폴더 네비게이션 히스토리 (F3)

    /// 뒤로/앞으로 폴더 히스토리(세션 내 휘발 — SessionState 무변경, 스펙 §3).
    var navHistory = NavigationHistory()
    /// 히스토리 이동·세션 복원·강제 재조준 중 didSet 기록을 막는 플래그(isRestoringLayout 동형).
    private var suppressHistoryRecording = false
```

② `selectedFolder` didSet에 기록 한 줄 추가(Task 3에서 만든 블록의 `clearFileSelection` 앞):

```swift
    var selectedFolder: URL? = nil {
        didSet {
            restoreLibraryLayoutForSelectedFolder()
            restoreLibrarySortForSelectedFolder()
            // 히스토리 기록 — 전 진입로(드릴인·상위·사이드바 탭·openFolder·즐겨찾기)의
            // 단일 초크포인트. 새 호출부가 push를 빠뜨리는 태스크 경계 결함을 구조로 방지(스펙 §3.2).
            recordNavigationIfNeeded()
            // 폴더 이동 = 선택 해제(Finder 동일, F1b 스펙 §2). 같은 값 재대입은 무시.
            if oldValue != selectedFolder { clearFileSelection() }
        }
    }
```

③ 네비게이션 함수 신설 — `selectFolderForLibrary`(:815) 아래에 추가:

```swift
    // MARK: - 뒤로/앞으로/상위 (F3)

    private func recordNavigationIfNeeded() {
        guard !suppressHistoryRecording, let root = currentFolder else { return }
        navHistory.record(FolderLocation(root: root, display: selectedFolder ?? root))
    }

    /// 히스토리 항목의 두 폴더가 모두 디렉터리로 실존하는가.
    private static func folderExists(_ loc: FolderLocation) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: loc.root.path, isDirectory: &isDir),
              isDir.boolValue else { return false }
        guard FileManager.default.fileExists(atPath: loc.display.path, isDirectory: &isDir),
              isDir.boolValue else { return false }
        return true
    }

    func goBackInHistory() {
        guard let loc = navHistory.goBack(isValid: Self.folderExists) else { return }
        applyHistoryLocation(loc)
    }

    func goForwardInHistory() {
        guard let loc = navHistory.goForward(isValid: Self.folderExists) else { return }
        applyHistoryLocation(loc)
    }

    /// 히스토리 항목 적용 — 루트가 다르면 openFolder 경로 재사용(트리·인덱스·세션까지 복원).
    /// 항상 라이브러리 모드로 전환 — 리더에 남아 화면이 안 바뀌는 함정 방지(스펙 §3.2).
    private func applyHistoryLocation(_ loc: FolderLocation) {
        suppressHistoryRecording = true
        defer { suppressHistoryRecording = false }
        if currentFolder?.standardizedFileURL.path != loc.root.standardizedFileURL.path {
            openFolder(at: loc.root)
        }
        selectedFolder = loc.display
        mainMode = .library
    }

    /// 라이브러리 표시 폴더 기준 상위 이동 가능 여부 — currentFolder(루트) 하한.
    /// (LibraryView에서 이전 — 메뉴·⌘↑가 호출할 수 있게 AppState 소유, 스펙 §6)
    var canGoUpInLibrary: Bool {
        guard let display = selectedFolder ?? currentFolder,
              let root = currentFolder else { return false }
        let displayStd = display.standardizedFileURL.path
        let rootStd = root.standardizedFileURL.path
        // '/' 경계를 포함해 형제 폴더 오감지를 방지한다.
        return displayStd != rootStd && displayStd.hasPrefix(rootStd + "/")
    }

    /// 상위 폴더로(⌘↑·메뉴·경로 바) — 라이브러리 모드에서만(리더의 NSTextView ⌘↑ 표준
    /// 동작 강탈 방지, 스펙 §6), root 하한 클램프.
    func goUpInLibrary() {
        guard mainMode == .library else { return }
        guard let current = selectedFolder ?? currentFolder,
              let root = currentFolder else { return }
        let parent = current.deletingLastPathComponent()
        let parentStd = parent.standardizedFileURL.path
        let rootStd = root.standardizedFileURL.path
        if parentStd == rootStd || parentStd.hasPrefix(rootStd + "/") {
            selectedFolder = parent
        }
    }

    /// 표시 중 폴더가 rename/trash로 사라졌으면 가장 가까운 존재 조상으로 재조준
    /// (F1a 트리아지 잔여 — 빈 라이브러리·죽은 경로 바 방지, 스펙 §5).
    /// 사용자 내비게이션이 아니므로 히스토리에 기록하지 않는다. internal = 테스트 접근용.
    func retargetStaleSelectedFolder() {
        guard let sel = selectedFolder else { return }
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: sel.path, isDirectory: &isDir), isDir.boolValue { return }
        var candidate = sel.deletingLastPathComponent()
        while candidate.path != "/" {
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDir),
               isDir.boolValue { break }
            candidate = candidate.deletingLastPathComponent()
        }
        suppressHistoryRecording = true
        selectedFolder = candidate
        suppressHistoryRecording = false
    }
```

④ `restoreSessionIfNeeded`(:3041-3047)의 폴더 복원 분기 교체 — 복원 대입은 기록 억제, 이후 seed:

```swift
        if let folder = session.currentFolder,
           FileManager.default.fileExists(atPath: folder.path) {
            suppressHistoryRecording = true
            currentFolder = folder
            // 세션 복원 시 currentFolder가 바뀌므로 selectedFolder도 리셋한다.
            selectedFolder = folder
            suppressHistoryRecording = false
            // 복원 위치를 히스토리 시작점으로 seed(가짜 뒤로 항목 없이).
            navHistory.record(FolderLocation(root: folder, display: folder))
            loadFileTree()
        }
```

⑤ `completeFileOperation`(:2291-2296)에 재조준·prune 추가:

```swift
    /// 파일 작업 성공 후 공통 갱신 — 세대 토큰·트리·세션·선택 prune·표시 폴더/히스토리 정합(F3).
    private func completeFileOperation() {
        fileOpsGeneration += 1
        pruneFileSelection()
        retargetStaleSelectedFolder()
        navHistory.prune(isValid: Self.folderExists)
        loadFileTree()
        saveSession()
    }
```

- [ ] **Step 4: LibraryView 위임 전환**

`Sources/Views/LibraryView.swift` — 로컬 `canGoUp`(:24-32)과 `goUp()`(:176-188)을 삭제하고, 사용처 2곳을 위임으로 교체:

```swift
            if appState.canGoUpInLibrary {
                Button {
                    appState.goUpInLibrary()
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.borderless)
                .help("상위 폴더로")
            }
```

(`// MARK: - 상위 이동` 섹션 전체 삭제 — Task 10에서 헤더 자체가 PathBarView로 교체된다.)

- [ ] **Step 5: 테스트 통과 + 전체 회귀**

Run: `swift test --filter AppNavigationHistoryTests 2>&1 | tail -5` → `Executed 8 tests, with 0 failures`
Run: `swift test 2>&1 | tail -3` → 전체 통과 (특히 AppLibraryStateTests·AppLibraryLayoutMemoryTests — didSet 확장 회귀)

- [ ] **Step 6: 커밋**

```bash
git add Sources/App/AppState.swift Sources/Views/LibraryView.swift Tests/CmdMDTests/AppNavigationHistoryTests.swift
git commit -m "기능(F3): 히스토리 배선 — didSet 단일 초크포인트+억제 플래그·뒤로/앞으로(라이브러리 강제)·goUp AppState 이전·stale selectedFolder 재조준(F1a 잔여)"
```

---

### Task 8: PathBarModel 세그먼트 계산 (순수)

**Files:**
- Create: `Sources/Services/PathBarModel.swift`
- Test: `Tests/CmdMDTests/PathBarModelTests.swift` (신규)

**Interfaces:**
- Produces: `struct PathSegment: Equatable { let url: URL; let name: String; let isWithinRoot: Bool; let isFile: Bool }`; `PathBarModel.segments(target: URL, root: URL?, home: URL, targetIsFile: Bool) -> [PathSegment]`; `PathBarModel.isWithin(_ path: String, ancestor: String) -> Bool`

- [ ] **Step 1: 실패하는 테스트 작성**

`Tests/CmdMDTests/PathBarModelTests.swift`:

```swift
import XCTest
@testable import CmdMD

/// F3: PathBarModel 세그먼트 분해 테스트 — '/' 경계·루트 안/밖·홈 축약·파일 플래그.
/// 기존 SimpleBreadcrumbView의 경계 없는 hasPrefix(형제 폴더 오감지) 버그의 회귀 방지 포함.
final class PathBarModelTests: XCTestCase {

    private let home = URL(fileURLWithPath: "/Users/me")

    private func names(_ segs: [PathSegment]) -> [String] { segs.map(\.name) }

    // MARK: - 기본 분해: 홈 하위면 홈(~)부터

    func testSegmentsFromHomeForHomeRelativeTarget() {
        let segs = PathBarModel.segments(target: URL(fileURLWithPath: "/Users/me/docs/proj"),
                                         root: URL(fileURLWithPath: "/Users/me/docs"),
                                         home: home, targetIsFile: false)
        XCTAssertEqual(names(segs), ["~", "docs", "proj"])
        XCTAssertEqual(segs.map(\.isWithinRoot), [false, true, true],
                       "root(docs) 자신부터 안쪽이 isWithinRoot")
        XCTAssertEqual(segs.map(\.isFile), [false, false, false])
    }

    // MARK: - 홈 밖 target은 "/"부터

    func testSegmentsFromSlashForNonHomeTarget() {
        let segs = PathBarModel.segments(target: URL(fileURLWithPath: "/tmp/work"),
                                         root: nil, home: home, targetIsFile: false)
        XCTAssertEqual(names(segs), ["/", "tmp", "work"])
        XCTAssertEqual(segs.map(\.isWithinRoot), [false, false, false], "root nil이면 전부 루트 밖")
    }

    // MARK: - 파일 target: 마지막 세그먼트만 isFile

    func testFileTargetMarksLastSegment() {
        let segs = PathBarModel.segments(target: URL(fileURLWithPath: "/Users/me/docs/a.md"),
                                         root: URL(fileURLWithPath: "/Users/me/docs"),
                                         home: home, targetIsFile: true)
        XCTAssertEqual(segs.last?.isFile, true)
        XCTAssertEqual(segs.last?.name, "a.md")
        XCTAssertEqual(segs.dropLast().map(\.isFile), [false, false])
    }

    // MARK: - '/' 경계: 형제 폴더 오감지 회귀(a vs ab)

    func testSiblingPrefixIsNotWithinRoot() {
        let segs = PathBarModel.segments(target: URL(fileURLWithPath: "/Users/me/ab/x"),
                                         root: URL(fileURLWithPath: "/Users/me/a"),
                                         home: home, targetIsFile: false)
        XCTAssertEqual(segs.map(\.isWithinRoot), [false, false, false, false],
                       "'/Users/me/ab'는 root '/Users/me/a'의 하위가 아니다('/' 경계)")
    }

    // MARK: - 루트 자신 포함

    func testRootItselfIsWithinRoot() {
        let root = URL(fileURLWithPath: "/Users/me/docs")
        let segs = PathBarModel.segments(target: root, root: root, home: home, targetIsFile: false)
        XCTAssertEqual(segs.last?.isWithinRoot, true, "루트 자신도 isWithinRoot(클릭=루트 라이브러리)")
    }

    // MARK: - isWithin 헬퍼

    func testIsWithinBoundary() {
        XCTAssertTrue(PathBarModel.isWithin("/a/b", ancestor: "/a"))
        XCTAssertTrue(PathBarModel.isWithin("/a", ancestor: "/a"))
        XCTAssertFalse(PathBarModel.isWithin("/ab", ancestor: "/a"), "'/' 경계 필수")
        XCTAssertTrue(PathBarModel.isWithin("/x", ancestor: "/"), "루트 조상 특례")
    }
}
```

- [ ] **Step 2: 테스트 실패 확인**

Run: `swift test --filter PathBarModelTests 2>&1 | tail -5`
Expected: 컴파일 실패 — "cannot find 'PathBarModel' in scope"

- [ ] **Step 3: 최소 구현**

`Sources/Services/PathBarModel.swift` (신규):

```swift
import Foundation

// MARK: - PathSegment

/// 경로 바 세그먼트 하나(스펙 §4.1).
/// isWithinRoot = 작업 폴더(루트) 안(루트 자신 포함) — 클릭 시맨틱 분기(§4.3).
struct PathSegment: Equatable {
    let url: URL
    let name: String
    let isWithinRoot: Bool
    let isFile: Bool
}

// MARK: - PathBarModel

/// 경로 바 세그먼트 계산 — 순수 헬퍼(FS 접근 없음).
/// 비교는 standardizedFileURL + '/' 경계 — 기존 SimpleBreadcrumbView의 경계 없는
/// hasPrefix(형제 폴더 오감지) 버그를 제거한 구현(스펙 §4.1, 함정 #5).
enum PathBarModel {

    /// target(파일 또는 폴더)의 조상 체인을 위→아래 순서 세그먼트로 분해한다.
    /// 표시 범위: target이 home 하위면 home("~")부터, 아니면 "/"부터 전부.
    static func segments(target: URL, root: URL?,
                         home: URL = FileManager.default.homeDirectoryForCurrentUser,
                         targetIsFile: Bool) -> [PathSegment] {
        let targetStd = target.standardizedFileURL
        let homePath = home.standardizedFileURL.path
        let rootPath = root?.standardizedFileURL.path

        // target에서 위로 올라가며 수집 후 뒤집는다.
        let stopPath = isWithin(targetStd.path, ancestor: homePath) ? homePath : "/"
        var chain: [URL] = []
        var cursor = targetStd
        while true {
            chain.append(cursor)
            if cursor.path == stopPath || cursor.path == "/" { break }
            cursor = cursor.deletingLastPathComponent()
        }
        chain.reverse()

        return chain.enumerated().map { index, url in
            let isLast = index == chain.count - 1
            let name: String
            if url.path == homePath { name = "~" }
            else if url.path == "/" { name = "/" }
            else { name = url.lastPathComponent }
            return PathSegment(url: url,
                               name: name,
                               isWithinRoot: rootPath.map { isWithin(url.path, ancestor: $0) } ?? false,
                               isFile: isLast && targetIsFile)
        }
    }

    /// path가 ancestor와 같거나 그 하위인가 — '/' 경계 포함.
    static func isWithin(_ path: String, ancestor: String) -> Bool {
        if path == ancestor { return true }
        let prefix = ancestor.hasSuffix("/") ? ancestor : ancestor + "/"
        return path.hasPrefix(prefix)
    }
}
```

- [ ] **Step 4: 테스트 통과 확인**

Run: `swift test --filter PathBarModelTests 2>&1 | tail -5`
Expected: `Executed 6 tests, with 0 failures`

- [ ] **Step 5: 커밋**

```bash
git add Sources/Services/PathBarModel.swift Tests/CmdMDTests/PathBarModelTests.swift
git commit -m "기능(F3): PathBarModel 순수 세그먼트 분해 — '/' 경계·루트 안/밖 플래그·홈(~) 축약·파일 플래그"
```

---

### Task 9: 단축키 3종 + View 메뉴 + 커맨드 팔레트

**Files:**
- Modify: `Sources/Models/Shortcuts.swift` (case 3종·title·defaultBinding)
- Modify: `Sources/App/CmdMDApp.swift:129-134` 근처 (View 메뉴)
- Modify: `Sources/Views/CommandPaletteView.swift` (allCommands 배열에 3건 — "정보 보기" 항목 근처)
- Test: `Tests/CmdMDTests/ShortcutDefaultsTests.swift` (확장)

**Interfaces:**
- Consumes: `AppState.goBackInHistory()`/`goForwardInHistory()`/`goUpInLibrary()`/`canGoUpInLibrary`/`navHistory`(Task 7)
- Produces: `AppShortcut.navigateBack`(⌘[)·`.navigateForward`(⌘])·`.navigateUp`(⌘↑)

**설계 확인(스펙 §6):** ⌘[·⌘]·⌘↑는 하드코딩 단축키 12곳과 무충돌(수동 대조 완료 — ⇧⌘[/]는 탭 전환으로 Shift 한 끗 차이). ⌘↑는 NSTextView의 문서 처음 이동 표준과 충돌하므로 메뉴 `.disabled`(라이브러리 모드 한정) + 액션 내 가드 이중 방어 — 리더 모드에선 메뉴가 비활성이라 키가 텍스트 뷰로 정상 전달된다.

- [ ] **Step 1: 실패하는 테스트 작성** — `ShortcutDefaultsTests.swift`에 추가:

```swift
    func testF3NavigationShortcutDefaults() {
        // ⌘[/⌘]는 미점유 확인(⇧⌘[/]=탭 전환과 Shift로 구분), ⌘↑는 라이브러리 모드 한정.
        XCTAssertEqual(AppShortcut.navigateBack.defaultBinding,
                       KeyBinding(key: "[", command: true))
        XCTAssertEqual(AppShortcut.navigateForward.defaultBinding,
                       KeyBinding(key: "]", command: true))
        XCTAssertEqual(AppShortcut.navigateUp.defaultBinding,
                       KeyBinding(key: "ArrowUp", command: true))
    }
```

- [ ] **Step 2: 테스트 실패 확인**

Run: `swift test --filter ShortcutDefaultsTests 2>&1 | tail -5`
Expected: 컴파일 실패 — "type 'AppShortcut' has no member 'navigateBack'"

- [ ] **Step 3: AppShortcut 확장**

`Sources/Models/Shortcuts.swift` — enum에 case 추가(`case fileInfo` 아래):

```swift
    case navigateBack
    case navigateForward
    case navigateUp
```

`title` switch에 추가(`case .fileInfo` 아래):

```swift
        case .navigateBack:    return "Back (폴더 뒤로)"
        case .navigateForward: return "Forward (폴더 앞으로)"
        case .navigateUp:      return "Enclosing Folder (상위 폴더)"
```

`defaultBinding` switch에 추가(`case .fileInfo` 아래):

```swift
        case .navigateBack:    return KeyBinding(key: "[", command: true)
        case .navigateForward: return KeyBinding(key: "]", command: true)
        case .navigateUp:      return KeyBinding(key: "ArrowUp", command: true)
```

- [ ] **Step 4: View 메뉴** — `Sources/App/CmdMDApp.swift`의 "Toggle Reader/Library" 버튼(:129-132) 바로 아래에 추가:

```swift
                Divider()

                Button("뒤로") {
                    appState.goBackInHistory()
                }
                .appShortcut(appState.keyBinding(for: .navigateBack))
                .disabled(!appState.navHistory.canGoBack)

                Button("앞으로") {
                    appState.goForwardInHistory()
                }
                .appShortcut(appState.keyBinding(for: .navigateForward))
                .disabled(!appState.navHistory.canGoForward)

                Button("상위 폴더") {
                    appState.goUpInLibrary()
                }
                .appShortcut(appState.keyBinding(for: .navigateUp))
                // 라이브러리 모드 한정 — 리더에선 비활성이라 ⌘↑가 NSTextView(문서 처음 이동)로
                // 정상 전달된다(스펙 §6). 액션 내 가드와 이중 방어.
                .disabled(appState.mainMode != .library || !appState.canGoUpInLibrary)
```

- [ ] **Step 5: 커맨드 팔레트** — `Sources/Views/CommandPaletteView.swift`의 "정보 보기" Command(:292-300) 뒤에 추가:

```swift
            Command(
                title: "뒤로 (폴더 히스토리)",
                subtitle: "이전에 보던 폴더로",
                icon: "chevron.left",
                shortcut: appState.keyBinding(for: .navigateBack).displayString,
                keywords: ["뒤로", "back", "history", "히스토리", "폴더", "이전"]
            ) {
                appState.goBackInHistory()
            },

            Command(
                title: "앞으로 (폴더 히스토리)",
                subtitle: "다음 폴더로",
                icon: "chevron.right",
                shortcut: appState.keyBinding(for: .navigateForward).displayString,
                keywords: ["앞으로", "forward", "history", "히스토리", "폴더", "다음"]
            ) {
                appState.goForwardInHistory()
            },

            Command(
                title: "상위 폴더",
                subtitle: "라이브러리 표시 폴더의 상위로",
                icon: "chevron.up",
                shortcut: appState.keyBinding(for: .navigateUp).displayString,
                keywords: ["상위", "up", "enclosing", "parent", "폴더"]
            ) {
                appState.goUpInLibrary()
            },
```

- [ ] **Step 6: 테스트 통과(유일성 포함) + 전체**

Run: `swift test --filter ShortcutDefaultsTests 2>&1 | tail -5`
Expected: `Executed 4 tests, with 0 failures` (`testDefaultBindingsAreUnique`가 신규 3종 포함 자동 검증)
Run: `swift build 2>&1 | tail -3` → 경고 0

- [ ] **Step 7: 커밋**

```bash
git add Sources/Models/Shortcuts.swift Sources/App/CmdMDApp.swift Sources/Views/CommandPaletteView.swift Tests/CmdMDTests/ShortcutDefaultsTests.swift
git commit -m "기능(F3): 단축키 3종(뒤로 ⌘[·앞으로 ⌘]·상위 ⌘↑ 라이브러리 한정) + View 메뉴·커맨드 팔레트 진입점"
```

---

### Task 10: PathBarView — 공용 경로 바 + 리더·라이브러리 교체

**Files:**
- Create: `Sources/Views/PathBarView.swift`
- Modify: `Sources/Views/MainEditorView.swift` (:23-25 교체, :56-126 SimpleBreadcrumbView 삭제)
- Modify: `Sources/Views/LibraryView.swift` (libraryHeader → PathBarView)

**Interfaces:**
- Consumes: `PathBarModel.segments(...)`(Task 8), `AppState.goBackInHistory()/goForwardInHistory()/navHistory/selectFolderForLibrary(_:)/openFolder(at:)`(Task 7·기존), `keyBinding(for: .navigateBack/.navigateForward)`(Task 9)
- Produces: `PathBarView(target: URL?, targetIsFile: Bool, trailingText: String? = nil)`

- [ ] **Step 1: PathBarView 구현**

`Sources/Views/PathBarView.swift` (신규):

```swift
import SwiftUI

// MARK: - PathBarView

/// 공용 경로 바(24pt 스트립) — ‹ › 히스토리 버튼 + 클릭 가능 브레드크럼(스펙 §4).
/// 리더(target=활성 탭 파일)·라이브러리(target=표시 폴더) 양쪽이 재사용해 모드 토글 시
/// 같은 높이·위치라 점프가 없다. target nil이면 버튼만 표시(새 문서 탭 등).
struct PathBarView: View {
    @Environment(AppState.self) private var appState

    /// 경로를 분해할 대상(파일 또는 폴더). nil이면 세그먼트 없이 버튼만.
    let target: URL?
    /// target이 파일인가(마지막 세그먼트 클릭 불가·doc 아이콘).
    let targetIsFile: Bool
    /// 트레일링 라벨(라이브러리의 "N개 선택됨" 등).
    var trailingText: String? = nil

    var body: some View {
        HStack(spacing: 6) {
            historyButtons
            if let target {
                segmentStrip(for: target)
            }
            Spacer(minLength: 0)
            if let trailingText {
                Text(trailingText)
                    .font(.caption)
                    .foregroundStyle(Color.cmdsAccent)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    // MARK: - ‹ › 히스토리 버튼

    private var historyButtons: some View {
        HStack(spacing: 2) {
            Button {
                appState.goBackInHistory()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.borderless)
            .disabled(!appState.navHistory.canGoBack)
            .help("뒤로 (\(appState.keyBinding(for: .navigateBack).displayString))")

            Button {
                appState.goForwardInHistory()
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.borderless)
            .disabled(!appState.navHistory.canGoForward)
            .help("앞으로 (\(appState.keyBinding(for: .navigateForward).displayString))")
        }
    }

    // MARK: - 브레드크럼

    private func segmentStrip(for target: URL) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                let segments = PathBarModel.segments(target: target,
                                                     root: appState.currentFolder,
                                                     targetIsFile: targetIsFile)
                ForEach(Array(segments.enumerated()), id: \.offset) { index, seg in
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                    segmentView(seg)
                }
            }
            .padding(.vertical, 4)
        }
        .contextMenu {
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([target])
            }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(target.path, forType: .string)
                appState.showToast("Path copied")
            }
        }
    }

    @ViewBuilder
    private func segmentView(_ seg: PathSegment) -> some View {
        if seg.isFile {
            segmentLabel(seg)
                .foregroundStyle(.primary)
        } else {
            Button {
                navigate(to: seg)
            } label: {
                // 루트 안=보통 톤(주 동선), 루트 밖=옅은 톤(클릭은 가능 — 작업 폴더 전환).
                segmentLabel(seg)
                    .foregroundStyle(seg.isWithinRoot ? AnyShapeStyle(.secondary)
                                                      : AnyShapeStyle(.tertiary))
            }
            .buttonStyle(.plain)
        }
    }

    private func segmentLabel(_ seg: PathSegment) -> some View {
        HStack(spacing: 3) {
            Image(systemName: seg.isFile ? "doc.text" : (seg.name == "~" ? "house" : "folder"))
                .font(.system(size: 10))
            Text(seg.name)
                .font(.system(size: 11))
                .lineLimit(1)
        }
    }

    /// 폴더 세그먼트 클릭 — 루트 안이면 표시 폴더 전환(+라이브러리 모드),
    /// 루트 밖 조상이면 작업 폴더 전환(Open Folder와 동일 — 히스토리로 복귀 가능, 스펙 §4.3).
    private func navigate(to seg: PathSegment) {
        if seg.isWithinRoot {
            appState.selectFolderForLibrary(seg.url)
        } else {
            appState.openFolder(at: seg.url)
            appState.mainMode = .library
        }
    }
}
```

- [ ] **Step 2: 리더 배치 교체** — `Sources/Views/MainEditorView.swift`:

:23-25를 다음으로 교체(fileURL 없어도 ‹ › 버튼은 표시):

```swift
        PathBarView(target: appState.currentTabFileURL, targetIsFile: true)
```

`// MARK: - Breadcrumb` 섹션의 `SimpleBreadcrumbView` struct 전체(:56-126)를 **삭제**한다(경계 없는 hasPrefix 버그 포함 — PathBarModel이 대체, 스펙 §4.2).

- [ ] **Step 3: 라이브러리 헤더 교체** — `Sources/Views/LibraryView.swift`:

`body`의 `libraryHeader`를 PathBarView로 교체:

```swift
    var body: some View {
        VStack(spacing: 0) {
            PathBarView(target: displayFolder, targetIsFile: false,
                        trailingText: appState.fileSelection.isEmpty
                            ? nil : "\(appState.fileSelection.count)개 선택됨")
            Divider()
            libraryBody
        }
        // 폴더가 바뀔 때만 1회 열거 — 매 렌더 동기 FS 호출 제거.
        .task(id: folderKey) { reloadEntries() }
        // 정렬 변경은 캐시 재정렬만(재열거 없음). 폴더 전환 직후엔 옛 entries에 한 번 적용된 뒤
        // .task(id: folderKey)가 새 폴더를 다시 열거한다(일시적 중복 — 무해).
        .onChange(of: appState.librarySort) { _, _ in applySort() }
    }
```

`// MARK: - 헤더`의 `libraryHeader`(상위 chevron 버튼 포함) 전체 삭제 — 상위 이동은 브레드크럼 부모 세그먼트+⌘↑(`goUpInLibrary`)가 대체한다(스펙 §4.2).

- [ ] **Step 4: 빌드·전체 테스트**

Run: `swift build 2>&1 | tail -3` → 경고 0 (SimpleBreadcrumbView 잔여 참조가 있으면 여기서 드러남 — `grep -rn "SimpleBreadcrumbView" Sources Tests`로 0건 확인)
Run: `swift test 2>&1 | tail -3` → 전체 통과

- [ ] **Step 5: 커밋**

```bash
git add Sources/Views/PathBarView.swift Sources/Views/MainEditorView.swift Sources/Views/LibraryView.swift
git commit -m "기능(F3): 공용 PathBarView — ‹ › 히스토리 버튼+클릭 브레드크럼(루트 밖=작업 폴더 전환), 리더 SimpleBreadcrumbView('/'경계 버그 포함) 대체·라이브러리 헤더 통합"
```

---

### Task 11: 최종 게이트 — 전체 테스트·경고 0·README

**Files:**
- Modify: `README.md` (파일 관리/탐색 문단 — 기존 서술 위치에 맞춰 경로 바·히스토리·정렬 한 줄, 테스트 수치 갱신)

- [ ] **Step 1: 전체 테스트**

Run: `swift test 2>&1 | tail -3`
Expected: `Executed 5XX tests, with 0 failures` — 수치를 기록(README·마무리 문서용). 기존 503 + 신규(설정 6·정렬 11·기억 6·트리 2·히스토리 9·앱 히스토리 8·경로 6·단축키 1 = 약 49) ≈ 552.

- [ ] **Step 2: 빌드 경고 확인**

Run: `swift build 2>&1 | grep -i warning | wc -l`
Expected: `0`

- [ ] **Step 3: README 갱신**

README의 파일 관리(F1a/F1b) 서술 근처에 탐색 기능 서술을 추가하고(경로 바 클릭 내비게이션·뒤로/앞으로 ⌘[/⌘]·정렬 이름/날짜/크기/종류(폴더별 기억)), 테스트 수치 문자열을 Step 1의 실측값으로 교체한다. `grep -n "테스트" README.md`로 수치 위치를 찾을 것.

- [ ] **Step 4: 커밋**

```bash
git add README.md
git commit -m "문서(F3): README 탐색 강화(경로 바·히스토리·정렬) 서술·테스트 수치 갱신"
```

---

## 수동 스모크 체크리스트 (계획 밖 — 구현 완료 후 실기)

1. 리더에서 md 열고 ⌘↑ → **무동작**(텍스트 커서가 문서 처음으로 — NSTextView 표준 유지), 라이브러리에서 ⌘↑ → 상위 이동.
2. 드릴인 3단 → ⌘[ 연타로 복귀 → ⌘]로 재진입. 파일 열어 리더로 나간 뒤 ⌘[ → 라이브러리 모드로 복귀.
3. 경로 바: 루트 밖 조상 클릭 → 작업 폴더 전환 → ⌘[ → 이전 루트 복원(트리까지).
4. 리스트 열 헤더 픽셀 정렬(수정일 92/크기 68) + 클릭 정렬·재클릭 방향 토글 + 그리드↔리스트 전환 후 정렬 유지.
5. 정렬 폴더별 기억: A 폴더 날짜순 → B 폴더(기본 PARA) → A 복귀 시 날짜순 복원. 앱 재시작 후에도 유지. 사이드바 트리의 A 폴더 자식도 날짜순인지 — **정렬 변경 직후 트리가 즉시 재정렬되는지 포함**(스펙 §2.5 "확인 필요": settings 변이가 사이드바 재렌더를 발화하는지 — 안 되면 관찰 가능한 값 참조 트리거 추가).
6. 대형 폴더(1,000+ 항목)에서 트리 스캔 체감(buildFileTree 메타 추가 비용).
7. 표시 중 폴더 rename → 라이브러리가 빈 화면이 아니라 존재 조상으로 이동(F1a 잔여 수정 확인).
8. 정렬 변경 후 ⌘A → 선택이 화면 순서와 일치(⇧클릭 범위 포함).
```
