# UI 다듬기 3건 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 탭 일괄 닫기(Close All Tabs)·탭 파일명 말줄임·즐겨찾기 폴더 열기(버그 수정)를 구현한다.

**Architecture:** 전부 기존 경로 재사용 위에 최소 가산 — 일괄 닫기는 기존 `closeTab` 반복+요약 NSAlert 1회, 말줄임은 Text 모디파이어 2개, 즐겨찾기 폴더는 기존 `openFolder()` 성공 분기를 URL 인자 버전으로 추출해 클릭 분기.

**Tech Stack:** Swift/SwiftUI, AppKit(NSAlert), XCTest(AppState는 `dataDirectory:` 임시 디렉터리 주입 관례).

**Spec:** `docs/superpowers/specs/2026-07-03-ui-polish-tabs-favorites-design.md`

## Global Constraints

- 일괄 닫기 대상 = **핀 고정 제외**(기존 closeOtherTabs/closeTabsToRight의 `!$0.isPinned` 관례). 더티+`confirmBeforeClosingDirtyTabs` ON이면 요약 확인 1회(모두 저장 후 닫기/저장 안 하고 닫기/취소), OFF거나 더티 없으면 확인 없이. 저장 실패·URL 없는 더티 탭은 닫지 않고 남김.
- 말줄임: `maxWidth: 180` + `.truncationMode(.middle)` — 다른 탭 요소 불변.
- 즐겨찾기: 폴더 클릭 = **작업 폴더 전환**(openFolder(at:)), 파일 클릭 = 기존 openDocument 불변. `FavoriteItem` 모델(Codable) 불변.
- 코드 주석·커밋 메시지는 한국어. '박다/박는다/박았다' 류 표현 금지. 파일 삭제 없음. 커밋은 태스크마다.
- Phase 게이트: 현 스위트 396개(XCTest 378+Testing 18) 유지. `swift test`는 정식 Xcode 필요.

---

### Task 1: closeAllTabs + 메뉴 배선

**Files:**
- Modify: `Sources/App/AppState.swift` (`closeTabsToRight` 아래에 메서드 2개 추가 — 약 :1680)
- Modify: `Sources/Views/TabBarView.swift` (`TabContextMenu`의 "Close Tabs to the Right" 버튼 아래)
- Modify: `Sources/App/CmdMDApp.swift` (File 메뉴 "Close Tab"(⌘W) 블록 아래 — 약 :184)
- Test: `Tests/CmdMDTests/AppCloseAllTabsTests.swift` (신규)

**Interfaces:**
- Consumes: `closeTab(_:)`, `isTabDirty(_:)`, `settings.confirmBeforeClosingDirtyTabs`, `documents`/`originalContents` 딕셔너리, `fileService.saveDocument(_:to:)`, `tabs`/`activeTabId`.
- Produces: `AppState.closeAllTabs()`(공개, 메뉴가 호출), `saveDocument(forTabId: UUID) async -> Bool`(private).

- [ ] **Step 1: 실패하는 테스트 작성**

`Tests/CmdMDTests/AppCloseAllTabsTests.swift` 신규. 기존 App* 테스트의 임시 디렉터리 주입 관례를 따른다(`Tests/CmdMDTests/`의 `TempDataDirectory` 헬퍼 — 다른 App* 테스트 파일에서 사용법 확인, 예: AppLibraryStateTests). **알림(NSAlert) 경로는 러너에서 모달이 뜨므로 테스트하지 않는다** — 더티 없음/설정 OFF 경로만 자동화(스펙 §4).

