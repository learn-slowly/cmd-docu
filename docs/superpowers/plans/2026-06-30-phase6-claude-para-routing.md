# Phase 6 — Claude 스마트 라우팅(PARA 분류) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 노트를 볼트로 보낼 때 규칙이 안 맞으면 Claude가 본문을 읽고 설정된 PARA 폴더 중 하나를 제안하고, 사용자가 기존 Send 시트에서 확인(Send)하면 이동한다.

**Architecture:** Phase 4 `ClaudeService.ask`와 기존 `sendToVault`/`autoRouteCurrentDocument`/`SendToVaultSheet`를 재사용한다. 신규는 모델(`ParaFolder`)·순수 헬퍼(`RouteHelper`)·AppState 오케스트레이션·UI 배선(Send 시트 버튼, VaultManager PARA 탭)만. Claude는 설정된 폴더 목록 중에서만 id로 고른다(경로 환각 방지).

**Tech Stack:** Swift 5.9+ / SwiftUI / SPM, macOS 14+, `claude -p`(Process), XCTest.

## Global Constraints

- 비샌드박스 유지. Claude는 직접 구현하지 않고 `Process`로만 호출(`ClaudeService.ask` 재사용).
- 제안→확인→실행. Claude 제안은 Send 시트를 프리필할 뿐, 사용자가 Send를 눌러야 이동. 자동 모드(`claudeRoutingEnabled`)도 시트로 제안→확인. 무단 이동·삭제 없음.
- Claude는 설정된 `paraFolders` 중에서만 선택. id로 답하게 하고 유효 id가 아니면 제안 폐기.
- 자동 라우팅에 Claude 사용 옵션 `claudeRoutingEnabled` 기본 **OFF**.
- 코드 주석·커밋 메시지는 한국어. '박다/박는다/박았다' 류 표현 금지(대안: 넣는다/적는다/채운다/추가한다 등).
- 신규 기능은 별도 파일로 분리. 설정 저장은 `appState.saveUserData()`(settings.json 포함).
- Process/Claude를 부르는 코드는 단위테스트하지 않는다(순수 함수만 테스트). 기존 139개 테스트가 깨지지 않아야 한다.
- 커밋 메시지 말미에 다음 두 줄을 넣는다:
  `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`
  `Claude-Session: https://claude.ai/code/session_01S2QuZUALidkTNRswXFL6xM`

### 확인된 기존 자산(재사용)
- `ClaudeService.ask(prompt:context:) async throws -> String`(actor); `AppState.claudeService` 인스턴스; `static AppState.claudeErrorMessage(_:) -> String`.
- `AppState.sendToVault(options:) async throws`(단일 전송, `currentDocument` 사용); `AppState.currentDocument: MarkdownDocument?`.
- `AppState.autoRouteCurrentDocument()` — 규칙 미매칭 분기에서 `showToast` 후 `showSendToVault = true`.
- `AppState.matchingRoutingRule(for:)`, `AppState.vaults`, `AppState.settings`(= `AppSettings`, Codable, settings.json 영속), `AppState.saveUserData()`.
- `SendToVaultSheet`(Destination 섹션: Vault Picker + Folder Picker/TextField; `availableFolders` 상태; `loadFolders(for:)`; `onAppear` 기본 프리필). `MarkdownDocument.content`.
- `VaultManagerView` — `enum ManagerSection { vaults, templates, rules }` 세그먼트 + 페인. 설정 변경 후 `appState.saveUserData()`.

---

### Task 1: ParaFolder 모델 + legoSeed + AppSettings 필드

**Files:**
- Create: `Sources/Models/ParaDestination.swift`
- Modify: `Sources/Models/Settings.swift` (`struct AppSettings`에 필드 3개 추가)
- Test: `Tests/CmdMDTests/ParaFolderTests.swift`

**Interfaces:**
- Produces:
  - `struct ParaFolder: Identifiable, Equatable, Codable, Hashable { let id: UUID; var label: String; var folder: String; var hint: String }` with `init(id:label:folder:hint:)` (hint defaults `""`).
  - `static func ParaFolder.legoSeed() -> [ParaFolder]`
  - `AppSettings.paraVaultId: UUID?`, `AppSettings.paraFolders: [ParaFolder]`, `AppSettings.claudeRoutingEnabled: Bool`

- [ ] **Step 1: 실패하는 테스트 작성**

