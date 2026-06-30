# Phase 6 — Claude 스마트 라우팅(PARA 분류) 설계

> 작성일 2026-06-30. cmd-docu 티어 2. PRD 3.6 / Phase 6.
> 원칙: 비샌드박스 유지 · Claude는 Process(`claude -p`)로만 호출 · 제안→확인→실행 · 무단 이동/삭제 금지 · Phase 게이트(swift test).

## 1. 목표

노트를 볼트로 보낼 때, 규칙이 안 맞으면 Claude가 본문을 읽고 알맞은 **PARA 폴더**를 제안한다.
제안은 기존 Send 시트의 Vault/Folder 선택을 **프리필**하는 형태로 보여주고, 사용자가 확인(Send)해야 실제 이동이 일어난다.
Claude는 **설정된 폴더 목록 중에서만** 고른다(경로 환각 방지).

## 2. 기존 자산(재사용)

- `ClaudeService.ask(prompt:context:)`(Phase 4, actor) — `claude -p`로 질의, stderr→`ClaudeError`(notLoggedIn/creditExhausted/timeout/failed) 분류.
- `AppState.sendToVault(document:options:quiet:)` — 실제 이동/복사(제안 후 확정 단계). 로그/undo 기존 로직.
- `AppState.autoRouteCurrentDocument()` — 규칙 평가 후 매칭 시 조용히 전송, 미매칭 시 Send 시트 열기. **이 미매칭 분기에 Claude를 끼운다.**
- `AppState.matchingRoutingRule(for:)` — 최고우선 매칭 규칙.
- `SendToVaultSheet`(`Sources/Views/SendToVaultSheet.swift`) — Destination 섹션에 Vault 픽커 + Folder 픽커/텍스트필드. **여기에 "Claude에게 맡기기" 버튼을 더한다.** 이 시트가 곧 확인 단계.
- `Settings`(Codable, 영속) — PARA 설정 필드를 여기에 추가.

## 3. 모델

### 3.1 `Sources/Models/ParaDestination.swift` (신규)
```swift
struct ParaFolder: Identifiable, Equatable, Codable, Hashable {
    let id: UUID
    var label: String   // 표시명 (예: "Projects — Living with Damage")
    var folder: String  // PARA 볼트 rootPath 기준 상대 경로 (예: "10000_Projects/Living_with_Damage")
    var hint: String     // Claude 분류용 짧은 설명(선택, 빈 문자열 허용)

    init(id: UUID = UUID(), label: String, folder: String, hint: String = "") { … }
}

extension ParaFolder {
    /// 레고 PARA 구조 시드. vaultId와 무관하게 폴더 라벨/경로/힌트만 제공한다.
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

### 3.2 `AppSettings` 필드 추가 (`Sources/Models/Settings.swift`, `struct AppSettings`)
```swift
var paraVaultId: UUID? = nil           // 지정 PARA 볼트(폴더 목록의 기준 root)
var paraFolders: [ParaFolder] = []     // Claude가 고를 후보 목록
var claudeRoutingEnabled: Bool = false // 자동 라우팅 미매칭 시 Claude 사용(기본 OFF)
```
(`AppSettings`는 이미 Codable·`settings.json`에 영속이라 기본값으로 하위호환 디코딩된다. `AppState.settings`로 접근.)

## 4. 순수 헬퍼 — `Sources/Models/RouteSuggestion.swift` (신규, 테스트 대상)

```swift
struct RouteSuggestion: Equatable {
    let folder: ParaFolder
    let reason: String
}

/// Claude가 답할 strict JSON 형태.
struct RouteParse: Decodable {
    let id: String
    let reason: String
}

enum RouteHelper {
    /// 분류 프롬프트. Claude에게 목록 중 best를 id로 골라 JSON만 답하게 지시한다.
    static func buildRoutePrompt(destinations: [ParaFolder]) -> String

    /// 본문 컨텍스트(너무 길면 maxChars로 자른다).
    static func buildRouteContext(noteBody: String, maxChars: Int = 4000) -> String

