# 폴더 검색 확장 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 사이드바 "Search in folder"가 모든 종류 파일의 파일명과 PDF 본문까지 검색하고, PDF 본문 결과를 클릭하면 해당 페이지로 점프한다.

**Architecture:** `SearchResult`에 매칭 종류(`kind`)를 추가하고, 검색 매칭 로직을 순수 헬퍼(`filenameMatch`/`contentLineMatches`)로 분리해 TDD한다. `performSearch`는 헬퍼를 써서 파일명(모든 종류)·텍스트 본문(md/markdown/txt)·PDF 본문(PDFKit 페이지 추출)을 모은다. PDF 결과는 마크다운 `scrollToLine`과 동형의 `.scrollToPDFPage` 노티로 `PDFReaderView`가 받아 페이지 이동한다.

**Tech Stack:** Swift 5.9+ / SwiftUI / AppKit / PDFKit / Foundation / XCTest. macOS 14+.

## Global Constraints

- macOS 14+, Swift 5.9+. 비샌드박스. 추가 의존성 없음(PDFKit 내장).
- Phase 게이트: 각 Task 테스트 + **기존 77개 XCTest 전부 통과**. `swift test`는 정식 Xcode에서만.
- 신규 로직은 순수 헬퍼/관찰자로 분리(테스트 가능·머지 안전). 기존 md 줄 검색·열기 동작 불변.
- 인덱싱/FTS5/시맨틱/이미지 OCR은 범위 밖(Phase 7/9).
- 내부 식별자 `CmdMD`·URL 스킴 `cmdmd`·원작자 고지 유지.
- 커밋 메시지는 한국어. **모든 커밋 끝에 아래 두 줄**:
  ```
  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01S2QuZUALidkTNRswXFL6xM
  ```
- 작업 브랜치: `cmd-docu`.

## File Structure

| 파일 | 책임 | 변경 |
| --- | --- | --- |
| `Sources/Models/Workspace.swift` | `SearchMatchKind` + `SearchResult.kind` | 수정 |
| `Tests/CmdMDTests/SearchResultKindTests.swift` | SearchResult 하위호환·kind | 신규 |
| `Sources/App/AppState.swift` | `filenameMatch`/`contentLineMatches` 헬퍼, `performSearch` 확장, `openDocument`에 scrollToPDFPage | 수정 |
| `Tests/CmdMDTests/FolderSearchHelpersTests.swift` | 헬퍼 순수 함수 검증 | 신규 |
| `Sources/Views/PDFReaderView.swift` | `.scrollToPDFPage` 관찰 → 페이지 이동 | 수정 |
| `Sources/Views/SidebarView.swift` | 결과 행 라벨(kind별)·클릭 분기 | 수정 |

현재 코드 상태(참고):
- `SearchResult`(`Workspace.swift:164`): `id, fileURL, lineNumber, lineContent, matchRange` + 멤버와이즈 init.
- `AppState.performSearch(query:in:)`: 폴더 재귀 열거 → md/markdown만 `String(contentsOf:)` 줄 검색 → `SearchResult`.
- `AppState.isListableInFileTree(_:)`: md/markdown/txt + 이미지 + pdf 판별(검색 대상 집합).
- `AppState.openDocument(at:inNewTab:scrollToLine:)`: 기존 탭이면 활성화(+scrollEditor), 아니면 `loadAndActivateDocument` 후 처리. `scrollEditor(toLine:)`가 0.3초 지연 후 `.scrollToLine` 게시.
- `SearchResultsList`(`SidebarView.swift:270`) onTap: `openDocument(at: result.fileURL, inNewTab: true, scrollToLine: result.lineNumber)`. `SearchResultRow`: "Line \(lineNumber)" + lineContent.
- `PDFReaderView.Coordinator`: NSObject, `pdfView`(weak)·`currentURL` 보유.

---

## Task 1: SearchResult에 kind 추가

**Files:**
- Modify: `Sources/Models/Workspace.swift` (`struct SearchResult`, ~164)
- Test: `Tests/CmdMDTests/SearchResultKindTests.swift`