`Tests/CmdMDTests/ParaFolderTests.swift`:
```swift
import XCTest
@testable import CmdMD

final class ParaFolderTests: XCTestCase {
    func testLegoSeedHasSixFoldersWithExpectedPaths() {
        let seed = ParaFolder.legoSeed()
        XCTAssertEqual(seed.count, 6)
        let folders = seed.map(\.folder)
        XCTAssertEqual(folders, [
            "10000_Projects/Living_with_Damage",
            "10000_Projects/Build_and_Deploy",
            "10000_Projects/Left_Forward",
            "20000_Areas",
            "30000_Resources",
            "40000_Archive",
        ])
        XCTAssertTrue(seed.allSatisfy { !$0.label.isEmpty && !$0.hint.isEmpty })
    }

    func testParaFolderRoundTripsCodable() throws {
        let f = ParaFolder(label: "L", folder: "P/Q", hint: "H")
        let data = try JSONEncoder().encode(f)
        let back = try JSONDecoder().decode(ParaFolder.self, from: data)
        XCTAssertEqual(f, back)
    }

    func testAppSettingsDefaultsParaFieldsWhenAbsent() throws {
        // 구버전 settings.json(신규 키 없음)도 기본값으로 디코드돼야 한다(하위호환).
        let json = #"{"fontSize":14}"#.data(using: .utf8)!
        let s = try JSONDecoder().decode(AppSettings.self, from: json)
        XCTAssertNil(s.paraVaultId)
        XCTAssertTrue(s.paraFolders.isEmpty)
        XCTAssertFalse(s.claudeRoutingEnabled)
    }
}
```

- [ ] **Step 2: 테스트 실패 확인**

Run: `swift test --filter ParaFolderTests`
Expected: 컴파일 실패("cannot find 'ParaFolder'").

- [ ] **Step 3: 모델 구현**

`Sources/Models/ParaDestination.swift`:
```swift
import Foundation

/// Claude PARA 라우팅의 후보 폴더 하나. folder는 PARA 볼트 rootPath 기준 상대 경로.
struct ParaFolder: Identifiable, Equatable, Codable, Hashable {
    let id: UUID
    var label: String   // 표시명
    var folder: String  // 예: "10000_Projects/Living_with_Damage"
    var hint: String    // Claude 분류용 짧은 설명(선택)

    init(id: UUID = UUID(), label: String, folder: String, hint: String = "") {
        self.id = id
        self.label = label
        self.folder = folder
        self.hint = hint
    }
}

extension ParaFolder {
    /// 레고 PARA 구조 시드. vaultId와 무관하게 라벨/경로/힌트만 제공한다.
    static func legoSeed() -> [ParaFolder] {
        [
            ParaFolder(label: "Projects — Living with Damage", folder: "10000_Projects/Living_with_Damage", hint: "피해·치료·회복 관련 진행 프로젝트"),
            ParaFolder(label: "Projects — Build and Deploy",   folder: "10000_Projects/Build_and_Deploy",   hint: "개발·배포·도구 제작 프로젝트"),
            ParaFolder(label: "Projects — Left Forward",       folder: "10000_Projects/Left_Forward",       hint: "정치·운동·조직 활동 프로젝트"),
            ParaFolder(label: "Areas",     folder: "20000_Areas",     hint: "지속 관리하는 역할·책임 영역"),
            ParaFolder(label: "Resources", folder: "30000_Resources", hint: "주제별 참고 자료·지식"),
            ParaFolder(label: "Archive",   folder: "40000_Archive",   hint: "끝났거나 비활성인 항목 보관"),
        ]
    }
}
```

- [ ] **Step 4: AppSettings 필드 추가**

`Sources/Models/Settings.swift`의 `struct AppSettings` 안, 기존 `var defaultSendFolder`/`conflictResolution`/`injectFrontmatterByDefault` 근처(line ~91-93 아래)에 추가:
```swift
    // MARK: PARA 스마트 라우팅
    var paraVaultId: UUID? = nil           // 지정 PARA 볼트
    var paraFolders: [ParaFolder] = []     // Claude가 고를 후보 목록
    var claudeRoutingEnabled: Bool = false // 자동 라우팅 미매칭 시 Claude 사용(기본 OFF)
```
(`AppSettings`는 멤버와이즈가 아니라 기본값 있는 저장 프로퍼티라 구 JSON도 하위호환 디코드된다.)

- [ ] **Step 5: 테스트 통과 확인**

Run: `swift test --filter ParaFolderTests`
Expected: PASS (3 tests).

- [ ] **Step 6: 커밋**

```bash
git add Sources/Models/ParaDestination.swift Sources/Models/Settings.swift Tests/CmdMDTests/ParaFolderTests.swift
git commit -m "기능(라우팅): ParaFolder 모델·legoSeed·AppSettings PARA 필드 추가

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01S2QuZUALidkTNRswXFL6xM"
```