```swift
import XCTest
@testable import CmdMD

@MainActor
final class AppCloseAllTabsTests: XCTestCase {
    private var temp: TempDataDirectory!
    private var appState: AppState!

    override func setUp() {
        super.setUp()
        temp = TempDataDirectory()
        appState = AppState(dataDirectory: temp.url)
    }

    override func tearDown() {
        temp = nil
        appState = nil
        super.tearDown()
    }

    func testCloseAllTabs_closesEverythingWhenNothingPinned() {
        appState.createNewTab()
        appState.createNewTab()
        appState.createNewTab()
        XCTAssertEqual(appState.tabs.count, 3)

        appState.closeAllTabs()

        XCTAssertTrue(appState.tabs.isEmpty)
        XCTAssertNil(appState.activeTabId)
    }

    func testCloseAllTabs_keepsPinnedTabs() {
        appState.createNewTab()
        appState.createNewTab()
        appState.createNewTab()
        let pinned = appState.tabs[1]
        appState.toggleTabPin(pinned)

        appState.closeAllTabs()

        XCTAssertEqual(appState.tabs.map(\.id), [pinned.id])
        XCTAssertEqual(appState.activeTabId, pinned.id)
    }

    func testCloseAllTabs_dirtyTabClosesWithoutAlertWhenConfirmOff() {
        appState.settings.confirmBeforeClosingDirtyTabs = false
        appState.createNewTab()
        // 활성 문서를 편집해 더티로 만든다(fullText 기준선과 어긋나게).
        if var doc = appState.currentDocument {
            doc.content += "\n편집됨"
            appState.currentDocument = doc
        }
        XCTAssertTrue(appState.tabs.contains(where: { appState.isTabDirty($0) }))

        appState.closeAllTabs()

        XCTAssertTrue(appState.tabs.isEmpty)
    }

    func testCloseAllTabs_noTabsIsNoOp() {
        XCTAssertTrue(appState.tabs.isEmpty)
        appState.closeAllTabs()   // 크래시·알림 없이 조용히 반환
        XCTAssertTrue(appState.tabs.isEmpty)
    }
}
```

주의: `currentDocument`의 편집 가능 프로퍼티명(`content` 등)은 `Sources/Models/Document.swift`를 열어 실제 이름으로 맞춘다(fullText를 바꾸는 본문 프로퍼티). `createNewTab`이 untitled 마크다운 탭+documents 항목을 만드는지 실제 코드로 확인하고, 아니면 임시 md 파일을 만들어 `loadAndActivateDocument`로 여는 방식으로 조정한다(테스트 의도는 유지).

- [ ] **Step 2: 실패 확인**

Run: `swift test --filter AppCloseAllTabsTests 2>&1 | tail -5`
Expected: 컴파일 실패 — `value of type 'AppState' has no member 'closeAllTabs'`.

- [ ] **Step 3: AppState 구현**

`Sources/App/AppState.swift`의 `closeTabsToRight(of:)` 아래에 추가:

```swift
    /// 핀 고정을 제외한 모든 탭을 닫는다. 더티 탭이 있고 확인 설정이 켜져 있으면
    /// 요약 알림 1회(모두 저장/저장 안 함/취소 — 개별 확인 연타 대신). 저장에
    /// 실패했거나 저장할 곳이 없는(URL 없는) 더티 탭은 닫지 않고 남긴다.
    func closeAllTabs() {
        let targets = tabs.filter { !$0.isPinned }
        guard !targets.isEmpty else { return }
        let dirtyTargets = targets.filter { isTabDirty($0) }

        guard !dirtyTargets.isEmpty, settings.confirmBeforeClosingDirtyTabs else {
            targets.forEach { closeTab($0) }
            return
        }

        let alert = NSAlert()
        alert.messageText = "저장 안 된 변경이 있는 탭이 \(dirtyTargets.count)개 있습니다."
        alert.informativeText = "저장하지 않고 닫으면 변경 내용이 사라집니다."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "모두 저장 후 닫기")
        alert.addButton(withTitle: "저장 안 하고 닫기")
        alert.addButton(withTitle: "취소")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            Task { @MainActor in
                var keptTabIds = Set<UUID>()
                for tab in dirtyTargets {
                    let saved = await saveDocument(forTabId: tab.id)
                    if !saved { keptTabIds.insert(tab.id) }
                }
                for tab in targets where !keptTabIds.contains(tab.id) {
                    closeTab(tab)
                }
                if !keptTabIds.isEmpty {
                    showToast("저장하지 못한 탭 \(keptTabIds.count)개는 남겨뒀습니다")
                }
            }
        case .alertSecondButtonReturn:
            targets.forEach { closeTab($0) }
        default:
            break
        }
    }

    /// 특정 탭의 문서를 디스크에 저장한다(파일 URL 있는 문서만 — 없으면 false).
    /// 성공 시 그 탭의 더티 기준선(originalContents)을 갱신한다.
    @MainActor
    private func saveDocument(forTabId tabId: UUID) async -> Bool {
        guard let tab = tabs.first(where: { $0.id == tabId }),
              var document = documents[tab.documentId],
              let url = document.fileURL else { return false }
        do {
            try await fileService.saveDocument(document, to: url)
            originalContents[tab.documentId] = document.fullText
            document.modifiedAt = Date()
            documents[tab.documentId] = document
            return true
        } catch {
            return false
        }
    }
```

