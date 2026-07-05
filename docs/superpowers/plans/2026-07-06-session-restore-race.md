# 세션 복원 경합 근본 수정 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 콜드 런치 시 세션 복원과 외부 파일 열기(Finder 더블클릭·드롭)의 경합·중복 창을 제거한다 — 외부 열기=항상 새 탭, 다중=마지막 활성, 복원=activate 없이 배치, WindowGroup→단일 Window 씬.

**Architecture:** AppState에 MainActor Task 체인 기반 "직렬 열기 큐"(`externalOpenChain`)를 두고 외부 열기 전 경로(onOpenURL·드롭)를 수렴시킨다. 세션 복원은 "로드만"(`loadDocument`)을 분리해 일괄 append 후 활성 1회 지정하고, 복원 Task를 큐 선두에 시드한다. 씬은 `WindowGroup`→`Window` 전환으로 중복 창 경로를 구조적으로 차단한다.

**Tech Stack:** Swift 5.9 / SwiftUI / XCTest. 새 패키지 의존성 0.

**스펙:** `docs/superpowers/specs/2026-07-06-session-restore-race-design.md` (승인됨 2026-07-06)

## Global Constraints

- macOS 14+ / Swift 5.9+ / SPM. 비샌드박스 유지.
- 새 패키지 의존성 추가 금지.
- 코드 주석·커밋 메시지는 한국어. '박다/박는다/박았다' 계열 어휘 금지.
- 테스트 게이트: `swift test` 전체 GREEN(기준 XCTest 628 + Swift Testing 18 = 646, 신규 테스트만큼 증가). **swift test엔 정식 Xcode 필요**(CLT는 build만).
- 커밋 메시지 끝에 Co-Authored-By/Claude-Session 트레일러(저장소 관례) 유지.
- 이 계획의 수정 파일 밖을 건드리지 않는다. 내부 열기 경로(라이브러리/트리 클릭), `cmdmd` URL 스킴, `SessionState` 포맷은 불변(스펙 §5).

---

### Task 1: 직렬 열기 큐 + 외부 열기=항상 새 탭 배선

**Files:**
- Modify: `Sources/App/AppState.swift` (탭 상태 선언부 근처 — `var activeTabId` 아래에 큐 추가; `placeTab` 위쪽 아무 열기 관련 섹션에 메서드 2개)
- Modify: `Sources/App/CmdMDApp.swift:347-353` (`handleURL`)
- Test: `Tests/CmdMDTests/AppExternalOpenQueueTests.swift` (신규)

**Interfaces:**
- Consumes: 기존 `loadAndActivateDocument(at:inNewTab:)`(private, 같은 파일), `AppState(dataDirectory:)` 주입, `TempDataDirectory` 테스트 헬퍼.
- Produces: `func enqueueExternalOpen(_ urls: [URL])` (internal), `var externalOpenChain: Task<Void, Never>?` (internal — 테스트·Task 2 복원 시드가 사용), `private func presentMainWindowIfNeeded()`.

- [ ] **Step 1: 실패하는 테스트 작성**

`Tests/CmdMDTests/AppExternalOpenQueueTests.swift` 생성:

```swift
import XCTest
@testable import CmdMD

/// 외부 열기 직렬 큐(스펙 §2.2·§2.3) — 도착 순 FIFO·항상 새 탭·마지막 처리 파일이 활성.
@MainActor
final class AppExternalOpenQueueTests: XCTestCase {
    var tempData: URL!
    var workDir: URL!
    var app: AppState!

    override func setUp() {
        super.setUp()
        tempData = TempDataDirectory.make()
        workDir = TempDataDirectory.make()
        app = AppState(dataDirectory: tempData)
    }

    override func tearDown() {
        TempDataDirectory.cleanup(tempData)
        TempDataDirectory.cleanup(workDir)
        super.tearDown()
    }

    private func makeNote(_ name: String) -> URL {
        let url = workDir.appendingPathComponent(name)
        try? "# \(name)\n".write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testSequentialEnqueueOpensInOrderAndActivatesLast() async {
        let a = makeNote("a.md"), b = makeNote("b.md"), c = makeNote("c.md")
        app.enqueueExternalOpen([a])
        app.enqueueExternalOpen([b])
        app.enqueueExternalOpen([c])
        await app.externalOpenChain?.value
        XCTAssertEqual(app.tabs.compactMap(\.fileURL), [a, b, c])
        XCTAssertEqual(app.activeTabId, app.tabs.last?.id)
    }

    func testBatchEnqueueActivatesLastOfBatch() async {
        let a = makeNote("a.md"), b = makeNote("b.md")
        app.enqueueExternalOpen([a, b])
        await app.externalOpenChain?.value
        XCTAssertEqual(app.tabs.compactMap(\.fileURL), [a, b])
        XCTAssertEqual(app.activeTab?.fileURL, b)
    }

    func testReopeningSameURLReusesExistingTab() async {
        let a = makeNote("a.md"), b = makeNote("b.md")
        app.enqueueExternalOpen([a, b])
        await app.externalOpenChain?.value
        let originalTabId = app.tabs.first?.id

        app.enqueueExternalOpen([a])   // 같은 URL 재열기 — 새 탭이 아니라 기존 탭 활성
        await app.externalOpenChain?.value
        XCTAssertEqual(app.tabs.count, 2)
        XCTAssertEqual(app.activeTabId, originalTabId)
    }

    func testEnqueueSwitchesToReaderMode() async {
        let a = makeNote("a.md")
        app.mainMode = .library
        app.enqueueExternalOpen([a])
        await app.externalOpenChain?.value
        XCTAssertEqual(app.mainMode, .reader)
    }

    func testEmptyEnqueueIsNoop() async {
        app.enqueueExternalOpen([])
        XCTAssertNil(app.externalOpenChain)
        XCTAssertTrue(app.tabs.isEmpty)
    }
}
```