**Interfaces:**
- Produces:
  - `enum SearchMatchKind { case filename; case line; case pdfPage }`
  - `SearchResult.kind: SearchMatchKind`
  - `init(fileURL:lineNumber:lineContent:matchRange:kind:)` — `kind` 기본 `.line`(하위호환)

- [ ] **Step 1: 실패 테스트 작성**

Create `Tests/CmdMDTests/SearchResultKindTests.swift`:
```swift
import XCTest
@testable import CmdMD

final class SearchResultKindTests: XCTestCase {
    private func rangeIn(_ s: String) -> Range<String.Index> {
        s.startIndex..<s.index(after: s.startIndex)
    }

    func testDefaultKindIsLine() {
        let r = SearchResult(fileURL: URL(fileURLWithPath: "/tmp/a.md"),
                             lineNumber: 3, lineContent: "hello", matchRange: rangeIn("hello"))
        XCTAssertEqual(r.kind, .line)
    }

    func testExplicitKindPreserved() {
        let name = "photo.png"
        let r = SearchResult(fileURL: URL(fileURLWithPath: "/tmp/\(name)"),
                             lineNumber: 0, lineContent: name, matchRange: rangeIn(name),
                             kind: .filename)
        XCTAssertEqual(r.kind, .filename)

        let p = SearchResult(fileURL: URL(fileURLWithPath: "/tmp/doc.pdf"),
                             lineNumber: 5, lineContent: "orange", matchRange: rangeIn("orange"),
                             kind: .pdfPage)
        XCTAssertEqual(p.kind, .pdfPage)
        XCTAssertEqual(p.lineNumber, 5)
    }
}
```

- [ ] **Step 2: 실패 확인**

Run: `swift test --filter SearchResultKindTests`
Expected: FAIL — `value of type 'SearchResult' has no member 'kind'` / `cannot find 'SearchMatchKind'`

- [ ] **Step 3: 구현**

`Sources/Models/Workspace.swift`, `struct SearchResult` 바로 위에 enum 추가:
```swift
/// 검색 결과 한 건의 종류 — 파일명 매칭 / 텍스트 줄 / PDF 페이지.
enum SearchMatchKind {
    case filename
    case line
    case pdfPage
}
```
`struct SearchResult`에 `kind` 저장 프로퍼티 추가(`matchRange` 다음 줄):
```swift
    let matchRange: Range<String.Index>
    let kind: SearchMatchKind
```
멤버와이즈 init을 아래로 교체(끝에 `kind` 기본값 추가):
```swift
    init(fileURL: URL, lineNumber: Int, lineContent: String,
         matchRange: Range<String.Index>, kind: SearchMatchKind = .line) {
        self.id = UUID()
        self.fileURL = fileURL
        self.lineNumber = lineNumber
        self.lineContent = lineContent
        self.matchRange = matchRange
        self.kind = kind
    }
```

- [ ] **Step 4: 통과 확인**

Run: `swift test --filter SearchResultKindTests`
Expected: PASS (2)

- [ ] **Step 5: 회귀 + 커밋**

Run: `swift build`
Expected: Build complete! (기존 `SearchResult(...)` 호출부는 kind 기본값 덕에 무변경 컴파일)
```bash
git add Sources/Models/Workspace.swift Tests/CmdMDTests/SearchResultKindTests.swift
git commit -m "$(cat <<'EOF'
폴더 검색 확장: SearchResult에 kind(파일명/줄/PDF페이지) 추가

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01S2QuZUALidkTNRswXFL6xM
EOF
)"
```

---

## Task 2: 검색 헬퍼 + performSearch 확장

**Files:**
- Modify: `Sources/App/AppState.swift` (`import PDFKit`, 헬퍼 추가, `performSearch` 교체)
- Test: `Tests/CmdMDTests/FolderSearchHelpersTests.swift`

**Interfaces:**
- Consumes: `SearchResult`/`SearchMatchKind`(Task 1), `DocumentKind.pdfExtensions`, `AppState.isListableInFileTree`
- Produces:
  - `static func AppState.filenameMatch(_ url: URL, query: String) -> SearchResult?`
  - `static func AppState.contentLineMatches(in text: String, fileURL: URL, query: String) -> [SearchResult]`
  - `performSearch`가 파일명(전종류)+텍스트본문(md/markdown/txt)+PDF본문(.pdfPage) 결과 생성

