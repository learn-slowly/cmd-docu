# 이미지 리더 (Phase 1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 단독 이미지 파일(png/jpg/jpeg/heic/webp/gif)을 기존 탭 UX로 열어 줌·팬·맞춤·GIF 재생으로 본다.

**Architecture:** A안 — 탭 kind 분기. `DocumentKind`로 확장자를 종류로 매핑하고 `EditorTab.kind`로 탭 종류를 들고, 뷰 레벨에서 마크다운 경로(`DocumentEditorView`)와 이미지 경로(`ImageReaderView`)를 가른다. 이미지 뷰는 `NSScrollView`(매그니피케이션)+`NSImageView`(`animates`) 네이티브 래퍼로 줌·팬·맞춤·GIF를 공짜로 얻는다. 기존 마크다운 흐름은 무변경.

**Tech Stack:** Swift 5.9+ / SwiftUI / AppKit(NSScrollView·NSImageView·NSViewRepresentable) / XCTest. macOS 14+.

## Global Constraints

- macOS 14+, Swift 5.9+. 비샌드박스 유지.
- Phase 게이트: 각 Task의 테스트 + **기존 57개 XCTest 전부 통과**. `swift test`는 **정식 Xcode 활성 상태**에서만 됨(CLT는 build만). 툴체인 전환 후엔 한 번 `rm -rf .build`.
- 신규 로직은 별도 파일로 격리(업스트림 머지 용이). 기존 파일은 분기 추가 위주, 마크다운 동작 불변.
- 표시명/식별자 규칙 유지: 내부 타입명 `CmdMD`·URL 스킴 `cmdmd`·원작자 고지 건드리지 않음.
- 커밋 메시지는 한국어. **모든 커밋 끝에 아래 두 줄을 붙인다**:
  ```
  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01S2QuZUALidkTNRswXFL6xM
  ```
- 작업 브랜치: `cmd-docu`.

## File Structure

| 파일 | 책임 | 변경 |
| --- | --- | --- |
| `Sources/Models/DocumentKind.swift` | 확장자→문서종류 단일 판별원 | 신규 |
| `Tests/CmdMDTests/DocumentKindTests.swift` | `DocumentKind` 매핑 검증 | 신규 |
| `Sources/Models/Workspace.swift` | `EditorTab`에 `kind` + Codable 하위호환 | 수정 |
| `Tests/CmdMDTests/EditorTabKindTests.swift` | EditorTab kind 디코딩/라운드트립 | 신규 |
| `Sources/Views/ImageReaderView.swift` | 네이티브 이미지 뷰(줌·팬·맞춤·GIF) | 신규 |
| `Sources/App/AppState.swift` | 로드 분기·탭 배치 헬퍼·패널 UTType·kind/URL/제목 노출 | 수정 |
| `Tests/CmdMDTests/AppImageTabTests.swift` | currentTabKind·windowTitle(이미지) | 신규 |
| `Sources/Views/MainEditorView.swift` | kind별 본문·브레드크럼 분기 | 수정 |

---

## Task 1: DocumentKind 모델 + 매핑 테스트

**Files:**
- Create: `Sources/Models/DocumentKind.swift`
- Test: `Tests/CmdMDTests/DocumentKindTests.swift`

**Interfaces:**
- Consumes: 없음
- Produces:
  - `enum DocumentKind: String, Codable { case markdown, image }`
  - `static let DocumentKind.imageExtensions: Set<String>` (소문자 확장자들)
  - `init(from url: URL)` — 확장자 소문자가 `imageExtensions`에 있으면 `.image`, 아니면 `.markdown`

- [ ] **Step 1: 실패 테스트 작성**

Create `Tests/CmdMDTests/DocumentKindTests.swift`:
```swift
import XCTest
@testable import CmdMD

final class DocumentKindTests: XCTestCase {
    private func kind(_ name: String) -> DocumentKind {
        DocumentKind(from: URL(fileURLWithPath: "/tmp/\(name)"))
    }

    func testImageExtensionsMapToImage() {
        for ext in ["png", "jpg", "jpeg", "heic", "webp", "gif"] {
            XCTAssertEqual(kind("file.\(ext)"), .image, "\(ext) should be image")
        }
    }

    func testUppercaseAndMixedCaseMapToImage() {
        XCTAssertEqual(kind("PHOTO.PNG"), .image)
        XCTAssertEqual(kind("Pic.Jpg"), .image)
    }

    func testMarkdownAndTextMapToMarkdown() {
        for ext in ["md", "markdown", "txt"] {
            XCTAssertEqual(kind("note.\(ext)"), .markdown, "\(ext) should be markdown")
        }
    }

    func testUnknownAndNoExtensionFallBackToMarkdown() {
        XCTAssertEqual(kind("data.xyz"), .markdown)
        XCTAssertEqual(kind("README"), .markdown)
    }

    func testImageExtensionsSetMatchesMapping() {
        for ext in DocumentKind.imageExtensions {
            XCTAssertEqual(kind("a.\(ext)"), .image)
        }
    }
}
```

