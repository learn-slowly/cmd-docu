# 자잘한 잔여 항목 일괄 처리(RAG 제외) 구현 계획

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) 문법으로 추적한다.

**Goal:** 문서·코드에 흩어진 잔여 소품 전부(RAG 계열 제외)를 한 배치로 정리한다 — Swift6 경고, App* 테스트 격리, Phase 8 Minor 2건, 미디어 후속 6건, KaTeX/Mermaid 로컬화, Claude 응답 저장·스트리밍, 문서 정정.

**Architecture:** 기존 패턴 재사용이 원칙 — 테스트 격리는 `TempDataDirectory`, 웹자산은 `LocalWebAssets` 인라인+CDN 폴백 패턴, 스트리밍은 기존 `ask()` 불변+`askStream` 신설(stream-json 실측 완료), 노트 저장은 `sendToVault` 재사용. 순수 함수 분리 + TDD.

**Tech Stack:** Swift 5.9/SwiftUI/SPM, XCTest, claude CLI 2.1.198(stream-json), npm(katex@0.16·mermaid@11 vendoring).

## Global Constraints

- 비샌드박스 유지. kordoc·claude는 `Process` 호출만 — 직접 구현 금지.
- **기존 `ClaudeService.ask(prompt:context:)` 시그니처·동작 불변** — RagService·RouteHelper·CleanupService가 의존. 스트리밍은 별도 메서드로만 추가.
- RAG 코드(`Rag*.swift`, `AskCorpusView`)는 이번 배치에서 건드리지 않는다.
- 원본 파일 이동·삭제 없음. 파일 쓰기는 새 노트 생성(`sendToVault`)뿐.
- 코드 주석·커밋 메시지는 한국어. '박다/박는다' 어휘 금지.
- 각 태스크 완료 시 관련 테스트 통과 확인 후 커밋. 최종 게이트: `swift test` 전체(기준선 345 = XCTest 327+Testing 18) + `swift build` 경고 0.
- 테스트 실행: `swift test`엔 정식 Xcode 필요(CLT는 build만). 필터 실행: `swift test --filter <ClassName>`.
- 새 패키지 의존성 0. vendored 자산(katex/mermaid)은 저장소에 커밋(약 4MB 증가 승인 전제).

## File Structure (신규/수정 지도)

- 수정: `Sources/App/AppState.swift` — T1(loadFileTree), T5(트리 siblings 블록), T6(claudeContext/askClaude), T8(pendingMediaScrollLines/openDocument/nearestHeadingSlug), T10(askClaude 스트리밍), T11(응답 저장 메서드)
- 수정: `Sources/Models/CompanionNote.swift` — T5(펜스·대소문자·role 헬퍼)
- 수정: `Sources/Services/LibraryListing.swift` — T5
- 수정: `Sources/Views/LibraryView.swift` — T7(LibraryListCell)
- 수정: `Sources/Views/MediaReaderView.swift` — T8(pending 줄 소비)
- 수정: `Sources/Views/FolderCleanupView.swift` — T4
- 수정: `Sources/App/CmdMDApp.swift` — T3(View 메뉴), T11(알림 이름)
- 수정: `Sources/Views/EditorTextView.swift` — T11(커서 삽입 핸들러)
- 수정: `Sources/Services/ClaudeService.swift` — T10(askStream+순수 파서)
- 수정: `Sources/Views/ClaudePanelView.swift` — T10(스트리밍 표시), T11(버튼 2개)
- 수정: `Sources/Services/LocalWebAssets.swift`, `Sources/Services/MarkdownRenderer.swift`, `Package.swift`, `Sources/Views/SettingsView.swift` — T9
- 생성: `Sources/Resources/web/{katex,mermaid}/…`, `scripts/vendor_web_assets.sh`, `scripts/inline_katex_fonts.py` — T9
- 수정(테스트): `Tests/CmdMDTests/{AppFillState,AppImageTab,AppIndexSearch,AppOfficeTab,AppPatch,AppPdfTab,AppWindowTitle}Tests.swift` — T2; `CompanionNoteTests`·`MediaListingTests` — T5; `AppClaudeTests` — T6; `AppMediaOpenTests` — T8; `LocalWebAssetsTests`·`RendererFeatureTests` — T9; `ClaudeServiceTests` — T10·T11
- 수정(문서): `CmdMD-fork_prd.md`, `README.md`, `THIRD-PARTY-NOTICES.md`(T9에서), `CLAUDE.md` — T13

---

### Task 1: Swift 6 경고 해소 — `loadFileTree`의 var self 캡처

**Files:**
- Modify: `Sources/App/AppState.swift:1211-1216`

**Interfaces:**
- Consumes: 없음
- Produces: 동작 불변(경고만 제거). `FileTreeBuildTests` 계속 통과.

- [ ] **Step 1: 현재 경고 확인**

Run: `swift build 2>&1 | grep -c "captured var"`
Expected: `1` (AppState.swift:1215 'reference to captured var self')

- [ ] **Step 2: guard-let 재바인딩으로 수정**

현재(1211-1216):
```swift
fileTreeTask = Task.detached(priority: .userInitiated) { [weak self] in
    let tree = AppState.buildFileTree(at: folder, expanded: snapshot)
    guard !Task.isCancelled else { return }
    // 호출 인스턴스에 대입 — static shared 참조 제거(다중 인스턴스·테스트 안전).
    await MainActor.run { self?.fileTree = tree }
}
```
수정 후:
```swift
fileTreeTask = Task.detached(priority: .userInitiated) { [weak self] in
    let tree = AppState.buildFileTree(at: folder, expanded: snapshot)
    guard !Task.isCancelled, let self else { return }
    // 호출 인스턴스에 대입 — static shared 참조 제거(다중 인스턴스·테스트 안전).
    // let 재바인딩으로 Swift 6 'captured var self' 경고 해소.
    await MainActor.run { self.fileTree = tree }
}
```
주의: `AppState.shared`로 되돌리지 말 것 — Phase 8.7에서 shared 대입이 다중 인스턴스/테스트 결함으로 확인돼 self로 고친 이력 있음(CLAUDE.md).

- [ ] **Step 3: 경고 0 + 기존 테스트 확인**

Run: `swift build 2>&1 | grep -c warning` → Expected: `0`
Run: `swift test --filter FileTreeBuildTests` → Expected: PASS

