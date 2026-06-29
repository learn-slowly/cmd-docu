# PDF 리더 (Phase 2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `.pdf` 파일을 기존 탭 UX로 열어 페이지·썸네일·문서 내 검색·텍스트 선택/복사·줌·회전으로 본다.

**Architecture:** Phase 1 이미지 리더의 `DocumentKind` 분기 구조를 재사용한다. `DocumentKind`에 `.pdf`를 추가하고, 비마크다운 파일 탭(이미지/PDF) 로드 분기를 확장하며, 뷰 레벨에서 `PDFReaderView`로 가른다. PDF 뷰는 `NSSplitView`에 `PDFThumbnailView`+`NSSearchField`+`PDFView`를 엮은 네이티브 래퍼다. 마크다운·이미지 경로는 무변경.

**Tech Stack:** Swift 5.9+ / SwiftUI / AppKit / PDFKit(PDFView·PDFThumbnailView·PDFDocument) / XCTest. macOS 14+.

## Global Constraints

- macOS 14+, Swift 5.9+. 비샌드박스 유지. 추가 의존성 없음(PDFKit은 macOS 내장).
- Phase 게이트: 각 Task의 테스트 + **기존 72개 XCTest 전부 통과**. `swift test`는 정식 Xcode 활성 상태에서만 됨(CLT는 build만).
- 신규 로직은 별도 파일로 격리(업스트림 머지 용이). 기존 파일은 분기 확장 위주, 마크다운·이미지 동작 불변.
- 표시명/식별자 규칙 유지: 내부 타입명 `CmdMD`·URL 스킴 `cmdmd`·원작자 고지 건드리지 않음.
- "보기"만 구현(PDFKit). 텍스트→마크다운 추출은 Phase 3(kordoc) 몫 — 여기서 하지 않음.
- 커밋 메시지는 한국어. **모든 커밋 끝에 아래 두 줄을 붙인다**:
  ```
  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01S2QuZUALidkTNRswXFL6xM
  ```
- 작업 브랜치: `cmd-docu`.

## File Structure

| 파일 | 책임 | 변경 |
| --- | --- | --- |
| `Sources/Models/DocumentKind.swift` | 확장자→종류 판별에 `.pdf` 추가 | 수정 |
| `Tests/CmdMDTests/DocumentKindTests.swift` | pdf 매핑 검증 | 수정 |
| `Sources/Views/PDFReaderView.swift` | PDFView+썸네일+검색 네이티브 뷰 | 신규 |
| `Sources/App/AppState.swift` | 로드 분기 `.pdf` 포함·패널·목록 필터 | 수정 |
| `Tests/CmdMDTests/FileTreeListingTests.swift` | pdf 목록 표시 검증 | 수정 |
| `Tests/CmdMDTests/AppPdfTabTests.swift` | pdf 탭 노출 프로퍼티 검증 | 신규 |
| `Sources/Views/MainEditorView.swift` | `.pdf` → PDFReaderView 분기 | 수정 |

현재 관련 코드 상태(참고):
- `DocumentKind`: `enum DocumentKind: String, Codable { case markdown; case image }`, `static let imageExtensions: Set<String> = ["png","jpg","jpeg","heic","webp","gif"]`, `init(from url: URL)`.
- `AppState.loadAndActivateDocument`: 이미 `if DocumentKind(from: url) == .image { ... 이미지 탭 ... }` 분기 있음(그 아래 마크다운 do/catch).
- `AppState.isListableInFileTree(_:)`: `md/markdown/txt || DocumentKind.imageExtensions.contains(ext)`.
- `AppState.openFile()` 패널: `[.plainText, UTType(filenameExtension: "md")!, .png, .jpeg, .heic, .webP, .gif]`.
- `MainEditorView.body` Group: `if currentTabKind == .image, let url = currentTabFileURL { ImageReaderView(url: url) } else if let document = currentDocument { DocumentEditorView(document: document) } else { WelcomeView() }`.

---

## Task 1: DocumentKind에 .pdf 추가