---

### Task 2: RouteHelper 순수 헬퍼 + RouteSuggestion

**Files:**
- Create: `Sources/Models/RouteSuggestion.swift`
- Test: `Tests/CmdMDTests/RouteHelperTests.swift`

**Interfaces:**
- Consumes: `ParaFolder`(Task 1)
- Produces:
  - `struct RouteSuggestion: Equatable { let folder: ParaFolder; let reason: String }`
  - `struct RouteParse: Decodable { let id: String; let reason: String }`
  - `enum RouteHelper`:
    - `static func buildRoutePrompt(destinations: [ParaFolder]) -> String`
    - `static func buildRouteContext(noteBody: String, maxChars: Int = 4000) -> String`
    - `static func parseRouteSuggestion(_ stdout: String, destinations: [ParaFolder]) -> RouteSuggestion?`

- [ ] **Step 1: 실패하는 테스트 작성**

`Tests/CmdMDTests/RouteHelperTests.swift`:
```swift
import XCTest
@testable import CmdMD

final class RouteHelperTests: XCTestCase {
    private func dests() -> [ParaFolder] {
        [
            ParaFolder(id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, label: "Projects", folder: "10000_Projects", hint: "진행 프로젝트"),
            ParaFolder(id: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!, label: "Resources", folder: "30000_Resources", hint: "참고 자료"),
        ]
    }

    func testBuildRoutePromptIncludesEveryDestinationAndJSONInstruction() {
        let p = RouteHelper.buildRoutePrompt(destinations: dests())
        XCTAssertTrue(p.contains("00000000-0000-0000-0000-000000000001"))
        XCTAssertTrue(p.contains("Projects"))
        XCTAssertTrue(p.contains("진행 프로젝트"))
        XCTAssertTrue(p.contains("00000000-0000-0000-0000-000000000002"))
        XCTAssertTrue(p.contains("Resources"))
        XCTAssertTrue(p.lowercased().contains("json"))
        XCTAssertTrue(p.contains("\"id\""))
        XCTAssertTrue(p.contains("\"reason\""))
    }

    func testBuildRouteContextTruncatesLongBody() {
        let body = String(repeating: "가", count: 5000)
        let ctx = RouteHelper.buildRouteContext(noteBody: body, maxChars: 100)
        XCTAssertLessThan(ctx.count, body.count)
        XCTAssertTrue(ctx.contains("생략"))
    }

    func testBuildRouteContextKeepsShortBody() {
        let ctx = RouteHelper.buildRouteContext(noteBody: "짧은 본문", maxChars: 100)
        XCTAssertEqual(ctx, "짧은 본문")
    }

    func testParseValidJSONResolvesFolder() {
        let out = #"{"id":"00000000-0000-0000-0000-000000000002","reason":"참고용 자료라서"}"#
        let s = RouteHelper.parseRouteSuggestion(out, destinations: dests())
        XCTAssertEqual(s?.folder.folder, "30000_Resources")
        XCTAssertEqual(s?.reason, "참고용 자료라서")
    }

    func testParseExtractsJSONFromProseAndCodeFence() {
        let out = """
        제 판단은 다음과 같습니다:
        ```json
        {"id":"00000000-0000-0000-0000-000000000001","reason":"진행 중인 프로젝트 문서"}
        ```
        """
        let s = RouteHelper.parseRouteSuggestion(out, destinations: dests())
        XCTAssertEqual(s?.folder.folder, "10000_Projects")
    }

    func testParseUnknownIdReturnsNil() {
        let out = #"{"id":"99999999-9999-9999-9999-999999999999","reason":"x"}"#
        XCTAssertNil(RouteHelper.parseRouteSuggestion(out, destinations: dests()))
    }

    func testParseMalformedReturnsNil() {
        XCTAssertNil(RouteHelper.parseRouteSuggestion("도무지 JSON이 아님", destinations: dests()))
    }
}
```

- [ ] **Step 2: 테스트 실패 확인**

Run: `swift test --filter RouteHelperTests`
Expected: 컴파일 실패("cannot find 'RouteHelper'").

- [ ] **Step 3: 구현**

