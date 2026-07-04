# F3 탐색 강화 — 경로 바·히스토리·정렬 (설계)

- 날짜: 2026-07-04
- 상태: 사용자 승인(대화). Finder 대체 로드맵(F1a→F1b→**F3**→F2→F4)의 세 번째 조각.
- 선행: `2026-07-03-finder-replacement-roadmap.md`, F1a(파일 작업 기반), F1b(다중 선택+배치)

## 0. 목표와 사용자 결정

라이브러리를 "폴더를 실제로 돌아다니는 공간"으로 완성한다: 경로 바(브레드크럼), 뒤로/앞으로 폴더 히스토리, 정렬 옵션(이름/날짜/크기/종류).

사용자 결정(2026-07-04 대화):

| # | 결정 | 내용 |
|---|---|---|
| 1 | 정렬×PARA | 기본값은 지금 그대로 PARA 정렬. 사용자가 다른 키(이름/날짜/크기/종류)를 고르면 PARA 그룹을 **완전 대체**(폴더 먼저는 유지). PARA 시각 스타일(archive 흐리게·projects 강조)은 정렬과 독립이라 항상 유지. |
| 2 | 정렬 범위 | 라이브러리 + **사이드바 트리도 함께**. 트리 스캔에 날짜·크기 메타 조회를 추가하는 비용 감수. |
| 3 | 정렬 기억 | **폴더별 기억**(libraryLayouts 동형, settings.json 영속). 기억 없으면 PARA 기본. 트리도 각 폴더의 기억된 정렬을 따름(Finder의 폴더별 보기 옵션 감각). |
| 4 | 히스토리 | 항목 = **(작업 폴더 루트, 표시 폴더) 쌍**. 드릴인·상위 이동·사이드바 탭·작업 폴더 전환(Open Folder·즐겨찾기)까지 전부 기록, 뒤로가 이전 루트까지 복원. 세션 내 휘발(재시작 시 빈 히스토리). 뒤로/앞으로 실행 시 항상 라이브러리 모드로 전환. |
| 5 | 경로 바 | **공용 클릭 가능 컴포넌트 하나로 통일** — 라이브러리 헤더와 리더의 SimpleBreadcrumbView 둘 다 교체. 루트 밖 조상도 클릭 가능(=작업 폴더 전환, 히스토리로 복귀 가능). |
| 6 | 입력 수단 | ⌘[ / ⌘](리맵 가능) + 경로 바 ‹ › 버튼 + ⌘↑(상위, 라이브러리 모드 한정)만. 마우스 4/5버튼·트랙패드 스와이프는 범위 밖. |

## 1. 현재 구조 (정찰 확정 사실)

- 정렬의 단일 진실원은 `ParaLens.sorted(_:under:)`(PARA rank→폴더 먼저→이름 `localizedStandardCompare`). 호출부 3곳: 사이드바 트리 루트(SidebarView:168)·트리 자식(SidebarView:410)·라이브러리(LibraryView:40 reloadEntries). 사용자 정렬 상태는 앱 전체에 전무.
- 라이브러리 리스트엔 수정일(92pt)·크기(68pt) 열이 "표시만(정렬은 F3)" 주석과 함께 이미 존재(LibraryView:314-326). List+커스텀 HStack 셀(Table 아님), 열 헤더 행 없음.
- `LibraryListing.entries`는 fileSize·modifiedAt을 이미 채움. `AppState.buildFileTree`는 안 채움(의도적 비용 절감 — 이번에 뒤집는 결정).
- 라이브러리 표시 폴더 = `selectedFolder ?? currentFolder`. entries는 `@State` 캐시 + `.task(id: folderKey)`(표시폴더|currentFolder|fileOpsGeneration) 단일 갱신 경로. `reloadEntries`가 `libraryOrderedURLs`(⌘A·⇧범위 선택의 진실원)도 함께 갱신.
- `selectedFolder` 대입 지점 5곳: openFolder(at:) :805 / selectFolderForLibrary :815 / 세션 복원 :3045 / 라이브러리 드릴인 LibraryView:166 / goUp LibraryView:186. didSet이 레이아웃 복원+선택 클리어 수행. `currentFolder` 대입은 2곳(openFolder·세션 복원)뿐.
- 폴더별 기억 선례: `settings.libraryLayouts[standardizedFileURL.path]` + `libraryLayout` didSet 저장 + `isRestoringLayout` 되먹임 방지. 단 persist 키는 `selectedFolder ?? currentFolder`, restore 키는 `selectedFolder`만 — **비대칭**(이번에 통일).
- 리더 모드엔 클릭 불가 `SimpleBreadcrumbView`(24pt 스트립, MainEditorView:58-126) 존재. `computePathParts`가 '/' 경계 없는 `hasPrefix`(:111)라 형제 폴더 오감지 여지(구형 패턴 — 이번에 수정). 라이브러리 헤더는 상위 chevron 버튼+폴더명+선택 개수(LibraryView:57-86). goUp/canGoUp은 standardized+'/' 경계로 currentFolder 하한 클램프(올바른 패턴 — 계승).
- ⌘[ / ⌘] / ⌘↑는 앱 코드에서 미점유(⇧⌘[/]만 탭 전환). AppShortcut enum(23종)에 case를 추가하면 리맵 UI·유일성 테스트 자동 편입. KeyBinding은 대괄호·화살표 키 수용 가능. ⌘↑는 NSTextView의 문서 처음 이동 표준과 충돌 소지(AppKit 동작) → 라이브러리 모드 가드 필수.
- SessionState는 합성 Codable(하위호환 디코드 없음) — 필드 추가 시 구 session.json 복원 1회 무산. **이번엔 건드리지 않는다**(히스토리 휘발 결정과 정합).