- [ ] **Step 1: 실패 테스트 작성**

Create `Tests/CmdMDTests/FolderSearchHelpersTests.swift`:
```swift
import XCTest
@testable import CmdMD

final class FolderSearchHelpersTests: XCTestCase {
    private let img = URL(fileURLWithPath: "/tmp/Vacation_Orange.png")
    private let md  = URL(fileURLWithPath: "/tmp/note.md")

    // filenameMatch
    func testFilenameMatchCaseInsensitive() {
        let r = AppState.filenameMatch(img, query: "orange")
        XCTAssertNotNil(r)
        XCTAssertEqual(r?.kind, .filename)
        XCTAssertEqual(r?.lineContent, "Vacation_Orange.png")
        XCTAssertEqual(r?.lineNumber, 0)
    }

    func testFilenameNoMatchReturnsNil() {
        XCTAssertNil(AppState.filenameMatch(img, query: "banana"))
    }

    func testFilenameEmptyQueryReturnsNil() {
        XCTAssertNil(AppState.filenameMatch(img, query: ""))
    }

    // contentLineMatches
    func testContentLineMatchesFindsMatchingLinesWith1BasedNumbers() {
        let text = "alpha\nbeta orange\ngamma\nORANGE again"
        let hits = AppState.contentLineMatches(in: text, fileURL: md, query: "orange")
        XCTAssertEqual(hits.count, 2)
        XCTAssertEqual(hits[0].lineNumber, 2)
        XCTAssertEqual(hits[0].lineContent, "beta orange")
        XCTAssertEqual(hits[0].kind, .line)
        XCTAssertEqual(hits[1].lineNumber, 4)   // 대소문자 무시
    }

    func testContentLineMatchesNoMatchEmpty() {
        let hits = AppState.contentLineMatches(in: "nothing here", fileURL: md, query: "orange")
        XCTAssertTrue(hits.isEmpty)
    }
}
```

- [ ] **Step 2: 실패 확인**

Run: `swift test --filter FolderSearchHelpersTests`
Expected: FAIL — `type 'AppState' has no member 'filenameMatch'`

- [ ] **Step 3: 헬퍼 구현**

`Sources/App/AppState.swift` 상단 import에 PDFKit 추가(이미 있으면 생략):
```swift
import PDFKit
```
`// MARK: - Folder Search` 아래(또는 `performSearch` 위)에 순수 헬퍼 추가:
```swift
    /// 파일명에 query(대소문자 무시)가 들어있으면 .filename 결과를 만든다.
    static func filenameMatch(_ url: URL, query: String) -> SearchResult? {
        guard !query.isEmpty else { return nil }
        let name = url.lastPathComponent
        guard let range = name.range(of: query, options: .caseInsensitive) else { return nil }
        return SearchResult(fileURL: url, lineNumber: 0, lineContent: name,
                            matchRange: range, kind: .filename)
    }

    /// text의 각 줄에서 query(대소문자 무시) 첫 위치를 찾아 .line 결과(줄번호 1-base)로.
    static func contentLineMatches(in text: String, fileURL: URL, query: String) -> [SearchResult] {
        guard !query.isEmpty else { return [] }
        var results: [SearchResult] = []
        let lines = text.components(separatedBy: .newlines)
        for (index, line) in lines.enumerated() {
            if let range = line.range(of: query, options: .caseInsensitive) {
                results.append(SearchResult(fileURL: fileURL, lineNumber: index + 1,
                                            lineContent: line, matchRange: range, kind: .line))
            }
        }
        return results
    }
```

- [ ] **Step 4: 통과 확인(헬퍼)**

Run: `swift test --filter FolderSearchHelpersTests`
Expected: PASS (5)

- [ ] **Step 5: performSearch 교체**