`Sources/Models/RouteSuggestion.swift`:
```swift
import Foundation

/// Claude가 고른 PARA 목적지(해석 완료).
struct RouteSuggestion: Equatable {
    let folder: ParaFolder
    let reason: String
}

/// Claude가 답해야 하는 strict JSON 형태.
struct RouteParse: Decodable {
    let id: String
    let reason: String
}

/// PARA 라우팅 프롬프트/컨텍스트/파싱 순수 헬퍼(테스트 대상).
enum RouteHelper {
    /// 목록 중 best를 id로 골라 JSON만 답하게 지시하는 프롬프트.
    static func buildRoutePrompt(destinations: [ParaFolder]) -> String {
        let list = destinations
            .map { "- \($0.id.uuidString) | \($0.label) — \($0.hint)" }
            .joined(separator: "\n")
        return """
        아래는 노트를 분류할 PARA 폴더 후보다. 이어지는 노트 본문을 읽고, 가장 알맞은 폴더 하나를 골라라.
        반드시 아래 목록의 id 중 하나만 고른다.

        \(list)

        답은 다른 텍스트 없이 strict JSON 한 줄로만 한다:
        {"id":"<위 목록의 id>","reason":"<한국어 한 줄 이유>"}
        """
    }

    /// 본문 컨텍스트. maxChars 초과면 앞부분만 남기고 잘렸음을 표시한다.
    static func buildRouteContext(noteBody: String, maxChars: Int = 4000) -> String {
        guard noteBody.count > maxChars else { return noteBody }
        return String(noteBody.prefix(maxChars)) + "\n…(생략)"
    }

    /// stdout에서 첫 {…} JSON을 추출·디코드하고 id를 ParaFolder로 해석한다. 실패 시 nil.
    static func parseRouteSuggestion(_ stdout: String, destinations: [ParaFolder]) -> RouteSuggestion? {
        guard let start = stdout.firstIndex(of: "{"),
              let end = stdout.lastIndex(of: "}"), start < end else { return nil }
        let jsonText = String(stdout[start...end])
        guard let data = jsonText.data(using: .utf8),
              let parsed = try? JSONDecoder().decode(RouteParse.self, from: data),
              let folder = destinations.first(where: { $0.id.uuidString == parsed.id })
        else { return nil }
        return RouteSuggestion(folder: folder, reason: parsed.reason)
    }
}
```

- [ ] **Step 4: 테스트 통과 확인**

Run: `swift test --filter RouteHelperTests`
Expected: PASS (7 tests).

- [ ] **Step 5: 커밋**

```bash
git add Sources/Models/RouteSuggestion.swift Tests/CmdMDTests/RouteHelperTests.swift
git commit -m "기능(라우팅): RouteHelper(프롬프트·컨텍스트·JSON 파싱) 추가

Claude는 목록 id 중에서만 선택, stdout에서 첫 {…} 추출·검증·해석.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01S2QuZUALidkTNRswXFL6xM"
```

---

### Task 3: AppState 오케스트레이션

**Files:**
- Modify: `Sources/App/AppState.swift`
  - 상태 필드 추가(다른 Claude/route 상태 근처)
  - 메서드 추가(`claudeErrorMessage` 근처, line ~374 이후 적당한 위치)
  - `autoRouteCurrentDocument()` 미매칭 분기 수정(line ~1671-1678)
- Test: `Tests/CmdMDTests/AppParaRoutingTests.swift`

**Interfaces:**
- Consumes: `RouteHelper`/`RouteSuggestion`(Task 2), `ParaFolder`(Task 1), `claudeService`, `AppState.claudeErrorMessage`, `AppState.vaults`, `AppState.settings`
- Produces:
  - `var AppState.claudeRouteInProgress: Bool`
  - `var AppState.claudeRouteError: String?`
  - `var AppState.autoTriggerClaudeRoute: Bool`
  - `func AppState.isParaRoutingConfigured() -> Bool`
  - `var AppState.paraVault: Vault?`
  - `func AppState.requestClaudeRoute(noteBody: String) async -> RouteSuggestion?` (@MainActor)

- [ ] **Step 1: 실패하는 테스트 작성**

