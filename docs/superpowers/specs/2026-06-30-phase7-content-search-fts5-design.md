# Phase 7 — 내용 검색 (Docufinder식, 영속 FTS5 인덱스 + 파일 감시) 설계

> 작성일 2026-06-30. cmd-docu 티어 3. PRD 3.7 / Phase 7.
> 원칙: 비샌드박스 유지 · macOS 내장만 사용(새 패키지 의존성 없음) · 인덱싱은 읽기 전용 · 삭제 없음 · Phase 게이트(swift test).

## 1. 목표

폴더를 등록하면 본문을 추출해 **SQLite FTS5 인덱스**에 적재하고, 키워드로 **파일명이 아니라 본문**을 1초 안에 찾는다(HWP·PDF·오피스·텍스트). 결과는 파일+스니펫으로 보여주고 클릭하면 연다. 등록 폴더의 파일이 추가/수정/삭제되면 **FSEvents 파일 감시**로 자동 증분 재인덱싱한다.

기존 "Search in folder"(라이브 스캔, 열린 폴더 한정)는 그대로 둔다. Phase 7은 **등록 폴더 대상 영속 인덱스 검색**이라는 별도 면이다.

## 2. 검증 완료(코드, CLAUDE.md "추정 금지" 준수)

- `import SQLite3`(macOS SDK 제공, 무依存)로 FTS5 가상테이블·`snippet()`·한글 매칭 동작 확인(SQLite 3.51.0). 스니펫 예: `정의당 평가서 [선거] 분석`.
- FSEvents Swift 브리징(`FSEventStreamCreate` + `Unmanaged` info 패턴 + `kFSEventStreamCreateFlagFileEvents`) 컴파일·실행 확인.
- 둘 다 macOS 기본 — `Package.swift`에 새 의존성 불필요. (Task 1에서 SPM 패키지 내 `import SQLite3` 빌드 재확인.)

## 3. 아키텍처

신규 파일로 모듈화(업스트림 머지 용이). 기존 `KordocService.markdown`(office), PDFKit(pdf), `AppState.loadAndActivateDocument`(열기)을 재사용.

### 3.1 `Sources/Services/SearchIndex.swift` (신규 actor)
SQLite FTS5 래퍼. DB 경로: `<AppSupport>/CmdMD/searchindex.sqlite`.

스키마(최초 1회 생성):
```sql
CREATE TABLE IF NOT EXISTS files(
  path TEXT PRIMARY KEY, mtime REAL NOT NULL, ext TEXT, indexedAt REAL
);
CREATE VIRTUAL TABLE IF NOT EXISTS docs USING fts5(
  path UNINDEXED, filename, body, tokenize = 'unicode61'
);
```
(`files`는 mtime 스킵·삭제 추적용 메타. `docs`는 검색 대상. path로 둘을 잇는다.)

공개 API(actor 메서드):
```swift
func needsIndex(path: String, mtime: Double) -> Bool   // files에 같은 path+mtime 있으면 false
func upsert(path: String, filename: String, body: String, mtime: Double, ext: String)
func remove(path: String)                              // files+docs에서 삭제
func removeUnder(folder: String) -> Int                // 폴더 등록 해제 시 그 하위 전부 삭제(반환=삭제 수)
func search(query: String, limit: Int = 200) -> [IndexHit]
func indexedPaths(under folder: String) -> [String]    // 삭제 감지용(인덱스엔 있는데 디스크엔 없는 파일)
func clear()
func count() -> Int
```
- `upsert`: 트랜잭션으로 `DELETE FROM docs WHERE path=?` → `INSERT INTO docs` → `files` upsert(REPLACE).
- `search`: 새니타이즈된 MATCH로 `SELECT path, snippet(docs, 2, '[', ']', '…', 10), (filename MATCH ?) ...`. 본문 매칭 + 파일명 매칭 모두 포함. 랭크는 FTS5 `rank` 또는 `bm25(docs)`. 결과 `IndexHit{ path, snippet, isFilenameMatch }`.
- DB 열기 실패/손상: 파일 삭제 후 재생성(인덱스는 재구성 가능한 캐시).