`performSearch(query:in:)` 본문을 아래로 교체(파일명 전종류 + 텍스트 + PDF):
```swift
    private func performSearch(query: String, in folder: URL) async -> [SearchResult] {
        var results: [SearchResult] = []
        let fileManager = FileManager.default

        guard let enumerator = fileManager.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        let maxResults = 500
        let textExtensions: Set<String> = ["md", "markdown", "txt"]
        let fileURLs = enumerator.allObjects.compactMap { $0 as? URL }

        for fileURL in fileURLs {
            guard Self.isListableInFileTree(fileURL) else { continue }

            // 1) 파일명 매칭(모든 종류: md/txt·이미지·pdf)
            if let nameHit = Self.filenameMatch(fileURL, query: query) {
                results.append(nameHit)
                if results.count >= maxResults { return results }
            }

            let ext = fileURL.pathExtension.lowercased()

            // 2) 텍스트 본문(md/markdown/txt)
            if textExtensions.contains(ext) {
                if let content = try? String(contentsOf: fileURL, encoding: .utf8) {
                    for hit in Self.contentLineMatches(in: content, fileURL: fileURL, query: query) {
                        results.append(hit)
                        if results.count >= maxResults { return results }
                    }
                }
            // 3) PDF 본문(페이지별 추출 → .pdfPage)
            } else if DocumentKind.pdfExtensions.contains(ext) {
                if let pdf = PDFDocument(url: fileURL) {
                    for pageIndex in 0..<pdf.pageCount {
                        guard let page = pdf.page(at: pageIndex),
                              let pageText = page.string else { continue }
                        for hit in Self.contentLineMatches(in: pageText, fileURL: fileURL, query: query) {
                            results.append(SearchResult(
                                fileURL: fileURL,
                                lineNumber: pageIndex + 1,        // 페이지 번호(1-base)
                                lineContent: hit.lineContent,
                                matchRange: hit.matchRange,
                                kind: .pdfPage
                            ))
                            if results.count >= maxResults { return results }
                        }
                    }
                }
            }
            // 이미지: 본문 없음 — 파일명 매칭만(위 1번)
        }

        return results
    }
```

- [ ] **Step 6: 전체 빌드·테스트**

Run: `swift build && swift test`
Expected: Build complete! + 모든 테스트 PASS(기존 77 + 신규 7)

- [ ] **Step 7: 커밋**

```bash
git add Sources/App/AppState.swift Tests/CmdMDTests/FolderSearchHelpersTests.swift
git commit -m "$(cat <<'EOF'
폴더 검색 확장: 파일명(전종류)·텍스트·PDF 본문 검색

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01S2QuZUALidkTNRswXFL6xM
EOF
)"
```

---

## Task 3: PDF 페이지 점프 (openDocument + PDFReaderView 관찰)

**Files:**
- Modify: `Sources/Views/PDFReaderView.swift` (`.scrollToPDFPage` Name·payload·관찰)
- Modify: `Sources/App/AppState.swift` (`openDocument`에 `scrollToPDFPage` 파라미터 + 게시)

**Interfaces:**
- Consumes: `PDFReaderView`(Phase 2), `openDocument`(기존)
- Produces:
  - `Notification.Name.scrollToPDFPage`, `struct PDFPageJump { let url: URL; let page: Int }`
  - `openDocument(at:inNewTab:scrollToLine:scrollToPDFPage:)` — `scrollToPDFPage: Int? = nil`
  - `PDFReaderView`가 자기 url과 일치하는 점프 노티를 받으면 해당 페이지로 이동

빌드 + 수동 검증(점프). 자동 단위테스트 없음(UI/통합).

- [ ] **Step 1: PDFReaderView에 Name·payload·관찰 추가**