`Tests/CmdMDTests/AppParaRoutingTests.swift`:
```swift
import XCTest
@testable import CmdMD

final class AppParaRoutingTests: XCTestCase {
    @MainActor
    func testIsParaRoutingConfiguredFalseWhenUnset() {
        let app = AppState()
        XCTAssertFalse(app.isParaRoutingConfigured())
    }

    @MainActor
    func testIsParaRoutingConfiguredFalseWithoutFolders() {
        let app = AppState()
        let vault = Vault(name: "V", rootPath: URL(fileURLWithPath: "/tmp/v"))
        app.vaults = [vault]
        app.settings.paraVaultId = vault.id
        app.settings.paraFolders = []
        XCTAssertFalse(app.isParaRoutingConfigured())
    }

    @MainActor
    func testIsParaRoutingConfiguredTrueWhenVaultAndFoldersPresent() {
        let app = AppState()
        let vault = Vault(name: "V", rootPath: URL(fileURLWithPath: "/tmp/v"))
        app.vaults = [vault]
        app.settings.paraVaultId = vault.id
        app.settings.paraFolders = ParaFolder.legoSeed()
        XCTAssertTrue(app.isParaRoutingConfigured())
        XCTAssertEqual(app.paraVault?.id, vault.id)
    }

    @MainActor
    func testIsParaRoutingConfiguredFalseWhenVaultMissing() {
        let app = AppState()
        app.settings.paraVaultId = UUID()      // 등록되지 않은 볼트
        app.settings.paraFolders = ParaFolder.legoSeed()
        XCTAssertFalse(app.isParaRoutingConfigured())
        XCTAssertNil(app.paraVault)
    }

    @MainActor
    func testRequestClaudeRouteUnconfiguredSetsErrorAndReturnsNil() async {
        let app = AppState()
        let result = await app.requestClaudeRoute(noteBody: "본문")
        XCTAssertNil(result)
        XCTAssertNotNil(app.claudeRouteError)
        XCTAssertFalse(app.claudeRouteInProgress)
    }
}
```

> 참고: 위 테스트는 Claude를 호출하지 않는 경로만 검증한다(미설정 가드). 실제 `claudeService.ask` 호출 경로는 단위테스트하지 않는다(관례).

- [ ] **Step 2: 테스트 실패 확인**

Run: `swift test --filter AppParaRoutingTests`
Expected: 컴파일 실패("cannot find 'isParaRoutingConfigured'" 등).

- [ ] **Step 3: 상태 필드 추가**

`Sources/App/AppState.swift`에서 기존 Claude 관련 상태(예: `claudeError`/`claudePanelVisible` 등) 근처에 추가:
```swift
    /// PARA 스마트 라우팅 상태.
    var claudeRouteInProgress: Bool = false
    var claudeRouteError: String? = nil
    /// autoRoute 미매칭 → Send 시트가 onAppear에서 자동 제안하도록 켜는 1회성 플래그.
    var autoTriggerClaudeRoute: Bool = false
```

- [ ] **Step 4: 메서드 추가**

`static func claudeErrorMessage(_:)` 정의 근처(같은 MARK 블록 끝) 아래에 추가:
```swift
    // MARK: - PARA 스마트 라우팅

    /// PARA 볼트와 폴더가 모두 설정됐고 그 볼트가 실제 등록돼 있는가(버튼 활성/가드용).
    func isParaRoutingConfigured() -> Bool {
        guard let id = settings.paraVaultId, !settings.paraFolders.isEmpty else { return false }
        return vaults.contains { $0.id == id }
    }

    /// 설정된 PARA 볼트 객체(없으면 nil).
    var paraVault: Vault? {
        guard let id = settings.paraVaultId else { return nil }
        return vaults.first { $0.id == id }
    }

    /// 본문을 Claude에 보내 PARA 폴더 제안을 받는다. 실패 시 claudeRouteError 세팅 후 nil.
    @MainActor
    func requestClaudeRoute(noteBody: String) async -> RouteSuggestion? {
        guard isParaRoutingConfigured() else {
            claudeRouteError = "설정에서 PARA 볼트와 폴더를 먼저 추가하세요."
            return nil
        }
        claudeRouteError = nil
        claudeRouteInProgress = true
        defer { claudeRouteInProgress = false }
        let dests = settings.paraFolders
        let prompt = RouteHelper.buildRoutePrompt(destinations: dests)
        let context = RouteHelper.buildRouteContext(noteBody: noteBody)
        do {
            let out = try await claudeService.ask(prompt: prompt, context: context)
            if let suggestion = RouteHelper.parseRouteSuggestion(out, destinations: dests) {
                return suggestion
            }
            claudeRouteError = "Claude 제안을 해석하지 못했습니다. 직접 골라 주세요."
            return nil
        } catch {
            claudeRouteError = Self.claudeErrorMessage(error)
            return nil
        }
    }
```

- [ ] **Step 5: autoRouteCurrentDocument 미매칭 분기 수정**