## 2. 정렬

### 2.1 모델 — `Sources/Models/LibrarySort.swift` (신규)

```swift
enum LibrarySortKey: String, Codable, CaseIterable {
    case para, name, date, size, kind
}
struct LibrarySort: Codable, Equatable {
    var key: LibrarySortKey
    var ascending: Bool
    static let `default` = LibrarySort(key: .para, ascending: true)
    static func defaultAscending(for key: LibrarySortKey) -> Bool // name·kind·para=true, date·size=false
}
```

- 키를 새로 고르면 그 키의 기본 방향으로 시작(이름·종류 오름차순, 날짜·크기 내림차순=최신·큰 것 먼저). 같은 키 재선택/열 헤더 재클릭 = 방향 토글.
- `.para`는 방향 개념 없음 — 방향 UI 비활성, ascending 값 무시.

### 2.2 정렬 헬퍼 — `Sources/Services/LibrarySorting.swift` (신규, 순수)

```swift
enum LibrarySorting {
    static func sorted(_ items: [FileTreeItem], by sort: LibrarySort, under root: URL?) -> [FileTreeItem]
}
```

- `key == .para` → 기존 `ParaLens.sorted(items, under: root)`에 그대로 위임. **ParaLens 원본 불변**(ParaLensTests 18개·사이드바 기본 동작 안전).
- 그 외 키: ①폴더 먼저(방향과 무관하게 항상) → ②선택 키 비교(ascending 반영) → ③이름 `localizedStandardCompare` 오름차순 tie-break(방향과 무관하게 고정 — 안정된 2차 질서).
  - **name**: `localizedStandardCompare`(Finder식 자연 정렬·한국어 로케일).
  - **date**: `modifiedAt`, nil은 `.distantPast` 취급(항상 가장 오래된 쪽).
  - **size**: 파일만 의미 — 폴더 구간은 이름 오름차순 고정(폴더 크기 미계산 설계 유지), 파일 nil은 0 취급.
  - **kind**: `DocumentKind` rank → 같은 kind 안에서 `pathExtension` 사전순 → 이름. rank는 `DocumentKind`에 `sortRank` computed 추가(단일 판별원 정합): markdown(문서) 0 → office 1 → pdf 2 → image 3 → media 4. 폴더는 폴더 구간에서 이름순.
- `buildFileTree`의 내부 2중 정렬(localizedCaseInsensitiveCompare — 렌더에서 항상 덮여 무효)은 이번 범위에서 **정리하지 않는다**(FileTreeBuildTests 결합, 별건). 주석으로 무효임만 명시.

### 2.3 상태·기억 — AppState + Settings