**Files:**
- Modify: `Sources/Models/DocumentKind.swift`
- Test: `Tests/CmdMDTests/DocumentKindTests.swift`

**Interfaces:**
- Consumes: 기존 `DocumentKind`(`.markdown`, `.image`, `imageExtensions`, `init(from:)`)
- Produces:
  - `DocumentKind.pdf` 케이스
  - `static let DocumentKind.pdfExtensions: Set<String> = ["pdf"]`
  - `init(from:)`가 `pdf` 확장자(대소문자 무시) → `.pdf`

- [ ] **Step 1: 실패 테스트 추가**

`Tests/CmdMDTests/DocumentKindTests.swift` 의 `final class DocumentKindTests` 안에 메서드 2개 추가(기존 메서드는 그대로 두고 추가만):
```swift
    func testPdfMapsToPdf() {
        XCTAssertEqual(kind("doc.pdf"), .pdf)
        XCTAssertEqual(kind("REPORT.PDF"), .pdf)
        XCTAssertEqual(kind("Paper.Pdf"), .pdf)
    }

    func testPdfExtensionsSetMatchesMapping() {
        for ext in DocumentKind.pdfExtensions {
            XCTAssertEqual(kind("a.\(ext)"), .pdf)
        }
    }
```
(참고: 기존 파일 상단에 `private func kind(_ name: String) -> DocumentKind { DocumentKind(from: URL(fileURLWithPath: "/tmp/\(name)")) }` 헬퍼가 이미 있다.)

- [ ] **Step 2: 실패 확인**

Run: `swift test --filter DocumentKindTests`
Expected: FAIL — `type 'DocumentKind' has no member 'pdf'` (컴파일 에러)

- [ ] **Step 3: 구현**

`Sources/Models/DocumentKind.swift` 수정. enum에 `case pdf` 추가:
```swift
enum DocumentKind: String, Codable {
    case markdown
    case image
    case pdf
}
```
extension에 `pdfExtensions` 추가하고 `init(from:)`를 아래로 교체:
```swift
    /// 보기를 네이티브 PDF 뷰로 가르는 확장자 집합(소문자).
    static let pdfExtensions: Set<String> = ["pdf"]

    /// 확장자(대소문자 무시)로 종류를 정한다. 이미지·PDF가 아니면 마크다운(현행 기본 동작).
    init(from url: URL) {
        let ext = url.pathExtension.lowercased()
        if DocumentKind.imageExtensions.contains(ext) {
            self = .image
        } else if DocumentKind.pdfExtensions.contains(ext) {
            self = .pdf
        } else {
            self = .markdown
        }
    }
```
(기존 `imageExtensions` 선언은 그대로 둔다.)

- [ ] **Step 4: 통과 확인**

Run: `swift test --filter DocumentKindTests`
Expected: PASS (기존 + 신규 2개)

- [ ] **Step 5: 커밋**

```bash
git add Sources/Models/DocumentKind.swift Tests/CmdMDTests/DocumentKindTests.swift
git commit -m "$(cat <<'EOF'
PDF 리더(Phase 2): DocumentKind에 .pdf 추가

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01S2QuZUALidkTNRswXFL6xM
EOF
)"
```

---

## Task 2: PDFReaderView (PDFView + 썸네일 + 검색)

**Files:**
- Create: `Sources/Views/PDFReaderView.swift`

**Interfaces:**
- Consumes: 없음(독립 뷰)
- Produces: `struct PDFReaderView: NSViewRepresentable { let url: URL }` — Task 4에서 `PDFReaderView(url:)`로 사용

UI 컴포넌트라 자동 단위 테스트 없음. 산출물 = 컴파일 통과. 동작은 Task 4 배선 후 수동 확인.

- [ ] **Step 1: 뷰 구현**