주의: `documents`/`originalContents`/`fileService`의 실제 접근 수준·타입은 파일 상단 선언과 `closeTab`·`saveCurrentDocument`(:1404) 구현을 열어 확인하고 맞춘다(의도: `saveCurrentDocument`의 저장 경로를 활성 탭이 아닌 지정 탭에 적용).

- [ ] **Step 4: 테스트 통과 확인**

Run: `swift test --filter AppCloseAllTabsTests 2>&1 | tail -5`
Expected: 4개 테스트 PASS.

- [ ] **Step 5: 메뉴 배선**

(a) `Sources/Views/TabBarView.swift`의 `TabContextMenu` — "Close Tabs to the Right" 버튼 블록 바로 아래에 추가:

```swift
        Button {
            appState.closeAllTabs()
        } label: {
            Label("Close All Tabs", systemImage: "xmark.circle")
        }
```

(b) `Sources/App/CmdMDApp.swift` — File 메뉴의 "Close Tab" 버튼 블록(`.keyboardShortcut("w", modifiers: .command)` + `.disabled(appState.tabs.isEmpty)`) 바로 아래에 추가:

```swift
                Button("Close All Tabs") {
                    appState.closeAllTabs()
                }
                .keyboardShortcut("w", modifiers: [.command, .option])
                .disabled(appState.tabs.isEmpty)
```

- [ ] **Step 6: 전체 게이트 + 커밋**

Run: `swift build 2>&1 | tail -3 && swift test 2>&1 | grep -E "Executed [0-9]+ tests" | tail -1`
Expected: 경고 0, `Executed 382 tests`(378+4; Swift Testing 18 별도).

```bash
git add Sources/App/AppState.swift Sources/Views/TabBarView.swift Sources/App/CmdMDApp.swift Tests/CmdMDTests/AppCloseAllTabsTests.swift
git commit -m "기능(탭): Close All Tabs — 핀 제외 일괄 닫기, 더티 요약 확인 1회(모두 저장/저장 안 함/취소), 저장 실패·URL 없는 탭은 남김. 진입점: 탭 우클릭·File 메뉴 ⌥⌘W"
```

---

### Task 2: 탭 파일명 말줄임

**Files:**
- Modify: `Sources/Views/TabBarView.swift` (`TabItemView`의 `Text(tab.displayTitle)` — 약 :60)

**Interfaces:** 없음 (표시 전용).

- [ ] **Step 1: 모디파이어 추가**

현행:

```swift
            Text(tab.displayTitle)
                .font(.system(size: 12))
                .lineLimit(1)
                .foregroundColor(isActive ? .primary : .secondary)
```

변경(긴 파일명만 180pt에서 가운데 말줄임 — 앞부분·확장자 보존, 짧은 이름은 현행 폭 그대로):

```swift
            Text(tab.displayTitle)
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 180)
                .foregroundColor(isActive ? .primary : .secondary)
```

- [ ] **Step 2: 빌드·전체 테스트** (표시 전용 — 검증은 수동 스모크 몫)

Run: `swift build 2>&1 | tail -3 && swift test 2>&1 | grep -E "Executed [0-9]+ tests" | tail -1`
Expected: 경고 0, `Executed 382 tests` 통과.

- [ ] **Step 3: 커밋**

```bash
git add Sources/Views/TabBarView.swift
git commit -m "개선(탭): 긴 파일명 가운데 말줄임 — 최대 180pt, 앞부분·확장자 보존(탭이 무한정 넓어지던 문제 해소)"
```

---

### Task 3: 즐겨찾기 폴더 열기 (버그 수정)

**Files:**
- Modify: `Sources/App/AppState.swift` (`openFolder()` — :748-764 리팩터·URL 인자 버전 추출)
- Modify: `Sources/Views/SidebarView.swift` (`FavoritesListView` 탭 핸들러 :573-577, `FavoriteRow` :606-627)
- Test: `Tests/CmdMDTests/AppOpenFolderAtTests.swift` (신규)