- [ ] **Step 2: 실패 확인**

Run: `swift test --filter AppExternalOpenQueueTests 2>&1 | tail -5`
Expected: **컴파일 실패** — `enqueueExternalOpen`/`externalOpenChain` 미존재("has no member" 류). 컴파일 실패도 RED로 인정(신규 API).

- [ ] **Step 3: 최소 구현**

`Sources/App/AppState.swift` — `var activeTabId: UUID?` 선언(17행 부근) 아래에 프로퍼티, `placeTab`(1082행 부근) 위에 메서드 추가:

```swift
    /// 외부 열기(더블클릭·드롭)와 세션 복원을 도착 순으로 직렬 처리하는 체인(스펙 §2.3).
    /// 마지막에 처리된 파일이 활성 탭이 된다. 내부 열기(라이브러리·트리 클릭)는 이 큐를 타지 않는다.
    var externalOpenChain: Task<Void, Never>?
```

```swift
    /// 외부에서 온 파일 열기 요청을 직렬 큐에 제출한다 — 항상 새 탭(같은 URL은 기존 탭 활성,
    /// 스펙 §2.2). 배치 안 순서 = 열리는 순서, 마지막 파일이 활성.
    func enqueueExternalOpen(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let prev = externalOpenChain
        externalOpenChain = Task { @MainActor in
            await prev?.value
            self.mainMode = .reader
            for url in urls {
                await self.loadAndActivateDocument(at: url, inNewTab: true)
            }
            self.presentMainWindowIfNeeded()
        }
    }

    /// 외부 열기 처리 후 문서 창이 숨겨져 있으면 표시한다. 단일 Window 씬은 WindowGroup과
    /// 달리 이벤트 전달용 새 창을 만들지 않으므로 필요(스펙 §2.1 — SwiftUI가 자체 재표시하면
    /// 보험, 안 하면 필수 경로). headless 테스트에선 NSApp이 nil이라 no-op.
    private func presentMainWindowIfNeeded() {
        guard let app = NSApp else { return }
        app.activate(ignoringOtherApps: true)
        if let window = app.windows.first(where: { $0.canBecomeMain }), !window.isVisible {
            window.makeKeyAndOrderFront(nil)
        }
    }
```

`Sources/App/CmdMDApp.swift:347-353` — `handleURL` 파일 분기 교체:

```swift
    private func handleURL(_ url: URL) {
        if url.scheme == "cmdmd" {
            appState.openInternalURL(url)
        } else if url.isFileURL {
            // 외부 열기 = 직렬 큐(항상 새 탭·다중은 마지막 활성 — 스펙 §2.2·§2.3).
            appState.enqueueExternalOpen([url])
        }
    }
```

- [ ] **Step 4: 통과 확인**

Run: `swift test --filter AppExternalOpenQueueTests 2>&1 | tail -5`
Expected: `Executed 5 tests, with 0 failures`

- [ ] **Step 5: 회귀 없음 확인 + 커밋**

Run: `swift test 2>&1 | tail -3` → 전체 GREEN 확인.

```bash
git add Sources/App/AppState.swift Sources/App/CmdMDApp.swift Tests/CmdMDTests/AppExternalOpenQueueTests.swift
git commit -m "기능(세션): 외부 열기 직렬 큐 — 항상 새 탭·도착 순 FIFO·마지막 활성 (스펙 §2.2-2.3)"
```