- [ ] **Step 2: 실패 확인**

Run: `swift test --filter DocumentKindTests`
Expected: FAIL — `cannot find 'DocumentKind' in scope` (컴파일 에러)

- [ ] **Step 3: 최소 구현**

Create `Sources/Models/DocumentKind.swift`:
```swift
import Foundation

/// 파일 확장자 → 문서 종류 단일 판별원. PDF·오피스는 이후 Phase에서 케이스만 추가한다.
enum DocumentKind: String, Codable {
    case markdown
    case image
}

extension DocumentKind {
    /// 보기를 네이티브 이미지 뷰로 가르는 확장자 집합(소문자).
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "webp", "gif"]

    /// 확장자(대소문자 무시)로 종류를 정한다. 알 수 없거나 확장자 없으면 마크다운(현행 기본 동작).
    init(from url: URL) {
        let ext = url.pathExtension.lowercased()
        self = DocumentKind.imageExtensions.contains(ext) ? .image : .markdown
    }
}
```

- [ ] **Step 4: 통과 확인**

Run: `swift test --filter DocumentKindTests`
Expected: PASS (5 tests)

- [ ] **Step 5: 커밋**

```bash
git add Sources/Models/DocumentKind.swift Tests/CmdMDTests/DocumentKindTests.swift
git commit -m "$(cat <<'EOF'
이미지 리더(Phase 1): DocumentKind 확장자 매핑 추가

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01S2QuZUALidkTNRswXFL6xM
EOF
)"
```

---

## Task 2: EditorTab.kind + Codable 하위호환

**Files:**
- Modify: `Sources/Models/Workspace.swift:40-76` (`struct EditorTab`)
- Test: `Tests/CmdMDTests/EditorTabKindTests.swift`

**Interfaces:**
- Consumes: `DocumentKind` (Task 1)
- Produces:
  - `EditorTab.kind: DocumentKind` (기본 `.markdown`)
  - 멤버와이즈 `init(... , kind: DocumentKind = .markdown)`
  - 커스텀 `init(from decoder:)` — `kind` 키 없으면 `.markdown`. `encode(to:)`는 합성 유지(키 항상 기록).

- [ ] **Step 1: 실패 테스트 작성**

Create `Tests/CmdMDTests/EditorTabKindTests.swift`:
```swift
import XCTest
@testable import CmdMD

final class EditorTabKindTests: XCTestCase {
    func testDefaultKindIsMarkdown() {
        let tab = EditorTab()
        XCTAssertEqual(tab.kind, .markdown)
    }

    func testRoundTripPreservesImageKind() throws {
        let tab = EditorTab(fileURL: URL(fileURLWithPath: "/tmp/a.png"),
                            title: "a", kind: .image)
        let data = try JSONEncoder().encode(tab)
        let decoded = try JSONDecoder().decode(EditorTab.self, from: data)
        XCTAssertEqual(decoded.kind, .image)
    }

    func testLegacyJSONWithoutKindDecodesAsMarkdown() throws {
        // kind 키가 없는 구버전 세션 JSON
        let json = """
        {
          "id": "00000000-0000-0000-0000-000000000001",
          "documentId": "00000000-0000-0000-0000-000000000002",
          "title": "legacy",
          "isPinned": false,
          "isDirty": false,
          "scrollPosition": 0,
          "cursorPosition": 0
        }
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(EditorTab.self, from: json)
        XCTAssertEqual(decoded.kind, .markdown)
        XCTAssertEqual(decoded.title, "legacy")
    }
}
```

- [ ] **Step 2: 실패 확인**

Run: `swift test --filter EditorTabKindTests`
Expected: FAIL — `value of type 'EditorTab' has no member 'kind'`

