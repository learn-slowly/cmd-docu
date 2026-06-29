# Phase 3 — 한글·오피스 읽기 (kordoc) 설계

- 날짜: 2026-06-29
- 대상: cmd-docu (CmdMD 포크), `cmd-docu` 브랜치
- 범위: PRD 티어 1 / Phase 3 — HWP·HWPX·HWPML·DOC(X)·XLS(X)를 kordoc으로 마크다운 변환해 **읽기전용** 렌더
- 통합 방식: A안 — `DocumentKind.office` + 비동기 `KordocService`(외부 CLI) + 읽기전용 마크다운 뷰

## 0. 검증된 사실 (추정 아님 — 실제 확인)
- kordoc은 npm 패키지(v3.5.1, bin `kordoc`=dist/cli.js). CLI: `kordoc [options] <files...>`, `--format markdown|json`(기본 markdown), `-o <path>` 출력 파일, `--silent`. **stdout이 아니라 `-o` 파일로 출력**.
- node/npx는 `/opt/homebrew/bin`. kordoc은 현재 **미설치**(npx -y가 받아옴; 첫 실행 시 다운로드로 느릴 수 있음).
- 실제 HWP 변환 성공 시 JSON 스키마(확인):
  ```json
  { "success": true, "fileType": "hwp",
    "markdown": "<완성된 마크다운 전체>",
    "blocks": [ {"type":"paragraph|heading|table", "text":"…", "pageNumber":N, "level":N, "style":{…}} ],
    "metadata": { … }, "outline": [ … ] }
  ```
- GUI 앱(.app)은 로그인 셸 PATH를 상속하지 않음 → npx 절대경로 탐지 필요.
- 우리 cupsfilter PDF로는 kordoc PDF 파서가 실패했으나, PDF는 PDFKit(Phase 2)이 담당하므로 무관. kordoc은 HWP/오피스용.

## 1. 목표 / 비목표
**목표**
- `.hwp .hwpx .hwpml .doc .docx .xls .xlsx`를 탭으로 열면 kordoc이 마크다운으로 변환, 기존 마크다운 프리뷰로 **읽기전용** 표시.
- 변환은 비동기(로딩 표시). kordoc/Node 미설치·변환 실패·타임아웃은 **크래시 없이** 안내 표시.
- 원본 파일 절대 미변경(저장/편집 경로가 office 탭을 건드리지 않음).
- JSON(`--format json`)으로 받아 `markdown`+`blocks`+`outline`+`metadata`를 모델로 파싱(렌더는 `markdown` 필드 사용; blocks/outline은 모델 보유, 활용은 이후).

**비목표(YAGNI)**
- kordoc 쓰기/패치/양식 채우기(Phase 5), blocks 기반 커스텀 렌더, outline 네비게이션 UI, HWP 내장 이미지 완전 충실도, kordoc 자동 설치, kordoc-mcp 경유.

## 2. 통합 방식 (A안)
이미지/PDF에서 쓴 `DocumentKind` 분기 패턴 + 외부 CLI 비동기. office 탭은 `MarkdownDocument` 없이(이미지/PDF와 동일) 생성하되, 변환 결과(마크다운)는 별도 상태에 보관해 읽기전용 프리뷰로 렌더.
- B안(동기 변환): 메인스레드 블로킹 → 기각.
- C안(kordoc-mcp): MCP 클라이언트 필요, 과함 → 기각.

## 3. 구성요소

### 3.1 `Sources/Models/KordocResult.swift` (신규, Codable)
```
struct KordocResult: Codable {
    let success: Bool
    let fileType: String
    let markdown: String
    let blocks: [KordocBlock]?
    let outline: [KordocOutlineItem]?
    // metadata는 자유형식 — v1에선 디코딩 생략 가능(무시). 필요시 [String: ...] 대신 보류.
}
struct KordocBlock: Codable {
    let type: String
    let text: String?
    let pageNumber: Int?
    let level: Int?
    // style은 자유형식 객체 — v1 디코딩 생략(무시).
}
struct KordocOutlineItem: Codable {   // 실제 스키마 확인됨
    let level: Int?
    let text: String?
    let pageNumber: Int?
}
// blocks[].style = {fontSize,…} 자유형식, metadata = {version,pageCount,…} 자유형식 — 둘 다 v1 디코딩 생략(무시).
```
- 방어적 디코딩: 알 수 없는/누락 필드는 옵셔널. `markdown`·`success`·`fileType`만 필수. `metadata`/`style` 등 자유형식은 디코딩 대상에서 제외(미래 필요 시 추가).