---

### Task 2: loadDocument 분리 + 배치 복원(큐 시드)

**Files:**
- Modify: `Sources/App/AppState.swift:1108-1155` (`loadAndActivateDocument` 재구성 → `loadDocument`/`finishOpening` 분리), `Sources/App/AppState.swift:3322-3359` (`restoreSessionIfNeeded` 배치화), `Sources/App/AppState.swift:17` (`activeTabId`에 didSet 카운터)
- Test: `Tests/CmdMDTests/AppSessionBatchRestoreTests.swift` (신규)

**Interfaces:**
- Consumes: Task 1의 `externalOpenChain`·`enqueueExternalOpen(_:)`. 기존 `SessionState`(`Sources/Models/Workspace.swift:231-238`, memberwise init — openFiles/activeFileIndex/viewMode/currentFolder/sidebarVisible/inspectorVisible), `Self.mediaRedirectTarget(for:)`, `Self.shouldRestoreActiveTab(current:restoredTabIds:)`, `placeTab(_:inNewTab:)`.
- Produces: `private func loadDocument(at:) async -> EditorTab?`(로드만 — 배치·단건 공용), `private func finishOpening(_ tab: EditorTab)`, `private(set) var activeTabIdChangeCount: Int`(테스트 관찰용). `loadAndActivateDocument` 시그니처 불변(동작 불변 — 기존 App* 스위트가 백스톱, 스펙 §3-6).

- [ ] **Step 1: 실패하는 테스트 작성**

`Tests/CmdMDTests/AppSessionBatchRestoreTests.swift` 생성:

```swift
import XCTest
@testable import CmdMD

/// 배치 세션 복원(스펙 §2.4) — 로드만 일괄, 활성 탭은 끝에 정확히 1회.
/// 복원 Task는 외부 열기 큐 선두에 시드돼, 복원 중 도착한 외부 열기가 마지막=활성이 된다.
@MainActor
final class AppSessionBatchRestoreTests: XCTestCase {
    var tempData: URL!
    var workDir: URL!

    override func setUp() {
        super.setUp()
        tempData = TempDataDirectory.make()
        workDir = TempDataDirectory.make()
    }

    override func tearDown() {
        TempDataDirectory.cleanup(tempData)
        TempDataDirectory.cleanup(workDir)
        super.tearDown()
    }

    private func makeNote(_ name: String) -> URL {
        let url = workDir.appendingPathComponent(name)
        try? "# \(name)\n".write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// 실제 앱과 동일한 session.json을 시드(JSONEncoder 기본 — URL은 plain string 인코딩).
    private func seedSession(openFiles: [URL], activeIndex: Int?) throws {
        let session = SessionState(
            openFiles: openFiles,
            activeFileIndex: activeIndex,
            viewMode: .source,
            currentFolder: nil,
            sidebarVisible: true,
            inspectorVisible: false
        )
        let data = try JSONEncoder().encode(session)
        try data.write(to: tempData.appendingPathComponent("session.json"))
    }

    func testBatchRestoreOpensAllTabsAndActivatesSavedIndexOnce() async throws {
        let a = makeNote("a.md"), b = makeNote("b.md"), c = makeNote("c.md")
        try seedSession(openFiles: [a, b, c], activeIndex: 1)

        let app = AppState(dataDirectory: tempData)
        await app.externalOpenChain?.value

        XCTAssertEqual(app.tabs.compactMap(\.fileURL), [a, b, c])
        XCTAssertEqual(app.activeTab?.fileURL, b)
        // 배치 복원의 핵심 — 중간 활성화 없이 끝에 정확히 1회만 지정(스펙 §3-1).
        XCTAssertEqual(app.activeTabIdChangeCount, 1)
    }

    func testExternalOpenDuringRestoreEndsUpLastAndActive() async throws {
        let a = makeNote("a.md"), b = makeNote("b.md")
        let external = makeNote("external.md")
        try seedSession(openFiles: [a, b], activeIndex: 0)

        let app = AppState(dataDirectory: tempData)
        // 복원 체인이 도는 도중 외부 열기 도착(Finder 더블클릭 시뮬레이션) — 체인 직렬화로
        // 복원 완료 뒤에 처리돼 마지막 탭·활성이 된다(스펙 §2.4).
        app.enqueueExternalOpen([external])
        await app.externalOpenChain?.value

        XCTAssertEqual(app.tabs.compactMap(\.fileURL), [a, b, external])
        XCTAssertEqual(app.activeTab?.fileURL, external)
    }

    func testRestoreDeduplicatesRepeatedURLs() async throws {
        let a = makeNote("a.md"), b = makeNote("b.md")
        try seedSession(openFiles: [a, b, a], activeIndex: nil)

        let app = AppState(dataDirectory: tempData)
        await app.externalOpenChain?.value

        XCTAssertEqual(app.tabs.compactMap(\.fileURL), [a, b])
    }

    func testRestoreSkipsMissingFilesAndResolvesActiveByURL() async throws {
        let a = makeNote("a.md"), b = makeNote("b.md")
        let missing = workDir.appendingPathComponent("ghost.md")   // 만들지 않음
        // activeIndex 2 = b (missing이 필터돼도 URL로 해석해야 맞음 — 구 코드의 인덱스 시프트 수정)
        try seedSession(openFiles: [a, missing, b], activeIndex: 2)

        let app = AppState(dataDirectory: tempData)
        await app.externalOpenChain?.value

        XCTAssertEqual(app.tabs.compactMap(\.fileURL), [a, b])
        XCTAssertEqual(app.activeTab?.fileURL, b)
    }

    func testNoSessionFileMeansNoChainAndNoTabs() async {
        let app = AppState(dataDirectory: tempData)
        XCTAssertNil(app.externalOpenChain)
        XCTAssertTrue(app.tabs.isEmpty)
    }
}
```