`Sources/Views/PDFReaderView.swift` 파일 끝(구조체 밖)에 추가:
```swift
/// 검색 결과(PDF 본문)에서 특정 페이지로 이동 요청. object로 PDFPageJump를 싣는다.
extension Notification.Name {
    static let scrollToPDFPage = Notification.Name("scrollToPDFPage")
}

/// 어떤 PDF의 몇 페이지로 갈지(1-base). 여러 PDF 탭 중 url로 대상 식별.
struct PDFPageJump {
    let url: URL
    let page: Int
}
```
`Coordinator`에 관찰자 보관·등록·해제 추가. `Coordinator` 안에 프로퍼티와 init/deinit 추가(기존 프로퍼티 옆):
```swift
        private var observers: [NSObjectProtocol] = []

        override init() {
            super.init()
            let center = NotificationCenter.default
            observers.append(center.addObserver(
                forName: .scrollToPDFPage, object: nil, queue: .main
            ) { [weak self] note in
                guard let self,
                      let jump = note.object as? PDFPageJump,
                      jump.url == self.currentURL,
                      let pdfView = self.pdfView,
                      let document = pdfView.document,
                      jump.page >= 1, jump.page <= document.pageCount,
                      let page = document.page(at: jump.page - 1) else { return }
                pdfView.go(to: page)
            })
        }

        deinit {
            observers.forEach { NotificationCenter.default.removeObserver($0) }
        }
```
(주의: 기존 `Coordinator`에 사용자 정의 `init`이 없다면 위 `override init()`을 추가. 이미 있으면 그 안에 옵저버 등록 코드를 합칠 것. `makeCoordinator()`는 `Coordinator()`를 그대로 반환.)

- [ ] **Step 2: 빌드 확인(관찰자)**

Run: `swift build`
Expected: Build complete!

- [ ] **Step 3: openDocument에 scrollToPDFPage 추가**

`Sources/App/AppState.swift`의 `openDocument`를 찾아 시그니처와 본문을 확장. 현재 형태:
```swift
    func openDocument(at url: URL, inNewTab: Bool = false, scrollToLine line: Int? = nil) {
        if let existingTab = tabs.first(where: { $0.fileURL == url }) {
            activeTabId = existingTab.id
            if let line { scrollEditor(toLine: line) }
            return
        }
        Task { @MainActor in
            await loadAndActivateDocument(at: url, inNewTab: inNewTab)
            if let line { scrollEditor(toLine: line) }
        }
    }
```
아래로 교체(파라미터 + 두 경로 모두 페이지 점프 게시):
```swift
    func openDocument(at url: URL, inNewTab: Bool = false,
                      scrollToLine line: Int? = nil, scrollToPDFPage pdfPage: Int? = nil) {
        if let existingTab = tabs.first(where: { $0.fileURL == url }) {
            activeTabId = existingTab.id
            if let line { scrollEditor(toLine: line) }
            if let pdfPage { scrollPDF(toPage: pdfPage, url: url) }
            return
        }
        Task { @MainActor in
            await loadAndActivateDocument(at: url, inNewTab: inNewTab)
            if let line { scrollEditor(toLine: line) }
            if let pdfPage { scrollPDF(toPage: pdfPage, url: url) }
        }
    }

    /// PDF 탭이 떠서 PDFReaderView가 구독을 마칠 시간을 준 뒤 페이지 점프 노티 게시.
    private func scrollPDF(toPage page: Int, url: URL) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NotificationCenter.default.post(name: .scrollToPDFPage,
                                            object: PDFPageJump(url: url, page: page))
        }
    }
```

- [ ] **Step 4: 빌드 + 전체 테스트**

Run: `swift build && swift test`
Expected: Build complete! + 모든 테스트 PASS(77 + 7)

- [ ] **Step 5: 커밋**

```bash
git add Sources/Views/PDFReaderView.swift Sources/App/AppState.swift
git commit -m "$(cat <<'EOF'
폴더 검색 확장: PDF 결과 페이지 점프(.scrollToPDFPage)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01S2QuZUALidkTNRswXFL6xM
EOF
)"
```

---

## Task 4: 결과 행 라벨 + 클릭 분기 (SidebarView)

**Files:**
- Modify: `Sources/Views/SidebarView.swift` (`SearchResultRow` 라벨, `SearchResultsList` onTap)

**Interfaces:**
- Consumes: `SearchResult.kind`(Task 1), `openDocument(...scrollToPDFPage:)`(Task 3)
- Produces: kind별 라벨(이름/Line N/p.N)·클릭 시 알맞은 위치로 열기

빌드 + 수동 검증.

- [ ] **Step 1: SearchResultRow 라벨 kind별로**

