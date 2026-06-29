# Phase 2 — PDF 리더 설계

- 날짜: 2026-06-29
- 대상: cmd-docu (CmdMD 포크), `cmd-docu` 브랜치
- 범위: PRD 티어 1 / Phase 2 — PDF 보기(페이지·썸네일·문서 내 검색·텍스트 선택/복사·줌·회전)
- 통합 방식: **A안 — DocumentKind 분기 재사용** (Phase 1 이미지 리더와 동일 패턴)

## 1. 목표 / 비목표

**목표**
- `.pdf`를 기존 탭 UX로 같은 창에서 연다.
- `PDFView`로 페이지 이동·줌·맞춤·텍스트 선택/복사·회전.
- 좌측 **썸네일 사이드바**(`PDFThumbnailView`)로 페이지 미리보기·클릭 이동. 토글 가능.
- 상단 **검색 필드**로 문서 내 텍스트 검색 → 일치 하이라이트 + 다음/이전 이동.
- 로드 실패 시 크래시 없이 플레이스홀더.

**비목표 (YAGNI)**
- 주석/마크업 편집, 폼 채우기, 페이지 추출·병합·삭제, 인쇄.
- PDF 텍스트 → 마크다운 추출(= Phase 3 kordoc 역할; "보기"와 "추출" 분리 — PRD §3.1).
- HWP·오피스(Phase 3).

## 2. 통합 방식 (A안)

Phase 1에서 도입한 `DocumentKind` + `EditorTab.kind` + 뷰 레벨 분기 구조에 `.pdf`를 추가한다. 이미지와 동일하게 PDF 탭은 `MarkdownDocument`/파일워처/originalContents 없이 URL만 가진 `EditorTab`로 만든다.

- B안(image+pdf 공통 추상화 프로토콜): 종류 2개에 추상화는 과함(YAGNI). 기각.
- C안(PDF 페이지를 이미지로 렌더해 이미지 뷰 재사용): 검색·텍스트 선택 불가. 기각.

PDFKit(`PDFView`·`PDFThumbnailView`·`PDFDocument.findString`)이 핵심 기능을 제공하므로 구현량은 적다. 모두 macOS 내장(추가 의존성 없음).

## 3. 구성요소

### 3.1 `Sources/Models/DocumentKind.swift` (수정)
- `enum DocumentKind`에 `case pdf` 추가.
- `init(from url: URL)` 매핑: 확장자 `pdf` → `.pdf`. (이미지 집합 검사보다 먼저/뒤 순서 무관 — 상호 배타)
- 단일 판별원 유지: `static let pdfExtensions: Set<String> = ["pdf"]` 추가(이미지의 `imageExtensions`와 같은 패턴).
- `init(from:)` 로직:
  ```
  let ext = url.pathExtension.lowercased()
  if imageExtensions.contains(ext) { self = .image }
  else if pdfExtensions.contains(ext) { self = .pdf }
  else { self = .markdown }
  ```

### 3.2 `Sources/Views/PDFReaderView.swift` (신규)
- `NSViewRepresentable`. 입력 `let url: URL`.
- `makeNSView`: `NSSplitView`(수평) 구성
  - 좌: `PDFThumbnailView`(폭 ~150, 토글 시 숨김). `thumbnailView.pdfView = pdfView`로 연결.
  - 우: 세로 컨테이너 = 상단 `NSSearchField` + 그 아래 `PDFView`.
  - `PDFView`: `autoScales = true`, `displayMode = .singlePageContinuous`, `document = PDFDocument(url: url)`.
- 검색: `NSSearchField` target/action → Coordinator가
  - `pdfView.document?.findString(text, withOptions: [.caseInsensitive])` 로 `[PDFSelection]` 획득
  - `pdfView.highlightedSelections = selections`; 첫 일치로 `pdfView.go(to:)` + `pdfView.setCurrentSelection(_, animate:)`
  - 빈 문자열이면 하이라이트 해제(`highlightedSelections = nil`).
  - 다음/이전 이동(확정): 검색 필드에서 **Enter = 다음 일치**로 순회(Coordinator가 결과 배열 + 현재 인덱스 보관, 끝에서 처음으로 wrap). 이전 이동 버튼은 v1 비목표.
- 썸네일(확정): **기본 표시**. 상단 작은 토글 버튼으로 좌측 패널 collapse/expand(`NSSplitView` 패널 토글).
- 로드 실패(`PDFDocument(url:)` == nil): PDFView/썸네일 대신 플레이스홀더(SF Symbol + "PDF를 열 수 없음"). 크래시 금지.
- `url` 변경 시(`updateNSView`) 문서 재로딩(현재 url과 다를 때만), 검색 상태 초기화.