- [ ] **Step 2: 실패 확인**

Run: `swift test --filter AppSessionBatchRestoreTests 2>&1 | tail -8`
Expected: 컴파일 실패(`activeTabIdChangeCount` 미존재). 그것부터 최소로 뚫으면(Step 3의 didSet 카운터만 먼저 넣으면) 이후 RED는: `testBatchRestoreOpensAllTabsAndActivatesSavedIndexOnce` — 구 복원은 탭마다 활성화라 `activeTabIdChangeCount == 3+1` / `testExternalOpenDuringRestoreEndsUpLastAndActive` — 구 복원은 `externalOpenChain`을 시드하지 않아 `await`가 복원 완료를 기다리지 못함(탭 0~2개 비결정) / dedup 테스트 — 구 코드는 재사용 가드로 우연히 통과할 수 있음(무방).

- [ ] **Step 3: 구현**

**(a)** `Sources/App/AppState.swift:17` — `activeTabId`에 didSet 카운터:

```swift
    var activeTabId: UUID? {
        didSet { activeTabIdChangeCount += 1 }
    }
    /// 테스트 관찰용 — 배치 복원이 활성 탭을 정확히 1회만 지정하는지 검증(스펙 §3-1).
    private(set) var activeTabIdChangeCount = 0
```

**(b)** `Sources/App/AppState.swift:1108-1155` — `loadAndActivateDocument`를 3분할. 기존 본문을 아래로 교체(동작 불변 — 리다이렉트→재사용 가드→로드→배치→부수효과→저장 순서 유지):

```swift
    @MainActor
    private func loadAndActivateDocument(at url: URL, inNewTab: Bool) async {
        // 짝꿍 노트를 직접 열면 대응 미디어로 리다이렉트 — 노트는 미디어 뷰 안에서 열람·편집한다.
        let target = Self.mediaRedirectTarget(for: url) ?? url
        if let existingTab = tabs.first(where: { $0.fileURL == target }) {
            activeTabId = existingTab.id
            return
        }
        guard let tab = await loadDocument(at: target) else { return }
        placeTab(tab, inNewTab: inNewTab)
        finishOpening(tab)
        saveSession()
    }

    /// 문서를 읽어 "미배치" 탭을 만든다 — placeTab/활성화/saveSession 없음(스펙 §2.4).
    /// 리다이렉트·중복 판별은 호출자 몫. markdown 로드 실패 시 errorMessage 세팅 후 nil.
    @MainActor
    private func loadDocument(at url: URL) async -> EditorTab? {
        // 이미지·PDF·오피스·미디어: MarkdownDocument/워처/originalContents 없이 탭만.
        let kind = DocumentKind(from: url)
        if kind != .markdown {
            return EditorTab(
                fileURL: url,
                title: url.deletingPathExtension().lastPathComponent,
                kind: kind
            )
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
            return tab
        } catch {
            errorMessage = "Failed to open file: \(error.localizedDescription)"
            return nil
        }
    }

    /// 열기 마무리 부수효과(최근 파일·오피스 변환 재시도·파일 워처·태그 수확) —
    /// 단건(loadAndActivateDocument)·배치(restoreSessionIfNeeded) 공용.
    @MainActor
    private func finishOpening(_ tab: EditorTab) {
        guard let url = tab.fileURL else { return }
        addToRecentFiles(url)
        switch tab.kind {
        case .office:
            retryOfficeConversion(tabID: tab.id, fileURL: url)
        case .markdown:
            startWatchingFile(at: url, for: tab.id)
            if let document = documents[tab.documentId] {
                harvestTags(from: document)
            }
        default:
            break
        }
    }
```

