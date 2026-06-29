# 폴더 검색 확장 (파일명 + PDF 본문) 설계

- 날짜: 2026-06-29
- 대상: cmd-docu (CmdMD 포크), `cmd-docu` 브랜치
- 범위: 기존 "Search in folder"(현재 폴더 라이브 검색)를 확장 — ① 모든 종류 파일의 **파일명** 검색, ② **PDF 본문** 검색, PDF 결과는 **해당 페이지로 점프**
- 비범위: 키워드 인덱싱·SQLite FTS5(PRD Phase 7), 시맨틱·RAG(Phase 9). 여기선 인덱스 없이 현재 폴더를 그때그때 훑는 라이브 검색만 확장.

## 1. 목표 / 비목표

**목표**
- 사이드바 "Search in folder"가 다음을 모두 찾는다(현재 폴더 재귀, Enter 시 1회 실행):
  - **파일명 매칭**: md/markdown/txt·이미지(png/jpg/jpeg/heic/webp/gif)·pdf — 파일명에 질의어 포함 시.
  - **본문 매칭(텍스트)**: md/markdown/txt 줄 단위(기존 + txt 추가).
  - **본문 매칭(PDF)**: PDFKit으로 페이지별 텍스트 추출 후 줄 검색.
  - 이미지는 본문이 없으므로 **파일명만**.
- 결과 클릭 시 알맞은 리더로 열림(기존 `openDocument` kind 분기). 본문 결과는 위치로 이동:
  - md/txt → 해당 **줄**(기존 scrollToLine).
  - PDF → 해당 **페이지로 점프**.

**비목표(YAGNI)**
- 영구 인덱스·파일 감시(Phase 7), 시맨틱(Phase 9).
- 이미지 OCR(이미지 본문 텍스트 추출).
- 검색어 하이라이트 색상 커스터마이즈 등.

## 2. 현재 상태(기준)
- `AppState.performSearch(query:in:)`(`Sources/App/AppState.swift`)가 폴더를 재귀 열거하되 **md/markdown 본문만** 줄 검색 → `[SearchResult]`.
- `SearchResult`(`Sources/Models/Workspace.swift`): `fileURL`, `lineNumber`, `lineContent`, `matchRange`.
- 사이드바: `FolderSearchView`(검색 토글 시 목록 대체) → `SearchResultsList` → `SearchResultRow`("Line N" + 내용). 클릭 → `openDocument(at:inNewTab:true, scrollToLine:)`.
- `openDocument`는 이미 kind 분기(md/image/pdf). `scrollToLine`은 마크다운에서만 의미.
- `AppState.isListableInFileTree(_:)`가 표시 대상(md/txt/이미지/pdf) 판별 — 검색 대상 집합으로 재사용.

## 3. 설계

### 3.1 SearchResult 모델 (`Sources/Models/Workspace.swift` 수정)
- `enum SearchMatchKind { case filename, line, pdfPage }` 추가.
- `SearchResult`에 `let kind: SearchMatchKind` 추가.
  - `.filename`: `lineNumber = 0`, `lineContent = 파일명`, `matchRange = 파일명 내 범위`.
  - `.line`: 기존 의미(lineNumber = 줄 번호).
  - `.pdfPage`: `lineNumber = 페이지 번호(1-base)`, `lineContent = 일치 줄 스니펫`.
- 하위호환: 기존 멤버와이즈 `init(fileURL:lineNumber:lineContent:matchRange:)`는 `kind = .line` 기본으로 유지(기존 호출부 무변경). `.filename`/`.pdfPage`용 추가 생성자 제공.

### 3.2 검색 로직 — 테스트 가능한 순수 헬퍼로 분리 (`Sources/App/AppState.swift`)
파일시스템·async인 `performSearch`는 직접 단위테스트가 어렵다. 순수 함수로 매칭 로직을 분리해 TDD한다:
- `static func filenameMatch(_ url: URL, query: String) -> SearchResult?`
  - 파일명(소문자)에 query(소문자) 포함 시 `.filename` 결과, 아니면 nil.
- `static func contentLineMatches(in text: String, fileURL: URL, query: String) -> [SearchResult]`
  - text를 줄 분해, 각 줄에서 query(대소문자 무시) 첫 위치 매칭 → `kind == .line`, `lineNumber = 줄번호(1-base)`, `lineContent = 줄`, `matchRange` 채운 결과 배열. 미일치 시 빈 배열.
  - **텍스트 파일(md/markdown/txt)**: 파일 전체 텍스트로 1회 호출 → 그대로 `.line` 결과로 사용.
  - **PDF**: 각 페이지 `page.string`으로 호출한 뒤, performSearch가 반환된 각 결과를 **`.pdfPage`로 재구성**(`lineNumber = 페이지번호`, `lineContent`·`matchRange`는 유지). 즉 헬퍼는 한 종류(`.line`)만 만들고, 페이지 번호 부여는 호출부(performSearch)가 담당해 함수를 순수·단순하게 유지.