`autoRouteCurrentDocument()`의 미매칭 분기(현재):
```swift
        guard let rule = matchingRoutingRule(for: document),
              let vault = vaults.first(where: { $0.id == rule.targetVaultId }) else {
            showToast("No routing rule matches — opening Send dialog")
            showSendToVault = true
            return
        }
```
다음으로 교체:
```swift
        guard let rule = matchingRoutingRule(for: document),
              let vault = vaults.first(where: { $0.id == rule.targetVaultId }) else {
            if settings.claudeRoutingEnabled && isParaRoutingConfigured() {
                autoTriggerClaudeRoute = true   // 시트가 onAppear에서 소비해 자동 제안
            } else {
                showToast("No routing rule matches — opening Send dialog")
            }
            showSendToVault = true
            return
        }
```

- [ ] **Step 6: 테스트 통과 + 빌드 확인**

Run: `swift test --filter AppParaRoutingTests`
Expected: PASS (5 tests).
Run: `swift build`
Expected: 빌드 성공.

- [ ] **Step 7: 커밋**

```bash
git add Sources/App/AppState.swift Tests/CmdMDTests/AppParaRoutingTests.swift
git commit -m "기능(라우팅): AppState PARA 라우팅 상태·requestClaudeRoute·autoRoute 분기

미설정 가드·paraVault·Claude 제안 수신, 자동 모드는 autoTriggerClaudeRoute로 시트에 위임.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01S2QuZUALidkTNRswXFL6xM"
```

---

### Task 4: SendToVaultSheet — "Claude에게 맡기기" 버튼 + 자동 트리거

**Files:**
- Modify: `Sources/Views/SendToVaultSheet.swift`
- Test: 없음(UI; `swift build` + `swift test` 회귀만)

**Interfaces:**
- Consumes: `AppState.requestClaudeRoute(noteBody:)`/`claudeRouteInProgress`/`claudeRouteError`/`autoTriggerClaudeRoute`/`paraVault`/`isParaRoutingConfigured()`(Task 3), `AppState.currentDocument`, `RouteSuggestion`(Task 2)
- Produces: 시트 내부 동작만(공개 인터페이스 없음)

- [ ] **Step 1: Destination 섹션에 버튼·캡션 추가**

`Sources/Views/SendToVaultSheet.swift`에 로컬 상태 추가(기존 `@State` 목록 끝, line ~18 근처):
```swift
    @State private var routeCaption: String?      // Claude 제안 이유 또는 에러 표시
```
그리고 `Section("Destination")`의 Folder 픽커/텍스트필드 블록(line ~55-65) 바로 다음, 섹션 안에 추가:
```swift
                    if !isBatch && appState.isParaRoutingConfigured() {
                        HStack {
                            Button {
                                runClaudeRoute()
                            } label: {
                                Label("Claude에게 맡기기", systemImage: "wand.and.stars")
                            }
                            .disabled(appState.claudeRouteInProgress)
                            if appState.claudeRouteInProgress {
                                ProgressView().controlSize(.small)
                            }
                        }
                        if let caption = routeCaption {
                            Text(caption)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
```

- [ ] **Step 2: 동작 메서드 추가 + 자동 트리거**

`send()` 위(또는 helper 영역)에 추가:
```swift
    /// Claude에게 현재 문서 본문을 보내 PARA 폴더를 제안받아 Vault/Folder를 프리필한다.
    private func runClaudeRoute() {
        guard let body = appState.currentDocument?.content else {
            routeCaption = "보낼 문서를 찾을 수 없습니다."
            return
        }
        routeCaption = nil
        Task {
            let suggestion = await appState.requestClaudeRoute(noteBody: body)
            await MainActor.run {
                if let s = suggestion, let vault = appState.paraVault {
                    selectedVault = vault
                    loadFolders(for: vault)
                    targetFolder = s.folder.folder
                    // 제안 폴더가 목록에 없으면 끼워 픽커에 보이게 한다.
                    if !availableFolders.contains(s.folder.folder) {
                        availableFolders.insert(s.folder.folder, at: 0)
                    }
                    routeCaption = "제안: \(s.folder.label) — \(s.reason)"
                } else {
                    routeCaption = appState.claudeRouteError ?? "제안을 받지 못했습니다."
                }
            }
        }
    }
```
그리고 `onAppear`(line ~155-165) 끝에 자동 트리거 추가:
```swift
            if appState.autoTriggerClaudeRoute {
                appState.autoTriggerClaudeRoute = false   // 1회성 소비
                if !isBatch && appState.isParaRoutingConfigured() {
                    runClaudeRoute()
                }
            }
```

- [ ] **Step 3: 빌드·회귀 확인**

Run: `swift build`
Expected: 빌드 성공(경고 없음).
Run: `swift test`
Expected: 기존 + Task1-3 신규 모두 PASS(UI 단위테스트 없음).