순수 헬퍼(같은 파일, 테스트 대상):
```swift
enum FTSQuery {
    /// 사용자 입력 → 안전한 FTS5 MATCH 문자열.
    /// 공백으로 용어 분리, 각 용어를 "..."로 감싸 특수문자 무력화, 마지막 용어에 prefix * 부여.
    /// 빈 입력이면 nil(검색 안 함).
    static func sanitize(_ raw: String) -> String?
}
```
예: `선거 분석` → `"선거" "분석"*`. `a"b` → `"a""b"`(따옴표 이스케이프) 같은 깨짐 방지.

`struct IndexHit: Equatable { let path: String; let snippet: String; let isFilenameMatch: Bool }`

### 3.2 `Sources/Services/ContentExtractor.swift` (신규)
파일 URL → 인덱싱 본문(없으면 nil = 파일명만 인덱싱).
```swift
enum ContentExtractor {
    /// 종류별 본문 추출. office는 kordoc(Process)로 비동기 추출.
    static func body(for url: URL, kordoc: KordocService) async -> String?
    /// kordoc 없이 즉시 추출 가능한 종류만(text/pdf) — 테스트·동기 경로용 순수 분기.
    static func localBody(for url: URL) -> String?
}
```
- text(`md`,`markdown`,`txt`): `String(contentsOf:encoding:.utf8)`.
- pdf: `PDFDocument(url:)` 전체 페이지 `.string` 연결.
- office(`DocumentKind.officeExtensions`): `try? await kordoc.markdown(for:)`(실패 시 nil).
- image: nil(파일명만).
- `body(for:)`는 office면 kordoc 분기, 그 외 `localBody`.

### 3.3 `Sources/Services/SearchIndexer.swift` (신규 actor)
폴더 인덱싱 오케스트레이션.
```swift
actor SearchIndexer {
    init(index: SearchIndex, kordoc: KordocService)
    /// 폴더를 워킹하며 변경된 파일만 (재)인덱싱하고, 디스크에서 사라진 파일은 인덱스에서 제거한다.
    /// progress: (done, total) 콜백(메인 디스패치는 호출측 책임).
    func indexFolder(_ folder: URL, progress: ((Int, Int) -> Void)?) async
    /// 단일 파일 (재)인덱싱(파일 감시 증분용). 삭제된 파일이면 remove.
    func reindex(path: String) async
}
```
- `indexFolder`: `FileManager.enumerator`로 나열(skipsHidden·skipsPackageDescendants), `AppState.isListableInFileTree` 기준. 각 파일 mtime 조회 → `needsIndex` false면 스킵 → `ContentExtractor.body` → `index.upsert`. 끝에 `index.indexedPaths(under:)` 중 디스크에 없는 경로 `remove`.
- 진행률은 total=나열 수, done 증가.

### 3.4 `Sources/Services/FolderWatcher.swift` (신규 class)
FSEvents로 등록 폴더들을 감시.
```swift
final class FolderWatcher {
    var onChangedPaths: (([String]) -> Void)?    // 변경된 경로(파일/폴더) 배치
    func start(folders: [String])                // 기존 스트림 교체
    func stop()
}
```
- `FSEventStreamCreate`(콜백 + `Unmanaged.passUnretained(self)` info), `kFSEventStreamCreateFlagFileEvents`, latency 0.5s(디바운스), `FSEventStreamSetDispatchQueue`(전용 큐), Start. 콜백은 `Unmanaged.fromOpaque`로 self 복원 → `onChangedPaths`.
- `stop`: Stop·Invalidate·Release.
- 등록 폴더 변경 시 `start(folders:)`로 스트림 재구성.

### 3.5 `AppSettings` 필드 (`Sources/Models/Settings.swift`)
```swift
var indexedFolders: [String] = []   // 인덱스 검색 등록 폴더(절대 경로). 영속·하위호환.
```

### 3.6 AppState 배선 (`Sources/App/AppState.swift`)
- 인스턴스: `searchIndex = SearchIndex()`, `searchIndexer = SearchIndexer(index:kordoc:)`, `folderWatcher = FolderWatcher()`.
- 상태: `showIndexSearch: Bool`, `indexSearchText: String`, `indexSearchResults: [IndexHit]`, `indexInProgress: Bool`, `indexProgress: (done: Int, total: Int)?`.
- 메서드:
  - `registerIndexFolder(URL)` — settings.indexedFolders에 추가(중복·중첩 방지), saveUserData, `indexFolder` 비동기 실행, watcher 재시작.
  - `unregisterIndexFolder(String)` — 목록 제거, `index.removeUnder(folder)`, saveUserData, watcher 재시작.
  - `reindexAll()` / `reindexFolder(_)` — 수동 재인덱싱.
  - `runIndexSearch(query:)` — `index.search` → indexSearchResults(타이핑 디바운스는 뷰).
  - `startFolderWatching()` — 앱 시작 시 indexedFolders로 watcher.start, `onChangedPaths`에서 변경 경로를 `searchIndexer.reindex`로(디바운스·등록 폴더 하위만), 끝나면 현재 쿼리 재검색.
  - `openIndexHit(_)` — 경로로 `loadAndActivateDocument`.