- [ ] **Step 4: Commit** — `수정: loadFileTree self 캡처를 let 재바인딩으로 — Swift 6 'captured var' 경고 해소(빌드 유일 경고)`

---

### Task 2: App* 테스트 임시 데이터 디렉터리 전환 (완전 격리 마무리)

**Files:**
- Modify: `Tests/CmdMDTests/AppFillStateTests.swift:15` (1곳, defer 패턴)
- Modify: `Tests/CmdMDTests/AppIndexSearchTests.swift:35` (1곳, defer 패턴)
- Modify: `Tests/CmdMDTests/AppImageTabTests.swift:6,18,29` / `AppOfficeTabTests.swift:6,17` / `AppPatchTests.swift:27,38,47` / `AppPdfTabTests.swift:6,18` / `AppWindowTitleTests.swift:6,12` (setUp/tearDown 패턴)

**Interfaces:**
- Consumes: `TempDataDirectory.make()/cleanup(_:)` (`Tests/CmdMDTests/TempDataDirectory.swift`), `AppState(dataDirectory:)` (`Sources/App/AppState.swift:602`)
- Produces: 없음(테스트만)

- [ ] **Step 1: 다수-사용 파일 5개에 setUp/tearDown 패턴 적용** — `AppLibraryStateTests.swift:6-32`와 동일하게:
```swift
private var tempDir: URL!
override func setUp() { super.setUp(); tempDir = TempDataDirectory.make() }
override func tearDown() { TempDataDirectory.cleanup(tempDir); tempDir = nil; super.tearDown() }
// 각 `AppState()` → `AppState(dataDirectory: tempDir)`
```

- [ ] **Step 2: 단일-사용 2곳에 defer 패턴 적용** — `AppAskCorpusTests.swift:7-8`과 동일하게:
```swift
let dir = TempDataDirectory.make(); defer { TempDataDirectory.cleanup(dir) }
let app = AppState(dataDirectory: dir)
```

- [ ] **Step 3: 인자 없는 AppState() 잔존 0 확인**

Run: `grep -rn "AppState()" Tests/` → Expected: 결과 없음

- [ ] **Step 4: 해당 클래스 테스트 실행**

Run: `swift test --filter "AppFillStateTests|AppImageTabTests|AppIndexSearchTests|AppOfficeTabTests|AppPatchTests|AppPdfTabTests|AppWindowTitleTests"`
Expected: 전부 PASS

- [ ] **Step 5: Commit** — `테스트: 나머지 App* 테스트 7파일을 임시 데이터 디렉터리로 전환 — 실제 settings/session 오염 원천 차단(완전 격리)`

---

### Task 3: View 메뉴에 "폴더 정리 (배치)" 진입점

**Files:**
- Modify: `Sources/App/CmdMDApp.swift:113-159` (`CommandMenu("View")` 안, Ask Claude 버튼 뒤)

**Interfaces:**
- Consumes: `appState.resetCleanup()` (`AppState.swift:2082`), `appState.showFolderCleanup` (`AppState.swift:126`) — 커맨드 팔레트(`CommandPaletteView.swift:281-290`)와 동일 조합
- Produces: 없음

- [ ] **Step 1: 버튼 추가** (Ask Claude 항목 아래, 기존 Divider 배치 관찰 후 자연스러운 위치):
```swift
Button("폴더 정리 (배치)") {
    appState.resetCleanup()
    appState.showFolderCleanup = true
}
```
- [ ] **Step 2: 빌드 확인** — `swift build` OK, 경고 0
- [ ] **Step 3: Commit** — `개선: View 메뉴에 "폴더 정리 (배치)" 진입점 — 커맨드팔레트와 동일 동작(Phase 8 잔여 Minor)`

---

### Task 4: 스킴 편집 목록을 안정 id ForEach로 — 삭제 애니메이션

**Files:**
- Modify: `Sources/Views/FolderCleanupView.swift:71-95` (스킴 버킷 목록)

**Interfaces:**
- Consumes: `CleanupBucket: Identifiable`(id: String, `CleanupModels.swift:24`), `appState.cleanupScheme: [CleanupBucket]`
- Produces: 없음(렌더 개선). `plan.moves`의 `ForEach(indices)`(:145)는 삭제가 없으므로 건드리지 않는다.

- [ ] **Step 1: 버킷 추가 코드의 id 유일성 확인** — FolderCleanupView에서 버킷을 추가하는 곳을 찾아 새 버킷 id가 유일한지 확인(중복/빈 문자열이면 `UUID().uuidString`로 고정). id가 안정적이지 않으면 이 태스크의 전제가 무너진다.
- [ ] **Step 2: ForEach를 바인딩 기반으로 교체**

현재: `ForEach(appState.cleanupScheme.indices, id: \.self) { i in … appState.cleanupScheme[i].name … remove(at: i) … }`
수정(뷰 상단에 `@Bindable var state = appState`가 없으면 body 안에서 생성 — ClaudePanelView.swift:11 패턴):
```swift
ForEach($state.cleanupScheme) { $bucket in
    // TextField("이름", text: $bucket.name) 등 인덱스 바인딩 → 요소 바인딩으로 치환
    Button(role: .destructive) {
        withAnimation {
            state.cleanupScheme.removeAll { $0.id == bucket.id }
        }
    } label: { Image(systemName: "trash") }
}
```
- [ ] **Step 3: 빌드 + 기존 Cleanup 테스트**

Run: `swift build && swift test --filter "Cleanup"` → Expected: PASS

- [ ] **Step 4: Commit** — `개선: 스킴 편집 ForEach를 안정 id(요소 바인딩)로 — 인덱스 id로 깨지던 삭제 애니메이션 정상화(Phase 8 잔여 Minor)`

---

### Task 5: CompanionNote 판별 통합 — `...` 닫는펜스 + 대소문자 무시 + 중복 제거

**Files:**
- Modify: `Sources/Models/CompanionNote.swift` (펜스 파싱 62-84, siblings 판별 25-28)
- Modify: `Sources/App/AppState.swift:1244-1262` (트리 siblings 블록)
- Modify: `Sources/Services/LibraryListing.swift:22-35`
- Test: `Tests/CmdMDTests/CompanionNoteTests.swift`, `Tests/CmdMDTests/MediaListingTests.swift`