- [ ] **Step 4: 커밋**

```bash
git add Sources/Views/SendToVaultSheet.swift
git commit -m "기능(라우팅): Send 시트에 Claude에게 맡기기 버튼·자동 트리거 배선

제안 폴더를 Vault/Folder에 프리필하고 이유를 캡션 표시. 이동은 사용자가 Send 눌러야 일어남.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01S2QuZUALidkTNRswXFL6xM"
```

---

### Task 5: VaultManagerView — "PARA 라우팅" 탭

**Files:**
- Modify: `Sources/Views/VaultManagerView.swift` (ManagerSection에 케이스 추가 + 새 `ParaManagerPane`)
- Test: 없음(UI; `swift build` + `swift test` 회귀만)

**Interfaces:**
- Consumes: `AppState.settings.paraVaultId`/`paraFolders`/`claudeRoutingEnabled`(Task 1), `AppState.vaults`, `AppState.saveUserData()`, `ParaFolder.legoSeed()`(Task 1)
- Produces: `struct ParaManagerPane: View`

- [ ] **Step 1: ManagerSection에 케이스 추가**

`enum ManagerSection`(line ~11-23)에 케이스·아이콘 추가:
```swift
        case para = "PARA"
```
`icon` switch에:
```swift
            case .para: return "sparkles"
```
`body`의 switch(line ~51-58)에:
```swift
            case .para:
                ParaManagerPane()
```

- [ ] **Step 2: ParaManagerPane 구현**

`Sources/Views/VaultManagerView.swift` 끝부분(다른 Pane 정의들 옆)에 추가:
```swift
// MARK: - PARA 라우팅

/// PARA 볼트·폴더 목록·자동 라우팅 토글을 관리한다. 변경은 saveUserData로 영속.
struct ParaManagerPane: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState
        Form {
            Section("PARA 볼트") {
                Picker("볼트", selection: $state.settings.paraVaultId) {
                    Text("선택 안 함").tag(nil as UUID?)
                    ForEach(appState.vaults) { vault in
                        Text(vault.displayName).tag(vault.id as UUID?)
                    }
                }
                .onChange(of: state.settings.paraVaultId) { appState.saveUserData() }
                Text("Claude가 제안하는 폴더는 이 볼트 기준 상대 경로입니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("폴더 목록") {
                if appState.settings.paraFolders.isEmpty {
                    Text("폴더가 없습니다. 아래 '기본 구조 채우기'로 시작하거나 직접 추가하세요.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach($state.settings.paraFolders) { $folder in
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("라벨", text: $folder.label)
                        TextField("폴더 경로(예: 10000_Projects/Build_and_Deploy)", text: $folder.folder)
                        TextField("힌트(분류 설명)", text: $folder.hint)
                    }
                    .padding(.vertical, 2)
                }
                .onDelete { idx in
                    state.settings.paraFolders.remove(atOffsets: idx)
                    appState.saveUserData()
                }
                HStack {
                    Button("폴더 추가") {
                        state.settings.paraFolders.append(ParaFolder(label: "새 폴더", folder: ""))
                        appState.saveUserData()
                    }
                    Button("기본 구조 채우기") {
                        // 비었을 때만 시드로 채운다(기존 항목 보존).
                        if state.settings.paraFolders.isEmpty {
                            state.settings.paraFolders = ParaFolder.legoSeed()
                        } else {
                            state.settings.paraFolders.append(contentsOf: ParaFolder.legoSeed())
                        }
                        appState.saveUserData()
                    }
                    Spacer()
                    Button("저장") { appState.saveUserData() }
                }
            }

            Section("자동 라우팅") {
                Toggle("규칙 미매칭 시 Claude에게 자동으로 제안 받기", isOn: $state.settings.claudeRoutingEnabled)
                    .onChange(of: state.settings.claudeRoutingEnabled) { appState.saveUserData() }
                Text("켜도 이동 전 Send 시트로 제안을 확인합니다(무단 이동 없음). 기본 OFF.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
```

> 텍스트필드 편집은 바인딩으로 즉시 모델에 반영되고, 명시적 영속은 '저장'/onChange/추가·삭제 시 `saveUserData()`로 한다.

- [ ] **Step 3: 빌드·회귀 확인**

Run: `swift build`
Expected: 빌드 성공(경고 없음).
Run: `swift test`
Expected: 모든 테스트 PASS.

- [ ] **Step 4: 커밋**