Create `Sources/Views/PDFReaderView.swift`:
```swift
import SwiftUI
import AppKit
import PDFKit

/// 단독 PDF 보기. NSSplitView에 썸네일(좌)·검색필드+PDFView(우)를 엮는다.
/// PDFView가 페이지 이동·줌·맞춤·텍스트 선택/복사·회전을 제공하고,
/// PDFThumbnailView가 페이지 썸네일·클릭 이동을, NSSearchField가 문서 내 검색을 담당.
/// 로드 실패 시 플레이스홀더(크래시 금지).
struct PDFReaderView: NSViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let container = NSView()

        let pdfView = PDFView()
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.translatesAutoresizingMaskIntoConstraints = false
        context.coordinator.pdfView = pdfView

        // 문서 로드(실패 시 플레이스홀더).
        guard let document = PDFDocument(url: url) else {
            return Self.placeholderView()
        }
        pdfView.document = document
        context.coordinator.currentURL = url

        // 썸네일(좌).
        let thumbnailView = PDFThumbnailView()
        thumbnailView.pdfView = pdfView
        thumbnailView.thumbnailSize = NSSize(width: 100, height: 130)
        thumbnailView.translatesAutoresizingMaskIntoConstraints = false
        let thumbScroll = NSScrollView()
        thumbScroll.documentView = thumbnailView
        thumbScroll.hasVerticalScroller = true
        thumbScroll.translatesAutoresizingMaskIntoConstraints = false

        // 검색 필드(상).
        let search = NSSearchField()
        search.placeholderString = "이 문서에서 검색"
        search.translatesAutoresizingMaskIntoConstraints = false
        search.target = context.coordinator
        search.action = #selector(Coordinator.searchChanged(_:))
        context.coordinator.searchField = search

        // 우측: 검색 + PDFView 세로 스택.
        let rightStack = NSStackView(views: [search, pdfView])
        rightStack.orientation = .vertical
        rightStack.spacing = 0
        rightStack.edgeInsets = NSEdgeInsets(top: 6, left: 6, bottom: 0, right: 0)
        rightStack.translatesAutoresizingMaskIntoConstraints = false
        rightStack.setHuggingPriority(.defaultLow, for: .vertical)
        search.setContentHuggingPriority(.required, for: .vertical)

        // 분할: 썸네일 | 우측.
        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.translatesAutoresizingMaskIntoConstraints = false
        split.addArrangedSubview(thumbScroll)
        split.addArrangedSubview(rightStack)
        context.coordinator.split = split
        context.coordinator.thumbPane = thumbScroll

        container.addSubview(split)
        NSLayoutConstraint.activate([
            split.topAnchor.constraint(equalTo: container.topAnchor),
            split.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            split.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        // 썸네일 패널 초기 폭.
        DispatchQueue.main.async {
            split.setPosition(160, ofDividerAt: 0)
        }
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // 탭 재사용으로 url이 바뀌면 문서 재로딩 + 검색 초기화.
        guard context.coordinator.currentURL != url else { return }
        if let document = PDFDocument(url: url) {
            context.coordinator.pdfView?.document = document
            context.coordinator.currentURL = url
            context.coordinator.searchField?.stringValue = ""
            context.coordinator.matches = []
            context.coordinator.matchIndex = 0
            context.coordinator.pdfView?.highlightedSelections = nil
        }
    }

    private static func placeholderView() -> NSView {
        let label = NSTextField(labelWithString: "PDF를 열 수 없습니다")
        label.alignment = .center
        label.textColor = .secondaryLabelColor
        let host = NSView()
        label.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: host.centerYAnchor),
        ])
        return host
    }

    final class Coordinator: NSObject {
        weak var pdfView: PDFView?
        weak var searchField: NSSearchField?
        weak var split: NSSplitView?
        weak var thumbPane: NSView?
        var currentURL: URL?
        var matches: [PDFSelection] = []
        var matchIndex: Int = 0

        /// 검색어 변경 시: 일치 목록을 갱신하고 첫 일치로 이동.
        /// 같은 검색어로 Enter를 반복하면 다음 일치로 순회한다.
        @objc func searchChanged(_ sender: NSSearchField) {
            guard let pdfView, let document = pdfView.document else { return }
            let text = sender.stringValue
            guard !text.isEmpty else {
                matches = []
                matchIndex = 0
                pdfView.highlightedSelections = nil
                return
            }
            // 이미 같은 결과가 있으면 다음 일치로 순회(Enter 반복).
            if !matches.isEmpty, !matches.isEmpty {
                matchIndex = (matchIndex + 1) % matches.count
            } else {
                matches = document.findString(text, withOptions: [.caseInsensitive])
                matchIndex = 0
            }
            guard !matches.isEmpty else {
                pdfView.highlightedSelections = nil
                return
            }
            pdfView.highlightedSelections = matches
            let current = matches[matchIndex]
            pdfView.setCurrentSelection(current, animate: true)
            pdfView.scrollSelectionToVisible(nil)
        }
    }
}
```
**주의:** `findString`은 검색어가 바뀔 때마다 재실행해야 정확하다. 위 코드는 "결과가 비어있지 않으면 순회"하는데, 검색어가 변경된 경우에도 옛 결과를 순회하는 버그가 생긴다. 아래처럼 **마지막 검색어를 보관**해 검색어가 바뀌면 재검색하도록 `Coordinator`에 `lastQuery` 를 추가하고 `searchChanged`를 보정한다:

```swift
        var lastQuery: String = ""
```
그리고 `searchChanged` 본문의 분기를 다음으로 교체:
```swift
            if text == lastQuery, !matches.isEmpty {
                matchIndex = (matchIndex + 1) % matches.count
            } else {
                lastQuery = text
                matches = document.findString(text, withOptions: [.caseInsensitive])
                matchIndex = 0
            }
```

- [ ] **Step 2: 빌드 확인**

Run: `swift build`
Expected: `Build complete!` (에러 없음)

- [ ] **Step 3: 커밋**

```bash
git add Sources/Views/PDFReaderView.swift
git commit -m "$(cat <<'EOF'
PDF 리더(Phase 2): PDFReaderView(PDFView+썸네일+검색) 추가

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01S2QuZUALidkTNRswXFL6xM
EOF
)"
```

---

## Task 3: AppState — PDF 로드 분기 + 패널 + 목록

**Files:**
- Modify: `Sources/App/AppState.swift` (loadAndActivateDocument의 이미지 분기, openFile 패널, isListableInFileTree)
- Test: `Tests/CmdMDTests/AppPdfTabTests.swift`, `Tests/CmdMDTests/FileTreeListingTests.swift`

**Interfaces:**
- Consumes: `DocumentKind.pdf`(Task 1), 기존 `EditorTab(kind:)`, `placeTab`, `currentTabKind`, `currentTabFileURL`
- Produces: PDF URL을 열면 `kind:.pdf` 탭 생성, 패널·사이드바 목록에 pdf 포함

- [ ] **Step 1: 실패 테스트 작성/확장**

Create `Tests/CmdMDTests/AppPdfTabTests.swift`:
```swift
import XCTest
@testable import CmdMD

final class AppPdfTabTests: XCTestCase {
    func testCurrentTabKindReflectsActivePdfTab() {
        let appState = AppState()
        let tab = EditorTab(fileURL: URL(fileURLWithPath: "/tmp/paper.pdf"),
                            title: "paper", kind: .pdf)
        appState.tabs = [tab]
        appState.activeTabId = tab.id

        XCTAssertEqual(appState.currentTabKind, .pdf)
        XCTAssertEqual(appState.currentTabFileURL,
                       URL(fileURLWithPath: "/tmp/paper.pdf"))
    }

    func testWindowTitleUsesFilenameForPdfTab() {
        let appState = AppState()
        let tab = EditorTab(fileURL: URL(fileURLWithPath: "/tmp/report.pdf"),
                            title: "report", kind: .pdf)
        appState.tabs = [tab]
        appState.activeTabId = tab.id

        XCTAssertEqual(appState.windowTitle, "report")
    }
}
```
`Tests/CmdMDTests/FileTreeListingTests.swift` 의 클래스 안에 메서드 추가(기존 메서드 유지):
```swift
    func testPdfIsListed() {
        XCTAssertTrue(listable("paper.pdf"))
        XCTAssertTrue(listable("REPORT.PDF"))
    }
```
또한 같은 파일의 `testUnsupportedFilesAreNotListed` 에서 `"pdf"` 를 제거한다(이제 지원하므로). 그 메서드를 아래로 교체:
```swift
    func testUnsupportedFilesAreNotListed() {
        for ext in ["hwp", "docx", "xlsx", "zip"] {
            XCTAssertFalse(listable("doc.\(ext)"), "\(ext) should not be listed yet")
        }
    }
```