### 3.2 `Sources/Services/KordocService.swift` (신규 actor)
- `enum KordocError: Error { case toolNotFound, conversionFailed(String), timeout, decodeFailed }`
- `func convert(fileURL: URL) async throws -> KordocResult`
  1. npx 경로 탐지(`resolveNpxPath()`): 후보 `/opt/homebrew/bin/npx`, `/usr/local/bin/npx`, `/usr/bin/npx`; 없으면 `/bin/zsh -lc "which npx"` 결과. 모두 실패 → `throw .toolNotFound`.
  2. 임시 출력 경로 생성(`FileManager.default.temporaryDirectory` + UUID + ".json").
  3. `Process` 실행: launchPath=npx, args=`["-y","kordoc", fileURL.path, "--format","json","-o", tmp.path, "--silent"]`. stderr 캡처.
  4. 타임아웃(예 120초): 초과 시 `process.terminate()` + `throw .timeout`.
  5. 종료 코드 0 아니거나 tmp 없음 → `throw .conversionFailed(stderr 일부)`.
  6. tmp 읽어 `JSONDecoder().decode(KordocResult.self)`; 실패 → `.decodeFailed`. 성공 후 tmp 삭제(방어적).
- 비샌드박스 유지 전제(서브프로세스 호출).

### 3.3 `Sources/Models/DocumentKind.swift` (수정)
- `case office` 추가.
- `static let officeExtensions: Set<String> = ["hwp","hwpx","hwpml","doc","docx","xls","xlsx"]`.
- `init(from:)`: image → pdf → **office** → markdown 순서로 검사.