- 앱 시작(`loadUserData` 이후): `startFolderWatching()` + (선택) 백그라운드 초기 정합 인덱싱.

### 3.7 UI — `Sources/Views/IndexSearchView.swift` (신규 시트)
- 상단: "등록 폴더" 섹션 — 목록(경로·인덱싱 파일수), "폴더 추가…"(NSOpenPanel, 디렉터리), 행별 "재인덱싱"·"제거". 인덱싱 중이면 진행률 바(done/total).
- 검색창(자동 포커스) → 0.2s 디바운스 → `runIndexSearch`.
- 결과 리스트: 행마다 확장자 아이콘 + 파일명 + 경로(2줄째) + 스니펫([대괄호] 강조). 파일명 매칭은 뱃지. 클릭=`openIndexHit`(열고 시트 닫기).
- 빈 상태: 등록 폴더 없으면 "폴더를 추가해 인덱싱하세요", 결과 없으면 "결과 없음".
- 진입점: 커맨드 팔레트 항목 + View 메뉴 + 단축키(`AppShortcut`에 추가, 충돌 없는 키). `ContentView`에 `.sheet(isPresented: $state.showIndexSearch)`.

## 4. 에러·안전

- 인덱싱은 **읽기 전용** — 원본 파일을 절대 변경/이동/삭제하지 않는다.
- kordoc 미설치/실패: 그 파일만 본문 없이(파일명만) 또는 스킵, 크래시 없음. 전체 인덱싱은 계속.
- DB 열기/쿼리 실패·손상: DB 파일 삭제 후 재생성(인덱스는 재구성 가능 캐시). 사용자에게 토스트만.
- 등록 해제·인덱스 삭제는 **DB만** 건드린다(디스크 파일 불변).
- FSEvents 콜백 폭주: 0.5s 디바운스 + 변경 경로를 등록 폴더 하위로 한정, 같은 경로 중복 제거.
- 대용량: 결과 limit(기본 200), 인덱싱은 off-main·증분(mtime 스킵).

## 5. 테스트(Phase 게이트)

SQLite는 in-process라 **인덱스를 단위테스트한다**(kordoc/FSEvents와 달리 Process·시스템 콜백 아님):
- `SearchIndex`(임시 파일 DB, teardown 삭제):
  - upsert 후 `search`가 본문 키워드로 히트, `snippet`에 쿼리 토큰 포함.
  - 파일명 매칭(`isFilenameMatch`) 동작.
  - `needsIndex`: 같은 mtime이면 false, 바뀌면 true.
  - `remove`/`removeUnder` 후 검색 결과에서 사라짐, `count` 감소.
  - 한글 쿼리 매칭.
- `FTSQuery.sanitize`(순수): 다중 용어→따옴표+prefix, 따옴표/특수문자 이스케이프, 빈 입력→nil.
- `ContentExtractor.localBody`(순수): text 읽기, pdf 추출(픽스처), 미지원 확장자→nil. (office=kordoc 분기는 제외.)
- `AppSettings.indexedFolders` 하위호환 디코드(구 JSON→빈 배열).
- 제외(단위테스트 안 함, 수동 검증): `FolderWatcher`(FSEvents), `ContentExtractor.body`의 kordoc 분기, `SearchIndexer`의 Process 경유 부분, UI.

게이트: 시작·종료 시 `swift test`로 기존 154개 + 신규 통과. (정식 Xcode 필요.)

## 6. 범위 밖(후속)

- 줄/페이지 단위 정밀 점프(현재 파일+스니펫). 기존 라이브 검색이 줄/페이지 점프를 이미 제공.
- 시맨틱/임베딩 검색·RAG는 Phase 9.
- 인덱스 동기화 상태 UI 고도화(배지·백그라운드 인덱싱 알림)는 다듬기 단계.
- 기존 Omnisearch/폴더검색과의 통합(현재는 별도 면 유지).