- [ ] **Step 3: 최소 구현**

In `Sources/Models/Workspace.swift`, `struct EditorTab` 에 `kind` 프로퍼티 추가 — `cursorPosition` 선언 바로 아래:
```swift
    var cursorPosition: Int
    var kind: DocumentKind
```

멤버와이즈 `init` 에 `kind` 파라미터 추가(기본값). 기존 `init(...)` 의 파라미터 목록 끝(`cursorPosition: Int = 0` 뒤)과 본문 끝(`self.cursorPosition = cursorPosition` 뒤)에:
```swift
        cursorPosition: Int = 0,
        kind: DocumentKind = .markdown
    ) {
        // ... 기존 할당들 ...
        self.cursorPosition = cursorPosition
        self.kind = kind
    }
```

`struct EditorTab` 의 닫는 `}` 직전(`displayTitle` 다음)에 커스텀 디코더 추가:
```swift
    // 구버전 세션 JSON엔 `kind` 키가 없으므로 기본 .markdown 으로 디코딩.
    // (커스텀 init(from:)만 제공하면 encode(to:)는 합성된다.)
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        documentId = try c.decode(UUID.self, forKey: .documentId)
        fileURL = try c.decodeIfPresent(URL.self, forKey: .fileURL)
        title = try c.decode(String.self, forKey: .title)
        isPinned = try c.decode(Bool.self, forKey: .isPinned)
        isDirty = try c.decode(Bool.self, forKey: .isDirty)
        scrollPosition = try c.decode(CGFloat.self, forKey: .scrollPosition)
        cursorPosition = try c.decode(Int.self, forKey: .cursorPosition)
        kind = try c.decodeIfPresent(DocumentKind.self, forKey: .kind) ?? .markdown
    }
```

- [ ] **Step 4: 통과 확인**

Run: `swift test --filter EditorTabKindTests`
Expected: PASS (3 tests)

- [ ] **Step 5: 회귀 확인 + 커밋**

Run: `swift test`
Expected: 기존 57개 + 신규 모두 PASS

```bash
git add Sources/Models/Workspace.swift Tests/CmdMDTests/EditorTabKindTests.swift
git commit -m "$(cat <<'EOF'
이미지 리더(Phase 1): EditorTab.kind 추가(세션 하위호환)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01S2QuZUALidkTNRswXFL6xM
EOF
)"
```

---

## Task 3: ImageReaderView (네이티브 줌·팬·맞춤·GIF)

**Files:**
- Create: `Sources/Views/ImageReaderView.swift`

**Interfaces:**
- Consumes: 없음(독립 뷰)
- Produces: `struct ImageReaderView: NSViewRepresentable { let url: URL }` — Task 5에서 `ImageReaderView(url:)` 로 사용

UI 컴포넌트라 자동 테스트 없음. 산출물 = 컴파일 통과. 동작은 Task 5 배선 후 수동 확인.

- [ ] **Step 1: 뷰 구현**