**(c)** `Sources/App/AppState.swift:3343-3358` — `restoreSessionIfNeeded`의 파일 열기 루프를 배치로 교체(앞부분 뷰/폴더 복원 3327-3341행은 불변):

```swift
        let files = session.openFiles.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !files.isEmpty else { return }

        // 배치 복원(스펙 §2.4) — 로드만 하고 일괄 append, 활성 탭은 끝에 정확히 1회.
        // 이 Task를 외부 열기 큐 선두에 시드해, 복원 중 도착한 외부 열기(onOpenURL·드롭)는
        // 체인상 복원 뒤에 처리된다 → 자연히 "외부 파일 = 마지막 = 활성".
        externalOpenChain = Task { @MainActor in
            var restored: [EditorTab] = []
            for url in files {
                let target = Self.mediaRedirectTarget(for: url) ?? url
                guard !tabs.contains(where: { $0.fileURL == target }),
                      !restored.contains(where: { $0.fileURL == target }) else { continue }
                if let tab = await loadDocument(at: target) {
                    restored.append(tab)
                }
            }
            guard !restored.isEmpty else { return }
            tabs.append(contentsOf: restored)
            for tab in restored { finishOpening(tab) }

            // 방어적 가드 유지(스펙 §2.4) — 체인 밖 경로(사용자 클릭)가 먼저 활성 탭을
            // 만들었으면 덮어쓰지 않는다. 저장 인덱스는 openFiles 기준이므로 URL로 해석
            // (존재 필터·중복 제거로 인덱스가 밀리는 구버전 시프트 수정).
            if Self.shouldRestoreActiveTab(current: activeTabId,
                                           restoredTabIds: Set(restored.map(\.id))) {
                var activeTab: EditorTab?
                if let index = session.activeFileIndex, index < session.openFiles.count {
                    let savedURL = session.openFiles[index]
                    let target = Self.mediaRedirectTarget(for: savedURL) ?? savedURL
                    activeTab = restored.first(where: { $0.fileURL == target })
                }
                activeTabId = (activeTab ?? restored.last)?.id
            }
            saveSession()
        }
```

기존 3346-3358행의 `Task { ... loadAndActivateDocument ... }` 블록은 삭제된다.

- [ ] **Step 4: 통과 확인**

Run: `swift test --filter AppSessionBatchRestoreTests 2>&1 | tail -5`
Expected: `Executed 5 tests, with 0 failures`

- [ ] **Step 5: 리팩터 동작 불변 백스톱(스펙 §3-6) + 커밋**

Run: `swift test 2>&1 | tail -3` — 특히 `AppMediaOpenTests`·`AppImageTabTests`·`AppOfficeTabTests`·`AppPdfTabTests`·`AppSessionRestoreTests`(기존 가드 4케이스 유지) 포함 전체 GREEN.

```bash
git add Sources/App/AppState.swift Tests/CmdMDTests/AppSessionBatchRestoreTests.swift
git commit -m "기능(세션): 배치 복원 — loadDocument 분리·일괄 append·활성 1회·큐 선두 시드 (스펙 §2.4)"
```

---

### Task 3: 드롭 수집 순서 보존 + 드롭→큐 통일

**Files:**
- Modify: `Sources/App/AppState.swift:2411-2449` (`collectDropURLs` 슬롯 순서 보존, `openExternalFileDrops` 큐 위임)
- Modify: `Tests/CmdMDTests/AppFileDropTests.swift` (기존 openExternalFileDrops 테스트 3건을 체인 대기 방식으로 정렬 + 신규 2건)

**Interfaces:**
- Consumes: Task 1의 `enqueueExternalOpen(_:)`·`externalOpenChain`.
- Produces: `static func collectDropURLs(_:completion:)` 계약 강화 — **반환 URL 순서 = provider 순서**(기존 소비자 `handleFileDrop`(2381행)은 순서 무관이라 영향 없음). `openExternalFileDrops(_:)` 시맨틱 변경 — 단일 드롭도 항상 새 탭(스펙 §2.3 명시 개정).

- [ ] **Step 1: 실패하는 테스트 작성**