**Interfaces:**
- Produces (후속 태스크·호출부가 쓰는 정확한 이름):
```swift
extension CompanionNote {
    /// 목록 한 폴더의 파일명들 → 소문자 키 집합(대소문자 무시 매칭용)
    static func siblingKeys<S: Sequence>(_ names: S) -> Set<String> where S.Element == String
    /// 짝꿍 노트인가(숨김 대상) — siblingKeys는 siblingKeys(_:) 산출물
    static func isCompanionNote(_ url: URL, siblingKeys: Set<String>) -> Bool
    /// 미디어 파일에 짝꿍 노트가 있는가(배지)
    static func hasCompanionNote(for url: URL, siblingKeys: Set<String>) -> Bool
    /// frontmatter 분리(공용) — 닫는펜스 --- 또는 ..., 뒤 공백 관용, 여는 펜스는 첫 줄 트림 == "---"
    static func splitFrontmatter(_ content: String) -> (yaml: String, body: String)?
}
```
- `summary(fromNoteContent:)`·`bodyStrippingFrontmatter(_:)`는 `splitFrontmatter` 위에서 재구성(공개 시그니처 불변).
- 기존 `isCompanionNote(_:siblings:)`는 제거하고 호출부·테스트를 `siblingKeys:`로 전환(내부 API).

- [ ] **Step 1: 실패 테스트 작성** — `CompanionNoteTests.swift`에 추가:
```swift
func testSummaryParsesDotsClosingFence() {
    let content = "---\nsummary: 회의 메모\n...\n본문"
    XCTAssertEqual(CompanionNote.summary(fromNoteContent: content), "회의 메모")
}
func testBodyStrippingHandlesDotsClosingFence() {
    let content = "---\nsummary: s\n...\n본문 시작"
    XCTAssertEqual(CompanionNote.bodyStrippingFrontmatter(content), "본문 시작")
}
func testClosingFenceToleratesTrailingSpace() {
    let content = "---\nsummary: s\n--- \n본문"
    XCTAssertEqual(CompanionNote.bodyStrippingFrontmatter(content), "본문")
}
func testSiblingMatchingIsCaseInsensitive() {
    // 미디어가 Clip.MOV, 노트가 Clip.mov.md — 숨김·배지 모두 성립해야 한다
    let keys = CompanionNote.siblingKeys(["Clip.MOV", "Clip.mov.md"])
    XCTAssertTrue(CompanionNote.isCompanionNote(URL(fileURLWithPath: "/t/Clip.mov.md"), siblingKeys: keys))
    XCTAssertTrue(CompanionNote.hasCompanionNote(for: URL(fileURLWithPath: "/t/Clip.MOV"), siblingKeys: keys))
}
func testUppercaseMdNoteMatches() {
    // 노트 확장자가 .MD — a.mp3에 배지, a.mp3.MD 숨김
    let keys = CompanionNote.siblingKeys(["a.mp3", "a.mp3.MD"])
    XCTAssertTrue(CompanionNote.isCompanionNote(URL(fileURLWithPath: "/t/a.mp3.MD"), siblingKeys: keys))
    XCTAssertTrue(CompanionNote.hasCompanionNote(for: URL(fileURLWithPath: "/t/a.mp3"), siblingKeys: keys))
}
```
`MediaListingTests.swift`엔 대소문자 교차 fixture(`Clip.MOV`+`Clip.mov.md`)로 트리·라이브러리 동치 케이스 1쌍 추가(기존 `testLibraryListingMatchesTreeBehavior` 패턴).

- [ ] **Step 2: 실패 확인** — `swift test --filter "CompanionNoteTests|MediaListingTests"` → 신규 테스트 FAIL(컴파일 에러 포함 가능: siblingKeys 미존재)

- [ ] **Step 3: CompanionNote 구현**
```swift
static func siblingKeys<S: Sequence>(_ names: S) -> Set<String> where S.Element == String {
    Set(names.map { $0.lowercased() })
}
static func isCompanionNote(_ url: URL, siblingKeys: Set<String>) -> Bool {
    guard let media = mediaURL(for: url) else { return false }
    return siblingKeys.contains(media.lastPathComponent.lowercased())
}
static func hasCompanionNote(for url: URL, siblingKeys: Set<String>) -> Bool {
    guard DocumentKind(from: url) == .media else { return false }
    return siblingKeys.contains(noteURL(for: url).lastPathComponent.lowercased())
}
static func splitFrontmatter(_ content: String) -> (yaml: String, body: String)? {
    var text = content
    if text.hasPrefix("\u{FEFF}") { text.removeFirst() }   // BOM 관용(FileService와 정렬)
    let lines = text.components(separatedBy: "\n")
    guard let first = lines.first, first.trimmingCharacters(in: .whitespaces) == "---" else { return nil }
    for (i, line) in lines.enumerated().dropFirst() {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t == "---" || t == "..." {   // 닫는펜스 두 표기 모두(FileService.parseFrontmatter와 동일 규칙)
            let yaml = lines[1..<i].joined(separator: "\n")
            var body = lines[(i + 1)...].joined(separator: "\n")
            while body.hasPrefix("\n") { body.removeFirst() }
            return (yaml, body)
        }
    }
    return nil
}
```
`summary(fromNoteContent:)`는 `splitFrontmatter`의 yaml에서 기존 방식으로 summary 추출, `bodyStrippingFrontmatter`는 body 반환(실패 시 원문). 기존 통과 테스트(`testSummaryParsing` 등)가 회귀 감시.

- [ ] **Step 4: 호출부 2곳 전환** — `AppState.swift:1246`·`LibraryListing.swift:24`:
```swift
let siblingKeys = CompanionNote.siblingKeys(contents.map { $0.lastPathComponent })
// …
if CompanionNote.isCompanionNote(itemURL, siblingKeys: siblingKeys) { continue }
let hasNote = CompanionNote.hasCompanionNote(for: itemURL, siblingKeys: siblingKeys)
```
(두 곳의 "숨김+배지" 3줄 중복이 헬퍼 호출로 수렴 — FileTreeItem 생성은 각자 유지.)