Create `Sources/Views/ImageReaderView.swift`:
```swift
import SwiftUI
import AppKit

/// 단독 이미지 보기. NSScrollView 매그니피케이션으로 줌/팬/맞춤,
/// NSImageView(animates)로 GIF 재생. 로드 실패 시 플레이스홀더(크래시 금지).
struct ImageReaderView: NSViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.1
        scrollView.maxMagnification = 16
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.borderType = .noBorder
        scrollView.backgroundColor = .textBackgroundColor

        let imageView = NSImageView()
        imageView.imageScaling = .scaleNone
        imageView.animates = true
        scrollView.documentView = imageView

        context.coordinator.scrollView = scrollView
        context.coordinator.imageView = imageView

        let dbl = NSClickGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleDoubleClick(_:))
        )
        dbl.numberOfClicksRequired = 2
        scrollView.contentView.addGestureRecognizer(dbl)

        context.coordinator.load(url: url)
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        if context.coordinator.currentURL != url {
            context.coordinator.load(url: url)
        }
    }

    final class Coordinator: NSObject {
        weak var scrollView: NSScrollView?
        weak var imageView: NSImageView?
        var currentURL: URL?
        private var fitMagnification: CGFloat = 1

        func load(url: URL) {
            currentURL = url
            guard let imageView else { return }
            guard let image = NSImage(contentsOf: url) else {
                showPlaceholder()
                return
            }
            imageView.imageScaling = .scaleNone
            imageView.image = image
            imageView.frame = NSRect(origin: .zero, size: image.size)
            // 레이아웃이 잡힌 뒤 맞춤 배율 계산.
            DispatchQueue.main.async { [weak self] in self?.fitToWindow() }
        }

        func fitToWindow() {
            guard let scrollView, let image = imageView?.image else { return }
            let viewSize = scrollView.contentView.bounds.size
            let imgSize = image.size
            guard imgSize.width > 0, imgSize.height > 0,
                  viewSize.width > 0, viewSize.height > 0 else { return }
            // 축소만(작은 이미지는 100% 유지).
            let scale = min(viewSize.width / imgSize.width,
                            viewSize.height / imgSize.height, 1.0)
            fitMagnification = scale
            scrollView.magnification = scale
        }

        @objc func handleDoubleClick(_ g: NSClickGestureRecognizer) {
            guard let scrollView else { return }
            let point = g.location(in: scrollView.documentView)
            if abs(scrollView.magnification - 1.0) < 0.001 {
                scrollView.setMagnification(fitMagnification, centeredAt: point)
            } else {
                scrollView.setMagnification(1.0, centeredAt: point)
            }
        }

        private func showPlaceholder() {
            guard let imageView else { return }
            imageView.imageScaling = .scaleProportionallyDown
            imageView.image = NSImage(systemSymbolName: "exclamationmark.triangle",
                                      accessibilityDescription: "이미지를 열 수 없음")
            imageView.frame = NSRect(x: 0, y: 0, width: 240, height: 240)
        }
    }
}
```

- [ ] **Step 2: 빌드 확인**

Run: `swift build`
Expected: `Build complete!` (에러 없음)

- [ ] **Step 3: 커밋**

```bash
git add Sources/Views/ImageReaderView.swift
git commit -m "$(cat <<'EOF'
이미지 리더(Phase 1): ImageReaderView 네이티브 뷰 추가

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01S2QuZUALidkTNRswXFL6xM
EOF
)"
```

---

## Task 4: AppState 로드 분기 + 노출 프로퍼티 + 패널 UTType

**Files:**
- Modify: `Sources/App/AppState.swift` — `windowTitle`(126-132), `openFile`(272-283), `loadAndActivateDocument`(360-400), 신규 계산 프로퍼티
- Test: `Tests/CmdMDTests/AppImageTabTests.swift`

**Interfaces:**
- Consumes: `DocumentKind`(Task 1), `EditorTab.kind`(Task 2)
- Produces:
  - `AppState.currentTabKind: DocumentKind`
  - `AppState.currentTabFileURL: URL?`
  - `placeTab(_:inNewTab:)` private 헬퍼
  - `loadAndActivateDocument` 가 `.image` 면 MarkdownDocument 없이 이미지 탭 생성
  - `windowTitle` 가 이미지 탭(문서 없음)에선 활성 탭 파일명을 반환

- [ ] **Step 1: 실패 테스트 작성**

Create `Tests/CmdMDTests/AppImageTabTests.swift`:
```swift
import XCTest
@testable import CmdMD

final class AppImageTabTests: XCTestCase {
    func testCurrentTabKindReflectsActiveImageTab() {
        let appState = AppState()
        let tab = EditorTab(fileURL: URL(fileURLWithPath: "/tmp/pic.png"),
                            title: "pic", kind: .image)
        appState.tabs = [tab]
        appState.activeTabId = tab.id

        XCTAssertEqual(appState.currentTabKind, .image)
        XCTAssertEqual(appState.currentTabFileURL,
                       URL(fileURLWithPath: "/tmp/pic.png"))
    }

    func testWindowTitleUsesFilenameForImageTab() {
        let appState = AppState()
        let tab = EditorTab(fileURL: URL(fileURLWithPath: "/tmp/sunset.jpg"),
                            title: "sunset", kind: .image)
        appState.tabs = [tab]
        appState.activeTabId = tab.id

        // 이미지 탭은 currentDocument 가 없으므로 파일명으로 제목.
        XCTAssertEqual(appState.windowTitle, "sunset")
    }

    func testCurrentTabKindDefaultsToMarkdownWhenNoTab() {
        let appState = AppState()
        XCTAssertEqual(appState.currentTabKind, .markdown)
    }
}
```

- [ ] **Step 2: 실패 확인**