- [ ] **Step 2: 실패 확인**

Run: `swift test --filter AppPdfTabTests` (그리고 `swift test --filter FileTreeListingTests`)
Expected: AppPdfTabTests PASS는 아직(컴파일은 됨 — currentTabKind는 kind 기반이라 통과할 수도 있음). FileTreeListingTests의 `testPdfIsListed`는 FAIL(아직 pdf 미포함). 최소 하나 RED 확인.
주: AppPdfTabTests는 기존 kind 기반 프로퍼티 덕에 바로 통과할 수 있다. 그 경우 RED 기준은 `testPdfIsListed`(목록 필터)와 Step 4의 실제 열기 동작이다.

- [ ] **Step 3: 구현 — 로드 분기에 .pdf 포함**

`Sources/App/AppState.swift` 의 `loadAndActivateDocument` 내 이미지 분기를 찾아 아래로 교체(이미지 전용 → 이미지/PDF 공통):
```swift
        // 이미지·PDF: MarkdownDocument/워처/originalContents 없이 탭만.
        let kind = DocumentKind(from: url)
        if kind == .image || kind == .pdf {
            let tab = EditorTab(
                fileURL: url,
                title: url.deletingPathExtension().lastPathComponent,
                kind: kind
            )
            placeTab(tab, inNewTab: inNewTab)
            addToRecentFiles(url)
            saveSession()
            return
        }
```
(기존 코드가 `if DocumentKind(from: url) == .image { let tab = EditorTab(..., kind: .image) ... }` 형태이므로, 위처럼 `kind` 변수를 쓰고 조건을 `== .image || == .pdf`로, `EditorTab(..., kind: kind)`로 바꾼다.)

- [ ] **Step 4: 구현 — 패널 + 목록 필터**

같은 파일 `openFile()` 의 패널 줄을 교체(`.pdf` 추가):
```swift
        panel.allowedContentTypes = [.plainText, UTType(filenameExtension: "md")!,
                                     .png, .jpeg, .heic, .webP, .gif, .pdf]
```
`isListableInFileTree(_:)` 를 교체(pdf 포함):
```swift
    static func isListableInFileTree(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == "md" || ext == "markdown" || ext == "txt"
            || DocumentKind.imageExtensions.contains(ext)
            || DocumentKind.pdfExtensions.contains(ext)
    }
```

- [ ] **Step 5: 통과 + 회귀 확인**

Run: `swift test`
Expected: AppPdfTabTests + FileTreeListingTests(testPdfIsListed 포함) + 기존 전부 PASS

- [ ] **Step 6: 커밋**

```bash
git add Sources/App/AppState.swift Tests/CmdMDTests/AppPdfTabTests.swift Tests/CmdMDTests/FileTreeListingTests.swift
git commit -m "$(cat <<'EOF'
PDF 리더(Phase 2): AppState PDF 로드 분기·패널·사이드바 목록

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01S2QuZUALidkTNRswXFL6xM
EOF
)"
```

---

## Task 4: MainEditorView — .pdf 배선

**Files:**
- Modify: `Sources/Views/MainEditorView.swift` (`MainEditorView.body` 의 Group 분기)

**Interfaces:**
- Consumes: `AppState.currentTabKind`(`.pdf`), `currentTabFileURL`, `PDFReaderView(url:)`(Task 2)
- Produces: PDF 탭이면 `PDFReaderView` 표시

UI 배선. 산출물 = 빌드 통과 + 수동 확인.

- [ ] **Step 1: Group 분기에 .pdf 추가**