`SearchResultRow`의 `Text("Line \(result.lineNumber)")` 부분을 kind 기반 라벨로 교체. `var body` 위에 헬퍼 추가하고 Text를 바꾼다:
```swift
struct SearchResultRow: View {
    let result: SearchResult

    private var badge: String {
        switch result.kind {
        case .filename: return "이름"
        case .line:     return "Line \(result.lineNumber)"
        case .pdfPage:  return "p.\(result.lineNumber)"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(badge)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(3)
                Spacer()
            }

            Text(result.lineContent)
                .font(.system(size: 11))
                .lineLimit(2)
                .foregroundColor(.primary)
        }
        .padding(.vertical, 4)
    }
}
```

- [ ] **Step 2: 클릭 분기**

`SearchResultsList`의 onTap(`appState.openDocument(at: result.fileURL, inNewTab: true, scrollToLine: result.lineNumber)`)을 kind별로 교체:
```swift
                            .onTapGesture {
                                switch result.kind {
                                case .line:
                                    appState.openDocument(at: result.fileURL, inNewTab: true,
                                                          scrollToLine: result.lineNumber)
                                case .pdfPage:
                                    appState.openDocument(at: result.fileURL, inNewTab: true,
                                                          scrollToPDFPage: result.lineNumber)
                                case .filename:
                                    appState.openDocument(at: result.fileURL, inNewTab: true)
                                }
                            }
```
(onTap의 정확한 위치/들여쓰기는 현재 코드에 맞춰 교체. `SearchResultsList`에 `@Environment(AppState.self) private var appState`가 이미 있다 — 없으면 추가.)

- [ ] **Step 3: 빌드 + 전체 테스트**

Run: `swift build && swift test`
Expected: Build complete! + 모든 테스트 PASS

- [ ] **Step 4: 커밋**

```bash
git add Sources/Views/SidebarView.swift
git commit -m "$(cat <<'EOF'
폴더 검색 확장: 결과 행 라벨(이름/줄/페이지)·클릭 분기

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01S2QuZUALidkTNRswXFL6xM
EOF
)"
```

---

## Task 5: 수동 검증

코드 변경 없음. 실제 폴더로 확인.

- [ ] **Step 1: 앱 실행**
```bash
pkill -f ".build/arm64-apple-macosx/debug/CmdMD" 2>/dev/null; true
swift run CmdMD
```

- [ ] **Step 2: 체크리스트** (샘플 폴더 `~/Desktop/cmd-docu-samples` 열고, 사이드바 돋보기로 검색)
- [ ] 질의어로 **이미지/PDF 파일명**이 결과에 뜸(라벨 "이름")
- [ ] PDF **본문** 단어(예: orange)가 결과에 뜸(라벨 "p.N")
- [ ] PDF 본문 결과 클릭 → 그 PDF가 열리고 **해당 페이지로 점프**
- [ ] md/txt 본문 결과(라벨 "Line N") 클릭 → 해당 줄로 이동(회귀 없음)
- [ ] 이미지 파일명 결과 클릭 → 이미지 리더로 열림
- [ ] 결과 없을 때 "No matches found" 정상

- [ ] **Step 3: 결과 기록** — 문제 없으면 완료. 이슈는 후속 Task로.

---

## Self-Review (계획 점검)

- **스펙 커버리지:** §3.1(kind)→Task1; §3.2(헬퍼·performSearch 파일명/텍스트/PDF)→Task2; §3.4(페이지 점프 노티·openDocument·PDFReaderView)→Task3; §3.3(행 라벨)+§3.4(클릭 분기)→Task4; §6 테스트→Task1·2 + Task5 수동. 누락 없음.
- **플레이스홀더 스캔:** 모든 코드 단계에 실제 코드. "적절한 처리" 류 없음.
- **타입 일관성:** `SearchMatchKind`(.filename/.line/.pdfPage)·`SearchResult(kind:)`·`filenameMatch`·`contentLineMatches`·`Notification.Name.scrollToPDFPage`·`PDFPageJump(url:page:)`·`openDocument(...scrollToPDFPage:)`가 정의 Task와 소비 Task에서 동일.
- **회귀 주의:** Task1의 kind 기본값 `.line`으로 기존 `SearchResult(...)` 호출부·기존 md 줄검색·결과 클릭 동작 보존. performSearch가 `isListableInFileTree`로 대상 한정(비표시 파일 제외).
- **범위:** 단일 계획 적합(폴더 검색 확장 한 기능).