`Tests/CmdMDTests/AppFileDropTests.swift`에 추가(파일 상단 기존 헬퍼·픽스처 재사용, 없으면 테스트 내 로컬 생성):

```swift
    /// 드롭 다중 열기 — provider 순서 보존·마지막 활성(스펙 §2.3). loadItem 콜백은
    /// 임의 순서라 슬롯 수집 없인 비결정적이었다.
    func testOpenExternalFileDropsPreservesProviderOrderAndActivatesLast() async {
        let dir = TempDataDirectory.make()
        defer { TempDataDirectory.cleanup(dir) }
        let names = ["drop-a.md", "drop-b.md", "drop-c.md"]
        let urls: [URL] = names.map {
            let u = dir.appendingPathComponent($0)
            try? "# \($0)\n".write(to: u, atomically: true, encoding: .utf8)
            return u
        }
        let providers = urls.map { NSItemProvider(object: $0 as NSURL) }

        app.openExternalFileDrops(providers)
        await waitForChainSeeded()
        await app.externalOpenChain?.value

        XCTAssertEqual(app.tabs.compactMap(\.fileURL).map(\.lastPathComponent), names)
        XCTAssertEqual(app.activeTabId, app.tabs.last?.id)
    }

    /// 단일 드롭 = 항상 새 탭(F2 '단일 드롭=활성 탭 교체'의 명시적 개정 — 스펙 §2.3).
    func testSingleExternalDropOpensNewTabInsteadOfReplacing() async {
        let dir = TempDataDirectory.make()
        defer { TempDataDirectory.cleanup(dir) }
        let first = dir.appendingPathComponent("existing.md")
        try? "# existing\n".write(to: first, atomically: true, encoding: .utf8)
        let dropped = dir.appendingPathComponent("dropped.md")
        try? "# dropped\n".write(to: dropped, atomically: true, encoding: .utf8)

        app.enqueueExternalOpen([first])
        await app.externalOpenChain?.value
        XCTAssertEqual(app.tabs.count, 1)

        app.openExternalFileDrops([NSItemProvider(object: dropped as NSURL)])
        await waitForChainSeeded(minimumTabs: 2)
        await app.externalOpenChain?.value

        XCTAssertEqual(app.tabs.compactMap(\.fileURL).map(\.lastPathComponent),
                       ["existing.md", "dropped.md"])   // 교체 아님 — 둘 다 남는다
        XCTAssertEqual(app.activeTab?.fileURL?.lastPathComponent, "dropped.md")
    }

    /// collectDropURLs 슬롯 수집 — 콜백이 "역순"으로 와도 provider 순서를 보존(스펙 §3-5).
    /// registerItem loadHandler에 지연을 넣어 역순 도착을 결정적으로 재현한다.
    func testCollectDropURLsPreservesOrderWithReversedCallbacks() {
        let dir = TempDataDirectory.make()
        defer { TempDataDirectory.cleanup(dir) }
        let urls: [URL] = ["slow.md", "mid.md", "fast.md"].map {
            let u = dir.appendingPathComponent($0)
            try? "x".write(to: u, atomically: true, encoding: .utf8)
            return u
        }
        // 첫 provider가 가장 늦게, 마지막이 가장 먼저 완료되도록 지연을 역배치.
        let delays: [Double] = [0.3, 0.15, 0.0]
        let providers: [NSItemProvider] = zip(urls, delays).map { url, delay in
            let p = NSItemProvider()
            p.registerItem(forTypeIdentifier: "public.file-url") { completion, _, _ in
                DispatchQueue.global().asyncAfter(deadline: .now() + delay) {
                    completion(url.dataRepresentation as NSData, nil)
                }
            }
            return p
        }

        let exp = expectation(description: "collect")
        var result: [URL] = []
        AppState.collectDropURLs(providers) { urls in
            result = urls
            exp.fulfill()
        }
        wait(for: [exp], timeout: 5)
        XCTAssertEqual(result.map(\.lastPathComponent), ["slow.md", "mid.md", "fast.md"])
    }

    /// collectDropURLs(비동기 group.notify)가 체인을 시드할 때까지 대기하는 폴링 헬퍼.
    private func waitForChainSeeded(minimumTabs: Int = 1,
                                    timeout: TimeInterval = 5) async {
        let deadline = Date().addingTimeInterval(timeout)
        while app.tabs.count < minimumTabs && Date() < deadline {
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
    }
```

주의: 이 파일의 기존 `app` 픽스처(setUp의 AppState) 이름·형식을 그대로 따른다. 기존에 `app` 프로퍼티가 없고 테스트마다 로컬 생성이면 동일하게 로컬 생성으로 맞춘다.