- `AppSettings.librarySorts: [String: LibrarySort] = [:]` — 선언 + `init(from:)`에 `decodeIfPresent ?? 기본값` 줄(두 곳 모두 — 한 곳만 고치면 재실행 시 무음 리셋되는 함정).
- 키 산출 공용 헬퍼 `AppState.folderMemoryKey(for: URL) -> String`(= `standardizedFileURL.path`). **정렬·레이아웃 기억 모두 이 헬퍼로 통일**하고, 복원·저장 기준 폴더도 둘 다 `selectedFolder ?? currentFolder`로 통일(기존 restore가 selectedFolder만 보던 비대칭 해소 — libraryLayouts 동작 개선 동반).
- `AppState.librarySort: LibrarySort = .default`:
  - didSet → `persistLibrarySortForCurrentFolder(oldValue:)`: 가드 3종(`!isRestoringSort` / `oldValue != new` / 대상 폴더 존재) 후 `settings.librarySorts[key] = librarySort; saveUserData()`. 툴바 메뉴·열 헤더는 이 프로퍼티 대입만 하고 영속은 didSet 전담(LibraryLayoutPicker 관례).
  - 복원 → `selectedFolder` didSet에서 `restoreLibrarySortForSelectedFolder()`: 기억 조회 → 없으면 `.default`로 복원(레이아웃과 달리 "유지"가 아니라 **기본 복귀** — 정렬은 폴더 속성이므로 기억 없는 폴더는 항상 PARA 기본이어야 결정 3과 정합) → 값 다를 때만 `isRestoringSort` 감싸고 대입.
- 트리용 조회 `AppState.sortForFolder(_ url: URL) -> LibrarySort` = `settings.librarySorts[folderMemoryKey(url)] ?? .default`.

### 2.4 적용 — 라이브러리

- `folderKey`에 정렬을 **넣지 않는다**(정렬 변경마다 디스크 재열거 방지). 대신 LibraryView에 `.onChange(of: appState.librarySort)` 추가 → 캐시된 entries를 `LibrarySorting.sorted`로 재정렬 + `appState.libraryOrderedURLs = entries.map(\.url)`를 **같은 함수에서 원자적으로 갱신**(⌘A·⇧범위가 화면 순서와 어긋나는 F1b류 결함 방어). `reloadEntries`(열거 시)와 재정렬(정렬 변경 시)이 공통 `applySort()` 헬퍼를 거치게 해 갱신 경로를 하나로 수렴.
- 재정렬은 `ForEach(id: \.url)` 동일성 덕에 셀 재생성 없음(썸네일·summary `.task(id: url)` 보존).

### 2.5 적용 — 사이드바 트리

- `buildFileTree`의 resourceValues에 `.fileSizeKey`·`.contentModificationDateKey` 추가(순수 static·detached 스캔이라 UI 블록 없음 — 대형 폴더 체감은 수동 스모크로 확인).
- SidebarView의 두 `ParaLens.sorted` 호출(:168 루트, :410 자식)을 `LibrarySorting.sorted(…, by: appState.sortForFolder(부모폴더), under:)`로 교체. 루트 레벨의 부모 = `currentFolder`. 기억 없는 폴더는 `.default`(=PARA)라 **기본 동작 완전 불변**.
- 사이드바는 매 렌더 인라인 정렬 — 추가 비용은 딕셔너리 조회 1회/폴더 수준으로 미미.
- ⚠️ 확인 필요(구현 시): 현재 폴더의 정렬 변경(settings.librarySorts 변이)이 사이드바 재렌더를 발화하는지 — AppState 관찰 경로에 따라 안 되면 명시 트리거(예: 관찰 가능한 librarySort/세대 값 참조) 추가.

### 2.6 정렬 UI

- **툴바(라이브러리 모드)**: ContentView 툴바의 라이브러리 분기(LibraryLayoutPicker 옆)에 정렬 Menu 추가 — 라벨 `arrow.up.arrow.down` 아이콘, 항목 [PARA(기본)·이름·날짜·크기·종류] 체크마크 + 디바이더 + [오름차순/내림차순](para일 땐 비활성). 항목 선택 = `appState.librarySort` 대입.
- **리스트 열 헤더 행 신설**(Table 전환 없음 — F1b 클릭 시맨틱·컨텍스트 메뉴·하이라이트 보존): PathBar/Divider 아래·List 위(스크롤 영역 **밖** — 배경 탭 선택 해제 제스처와 경합 없음)에 커스텀 HStack: [이름(유연)] [수정일 92pt] [크기 68pt]. 셀의 고정폭·listRowInsets(2/8)·아이콘 20pt와 픽셀 정렬 수동 동기. 클릭 = 그 키 선택, 재클릭 = 방향 토글, 활성 열에 ▲/▼ 표시. 종류 정렬은 열이 없으므로 툴바 메뉴로만. 그리드 모드도 툴바 메뉴로만(헤더 없음).