**Interfaces:**
- Consumes: `currentFolder`/`selectedFolder`/`selectedSidebarTab`/`sidebarVisible`, `loadFileTree()`, `rebuildNoteIndex()`, `saveSession()`, `openDocument(at:inNewTab:)`.
- Produces: `AppState.openFolder(at url: URL)`(공개 — 즐겨찾기 클릭이 호출).

- [ ] **Step 1: 실패하는 테스트 작성**

`Tests/CmdMDTests/AppOpenFolderAtTests.swift` 신규:

```swift
import XCTest
@testable import CmdMD

@MainActor
final class AppOpenFolderAtTests: XCTestCase {
    func testOpenFolderAt_switchesWorkspaceState() throws {
        let temp = TempDataDirectory()
        let appState = AppState(dataDirectory: temp.url)

        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("openFolderAt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        appState.openFolder(at: folder)

        XCTAssertEqual(appState.currentFolder, folder)
        XCTAssertEqual(appState.selectedFolder, folder)
        XCTAssertEqual(appState.selectedSidebarTab, .files)
        XCTAssertTrue(appState.sidebarVisible)
    }
}
```

- [ ] **Step 2: 실패 확인**

Run: `swift test --filter AppOpenFolderAtTests 2>&1 | tail -5`
Expected: 컴파일 실패 — `no member 'openFolder(at:)'` (기존 `openFolder()`는 인자 없음).

- [ ] **Step 3: openFolder(at:) 추출**

`Sources/App/AppState.swift:748-764`의 현행:

```swift
    func openFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK, let url = panel.url {
            currentFolder = url
            // currentFolder가 실제로 바뀌는 지점에서만 selectedFolder를 리셋한다.
            selectedFolder = url
            selectedSidebarTab = .files
            sidebarVisible = true
            loadFileTree()
            rebuildNoteIndex()
            saveSession()
        }
    }
```

을 다음으로 교체(성공 분기 본문 추출 — 동작 불변):

```swift
    func openFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        if panel.runModal() == .OK, let url = panel.url {
            openFolder(at: url)
        }
    }

    /// 작업 폴더를 지정 URL로 전환한다 — File > Open Folder의 성공 분기와 동일.
    /// 즐겨찾기 폴더 열기 등 패널 없는 진입로가 재사용한다.
    func openFolder(at url: URL) {
        currentFolder = url
        // currentFolder가 실제로 바뀌는 지점에서만 selectedFolder를 리셋한다.
        selectedFolder = url
        selectedSidebarTab = .files
        sidebarVisible = true
        loadFileTree()
        rebuildNoteIndex()
        saveSession()
    }
```

- [ ] **Step 4: 테스트 통과 확인**

Run: `swift test --filter AppOpenFolderAtTests 2>&1 | tail -5`
Expected: 1개 테스트 PASS.

- [ ] **Step 5: 즐겨찾기 클릭 분기 + 행 표시**

(a) `Sources/Views/SidebarView.swift`의 `FavoritesListView` 탭 핸들러 — 현행:

```swift
                    .onTapGesture {
                        if FileManager.default.fileExists(atPath: favorite.url.path) {
                            appState.openDocument(at: favorite.url, inNewTab: true)
                        }
                    }
```

을 다음으로 교체(폴더 분기 — 버그의 근본 수정):

```swift
                    .onTapGesture {
                        // 폴더 즐겨찾기: 파일 전용 openDocument로는 무동작이던 버그 —
                        // File > Open Folder와 동일하게 작업 폴더를 전환한다(스펙 §3).
                        var isDirectory: ObjCBool = false
                        guard FileManager.default.fileExists(atPath: favorite.url.path,
                                                             isDirectory: &isDirectory) else { return }
                        if isDirectory.boolValue {
                            appState.openFolder(at: favorite.url)
                        } else {
                            appState.openDocument(at: favorite.url, inNewTab: true)
                        }
                    }
```

(b) 같은 파일 `FavoriteRow`(:606-627) — 현행 body의 아이콘·이름 부분:

```swift
            HStack(spacing: 6) {
                Image(systemName: "star.fill")
                    .font(.caption)
                    .foregroundColor(.yellow)
                Text(favorite.displayName)
                    .font(.headline)
                    .lineLimit(1)
            }
```

을 다음으로 교체하고, struct에 `isDirectory` 계산 프로퍼티를 추가:

```swift
struct FavoriteRow: View {
    let favorite: FavoriteItem

    /// 즐겨찾기는 사용자가 손수 등록하는 소수 목록이라 행당 1회 FS 조회를 허용한다
    /// (파일 트리의 "렌더 중 FS 호출 0" 원칙은 수백 행 규모 얘기 — 스펙 §3).
    private var isDirectory: Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: favorite.url.path, isDirectory: &isDir)
            && isDir.boolValue
    }

    var body: some View {
        let directory = isDirectory
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: directory ? "folder.fill" : "star.fill")
                    .font(.caption)
                    .foregroundColor(directory ? .secondary : .yellow)
                // 폴더명은 확장자 개념이 없으니 그대로 — displayName의
                // deletingPathExtension이 점(.) 든 폴더명을 자르던 표시 버그 수정.
                Text(directory ? (favorite.alias ?? favorite.url.lastPathComponent)
                               : favorite.displayName)
                    .font(.headline)
                    .lineLimit(1)
            }

            Text(favorite.url.deletingLastPathComponent().path)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 4)
    }
}
```

- [ ] **Step 6: 전체 게이트 + 커밋**

Run: `swift build 2>&1 | tail -3 && swift test 2>&1 | grep -E "Executed [0-9]+ tests" | tail -1`
Expected: 경고 0, `Executed 383 tests`(382+1) 통과.

```bash
git add Sources/App/AppState.swift Sources/Views/SidebarView.swift Tests/CmdMDTests/AppOpenFolderAtTests.swift
git commit -m "수정(즐겨찾기): 폴더 즐겨찾기가 안 열리던 버그 — 클릭 핸들러가 파일 전용 openDocument만 호출. openFolder(at:) 추출(패널 분기 본문, 동작 불변)로 작업 폴더 전환 + 행 표시 폴더 아이콘·이름 잘림 수정"
```

---

### Task 4: 문서 기록 (CLAUDE.md)

**Files:**
- Modify: `CLAUDE.md` (「현재 상태」끝 항목 추가 + 「다음 액션」갱신)

**Interfaces:** 없음 (문서).

- [ ] **Step 1: CLAUDE.md 갱신**

「현재 상태」끝에 한 문단 추가(기존 문체·밀도) — 담을 사실: UI 다듬기 3건(2026-07-03) — ①Close All Tabs(핀 제외·더티 요약 확인 1회·저장 실패/URL 없는 탭 잔류·탭 우클릭+File 메뉴 ⌥⌘W) ②탭 파일명 말줄임(maxWidth 180·middle) ③즐겨찾기 폴더 버그 수정(클릭 핸들러가 파일 전용 openDocument라 무동작 — openFolder(at:) 추출로 작업 폴더 전환, 행 표시 폴더 아이콘·점 든 폴더명 잘림 수정, FavoriteItem 모델 불변). 테스트 수치는 커밋 전 실측(예상 401 = XCTest 383+Testing 18). 「다음 액션」의 수동 스모크 목록에 3건 확인 항목 추가(Close All 알림 3버튼·말줄임 렌더·즐겨찾기 폴더→트리 전환).

- [ ] **Step 2: 최종 게이트 + 커밋**

Run: `swift test 2>&1 | grep -E "Executed [0-9]+ tests" | tail -1`
Expected: `Executed 383 tests` 통과(수치를 문단에 실측으로 기록).

```bash
git add CLAUDE.md
git commit -m "문서: UI 다듬기 3건 완료 기록 — Close All Tabs·탭 말줄임·즐겨찾기 폴더 버그 수정"
```

---

## 수동 스모크 (구현 완료 후 사용자)

1. 탭 5~6개(핀 1·더티 1~2 섞어) → 탭 우클릭 "Close All Tabs" 또는 ⌥⌘W → 요약 알림(모두 저장/저장 안 함/취소) 각 버튼 동작·핀 탭 잔류
2. 아주 긴 파일명 파일 열기 → 탭이 180pt에서 가운데 말줄임(확장자 보임)
3. 즐겨찾기의 폴더 클릭 → 사이드바 트리 루트가 그 폴더로 전환(File > Open Folder와 동일), 파일 즐겨찾기는 기존대로 리더로 열림, 점(.) 든 폴더명이 안 잘리고 폴더 아이콘 표시