- [ ] **Step 2: 실패 확인**

Run: `swift test --filter AppFileDropTests 2>&1 | tail -8`
Expected: 신규 3건 중 확정 FAIL 2건 — `testCollectDropURLsPreservesOrderWithReversedCallbacks`는 구 코드(도착 순 append)가 `["fast.md","mid.md","slow.md"]`를 반환해 확정 FAIL, `testSingleExternalDropOpensNewTabInsteadOfReplacing`은 구 코드가 `openInNewTab=false`로 활성 탭을 교체해 `tabs.count == 1`이므로 확정 FAIL. `testOpenExternalFileDropsPreservesProviderOrderAndActivatesLast`는 콜백 순서에 따라 간헐(비결정이 곧 결함).

- [ ] **Step 3: 구현**

`Sources/App/AppState.swift:2411-2428` — `collectDropURLs`를 슬롯 수집으로 교체:

```swift
    /// providers → fileURL 수집(외부 Finder 드래그 전용). 내부 드래그는 handleFileDrop이
    /// draggingURLs 스냅샷으로 직접 처리해 이 경로에 오지 않는다(파스테보드/​provider 어느 쪽도
    /// 커스텀 페이로드 데이터를 나르지 못하는 실측 — DragPayload.isInternalDrag 주석 참조).
    /// 반환 순서 = provider 순서(인덱스 슬롯 — loadItem 콜백은 임의 스레드·임의 순서, 스펙 §2.3).
    static func collectDropURLs(_ providers: [NSItemProvider],
                                completion: @escaping ([URL]) -> Void) {
        let fileProviders = providers.filter {
            $0.hasItemConformingToTypeIdentifier("public.file-url")
        }
        var slots = [URL?](repeating: nil, count: fileProviders.count)
        let lock = NSLock()   // loadItem 콜백은 임의 스레드 — 슬롯 쓰기 직렬화
        let group = DispatchGroup()
        for (index, provider) in fileProviders.enumerated() {
            group.enter()
            provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                if let data = item as? Data,
                   let url = URL(dataRepresentation: data, relativeTo: nil) {
                    lock.lock(); slots[index] = url; lock.unlock()
                }
                group.leave()
            }
        }
        group.notify(queue: .main) { completion(slots.compactMap { $0 }) }
    }
```

`Sources/App/AppState.swift:2430-2449` — `openExternalFileDrops`를 큐 위임으로 교체:

```swift
    /// 리더·창 레벨 외부(Finder) 파일 드롭 = 열기. 직렬 큐로 수렴해 더블클릭과 시맨틱 통일 —
    /// 항상 새 탭, 다중은 provider 순서대로 열고 마지막 활성(스펙 §2.3).
    /// 개정(2026-07-06): F2의 "단일 드롭 = 활성 탭 교체"를 폐기 — 드롭 한 번에 작업 중이던
    /// 탭이 교체당하는 놀람 제거, 더블클릭·드롭 시맨틱 일치.
    func openExternalFileDrops(_ providers: [NSItemProvider]) {
        Self.collectDropURLs(providers) { [weak self] urls in
            self?.enqueueExternalOpen(urls)
        }
    }
```

- [ ] **Step 4: 기존 테스트 정렬**

`Tests/CmdMDTests/AppFileDropTests.swift`의 기존 3건(`testOpenExternalFileDropsOpensAllProvidersAsTabs`·`testOpenExternalFileDropsSingleProviderOpens`·`testOpenExternalFileDropsIgnoresNonFileProviders`)을 실행해 보고:
- 대기 방식이 폴링/expectation이면 그대로 두되 타임아웃 내 통과 확인.
- 단정이 "단일 드롭=교체"를 전제하면(예: 교체 후 tabs.count 단정) 새 시맨틱(항상 새 탭)에 맞게 단정만 수정하고, 수정 이유를 테스트 주석에 남긴다: `// 개정(2026-07-06): 단일 드롭=새 탭(세션 복원 스펙 §2.3)`.

Run: `swift test --filter AppFileDropTests 2>&1 | tail -5`
Expected: 전체 PASS(신규 2 포함).

- [ ] **Step 5: 전체 회귀 + 커밋**

Run: `swift test 2>&1 | tail -3` → GREEN.

```bash
git add Sources/App/AppState.swift Tests/CmdMDTests/AppFileDropTests.swift
git commit -m "수정(드롭): 수집 순서 보존(인덱스 슬롯)·드롭을 외부 열기 큐로 통일 — 단일 드롭도 새 탭 (스펙 §2.3)"
```