## 3. 히스토리

### 3.1 순수 모델 — `Sources/Services/NavigationHistory.swift` (신규)

```swift
struct FolderLocation: Equatable {
    let root: URL      // 작업 폴더(currentFolder)
    let display: URL   // 표시 폴더(selectedFolder ?? currentFolder)
}
struct NavigationHistory {
    private(set) var backStack: [FolderLocation]
    private(set) var forwardStack: [FolderLocation]
    private(set) var current: FolderLocation?
    mutating func record(_ loc: FolderLocation)
    // current가 nil이면 current만 채움(seed). 아니면 current를 backStack에 push하고 교체, forwardStack 클리어.
    // 직전 current와 standardized 경로가 같으면 무시(연속 중복 병합). backStack cap 100.
    mutating func goBack(isValid: (FolderLocation) -> Bool) -> FolderLocation?
    mutating func goForward(isValid: (FolderLocation) -> Bool) -> FolderLocation?
    // 죽은 항목은 건너뛰며 계속 pop(skip-pop). 이동 성공 시 current를 반대 스택에 push.
    mutating func prune(isValid: (FolderLocation) -> Bool)  // 파일 작업 후 죽은 경로 제거
    var canGoBack: Bool; var canGoForward: Bool
}
```

- 존재 검사는 클로저 주입(FS 접근 없는 순수 구조 — 단위테스트 결정적). 경로 비교는 전부 standardizedFileURL 기준.

### 3.2 AppState 배선

- `var navHistory = NavigationHistory()` (버튼·메뉴 활성 상태 갱신을 위해 뷰가 관찰 가능해야 — 기존 AppState 프로퍼티 관례 따름). 세션 비영속(결정 4 — SessionState 무변경).
- 기록 지점은 **`selectedFolder` didSet 한 곳**(단일 초크포인트). 대안이던 "전 호출부 명시 navigate API"는 새 호출부가 push를 빠뜨리는 태스크 경계 결함(F1a·F1b 최종 리뷰 3연속 패턴)에 취약해 기각.
  - `suppressHistoryRecording` 플래그가 꺼져 있고 `currentFolder != nil`일 때만 `navHistory.record(FolderLocation(root: currentFolder, display: selectedFolder ?? currentFolder))`.
  - openFolder(at:)는 currentFolder→selectedFolder 순 대입이라 didSet 1회 발화 시점에 새 (루트, 표시) 쌍이 정확히 잡힘 — 이중 기록 없음.
  - didSet은 같은 값 재대입에도 발화하나 record의 연속 중복 병합이 흡수.
- `suppressHistoryRecording = true`로 감싸는 곳: ①세션 복원의 selectedFolder 대입(복원 후 `navHistory.record(초기 위치)`로 seed) ②뒤로/앞으로 실행 자체 ③§5 동반 수정의 stale selectedFolder 재조준.
- `goBackInHistory()` / `goForwardInHistory()`:
  1. `navHistory.goBack(isValid: 디렉터리 존재)` → nil이면 no-op.
  2. `suppressHistoryRecording = true`.
  3. 루트가 다르면(standardized 비교) `openFolder(at: loc.root)` 재사용(loadFileTree·rebuildNoteIndex·saveSession 동반 — 의도된 전체 복원).
  4. `selectedFolder = loc.display` → `mainMode = .library` **강제**(리더에 남아 화면이 안 바뀌는 함정 방지 — 결정 4).
  5. 플래그 해제.

## 4. 경로 바 — `Sources/Views/PathBarView.swift` (신규)

### 4.1 세그먼트 계산 (순수, 같은 파일 내 또는 `PathBarModel`)

```swift
struct PathSegment: Equatable { let url: URL; let name: String; let isWithinRoot: Bool; let isFile: Bool }
static func segments(target: URL, root: URL?) -> [PathSegment]
```