### 3.3 `Sources/App/AppState.swift` (수정)
- `loadAndActivateDocument`: 비마크다운 분기를 `.image`뿐 아니라 `.pdf`도 포함하도록 확장. 즉
  ```
  let kind = DocumentKind(from: url)
  if kind == .image || kind == .pdf {
      let tab = EditorTab(fileURL: url, title: url.deletingPathExtension().lastPathComponent, kind: kind)
      placeTab(tab, inNewTab: inNewTab); addToRecentFiles(url); saveSession(); return
  }
  ```
  (kind를 탭에 그대로 전달 — 이미지/ PDF 공통)
- `openFile()` 패널 `allowedContentTypes`에 `.pdf` 추가.
- `isListableInFileTree`: `pdf` 확장자 포함(또는 `DocumentKind(from:) != .markdown || txt` 식). 명시적으로 `pdfExtensions` 포함.
- `currentTabKind`/`currentTabFileURL`/`windowTitle`은 kind 기반이라 수정 불필요(자동 동작).

### 3.4 `Sources/Views/MainEditorView.swift` (수정)
- 본문 Group 분기에 `.pdf` 추가:
  ```
  if appState.currentTabKind == .image, let url = appState.currentTabFileURL {
      ImageReaderView(url: url)
  } else if appState.currentTabKind == .pdf, let url = appState.currentTabFileURL {
      PDFReaderView(url: url)
  } else if let document = appState.currentDocument {
      DocumentEditorView(document: document)
  } else { WelcomeView() }
  ```
- 브레드크럼은 `currentTabFileURL` 기반이라 PDF 탭에서도 동작(무변경). 상태바는 `currentDocument != nil`이라 PDF 탭에선 자동 숨김(무변경).

## 4. 데이터 흐름
```
열기(openFile / 드롭 / 사이드바 클릭 / openDocument)
  → DocumentKind(from: url)
    ├─ .pdf   → EditorTab(kind:.pdf, fileURL) [문서/워처 없음] → MainEditorView: PDFReaderView(url:)
    ├─ .image → (Phase 1) ImageReaderView
    └─ .markdown → (기존) DocumentEditorView
```
마크다운 흐름·세션 저장/복원 무변경. 세션에 저장된 PDF 탭은 복원 시 확장자로 `.pdf` 재판별 → `PDFReaderView`.

## 5. 에러 처리
- `PDFDocument(url:)` 실패(손상·암호화 등): 플레이스홀더, 크래시·예외 없음.
- 암호 걸린 PDF: v1은 "열 수 없음" 플레이스홀더로 처리(암호 입력 UI는 비목표).
- PDF 탭인데 `fileURL == nil`(이론상 없음): 방어적 플레이스홀더.

## 6. 테스트 (Phase 게이트)

**신규/확장(XCTest, TDD):**
- `DocumentKindTests`: `pdf`/`PDF`/`Pdf` → `.pdf`; 기존 이미지·마크다운 매핑 불변.
- `FileTreeListingTests`: `pdf` 목록 표시; 기존 케이스 불변.
- `AppPdfTabTests`(또는 기존 탭 테스트 확장): `kind:.pdf` 탭에서 `currentTabKind == .pdf`, `currentTabFileURL` 일치, `windowTitle` = 파일명.

**게이트:** 기존 72개 + 신규 모두 통과(정식 Xcode). 뷰(`PDFReaderView`)·검색·썸네일·회전은 UI라 실제 PDF로 수동 확인(열기·페이지 이동·썸네일 클릭·검색 하이라이트·선택/복사·줌·회전·실패 플레이스홀더·마크다운/이미지 회귀 없음).

## 7. 파일 변경 요약
| 파일 | 변경 |
| --- | --- |
| `Sources/Models/DocumentKind.swift` | `.pdf` 케이스 + `pdfExtensions` + 매핑 |
| `Sources/Views/PDFReaderView.swift` | 신규 — PDFView+PDFThumbnailView+검색 래퍼 |
| `Sources/App/AppState.swift` | 로드 분기 `.pdf` 포함, 패널 `.pdf`, isListableInFileTree pdf |
| `Sources/Views/MainEditorView.swift` | `.pdf` → PDFReaderView 분기 |
| `Tests/CmdMDTests/DocumentKindTests.swift` | pdf 매핑 케이스 |
| `Tests/CmdMDTests/FileTreeListingTests.swift` | pdf 목록 케이스 |
| `Tests/CmdMDTests/AppPdfTabTests.swift` | 신규 — pdf 탭 노출 프로퍼티 |

신규 로직은 별도 파일(`PDFReaderView.swift`)로 격리. 기존 파일 변경은 분기 확장 위주, 마크다운·이미지 동작 불변.