- [ ] **Step 5: 통과 확인** — `swift test --filter "CompanionNoteTests|MediaListingTests|AppMediaOpenTests"` → PASS
- [ ] **Step 6: Commit** — `수정(미디어): 짝꿍 판별 통합 — frontmatter 닫는펜스 '...' 지원(이원화 해소)·siblings 대소문자 무시(숨김·배지 어긋남 해소)·트리/라이브러리 중복 3줄을 CompanionNote 헬퍼로`

---

### Task 6: media 탭 Claude 컨텍스트 = 짝꿍 노트

**Files:**
- Modify: `Sources/App/AppState.swift:424-430` (claudeContext), `:491-502` (askClaude)
- Test: `Tests/CmdMDTests/AppClaudeTests.swift`

**Interfaces:**
- Produces: `static func claudeContext(selection: String, markdown: String?, officeMarkdown: String?, mediaNote: String? = nil) -> String` — 우선순위 선택영역 > 마크다운 > 오피스 > **짝꿍 노트** > 빈 문자열. 기존 3-인자 호출은 기본값으로 소스 호환.

- [ ] **Step 1: 실패 테스트** — `AppClaudeTests.swift`:
```swift
func testContextUsesMediaNoteWhenOthersEmpty() {
    let ctx = AppState.claudeContext(selection: "", markdown: nil, officeMarkdown: nil, mediaNote: "노트 본문")
    XCTAssertEqual(ctx, "노트 본문")
}
func testMediaNoteIgnoredWhenMarkdownPresent() {
    let ctx = AppState.claudeContext(selection: "", markdown: "md", officeMarkdown: nil, mediaNote: "노트")
    XCTAssertEqual(ctx, "md")
}
```
- [ ] **Step 2: FAIL 확인** → **Step 3: 구현**

`claudeContext`에 `mediaNote` 파라미터 추가(우선순위 마지막). `askClaude()`에 (officeMarkdown 계산 아래):
```swift
// media 탭이면 짝꿍 노트 전문을 컨텍스트로(frontmatter 포함 — duration·summary 메타가 질문에 유용).
// 한계: 편집 중 미저장 버퍼는 뷰 로컬 @State라 디스크 기준(탭 전환 시 자동저장돼 실사용 영향 작음).
let mediaNote: String? = {
    guard currentTabKind == .media, let url = currentTabFileURL else { return nil }
    return try? String(contentsOf: CompanionNote.noteURL(for: url), encoding: .utf8)
}()
let context = Self.claudeContext(selection: selection, markdown: currentDocument?.content,
                                 officeMarkdown: officeMarkdown, mediaNote: mediaNote)
```
- [ ] **Step 4: PASS 확인** — `swift test --filter AppClaudeTests`
- [ ] **Step 5: Commit** — `개선(미디어): media 탭에서 Claude 컨텍스트로 짝꿍 노트 전달 — 빈 컨텍스트로 프롬프트만 가던 문제 해소(작업 B 후속)`

---

### Task 7: 리스트 셀 summary 리플로우 — 부제 높이 예약

**Files:**
- Modify: `Sources/Views/LibraryView.swift:257-284` (`LibraryListCell`)

**Interfaces:** 없음(렌더 전용)

- [ ] **Step 1: 부제 줄을 조건부 추가에서 높이 예약으로 변경**

현재(261-265): `if let summary { Text(summary)… }` — summary 비동기 도착 시 줄이 추가돼 행 높이가 변하고 목록이 다시 흐름.
수정:
```swift
if item.hasCompanionNote {
    // summary가 늦게 도착해도 행 높이가 변하지 않게 자리부터 확보(리플로우 방지)
    Text(summary ?? " ")
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
}
```
(짝꿍 노트 없는 셀은 기존처럼 부제 없음 — 높이 손해 없음.)
- [ ] **Step 2: 빌드 + Commit** — `개선(미디어): 리스트 셀 summary 부제 높이 예약 — 비동기 도착 시 목록 리플로우 제거(작업 B 후속)`

---

### Task 8: 미디어 리다이렉트 스크롤 타깃 전달 (줄점프 복원)

**Files:**
- Modify: `Sources/App/AppState.swift` — `openDocument`(:771-786), `nearestHeadingSlug`(:870-887 인근), 신규 프로퍼티
- Modify: `Sources/Views/MediaReaderView.swift` — pending 줄 소비
- Test: `Tests/CmdMDTests/AppMediaOpenTests.swift`

**Interfaces:**
- Produces:
```swift
// AppState
var pendingMediaScrollLines: [UUID: Int] = [:]   // 탭 id → 대기 중 줄(비영속)
static func nearestHeadingSlug(in content: String, before line: Int) -> String?  // 기존 인스턴스 메서드에서 순수 로직 추출, 인스턴스판은 위임
```

- [ ] **Step 1: 실패 테스트** — `AppMediaOpenTests.swift`(기존 `testOpeningCompanionNoteActivatesMediaTab`:49의 비동기 대기 패턴을 그대로 따라):
```swift
func testOpeningCompanionNoteWithLineSetsPendingScroll() async {
    // fixture: 미디어 a.mp3 + 노트 a.mp3.md (기존 setUp 재사용)
    // openDocument(at: 노트URL, scrollToLine: 7) → 미디어 탭 활성 + pendingMediaScrollLines[activeTabId] == 7
}
```
순수 로직: `testNearestHeadingSlugPure` — 헤딩 2개짜리 문자열에서 줄 7 앞 가장 가까운 헤딩 slug 반환.

- [ ] **Step 2: FAIL 확인** → **Step 3: 구현**

`openDocument`(두 분기 모두): 대상 탭이 `.media`면 `scrollEditor(toLine:)` 대신 pending 등록 —
```swift
// 기존 탭 분기(:776 인근)
if let line {
    if existingTab.kind == .media { pendingMediaScrollLines[existingTab.id] = line }
    else { scrollEditor(toLine: line) }
}
// 로드 분기(:783 인근) — 리다이렉트로 media 탭이 된 경우 포함
if let line {
    if currentTabKind == .media, let id = activeTabId { pendingMediaScrollLines[id] = line }
    else { scrollEditor(toLine: line) }
}
```
`nearestHeadingSlug` 순수화: 기존 인스턴스 메서드의 본문(현재 `currentDocument?.content` 사용)을 `static func nearestHeadingSlug(in content: String, before line: Int)`로 옮기고 인스턴스판은 `Self.nearestHeadingSlug(in: currentDocument?.content ?? "", before: line)` 위임.