- standardizedFileURL + '/' 경계 비교(기존 SimpleBreadcrumbView `computePathParts`의 경계 없는 `hasPrefix` 버그를 이 기회에 제거). 루트 자신은 `isWithinRoot = true`.
- 표시 범위: target이 홈(~) 하위면 홈부터(이름 대신 house 아이콘), 아니면 "/"부터 전부. 루트 밖 세그먼트는 secondary 톤(클릭은 가능), 루트 안은 보통 톤.

### 4.2 뷰 구성과 배치

- 한 줄 24pt 스트립: `[‹ › 뒤로/앞으로 버튼] [세그먼트 › 세그먼트 › …(수평 ScrollView)] [트레일링 액세서리]`.
  - ‹ › 버튼: `navHistory.canGoBack/canGoForward`로 비활성. 리더·라이브러리 양쪽 항상 표시.
  - 트레일링 액세서리: 라이브러리에선 기존 "N개 선택됨" 라벨 이전, 리더에선 없음.
  - 세그먼트 컨텍스트 메뉴: Reveal in Finder / Copy Path(기존 SimpleBreadcrumbView 기능 보존).
- **리더 모드**: MainEditorView readerLayout의 `SimpleBreadcrumbView`를 PathBarView로 교체(같은 자리·같은 높이), target = 활성 탭 fileURL. fileURL 없는 탭(새 문서)은 세그먼트 없이 ‹ › 버튼만. `SimpleBreadcrumbView`는 삭제.
- **라이브러리 모드**: libraryHeader를 PathBarView로 교체, target = displayFolder. 상위 chevron.up 버튼은 제거(부모 세그먼트+⌘↑가 대체), `goUp()` 로직은 ⌘↑용으로 AppState로 이전(§6). 모드 토글 시 경로 바가 같은 높이·위치라 점프 없음.

### 4.3 클릭 시맨틱

- 파일 세그먼트(리더의 마지막): 클릭 없음.
- 루트 안 폴더 세그먼트(루트 포함): `appState.selectFolderForLibrary(url)` — selectedFolder 대입+라이브러리 모드 전환. 리더에서도 동일(파일 보다가 폴더 클릭=그 폴더 라이브러리로 — 사이드바 폴더 탭과 같은 동선).
- 루트 밖 조상 세그먼트: `appState.openFolder(at: url)` + `mainMode = .library`(openFolder는 mainMode를 안 건드리므로 명시 전환). 작업 폴더 전환은 무겁지만(트리 재로드·인덱스 재구축) 히스토리로 즉시 복귀 가능(결정 5).

## 5. 동반 수정 — stale selectedFolder (F1a 트리아지 잔여)

표시 중 폴더가 rename/trash되면 selectedFolder가 죽은 URL로 남아 빈 라이브러리가 되는 기존 잔여 결함 — 경로 바·히스토리가 죽은 경로를 그대로 표시하게 되므로 이번에 수정:

- `completeFileOperation`에서 `selectedFolder`가 디렉터리로 존재하지 않으면 **가장 가까운 존재 조상**으로 재조준(`suppressHistoryRecording` 감싸서 — 사용자 내비게이션 아님), 이어서 `navHistory.prune(isValid:)`로 죽은 히스토리 항목 제거.

## 6. 단축키·메뉴·팔레트

- `AppShortcut`에 3 case 추가(설정 탭 리맵 UI·`ShortcutDefaultsTests` 유일성 검증 자동 편입):
  - `.navigateBack` = ⌘[ / `.navigateForward` = ⌘] — 미점유 확인(⇧⌘[/]=탭 전환과 Shift 한 끗 차이 — 메뉴 라벨로 구분 명시). NSTextView 표준 바인딩 아님 → 메뉴 `.appShortcut` 경로로 포커스 무관 동작.
  - `.navigateUp` = ⌘↑ — 액션에 `mainMode == .library` 가드(에디터의 문서 처음 이동 표준 강탈 방지 + 시트 포커스 중 오발화 차단). 하드코딩 단축키(⇧⌘[/] 등)와의 충돌은 enum 밖이라 설계 단계 수동 대조 완료: ⌘[·⌘]·⌘↑ 모두 무충돌.