```bash
git add Sources/Views/VaultManagerView.swift
git commit -m "기능(라우팅): VaultManager에 PARA 탭(볼트·폴더목록·자동토글) 추가

기본 구조 채우기(legoSeed)·폴더 CRUD·자동 라우팅 토글, 변경은 saveUserData로 영속.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01S2QuZUALidkTNRswXFL6xM"
```

---

### Task 6: Phase 게이트 — 전체 테스트·수동 검증·문서

**Files:**
- Modify: `CLAUDE.md`

**Interfaces:** 없음(통합 검증·문서).

- [ ] **Step 1: 전체 테스트**

Run: `swift test`
Expected: 모든 테스트 PASS(기존 139 + 신규 약 15 = 약 154). 실패 0.

- [ ] **Step 2: 수동 검증(앱)**

앱 실행 → 볼트 관리 → PARA 탭에서 PARA 볼트 지정·'기본 구조 채우기' → 마크다운 노트 열고 Send 시트 → "Claude에게 맡기기" → 제안 폴더가 Vault/Folder에 채워지고 이유 캡션 표시 확인 → Send로 이동 확인(원본/대상). 자동 토글 ON + 규칙 미매칭 시 시트가 자동 제안하는지 확인. (Claude 미로그인/크레딧 소진 시 에러 캡션 확인.)

- [ ] **Step 3: CLAUDE.md 상태 갱신**

`## 현재 상태`의 Phase 5b 줄 아래에 한 줄 추가(실제 수치로):
```markdown
- Phase 6 완료(2026-06-30). Claude 스마트 라우팅(PARA 분류) — `ParaFolder` 모델·`legoSeed`(레고 구조) + `AppSettings`(paraVaultId·paraFolders·claudeRoutingEnabled) + `RouteHelper`(프롬프트·컨텍스트 truncate·stdout JSON 추출/검증, **Claude는 설정 폴더 id 중에서만 선택**) + `AppState.requestClaudeRoute`(claudeService 재사용, 미설정 가드, claudeErrorMessage 재사용) + Send 시트 "Claude에게 맡기기"(제안→Vault/Folder 프리필+이유 캡션, 이동은 Send 눌러야) + VaultManager PARA 탭(볼트·폴더 CRUD·자동토글 기본 OFF) + autoRoute 미매칭 분기에 autoTriggerClaudeRoute. 제안→확인→실행, 무단 이동·삭제 없음. 약 NN개 테스트 통과.
```
그리고 `다음 액션:` 줄을 티어 3(Phase 7 내용검색)로 갱신.

- [ ] **Step 4: 커밋**

```bash
git add CLAUDE.md
git commit -m "문서: Phase 6 Claude PARA 스마트 라우팅 완료 상태 기록

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01S2QuZUALidkTNRswXFL6xM"
```

---

## Self-Review

**Spec coverage:**
- 3.1 ParaFolder + legoSeed → Task 1 ✓ / 3.2 AppSettings 필드 → Task 1 ✓
- 4 RouteHelper(buildRoutePrompt/buildRouteContext/parseRouteSuggestion) + RouteSuggestion/RouteParse → Task 2 ✓
- 5 AppState(상태·isParaRoutingConfigured·paraVault·requestClaudeRoute·autoRoute 분기) → Task 3 ✓
- 6.1 Send 시트 버튼·프리필·자동 트리거 → Task 4 ✓
- 6.2 VaultManager PARA 탭(볼트·폴더 CRUD·시드·자동토글) → Task 5 ✓
- 7 에러/안전(미설정 가드·claudeErrorMessage·파싱실패 캡션·무단이동 없음) → Task 3·4 ✓
- 8 테스트(legoSeed·하위호환·buildRoutePrompt·buildRouteContext·parseRouteSuggestion·isParaRoutingConfigured) → Task 1·2·3 ✓

**Placeholder scan:** NN(테스트 수)만 실행 시 채움. 코드/명령은 모두 구체값. TBD 없음.

**Type consistency:** `ParaFolder(id:label:folder:hint:)`(Task 1·2·3·5 일치), `RouteHelper.buildRoutePrompt(destinations:)`/`buildRouteContext(noteBody:maxChars:)`/`parseRouteSuggestion(_:destinations:)`(Task 2·3 일치), `RouteSuggestion{folder,reason}`(Task 2·3·4 일치), `requestClaudeRoute(noteBody:)`/`isParaRoutingConfigured()`/`paraVault`/`autoTriggerClaudeRoute`/`claudeRouteInProgress`/`claudeRouteError`(Task 3·4 일치), `settings.paraVaultId`/`paraFolders`/`claudeRoutingEnabled`(Task 1·3·5 일치). 일관성 확인됨.