`MediaReaderView`: 노트 로드 완료 지점과 `.onChange(of: appState.pendingMediaScrollLines[tabID])`에서 소비 —
```swift
private func consumePendingScroll() {
    guard let line = appState.pendingMediaScrollLines[tabID],
          case .loaded(let content) = noteState else { return }
    appState.pendingMediaScrollLines.removeValue(forKey: tabID)
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
        NotificationCenter.default.post(name: .scrollToLine, object: line)   // 편집 모드용
        if let slug = AppState.nearestHeadingSlug(in: content, before: line) {
            NotificationCenter.default.post(name: .scrollToHeading, object: slug)  // 미리보기용
        }
    }
}
```
**검증 필수(추정 금지):** `MarkdownPreviewView`가 `scrollSyncEnabled: false`여도 `.scrollToHeading` 알림을 구독하는지 코드로 확인(`PreviewView.swift:77` 인근). 구독이 sync 플래그에 묶여 있으면 — 미리보기 점프는 해당 구독을 플래그와 분리하거나, 최소한 편집 모드 진입 시 `.scrollToLine`이 동작하는 선에서 마무리하고 한계를 커밋 메시지에 기록.

- [ ] **Step 4: PASS 확인** — `swift test --filter AppMediaOpenTests` → 신규 포함 전부 PASS
- [ ] **Step 5: Commit** — `개선(미디어): 검색→미디어 리다이렉트 시 줄점프 복원 — 탭별 pending 줄 전달·짝꿍 노트 미리보기는 헤딩 점프(스펙 §4.6 트레이드오프 해소)`

---

### Task 9: KaTeX/Mermaid 로컬 번들화 (highlight.js 패턴 확장)

**Files:**
- Create: `scripts/vendor_web_assets.sh`, `scripts/inline_katex_fonts.py`, `Sources/Resources/web/katex/{katex.min.js,katex.inline.min.css,auto-render.min.js,mhchem.min.js}`, `Sources/Resources/web/mermaid/mermaid.min.js`, `Sources/Resources/web/VERSIONS.txt`
- Modify: `Package.swift`(resources), `Sources/Services/LocalWebAssets.swift`, `Sources/Services/MarkdownRenderer.swift:518-560`, `Sources/Views/SettingsView.swift:386`, `THIRD-PARTY-NOTICES.md`
- Test: `Tests/CmdMDTests/LocalWebAssetsTests.swift`, `Tests/CmdMDTests/RendererFeatureTests.swift`

**Interfaces:**
- Produces (`LocalWebAssets`):
```swift
static let katexJS: String?          // web/katex/katex.min.js
static let katexAutoRenderJS: String?
static let katexMhchemJS: String?
static let katexCSS: String?         // web/katex/katex.inline.min.css (woff2 data-URI 인라인판)
static let mermaidJS: String?        // web/mermaid/mermaid.min.js
static func katexBlock(css: String?, js: String?, mhchem: String?, autoRender: String?) -> String?  // 하나라도 nil → nil(CDN 폴백)
static func mermaidBlock(js: String?) -> String?
```

- [ ] **Step 1: vendoring 스크립트 작성·실행** — `scripts/vendor_web_assets.sh`:
```bash
#!/bin/bash
# KaTeX·Mermaid 자산을 npm에서 받아 Sources/Resources/web/에 반영한다(버전 갱신 시 재실행).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
cd "$TMP"
npm pack katex@0.16 mermaid@11 --silent
tar xf katex-*.tgz; mv package katex
tar xf mermaid-*.tgz; mv package mermaid
DEST="$ROOT/Sources/Resources/web"
mkdir -p "$DEST/katex" "$DEST/mermaid"
cp katex/dist/katex.min.js "$DEST/katex/"
cp katex/dist/contrib/auto-render.min.js "$DEST/katex/"
cp katex/dist/contrib/mhchem.min.js "$DEST/katex/"
cp mermaid/dist/mermaid.min.js "$DEST/mermaid/"
# 폰트를 data URI로 인라인한 CSS 생성(원본 CSS+fonts/ → katex.inline.min.css)
python3 "$ROOT/scripts/inline_katex_fonts.py" katex/dist/katex.min.css katex/dist/fonts "$DEST/katex/katex.inline.min.css"
{ echo "katex $(node -p "require('./katex/package.json').version")";
  echo "mermaid $(node -p "require('./mermaid/package.json').version")"; } > "$DEST/VERSIONS.txt"
echo "완료: $DEST"
```
`scripts/inline_katex_fonts.py`: `url(fonts/…woff2)` → base64 `data:font/woff2;base64,…`로 치환하고, 같은 `src:` 목록의 woff/ttf 폴백 참조는 제거(woff2만 유지 — WKWebView 지원). 정규식으로 `src:[^;]+;` 블록 단위 처리.
Run: `bash scripts/vendor_web_assets.sh` → Expected: `Sources/Resources/web/` 5파일+VERSIONS.txt 생성, `katex.inline.min.css`에 `url(fonts/` 잔존 0(`grep -c "url(fonts/" …` = 0).

- [ ] **Step 2: Package.swift에 리소스 선언** — `.executableTarget`에:
```swift
resources: [.copy("Resources/web")],
```
Run: `swift build` → Expected: OK, `.build/debug/CmdMD_CmdMD.bundle/web/katex/katex.min.js` 존재.