Run: `swift test --filter AppImageTabTests`
Expected: FAIL — `has no member 'currentTabKind'` / `currentTabFileURL`

- [ ] **Step 3: 계산 프로퍼티 추가**

`Sources/App/AppState.swift` 의 `windowTitle` 계산 프로퍼티 바로 아래에 추가:
```swift
    /// 활성 탭의 종류(없으면 마크다운).
    var currentTabKind: DocumentKind {
        tabs.first(where: { $0.id == activeTabId })?.kind ?? .markdown
    }

    /// 활성 탭의 파일 URL(이미지 뷰 배선용).
    var currentTabFileURL: URL? {
        tabs.first(where: { $0.id == activeTabId })?.fileURL
    }
```

- [ ] **Step 4: windowTitle 보강**

`windowTitle` 을 아래로 교체(문서 없을 때 활성 탭 파일명 폴백 추가):
```swift
    var windowTitle: String {
        if let title = currentDocument?.displayTitle.trimmingCharacters(in: .whitespacesAndNewlines),
           !title.isEmpty {
            return title
        }
        if let url = currentTabFileURL {
            return url.deletingPathExtension().lastPathComponent
        }
        return "cmd-docu"
    }
```

- [ ] **Step 5: 탭 배치 헬퍼 + 로드 분기**

`loadAndActivateDocument(at:inNewTab:)` 전체를 아래로 교체(마크다운 경로는 동작 동일, 배치 로직을 `placeTab` 으로 추출):
```swift
    /// 새 탭을 추가하거나 활성 탭을 교체(교체 시 옛 탭 자원 정리).
    private func placeTab(_ tab: EditorTab, inNewTab: Bool) {
        if inNewTab || tabs.isEmpty {
            tabs.append(tab)
        } else if let activeIndex = tabs.firstIndex(where: { $0.id == activeTabId }) {
            let oldTab = tabs[activeIndex]
            stopWatchingFile(for: oldTab.id)
            documents.removeValue(forKey: oldTab.documentId)
            originalContents.removeValue(forKey: oldTab.documentId)
            tabs[activeIndex] = tab
        } else {
            tabs.append(tab)
        }
        activeTabId = tab.id
    }

    @MainActor
    private func loadAndActivateDocument(at url: URL, inNewTab: Bool) async {
        if let existingTab = tabs.first(where: { $0.fileURL == url }) {
            activeTabId = existingTab.id
            return
        }

        // 이미지: MarkdownDocument/워처/originalContents 없이 탭만.
        if DocumentKind(from: url) == .image {
            let tab = EditorTab(
                fileURL: url,
                title: url.deletingPathExtension().lastPathComponent,
                kind: .image
            )
            placeTab(tab, inNewTab: inNewTab)
            addToRecentFiles(url)
            saveSession()
            return
        }

        do {
            let document = try await fileService.loadDocument(from: url)
            let tab = EditorTab(
                documentId: document.id,
                fileURL: url,
                title: document.displayTitle
            )
            documents[document.id] = document
            originalContents[document.id] = document.fullText
            placeTab(tab, inNewTab: inNewTab)
            addToRecentFiles(url)
            startWatchingFile(at: url, for: tab.id)
            harvestTags(from: document)
            saveSession()
        } catch {
            errorMessage = "Failed to open file: \(error.localizedDescription)"
        }
    }
```

- [ ] **Step 6: 열기 패널에 이미지 허용**

`openFile()` 의 `panel.allowedContentTypes` 줄을 교체:
```swift
        panel.allowedContentTypes = [.plainText, UTType(filenameExtension: "md")!,
                                     .png, .jpeg, .heic, .webP, .gif]
```
(`AppState.swift` 는 이미 `UniformTypeIdentifiers` 의 `UTType` 을 사용 중이라 import 불필요. 확인만.)

- [ ] **Step 7: 통과 + 회귀 확인**

Run: `swift test`
Expected: AppImageTabTests 3개 + 기존 57개 모두 PASS (총 60 + 기타 신규)

- [ ] **Step 8: 커밋**

```bash
git add Sources/App/AppState.swift Tests/CmdMDTests/AppImageTabTests.swift
git commit -m "$(cat <<'EOF'
이미지 리더(Phase 1): AppState 이미지 탭 로드 분기·노출 프로퍼티·패널 UTType

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01S2QuZUALidkTNRswXFL6xM
EOF
)"
```