`performSearch` 재작성(동작):
```
for url in 열거된 파일:
    guard isListableInFileTree(url) else { continue }
    if let m = filenameMatch(url, query) { results.append(m); cap 확인 }
    switch DocumentKind(from: url):
      .markdown(=md/markdown/txt 포함? 주: txt도 본문 검색):
          if 확장자 ∈ {md,markdown,txt}: 본문 읽어 lineMatches(.line) 추가
      .pdf:
          PDFDocument(url) 각 page.string에 대해 lineMatches(.pdfPage, page번호) 추가
      .image: (본문 없음 — 파일명만)
    maxResults(500) 도달 시 중단
```
- 주의: `DocumentKind(from:)`는 txt를 `.markdown`으로 분류하므로 본문 대상 판정은 확장자 집합(md/markdown/txt)으로 명시 검사한다(이미지/pdf와 혼동 없음).
- PDF 텍스트 없음(스캔본 등): 본문 결과 0, 파일명 매칭만 가능 — 정상.

### 3.3 결과 표시 (`Sources/Views/SidebarView.swift` — SearchResultRow)
- 라벨을 kind별로:
  - `.filename` → "이름"
  - `.line` → "Line \(lineNumber)"
  - `.pdfPage` → "p.\(lineNumber)"
- `.filename` 결과는 `lineContent`가 파일명이므로 그대로 표시(스니펫 자리에 파일명). 그룹 헤더(파일별)는 기존대로.

### 3.4 결과 열기 + PDF 페이지 점프
- `SearchResultsList`의 onTap에서 kind에 따라:
  - `.line` → `openDocument(at:, inNewTab: true, scrollToLine: lineNumber)` (기존).
  - `.filename` → `openDocument(at:, inNewTab: true)` (위치 이동 없음).
  - `.pdfPage` → `openDocument(at:, inNewTab: true)` + **PDF 페이지 점프 요청**.
- PDF 페이지 점프 메커니즘(마크다운 scrollToLine과 동형):
  - `AppState.openDocument`에 선택 파라미터 `scrollToPDFPage: Int? = nil` 추가. PDF 탭 활성화 후 짧은 지연 뒤 `NotificationCenter`에 `.scrollToPDFPage` 게시(object: `(url, page)` 식별 가능한 페이로드).
  - `PDFReaderView.Coordinator`가 `.scrollToPDFPage` 관찰: 페이로드의 url이 자신의 `currentURL`과 같을 때만 `if let page = pdfView.document?.page(at: pageIndex) { pdfView.go(to: page) }`. (1-base → 0-base 변환)
  - 관찰자는 Coordinator 생성 시 등록, `deinit`/teardown에서 해제(ImageReader/PreviewView 패턴 참고).

## 4. 데이터 흐름
```
FolderSearchView(Enter) → searchInFolder(query) → performSearch(현재 폴더 재귀)
  파일별: filenameMatch + (md/txt 본문 | pdf 페이지본문 | 이미지 없음) → [SearchResult{kind,…}]
SearchResultsList(파일별 그룹) → 행 라벨(이름/Line/p.N)
  클릭 → openDocument(kind 분기로 알맞은 리더) (+ scrollToLine 또는 scrollToPDFPage)
    → PDFReaderView가 .scrollToPDFPage 받으면 해당 페이지로 go(to:)
```

## 5. 에러 처리
- 읽기 실패 파일: 건너뜀(기존 catch continue).
- `PDFDocument(url:)` 실패: 본문 검색 생략(파일명 매칭은 가능). 크래시 없음.
- 잘못된 페이지 번호: `page(at:)` 범위 밖이면 무시(점프 안 함).

## 6. 테스트 (Phase 게이트)
**신규(XCTest, TDD — 순수 헬퍼 대상):**
- `filenameMatch`: 이름 포함/대소문자 무시 → 결과, 미포함 → nil; 확장자 무관(이미지·pdf 이름도).
- `contentLineMatches`: 여러 줄 중 일치 줄만, 대소문자 무시, `.line`·줄번호(1-base)·matchRange, 미일치 시 빈 배열. (PDF의 `.pdfPage` 재구성은 performSearch 통합이라 수동/소형 검증.)
- `SearchResult` 기본 init이 `kind == .line`(하위호환), 파일명/페이지 생성자 동작.
- (선택) `isListableInFileTree` 대상에 검색이 한정되는지는 performSearch 통합이라 수동/소형 검증.

**게이트:** 기존 77개 + 신규 모두 통과. UI(라벨·클릭·페이지 점프)와 실제 PDF/이미지/폴더 검색은 수동 확인:
- 폴더 검색에서 이미지/pdf **파일명**이 결과에 뜸
- pdf **본문** 단어가 결과에 뜨고 클릭 시 그 **페이지로 점프**
- md/txt 본문·줄 점프 회귀 없음, 이미지 파일명 결과 클릭 시 이미지 리더로 열림

## 7. 파일 변경 요약
| 파일 | 변경 |
| --- | --- |
| `Sources/Models/Workspace.swift` | `SearchMatchKind` + `SearchResult.kind`(+ 생성자) |
| `Sources/App/AppState.swift` | `filenameMatch`/`contentLineMatches` 순수 헬퍼, `performSearch` 확장, `openDocument` scrollToPDFPage 파라미터 + 노티 게시 |
| `Sources/Views/PDFReaderView.swift` | `.scrollToPDFPage` 관찰 → 페이지 이동 |
| `Sources/Views/SidebarView.swift` | SearchResultRow 라벨(kind별), 클릭 시 kind별 열기 |
| `Tests/CmdMDTests/FolderSearchTests.swift` | 신규 — filenameMatch/lineMatches/SearchResult 하위호환 |

신규 로직은 순수 헬퍼·관찰자로 분리해 테스트 가능·머지 안전하게. 기존 md 줄 검색·열기 동작 불변.