- [ ] **Step 3: LocalWebAssets 확장 (TDD)** — 먼저 `LocalWebAssetsTests.swift`에 기존 hljsBlock 패턴 그대로 실패 테스트:
```swift
func testKatexBlockNilWhenAnyAssetMissing() {
    XCTAssertNil(LocalWebAssets.katexBlock(css: "c", js: nil, mhchem: "m", autoRender: "a"))
}
func testKatexBlockContainsRenderMathInElement() {
    let block = LocalWebAssets.katexBlock(css: "c", js: "J", mhchem: "M", autoRender: "A")
    XCTAssertTrue(block!.contains("renderMathInElement"))
    XCTAssertTrue(block!.contains("<style>c</style>"))
}
func testMermaidBlockNilWithoutJS() { XCTAssertNil(LocalWebAssets.mermaidBlock(js: nil)) }
func testMermaidBlockWrapsScript() {
    XCTAssertTrue(LocalWebAssets.mermaidBlock(js: "MJS")!.contains("MJS"))
}
```
구현: `findAppResourceBundleURL()`(번들명 `"CmdMD_CmdMD.bundle"`, `findHighlightrBundleURL`과 동일 3-루트 탐색) + lazy static 5종(`web/katex/...`, `web/mermaid/...` 하위 파일 읽기) + 조립 함수:
```swift
static func katexBlock(css: String?, js: String?, mhchem: String?, autoRender: String?) -> String? {
    guard let css, let js, let mhchem, let autoRender else { return nil }
    return """
    <style>\(css)</style>
    <script>\(js)</script>
    <script>\(mhchem)</script>
    <script>\(autoRender)</script>
    <script>
    document.addEventListener('DOMContentLoaded', function() {
        if (typeof renderMathInElement === 'undefined') return;
        renderMathInElement(document.body, {
            delimiters: [
                {left: '$$', right: '$$', display: true},
                {left: '\\\\[', right: '\\\\]', display: true},
                {left: '\\\\(', right: '\\\\)', display: false},
                {left: '$', right: '$', display: false}
            ],
            throwOnError: false
        });
    });
    </script>
    """
}
static func mermaidBlock(js: String?) -> String? {
    guard let js else { return nil }
    return "<script>\(js)</script>"   // initialize 스니펫은 렌더러가 기존 그대로 뒤에 붙임
}
```
(delimiters는 `MarkdownRenderer.swift:554-560`의 CDN판과 **문자 단위로 동일**하게 — 구분자 목록을 원본에서 복사해 검증.)

- [ ] **Step 4: MarkdownRenderer 전환** — katexIncludes: `LocalWebAssets.katexBlock(css: .katexCSS, js: .katexJS, mhchem: .katexMhchemJS, autoRender: .katexAutoRenderJS) ?? 기존CDN문자열`. mermaidScript: `(LocalWebAssets.mermaidBlock(js: .mermaidJS) ?? CDN <script src>) + 기존 initialize 스니펫`. hljsIncludes(:656-699)와 같은 구조로.
- [ ] **Step 5: RendererFeatureTests 보강** — 공통 마커 방식(hljs의 `testHighlightJSIncludedForCodeBlocks` 주석 참고): KaTeX on → `renderMathInElement` 포함(인라인·CDN 공통), Mermaid 문서 → `mermaid.initialize` 포함. 기존 `html.contains("katex")` 단언이 인라인 경로에서도 성립하는지 실행으로 확인.
- [ ] **Step 6: THIRD-PARTY-NOTICES 갱신** — §1에 KaTeX(버전 VERSIONS.txt 기준, MIT, Copyright (c) 2013-2020 Khan Academy and other contributors)·Mermaid(버전, MIT, Copyright (c) 2014-2022 Knut Sveidqvist) 추가(§4 MIT 전문 참조 방식은 기존 Highlightr·Yams 항목과 동일). §2는 "로컬 번들 우선, 번들 누락 시에만 CDN 폴백"으로 재기술. `SettingsView.swift:386` 문구도 동일 취지로 갱신.
- [ ] **Step 7: 전체 확인** — `swift build && swift test --filter "LocalWebAssetsTests|RendererFeatureTests"` → PASS. `scripts/package_app.sh`의 `*.bundle` 글롭이 새 번들을 집는지 눈으로 확인(32-59줄).
- [ ] **Step 8: Commit** — `개선(렌더러): KaTeX·Mermaid 로컬 번들화 — vendoring 스크립트+SPM 리소스, 인라인 주입+CDN 폴백(highlight.js 패턴), KaTeX 폰트는 woff2 data-URI(Phase 8.7 후속)`

---

### Task 10: ClaudeService 스트리밍 — `askStream` + 패널 반영

**Files:**
- Modify: `Sources/Services/ClaudeService.swift`, `Sources/App/AppState.swift:491-521`(askClaude), `Sources/Views/ClaudePanelView.swift:32-53`
- Test: `Tests/CmdMDTests/ClaudeServiceTests.swift`

**Interfaces:**
- Produces:
```swift
// ClaudeService — 기존 ask는 그대로(RAG·라우팅·클린업 의존)
static func makeStreamArguments(prompt: String) -> [String]
static func textDelta(fromStreamLine line: String) -> String?           // stream_event/content_block_delta/text_delta만
static func finalResult(fromStreamLine line: String) -> (text: String, isError: Bool)?  // type=="result"
func askStream(prompt: String, context: String) -> AsyncThrowingStream<String, Error>
```
- 실측 포맷(claude 2.1.198, 2026-07-02 확인): 델타 = `{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"안"}},…}`, 최종 = `{"type":"result","subtype":"success","is_error":false,…,"result":"안녕",…}`. `system`/`assistant`/`rate_limit_event` 줄은 무시.