- `goUp()`/`canGoUp`을 LibraryView에서 AppState로 이전(메뉴 액션이 호출할 수 있게, 뷰는 위임 호출). 기존 standardized+'/' 경계 클램프 로직 그대로.
- View 메뉴에 디바이더+3항목(뒤로/앞으로/상위 폴더, `.disabled` 조건: 스택 empty / `!canGoUp || mainMode != .library`).
- 커맨드 팔레트에 3건 추가(`keyBinding(for:).displayString` 배선 — 스테일 표기 함정 회피).

## 7. 테스트 (전부 오프라인 결정적)

| 대상 | 내용 |
|---|---|
| `LibrarySortingTests` (신규) | para 위임(ParaLens 동일 결과)·이름/날짜/크기/종류 각 키·방향 반전·폴더 먼저 불변·크기 nil=0·날짜 nil=distantPast·폴더 구간 이름순·kind rank·tie-break 이름 고정 |
| `NavigationHistoryTests` (신규) | seed·record push/forward 클리어·연속 중복 병합·cap 100·goBack/goForward 왕복·skip-pop(isValid false)·prune |
| `PathBarModelTests` (신규) | 세그먼트 분해·루트 안/밖 플래그·'/' 경계(형제 폴더 `a` vs `ab` 오감지 회귀)·루트 자신·홈 하위/밖 표시 범위 |
| `LibrarySortSettingsTests` (신규) | librarySorts 라운드트립·키 부재 하위호환(구 settings.json 디코드) |
| `AppLibrarySortMemoryTests` (신규, TempDataDirectory 주입) | 폴더 전환 시 복원·기억 없으면 default 복귀·변경 시 저장·복원이 저장 유발 안 함(타 폴더 키 미생성) |
| `AppNavigationHistoryTests` (신규, TempDataDirectory 주입) | 드릴인/openFolder가 기록됨·세션 복원이 기록 안 함(seed만)·goBack이 기록 안 함·goBack 후 mainMode=.library·stale prune |
| `FileTreeBuildTests` (확장) | buildFileTree가 fileSize/modifiedAt 채움 |
| `ShortcutDefaultsTests` | case 추가로 자동 커버(기본값 유일성) |

UI 클릭·⌘↑ 실기 충돌·대형 폴더 트리 스캔 체감·열 헤더 픽셀 정렬은 수동 스모크.

## 8. 함정 체크리스트 (정찰 리스크 → 설계 반영)

1. 정렬 변경이 folderKey에 없어 무동작 → `.onChange(of: librarySort)` + 공통 `applySort()` 경로(§2.4).
2. entries·libraryOrderedURLs 비동기화 → 원자적 동시 갱신(§2.4).
3. didSet 되먹임(복원→저장, 뒤로→재기록) → `isRestoringSort`·`suppressHistoryRecording` 플래그(§2.3, §3.2).
4. Settings 디코드 줄 누락 시 무음 리셋 → 선언+디코드 두 곳 명시, 하위호환 테스트(§2.3, §7).
5. '/' 경계 없는 hasPrefix·raw URL 비교 → 전 비교 standardized+'/' 경계, SimpleBreadcrumbView 버그 제거(§4.1).
6. openDocument의 mainMode=.reader 강제 → 뒤로/앞으로가 .library 강제 복원(§3.2).
7. 죽은 경로(rename/trash) → skip-pop+prune+stale selectedFolder 재조준(§3.1, §5).
8. SessionState 합성 Codable 취약 → 무변경(히스토리 휘발).
9. 열 헤더 클릭마다 saveUserData 동기 7파일 재기록 → 기존 레이아웃 토글과 같은 비용, 선례상 허용.
10. ⌘↑ NSTextView 충돌 → 라이브러리 모드 가드 + 실기 스모크 항목.
11. ParaLens.sorted 원본·ParaLensTests 불변 → LibrarySorting이 위임으로 감쌈(§2.2).

## 9. 범위 밖

- 히스토리 세션 영속(SessionState 확장), 마우스 4/5버튼·트랙패드 스와이프, SwiftUI Table 전환, 정렬/레이아웃 기억의 rename 시 키 이관(스테일 키 무해 누적 — 기존 한계 유지), buildFileTree 내부 무효 정렬 정리(별건), 폴더 크기 계산(크기 정렬에서 폴더는 이름순).