---

## Task 5: MainEditorView 배선 (kind별 본문·브레드크럼)

**Files:**
- Modify: `Sources/Views/MainEditorView.swift:6-33` (`MainEditorView.body`)

**Interfaces:**
- Consumes: `AppState.currentTabKind`·`currentTabFileURL`(Task 4), `ImageReaderView`(Task 3)
- Produces: 이미지 탭이면 `ImageReaderView`, 아니면 기존 마크다운/환영 경로

UI 배선. 산출물 = 빌드 통과 + 수동 확인. (상태바는 기존 `currentDocument != nil` 조건이라 이미지 탭에서 자동으로 숨겨짐 — 변경 불필요.)

- [ ] **Step 1: body 교체**

`MainEditorView` 의 `body` 를 아래로 교체:
```swift
    var body: some View {
        VStack(spacing: 0) {
            if appState.settings.showTabBar && !appState.tabs.isEmpty {
                TabBarView()
            }

            if let fileURL = appState.currentTabFileURL {
                SimpleBreadcrumbView(fileURL: fileURL, folderURL: appState.currentFolder)
            }

            Group {
                if appState.currentTabKind == .image, let url = appState.currentTabFileURL {
                    ImageReaderView(url: url)
                } else if let document = appState.currentDocument {
                    DocumentEditorView(document: document)
                } else {
                    WelcomeView()
                }
            }

            if appState.settings.showStatusBar, appState.currentDocument != nil {
                StatusBarView()
            }
        }
    }
```
(브레드크럼 조건을 `currentDocument?.fileURL` → `currentTabFileURL` 로 바꿔 이미지 탭에서도 경로가 보이게 한다. 마크다운 탭은 동일 fileURL 이라 동작 불변.)

- [ ] **Step 2: 빌드 + 전체 테스트**

Run: `swift build && swift test`
Expected: `Build complete!` + 모든 테스트 PASS

- [ ] **Step 3: 커밋**

```bash
git add Sources/Views/MainEditorView.swift
git commit -m "$(cat <<'EOF'
이미지 리더(Phase 1): MainEditorView에 kind별 본문 분기 배선

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01S2QuZUALidkTNRswXFL6xM
EOF
)"
```

---

## Task 6: 수동 검증 (Phase 게이트 최종)

자동 테스트로 못 잡는 UI 동작을 실제 파일로 확인. 코드 변경 없음.

- [ ] **Step 1: 앱 실행**

Run: `swift run CmdMD`
(또는 빌드 후 실행. GUI 앱이라 사용자 확인 필요.)

- [ ] **Step 2: 체크리스트 확인**

각 포맷 파일을 ⌘O 또는 드롭으로 열어 확인:
- [ ] `.png` 열림, 화면 맞춤으로 표시
- [ ] `.jpg`/`.jpeg` 열림
- [ ] `.heic` 열림
- [ ] `.webp` 열림
- [ ] `.gif` **애니메이션 재생**
- [ ] 스크롤휠/핀치로 줌, 드래그로 팬
- [ ] 더블클릭으로 맞춤↔100% 토글
- [ ] 탭으로 열리고 닫힘(기존 UX 일관), 창 제목 = 파일명
- [ ] 손상/0바이트 이미지 → 플레이스홀더(크래시 없음)
- [ ] 마크다운 파일 열기·편집·프리뷰 동작 불변(회귀 없음)

- [ ] **Step 3: 결과 기록**

문제 없으면 Phase 1 완료. 발견된 이슈는 후속 Task로.

---

## Self-Review (계획 점검)

- **스펙 커버리지:** §3.1→Task1, §3.3(EditorTab)→Task2, §3.2(ImageReaderView)→Task3, §3.4(AppState)→Task4, §3.5(MainEditorView)→Task5, §6(테스트)→각 Task+Task6. 누락 없음.
- **플레이스홀더 스캔:** "적절한 에러처리" 류 없음 — 모든 코드 단계에 실제 코드 제시.
- **타입 일관성:** `DocumentKind`·`imageExtensions`·`init(from:)`·`EditorTab.kind`·`currentTabKind`·`currentTabFileURL`·`placeTab`·`ImageReaderView(url:)` 가 정의 Task와 소비 Task에서 동일 시그니처.
- **범위:** 단일 구현 계획에 적합(이미지 리더 한 기능).