- [ ] **Step 1: 실패 테스트** — 실측 줄을 fixture로:
```swift
func testTextDeltaParsesRealStreamEventLine() {
    let line = #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"안"}},"session_id":"s","uuid":"u"}"#
    XCTAssertEqual(ClaudeService.textDelta(fromStreamLine: line), "안")
}
func testTextDeltaIgnoresNonDeltaLines() {
    XCTAssertNil(ClaudeService.textDelta(fromStreamLine: #"{"type":"system","subtype":"init"}"#))
    XCTAssertNil(ClaudeService.textDelta(fromStreamLine: #"{"type":"assistant","message":{}}"#))
    XCTAssertNil(ClaudeService.textDelta(fromStreamLine: "not json"))
}
func testFinalResultParsesResultLine() {
    let line = #"{"type":"result","subtype":"success","is_error":false,"result":"안녕"}"#
    let r = ClaudeService.finalResult(fromStreamLine: line)
    XCTAssertEqual(r?.text, "안녕"); XCTAssertEqual(r?.isError, false)
}
func testMakeStreamArgumentsIncludeStreamFlags() {
    let args = ClaudeService.makeStreamArguments(prompt: "q")
    XCTAssertEqual(args.prefix(2), ["-p", "q"])
    XCTAssertTrue(args.contains("--output-format")); XCTAssertTrue(args.contains("stream-json"))
    XCTAssertTrue(args.contains("--verbose")); XCTAssertTrue(args.contains("--include-partial-messages"))
}
```
- [ ] **Step 2: FAIL 확인** → **Step 3: 순수 파서 구현** — `JSONSerialization`으로 dict 파싱:
```swift
static func textDelta(fromStreamLine line: String) -> String? {
    guard let data = line.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          obj["type"] as? String == "stream_event",
          let event = obj["event"] as? [String: Any],
          event["type"] as? String == "content_block_delta",
          let delta = event["delta"] as? [String: Any],
          delta["type"] as? String == "text_delta" else { return nil }
    return delta["text"] as? String
}
static func finalResult(fromStreamLine line: String) -> (text: String, isError: Bool)? {
    guard let data = line.data(using: .utf8),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          obj["type"] as? String == "result" else { return nil }
    return (obj["result"] as? String ?? "", (obj["is_error"] as? Bool) ?? (obj["subtype"] as? String != "success"))
}
```
- [ ] **Step 4: askStream 구현** — `ask`(39-94)와 동일 골격(경로 탐지→Process 3파이프→stdin detached write→120s 데드라인) 위에:
```swift
func askStream(prompt: String, context: String) -> AsyncThrowingStream<String, Error> {
    AsyncThrowingStream { continuation in
        let work = Task.detached { [timeout] in
            // 경로 탐지·Process 구성·run은 ask와 동일(arguments = Self.makeStreamArguments(prompt:))
            // stderr는 기존처럼 readDataToEndOfFile 병렬 수집
            // stdout은 증분: for try await line in outHandle.bytes.lines {
            //     if Task.isCancelled { process.terminate(); break }
            //     if let t = Self.textDelta(fromStreamLine: line) { emitted = true; continuation.yield(t) }
            //     else if let r = Self.finalResult(fromStreamLine: line) {
            //         if r.isError { sawErrorResult = true }
            //         else if !emitted, !r.text.isEmpty { continuation.yield(r.text) }  // 델타 미지원 폴백
            //     }
            // }
            // 데드라인 감시는 별도 Task로 polling(ask와 동일), 초과 시 terminate + .timeout finish
            // 종료 후: status != 0 || sawErrorResult → continuation.finish(throwing: Self.classify(...))
            //          아니면 continuation.finish()
        }
        continuation.onTermination = { _ in work.cancel() }
    }
}
```
(주석 골격이 아니라 완전한 코드로 작성 — 구현자는 `runCapturing`(:125-151)·`ask`의 기존 드레인·타임아웃 코드를 조립 재료로 사용. stdout 증분 읽기와 stderr 일괄 드레인을 반드시 동시에 시작해 파이프 교착을 피한다.)
- [ ] **Step 5: askClaude 전환** — `AppState.swift:508-520`:
```swift
Task { @MainActor in
    do {
        var acc = ""
        let stream = await claudeService.askStream(prompt: prompt, context: context)
        for try await chunk in stream {
            acc += chunk
            claudeResponse = acc          // @Observable — 패널이 실시간 갱신
        }
        if acc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            claudeResponse = nil
            claudeError = "Claude가 빈 응답을 돌려주었습니다. 다시 시도해 주세요."  // 기존 문구 유지
        }
    } catch {
        claudeResponse = nil
        claudeError = Self.claudeErrorMessage(error)
    }
    claudeBusy = false
}
```
- [ ] **Step 6: 패널 표시 순서 조정** — `ClaudePanelView.swift:32-53` Group 분기를 **에러 > 응답(스트리밍 중 포함) > busy 스피너 > 안내** 순으로 재배열(현재는 busy가 먼저라 부분 응답이 가려짐). busy && 응답 있음일 때는 응답 위에 소형 ProgressView 한 줄.
- [ ] **Step 7: 확인** — `swift test --filter "ClaudeServiceTests|AppClaudeTests"` PASS + 수동: 패널에서 질문 시 글자가 점진 표시(스모크는 최종 단계에서 일괄).
- [ ] **Step 8: Commit** — `개선(Claude): 패널 응답 스트리밍 — askStream(stream-json 실측 파서, 기존 ask 불변으로 RAG·라우팅 무영향)+패널 점진 표시(Phase 4 후속)`

---

### Task 11: Claude 응답 저장 — 본문 삽입 + 노트로 저장

**Files:**
- Modify: `Sources/App/AppState.swift`(신규 메서드), `Sources/Views/ClaudePanelView.swift:55-69`(버튼), `Sources/App/CmdMDApp.swift:392-397`(알림 이름), `Sources/Views/EditorTextView.swift:417-538`(Coordinator 핸들러)
- Test: `Tests/CmdMDTests/AppClaudeTests.swift` 또는 `ClaudeServiceTests.swift`

**Interfaces:**
- Produces:
```swift
extension Notification.Name { static let insertClaudeResponse = Notification.Name("insertClaudeResponse") }  // object: String
// AppState
static func noteTitle(fromPrompt prompt: String) -> String   // 트림·개행→공백·40자 절단, 빈 값이면 "Claude 응답"
func insertClaudeResponseIntoCurrentNote()   // markdown 탭 전용: 에디터 있으면 커서 삽입 알림, preview면 본문 끝 append
func saveClaudeResponseAsNote() async        // MarkdownDocument 생성 → sendToVault(document:options:)
```

- [ ] **Step 1: 실패 테스트(순수)** —
```swift
func testNoteTitleFromPromptTrimsAndCaps() {
    XCTAssertEqual(AppState.noteTitle(fromPrompt: "  이 문서를\n요약해줘  "), "이 문서를 요약해줘")
    XCTAssertEqual(AppState.noteTitle(fromPrompt: ""), "Claude 응답")
    XCTAssertEqual(AppState.noteTitle(fromPrompt: String(repeating: "가", count: 60)).count, 40)
}
```
- [ ] **Step 2: FAIL** → **Step 3: 구현**