---

### Task 4: Window 단일 창 씬 전환

**Files:**
- Modify: `Sources/App/CmdMDApp.swift:9` (WindowGroup → Window)

**Interfaces:**
- Consumes: 변경 없음 — 씬 콘텐츠·모디파이어·commands 전부 그대로.
- Produces: 단일 창 씬. **단위테스트 원리상 불가 영역**(스펙 §3) — 게이트는 빌드+전체 스위트, 실기 검증은 스모크(§4)로 위임.

- [ ] **Step 1: 씬 교체**

`Sources/App/CmdMDApp.swift:9`의 `WindowGroup {`를 다음으로 교체(콘텐츠·이후 모디파이어는 그대로):

```swift
        // 단일 창 씬(스펙 §2.1) — WindowGroup은 콜드 런치 시 상태 복원 창과 외부 열기(onOpenURL)
        // 이벤트 전달용 창을 각각 만들어 중복 문서 창 2개가 생겼다(같은 AppState 공유).
        // Window로 구조적으로 차단. 부수효과: File > New Window 기본 커맨드도 함께 사라진다(의도).
        Window("cmdALL", id: "main") {
```

- [ ] **Step 2: 빌드·전체 스위트 확인**

Run: `swift build 2>&1 | tail -2` → 경고 0·성공.
Run: `swift test 2>&1 | tail -3` → 전체 GREEN.

- [ ] **Step 3: 창 관련 기존 코드 영향 없음 확인(정찰 재확증)**

아래 3곳이 다중 창을 가정하지 않음을 눈으로 재확인만 한다(수정 없음):
- `CmdMDApp.swift:402-409` — willClose 미디어 정지(+canBecomeMain 필터)
- `CmdMDApp.swift:413-416` — 파일 키 로컬 모니터
- `Sources/Views/MenuBarView.swift:15` — NSApp.activate

- [ ] **Step 4: 커밋**

```bash
git add Sources/App/CmdMDApp.swift
git commit -m "기능(씬): WindowGroup→Window 단일 창 — 콜드 런치 중복 문서 창 구조적 차단 (스펙 §2.1)"
```

---

### Task 5: 문서 동기화 + 최종 게이트

**Files:**
- Modify: `docs/superpowers/specs/2026-07-04-f2-drag-move-design.md` (단일 드롭 시맨틱 개정 각주)
- Modify: `docs/superpowers/specs/2026-07-06-session-restore-race-design.md` (상태 줄 갱신)

**Interfaces:** 없음(문서만).

- [ ] **Step 1: F2 스펙 개정 각주**

`docs/superpowers/specs/2026-07-04-f2-drag-move-design.md`에서 "단일 드롭"의 기존 동작(활성 탭 교체/inNewTab 강제 없음)을 서술한 위치를 `grep -n "단일" docs/superpowers/specs/2026-07-04-f2-drag-move-design.md`로 찾아, 해당 절 바로 아래에 인용 블록 추가:

```markdown
> **개정(2026-07-06):** 세션 복원 경합 수정(`2026-07-06-session-restore-race-design.md` §2.3)으로
> 단일 드롭도 **항상 새 탭**으로 개정 — 더블클릭·드롭 시맨틱 통일, 활성 탭 교체 폐기.
```

- [ ] **Step 2: 세션 복원 스펙 상태 갱신**

`docs/superpowers/specs/2026-07-06-session-restore-race-design.md` 상단 `상태:` 줄을 다음으로 교체:

```markdown
상태: 구현 완료(2026-07-06) — 실기 스모크(§4)는 Downloads 정리 적용·재설치 후
```

- [ ] **Step 3: 최종 게이트 + 커밋**

Run: `swift test 2>&1 | tail -3` → 전체 GREEN(수치 기록 — 기준 646 + 신규 약 12).
Run: `swift build 2>&1 | grep -ci warning` → 0.

```bash
git add docs/superpowers/specs/2026-07-04-f2-drag-move-design.md docs/superpowers/specs/2026-07-06-session-restore-race-design.md
git commit -m "문서(스펙): F2 단일 드롭 개정 각주·세션 복원 스펙 상태 갱신"
```

---

## 계획 밖(코디네이터 몫)

- 최종 whole-branch 리뷰 → fix wave → CLAUDE.md·데일리 기록(관례).
- 재패키징·재설치·실기 스모크 5항목(스펙 §4)은 **Downloads 정리 적용 후** — §2.1 "확인 필요"(창 닫힘 상태 재표시)를 스모크 3번이 해소한다.