### 3.4 `Sources/App/AppState.swift` (수정)
- office 변환 상태 저장: `enum OfficeState { case loading; case loaded(KordocResult); case failed(String) }` + `var officeStates: [UUID: OfficeState] = [:]`(키 = EditorTab.id).
- `loadAndActivateDocument`: 비마크다운 분기를 image/pdf/**office**로 확장.
  - office: `EditorTab(kind:.office, fileURL:url, title:파일명)` 생성·placeTab·addToRecentFiles·saveSession. 그리고 `officeStates[tab.id] = .loading` 후 `Task { kordoc 변환 → loaded/failed 저장 }`. (변환은 `KordocService` 인스턴스 — `fileService`처럼 보관)
  - 실패 메시지: `.toolNotFound` → "kordoc 실행에 필요한 Node(18+)/kordoc을 찾을 수 없습니다. 터미널에서 `npx kordoc` 또는 `npm i -g kordoc` 후 다시 시도." / 그 외 → 사용자 친화 메시지.
- 탭 종료(closeTab) 시 `officeStates[id]` 정리(메모리·상태 누수 방지).
- `isListableInFileTree`: officeExtensions 포함.
- `openFile` 패널: office UTType 추가(`UTType(filenameExtension:)`로 보강; 시스템 UTType 없는 확장자 대비).
- `currentTabKind`/`currentTabFileURL`/`windowTitle`은 kind 기반이라 무변경.
- office 탭의 현재 상태 접근용 계산 프로퍼티(예: `func officeState(for tabID: UUID) -> OfficeState?`) 또는 뷰에서 직접 조회.

### 3.5 `Sources/Views/OfficeReaderView.swift` (신규)
- 입력: 탭 id(또는 OfficeState 바인딩) + fileURL.
- `loading` → 스피너 + "변환 중…(첫 실행은 kordoc 다운로드로 느릴 수 있음)".
- `loaded(result)` → 기존 `MarkdownPreviewView(documentID: tabID, markdown: result.markdown, baseURL: fileURL.deletingLastPathComponent(), options: appState.renderOptions(), scrollSyncEnabled: false)` 로 **읽기전용** 렌더.
- `failed(msg)` → 플레이스홀더(아이콘 + 메시지 + 재시도 버튼: 변환 재시작).

### 3.6 `Sources/Views/MainEditorView.swift` (수정)
- Group 분기에 `.office` 추가: `currentTabKind == .office, let url = currentTabFileURL → OfficeReaderView(...)`. (image/pdf 분기 뒤, markdown 앞)
- 브레드크럼(currentTabFileURL)·상태바(currentDocument != nil → office에선 자동 숨김) 무변경.

## 4. 데이터 흐름
```
열기 → DocumentKind(from:) == .office
 → EditorTab(kind:.office) + officeStates[id]=.loading
 → Task: KordocService.convert(npx kordoc … --format json -o tmp) → KordocResult
        성공: officeStates[id]=.loaded(result)
        실패: officeStates[id]=.failed(message)
 → MainEditorView → OfficeReaderView: loading/loaded(MarkdownPreviewView)/failed
마크다운·이미지·PDF 경로 무변경. 원본 파일 read-only.
```

## 5. 에러 처리 (CLAUDE.md: 크래시 금지·안내만)
- Node/kordoc 미탐지 → `.toolNotFound` → 설치 안내 플레이스홀더.
- 변환 실패(비0 종료/파서 오류) → `.conversionFailed` → stderr 요약 + 재시도.
- 타임아웃 → `.timeout` → 안내 + 재시도.
- JSON 디코드 실패 → `.decodeFailed` → 안내.
- 어떤 경우도 앱 크래시 없음. office 탭에 fileURL nil(이론상 없음) → 방어적 플레이스홀더.

## 6. 테스트 (Phase 게이트)
**신규(XCTest, TDD):**
- `KordocResultTests`: 실제 스키마를 본뜬 픽스처 JSON 문자열을 디코드 → `success/fileType/markdown` + `blocks`(type/text/pageNumber/level) + `outline` 파싱; 누락 필드(blocks/outline 없음)도 옵셔널로 통과; 잘못된 JSON은 디코드 실패.
- `DocumentKindTests`: hwp/hwpx/hwpml/doc/docx/xls/xlsx(대소문자 무시) → `.office`; pdf는 여전히 `.pdf`, 이미지/마크다운 불변.
- `FileTreeListingTests`: office 확장자 목록 표시.
- (가능하면) `AppOfficeTabTests`: office 탭 currentTabKind/windowTitle.

**게이트:** 기존 84개 + 신규 모두 통과. 서브프로세스(KordocService)·뷰·로딩/에러 UI는 **실제 HWP**(`/Users/ahbaik/Downloads/제9회_전국동시지방선거_정의당_평가서.hwp`)로 수동 검증:
- HWP 열기 → 로딩 → 마크다운 읽기전용 표시
- Node 경로 탐지(앱 실행 환경에서 npx 못 찾을 때 안내)
- 변환 실패/손상 파일 → 안내 플레이스홀더(크래시 없음)
- 마크다운/이미지/PDF 회귀 없음, 원본 .hwp 미변경

## 7. 파일 변경 요약
| 파일 | 변경 |
| --- | --- |
| `Sources/Models/KordocResult.swift` | 신규 — Codable 결과/블록/아웃라인 |
| `Sources/Services/KordocService.swift` | 신규 actor — npx 탐지 + Process 변환 + 디코드 |
| `Sources/Models/DocumentKind.swift` | `.office` + officeExtensions |
| `Sources/App/AppState.swift` | office 로드 분기·officeStates·패널·목록·closeTab 정리 |
| `Sources/Views/OfficeReaderView.swift` | 신규 — loading/loaded(프리뷰)/failed |
| `Sources/Views/MainEditorView.swift` | `.office` 분기 |
| `Tests/CmdMDTests/KordocResultTests.swift` | 신규 — JSON 디코딩 |
| `Tests/CmdMDTests/DocumentKindTests.swift` | office 매핑 |
| `Tests/CmdMDTests/FileTreeListingTests.swift` | office 목록 |

신규 로직(서비스·모델·뷰)은 별도 파일로 격리. 기존 파일은 분기 확장 위주, 마크다운·이미지·PDF 동작 불변. 원본 문서 read-only.