`insertClaudeResponseIntoCurrentNote()`:
```swift
func insertClaudeResponseIntoCurrentNote() {
    guard currentTabKind == .markdown, let doc = currentDocument,
          let resp = claudeResponse, !resp.isEmpty else { return }
    let block = "\n\n" + resp + "\n"
    if viewMode == .preview {
        updateContent(doc.content + block)          // 에디터 없음 — 끝에 덧붙임(insertImageMarkdown 패턴)
    } else {
        NotificationCenter.default.post(name: .insertClaudeResponse, object: block)  // 커서 위치 삽입
    }
}
```
Coordinator(EditorTextView, `insertLink`(:525-538) 패턴 복제):
```swift
// .insertClaudeResponse 구독(:417 인근 기존 구독 묶음에 추가)
private func insertPlainText(_ text: String) {
    guard let textView else { return }
    let range = textView.selectedRange()
    textView.textStorage?.replaceCharacters(in: range, with: text)
    textView.didChangeText()
}
```
`saveClaudeResponseAsNote()`(QuickCaptureView.sendToVault(:114-137) 패턴):
```swift
func saveClaudeResponseAsNote() async {
    guard let resp = claudeResponse, !resp.isEmpty else { return }
    guard let vault = defaultVault else {
        claudeError = "저장할 볼트가 없습니다. Vault Manager에서 볼트를 먼저 등록해 주세요."
        return
    }
    let doc = MarkdownDocument(title: Self.noteTitle(fromPrompt: claudePrompt), content: resp, isDraft: true)
    var options = SendOptions()
    options.targetVault = vault
    options.targetFolder = effectiveSendFolder(for: vault)
    do { try await sendToVault(document: doc, options: options, quiet: true) }
    catch { claudeError = "노트 저장 실패: \(error.localizedDescription)" }
}
```
(`MarkdownDocument`/`SendOptions` 생성 인자는 QuickCaptureView의 실제 사용형과 대조해 맞춘다.)

ClaudePanelView — 복사 버튼(:55-69) 옆에:
```swift
Button("본문에 삽입") { appState.insertClaudeResponseIntoCurrentNote(); flashFeedback("삽입됨") }
    .disabled(appState.currentTabKind != .markdown || appState.currentDocument == nil)
Button("노트로 저장") { Task { await appState.saveClaudeResponseAsNote(); flashFeedback("저장됨") } }
```
`flashFeedback`: `@State private var feedback: String?` + 2초 뒤 nil(간단한 캡션 표시). 저장 실패 시 claudeError가 우선 표시되므로 성공 캡션과 충돌 없음.
- [ ] **Step 4: PASS + 빌드** — `swift test --filter AppClaudeTests` PASS
- [ ] **Step 5: Commit** — `개선(Claude): 응답 저장 — 마크다운 본문 커서 삽입(미리보기 땐 끝에 추가)+기본 볼트 새 노트 저장(sendToVault 재사용, Phase 4 후속·PRD §Phase4 마지막 항목)`

---

### Task 12: 최종 whole-branch 리뷰 + 수정

- [ ] **Step 1:** `swift build`(경고 0) + `swift test` 전체 → 총수 기록(기준선 345 + 신규)
- [ ] **Step 2:** 이번 배치 diff 전체를 적대적 리뷰(코드리뷰 렌즈: 정확성·동시성·회귀·스펙일치). Critical/Important는 즉시 수정 + 회귀 테스트(RED→GREEN), Minor는 트리아지 기록.
- [ ] **Step 3:** 수정분 커밋.

### Task 13: 문서 정정 + 마무리(병합·데일리)

**Files:** `CmdMD-fork_prd.md`, `README.md`, `CLAUDE.md`

- [ ] **Step 1: PRD 정정** —
  - `:49` 헤더 `생성/패치/양식` → `패치/양식`
  - `:51` §3.4 설명에서 `(a) kordoc generate…` 항목 제거, patch/fill 2안으로 재구성 + "kordoc 실제 API 검증(Phase 5a)으로 generate 부재 확인" 한 줄
  - `:53` 제약 줄에서 "새 문서 생성은 HWPX 기준" 문구를 현실에 맞게 정리
  - `:197` → `- [ ] ~~md → HWPX 생성(kordoc generate…)~~ — kordoc에 generate 없음(Phase 5a 실측)으로 취소`
  - 완료 Phase 체크박스 `- [ ]`→`- [x]`: `:167,169,171,179,181,183,189,191,193,199,201,205,207,209,215,217,219,227,229,231` (`:193`은 Task 11로 이번에 완료됨)
  - `:235` KaTeX/Mermaid 로컬화 — 취소선 해제하고 `- [x]` 완료(Task 9) 표기. `:233` DOM 부분갱신은 보류 유지.
- [ ] **Step 2: README 정정** — `:12` Download를 `https://github.com/learn-slowly/cmd-docu/releases/latest`로, `:115` 테스트 수치를 Task 12 실측값으로, `:151` `Mermaid & KaTeX via CDN` → `Mermaid & KaTeX bundled locally (CDN fallback)`.
- [ ] **Step 3: CLAUDE.md 현재 상태에 배치 기록 추가** + 다음 액션 갱신(남은 것: Phase 10 본체, LLM-Wiki 스키마는 별건).
- [ ] **Step 4: Commit** — `문서: 잔여 소품 배치 완료 기록 — PRD generate 정정·완료 체크박스, README 링크·수치·CDN 문구, CLAUDE.md 현재 상태`
- [ ] **Step 5:** main 병합·origin 푸시(기존 워크플로), 옵시디언 데일리 로그 한 줄 추가.

---

## Self-Review 결과

- 범위 확인: 스윕 목록 중 RAG 3건(스트리밍·마크다운 렌더·리사이즈, A안, 형태소)과 LLM-Wiki 스키마(별건 산출물), PARA dismiss-then-present 수동 스모크(앱 구동 필요 — 최종 스모크 목록에 위임)를 제외한 전 항목이 태스크에 매핑됨.
- 타입 일관성: `siblingKeys`(T5)를 T5 내 호출부 2곳이 사용, `claudeContext` 4-인자(T6), `pendingMediaScrollLines`(T8), `askStream`(T10)→패널(T10)·저장(T11)은 `claudeResponse` 경유로 결합 낮음. AppState.swift를 만지는 T1·T5·T6·T8·T10·T11은 순차 실행.
- 미확정 지점 명시: T8의 PreviewView 구독 조건(코드 검증 후 적응), T11의 MarkdownDocument/SendOptions 생성 인자(QuickCaptureView 대조) — 구현 태스크 안에 검증 단계로 포함.