    /// Claude stdout에서 첫 {…} JSON 블록을 추출·디코드하고 id를 ParaFolder로 해석한다.
    /// 유효 id가 아니거나 파싱 실패면 nil.
    static func parseRouteSuggestion(_ stdout: String, destinations: [ParaFolder]) -> RouteSuggestion?
}
```

- `buildRoutePrompt`: 각 목적지를 `- <id> | <label> — <hint>` 한 줄로 나열하고, "위 목록에서 이 노트에 가장 알맞은 하나를 골라, 그 **id**와 한국어 한 줄 이유를 strict JSON `{\"id\":\"…\",\"reason\":\"…\"}`로만 답하라. 다른 텍스트 금지." 지시. id는 목적지의 `id.uuidString`.
- `buildRouteContext`: `noteBody`가 `maxChars` 초과면 앞부분만(잘림 표시 `\n…(생략)`).
- `parseRouteSuggestion`: stdout에서 첫 `{`부터 마지막 `}`까지(또는 코드펜스 내부) 추출 → `JSONDecoder().decode(RouteParse.self)` → `destinations.first { $0.id.uuidString == parsed.id }` → 있으면 `RouteSuggestion(folder:reason:)`, 없으면 nil. 디코드 실패도 nil.

> Process/Claude를 부르는 부분은 단위테스트하지 않는다(KordocWriteService·ClaudeService 관례). 위 세 함수만 테스트한다.

## 5. AppState 오케스트레이션 (`Sources/App/AppState.swift`)

상태:
```swift
var claudeRouteInProgress: Bool = false
var claudeRouteError: String? = nil
var autoTriggerClaudeRoute: Bool = false   // autoRoute 미매칭→시트 자동 호출 플래그
```

메서드:
```swift
/// PARA 볼트·폴더가 설정됐는지. 버튼 활성/가드용 순수 게이트.
func isParaRoutingConfigured() -> Bool {
    settings.paraVaultId != nil && !settings.paraFolders.isEmpty
        && vaults.contains { $0.id == settings.paraVaultId }
}

/// 본문을 Claude에 보내 PARA 제안을 받는다. 실패 시 claudeRouteError 세팅 후 nil.
@MainActor
func requestClaudeRoute(noteBody: String) async -> RouteSuggestion? {
    guard isParaRoutingConfigured() else {
        claudeRouteError = "설정에서 PARA 볼트와 폴더를 먼저 추가하세요."; return nil
    }
    claudeRouteError = nil
    claudeRouteInProgress = true
    defer { claudeRouteInProgress = false }
    let dests = settings.paraFolders
    let prompt = RouteHelper.buildRoutePrompt(destinations: dests)
    let context = RouteHelper.buildRouteContext(noteBody: noteBody)
    do {
        let out = try await claudeService.ask(prompt: prompt, context: context)
        if let s = RouteHelper.parseRouteSuggestion(out, destinations: dests) { return s }
        claudeRouteError = "Claude 제안을 해석하지 못했습니다. 직접 골라 주세요."
        return nil
    } catch {
        claudeRouteError = Self.claudeErrorMessage(error)  // Phase 4 헬퍼 재사용
        return nil
    }
}

/// PARA 볼트 객체(설정된 경우).
var paraVault: Vault? { vaults.first { $0.id == settings.paraVaultId } }
```

`autoRouteCurrentDocument()` 미매칭 분기 수정:
```swift
guard let rule = matchingRoutingRule(for: document), … else {
    if settings.claudeRoutingEnabled && isParaRoutingConfigured() {
        autoTriggerClaudeRoute = true   // 시트가 onAppear에서 소비해 자동 제안
    } else {
        showToast("No routing rule matches — opening Send dialog")
    }
    showSendToVault = true
    return
}
```
(자동 모드여도 시트를 띄워 제안→확인. 무단 이동 없음.)

## 6. UI

### 6.1 `SendToVaultSheet` — "Claude에게 맡기기" 버튼
Destination 섹션에, **단일 마크다운 전송이고 `isParaRoutingConfigured()`일 때** 버튼을 둔다(batch엔 미표시):
- 탭 → `claudeRouteInProgress`면 ProgressView·비활성 → `appState.requestClaudeRoute(noteBody: document.content)`:
  - 성공: `selectedVault = appState.paraVault`, `targetFolder = suggestion.folder.folder`, 로컬 `@State routeReason = suggestion.reason` 표시(캡션 "제안: <label> — <reason>").
  - 실패: `appState.claudeRouteError`를 캡션으로 표시(시트는 수동 그대로).
- `onAppear`: `appState.autoTriggerClaudeRoute`가 true면 false로 소비하고 위 동작을 자동 1회 실행(단일 마크다운·설정됨일 때).
- document 본문 출처: 현재 단일 전송 대상 문서(`appState.currentDocument` 또는 시트가 받는 문서). batch(`!appState.batchSendURLs.isEmpty`)면 버튼 자체를 숨긴다.

### 6.2 `VaultManagerView` — "PARA 라우팅" 섹션
- PARA 볼트 선택 Picker(`settings.paraVaultId`, 등록된 vault 중).
- 폴더 목록: 행마다 label/folder/hint 편집, 추가·삭제(이동/이름변경만, 삭제는 목록 항목 제거이지 파일 삭제 아님).
- "기본 구조 채우기" 버튼 → `settings.paraFolders = ParaFolder.legoSeed()`(기존이 있으면 확인 후 대체 또는 append — 기본은 비었을 때만 채우고, 차 있으면 추가).
- "자동 라우팅에 Claude 사용(기본 OFF)" 토글 → `settings.claudeRoutingEnabled`.

## 7. 에러·안전

- PARA 미설정: 버튼 비활성 + "설정에서 PARA 폴더를 먼저 추가하세요".
- ClaudeError(미로그인/크레딧/타임아웃/실패): `claudeErrorMessage`(Phase 4) 재사용해 캡션 표시.
- 제안 파싱 실패: "직접 골라 주세요" — 시트는 수동 선택 가능 상태로 둠.
- 무단 이동 없음: 제안은 시트 프리필일 뿐, 사용자가 Send를 눌러야 이동. 자동 모드도 시트로 제안→확인.
- 삭제 없음. 본문은 사용자 자신의 claude 구독으로 전송(Phase 4와 동일 신뢰 모델).

## 8. 테스트(Phase 게이트, 순수 함수만)

- `RouteHelper.buildRoutePrompt`: 모든 목적지의 id·label·hint가 프롬프트에 포함, strict JSON 지시 포함.
- `RouteHelper.buildRouteContext`: maxChars 이하 그대로, 초과 시 잘림.
- `RouteHelper.parseRouteSuggestion`:
  - 정상 JSON → 올바른 ParaFolder 해석.
  - 코드펜스/프로즈로 감싼 JSON → 추출 성공.
  - 목록에 없는 id → nil.
  - malformed/JSON 아님 → nil.
- `ParaFolder.legoSeed()`: 6개 항목·경로 정확.
- `AppState.isParaRoutingConfigured()`: 볼트+폴더 있을 때만 true(미설정·볼트 삭제 시 false).

게이트: 시작·종료 시 `swift test`로 기존 139개 + 신규 통과. (정식 Xcode 필요.)

## 9. 범위 밖(후속)

- Claude 제안 시 사용자가 시트에서 다른 PARA 폴더로 바꾸는 건 기존 Folder 픽커로 가능(별도 override UI 불필요).
- 규칙 자동학습·임베딩 기반 분류는 Phase 9(시맨틱+RAG).
- 오피스/PDF 자체의 PARA 라우팅(현재는 마크다운 노트 전송 대상).
- 다중 노트 일괄 Claude 라우팅(batch는 미표시).