`MainEditorView.body` 의 `Group { ... }` 내부를 아래로 교체:
```swift
            Group {
                if appState.currentTabKind == .image, let url = appState.currentTabFileURL {
                    ImageReaderView(url: url)
                } else if appState.currentTabKind == .pdf, let url = appState.currentTabFileURL {
                    PDFReaderView(url: url)
                } else if let document = appState.currentDocument {
                    // 탭 전환 시 NSTextView / WKWebView를 재생성하지 않도록 패널을 유지 — 성능 최적화.
                    DocumentEditorView(document: document)
                } else {
                    WelcomeView()
                }
            }
```

- [ ] **Step 2: 빌드 + 전체 테스트**

Run: `swift build && swift test`
Expected: `Build complete!` + 모든 테스트 PASS

- [ ] **Step 3: 커밋**

```bash
git add Sources/Views/MainEditorView.swift
git commit -m "$(cat <<'EOF'
PDF 리더(Phase 2): MainEditorView에 .pdf → PDFReaderView 분기

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01S2QuZUALidkTNRswXFL6xM
EOF
)"
```

---

## Task 5: 수동 검증 (Phase 게이트 최종)

자동 테스트로 못 잡는 UI 동작을 실제 PDF로 확인. 코드 변경 없음.

- [ ] **Step 1: 앱 실행**

먼저 기존 인스턴스 종료 후 실행:
```bash
pkill -f ".build/arm64-apple-macosx/debug/CmdMD" 2>/dev/null; true
swift run CmdMD
```
(GUI 앱. macOS 메뉴바 이름이 CmdMD로 보이는 것은 정상 — 번들명은 Phase 10. 앱 안 표시명은 cmd-docu.)

- [ ] **Step 2: 체크리스트 확인**

PDF 파일(논문/보고서 등)을 ⌘O, Finder 드래그, 또는 폴더 사이드바 클릭으로 열어 확인:
- [ ] `.pdf` 열림, 페이지가 표시됨
- [ ] 좌측 **썸네일** 표시, 썸네일 클릭 시 해당 페이지로 이동
- [ ] 스크롤/키로 페이지 이동, 줌(핀치/⌘±) 동작
- [ ] 텍스트 **선택 후 복사**(⌘C) 동작
- [ ] **회전**(메뉴/제스처) 동작 — PDFView 기본
- [ ] 상단 **검색 필드**에 단어 입력 → 일치 하이라이트 + 해당 위치로 이동, Enter 반복 시 다음 일치로
- [ ] 탭으로 열리고 닫힘, 창 제목 = 파일명, 사이드바 목록에 .pdf 보임
- [ ] 손상/0바이트 .pdf → "PDF를 열 수 없습니다" 플레이스홀더(크래시 없음)
- [ ] 마크다운·이미지 열기 회귀 없음

- [ ] **Step 3: 결과 기록**

문제 없으면 Phase 2 완료. 발견된 이슈는 후속 Task로.

---

## Self-Review (계획 점검)

- **스펙 커버리지:** §3.1(DocumentKind .pdf)→Task1; §3.2(PDFReaderView: PDFView+썸네일+검색+플레이스홀더)→Task2; §3.3(AppState 분기·패널·목록)→Task3; §3.4(MainEditorView)→Task4; §6(테스트)→Task1·3 + Task5 수동. 누락 없음.
- **플레이스홀더 스캔:** "적절한 처리" 류 없음 — 모든 코드 단계에 실제 코드. Task2의 검색 버그(검색어 변경 시 옛 결과 순회)는 `lastQuery` 보정까지 명시.
- **타입 일관성:** `DocumentKind.pdf`/`pdfExtensions`/`PDFReaderView(url:)`/`currentTabKind`/`currentTabFileURL`/`isListableInFileTree`/`placeTab`/`EditorTab(kind:)`가 정의 Task와 소비 Task에서 동일.
- **범위:** 단일 구현 계획에 적합(PDF 리더 한 기능).
- **회귀 주의:** Task3에서 `FileTreeListingTests.testUnsupportedFilesAreNotListed`의 `"pdf"` 제거를 명시(안 하면 그 테스트가 실패).
