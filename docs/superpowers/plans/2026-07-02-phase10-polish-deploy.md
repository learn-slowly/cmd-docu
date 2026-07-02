# Phase 10 다듬기·배포 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** cmdALL 겉면 개명·신규 기능 단축키 4종·Tools 설정 탭·배타성 트랩 수정·0.9.0 DMG 산출물·문서 마무리로 Phase 10을 완결한다.

**Architecture:** 앱 동작 변경은 최소(단축키는 기존 `AppShortcut` 리맵 체계에 case 추가, Tools 탭은 기존 정적 리졸버 2개를 동기 호출해 표시만). 개명은 노출 문자열 리터럴 치환 + 패키징 스크립트의 번들명/실행파일명 변수 분리(내부 식별자 전부 불변 — 데이터 마이그레이션 없음).

**Tech Stack:** Swift 5.9+/SwiftUI, SPM, XCTest, bash(package/dmg 스크립트), GitHub Actions(release.yml).

**Spec:** `docs/superpowers/specs/2026-07-02-phase10-polish-deploy-design.md`

## Global Constraints

- 비샌드박스 유지. kordoc·claude는 `Process` 호출 대상 — 직접 구현 금지.
- **변경 금지 식별자**: 번들ID `work.cmdspace.cmddocu`, SPM 타깃·바이너리명 `CmdMD`, `CFBundleExecutable=CmdMD`, URL 스킴 `cmdmd`, 데이터 디렉터리 `Application Support/CmdMD`.
- **치환 금지 URL**(저장소 주소): `github.com/repos/learn-slowly/cmd-docu/...`, `github.com/learn-slowly/cmd-docu...` — `cmd-docu`가 포함돼도 그대로 둔다.
- 새 앱 표시명: `cmdALL`. 새 버전: `0.9.0`.
- Phase 게이트: 작업 시작 전과 완료 후 `swift test` — 기존 382개(XCTest 364+Testing 18) 유지. `swift test`는 정식 Xcode 필요.
- 코드 주석·커밋 메시지는 한국어. '박다/박는다/박았다' 류 표현 금지.
- 파일 삭제 없음. 커밋은 태스크마다.

---

### Task 0: 베이스라인 게이트

**Files:** 없음 (검증만)

- [ ] **Step 1: 기존 테스트 전부 통과 확인**

Run: `cd /Users/ahbaik/coding/cmd-docu && swift test 2>&1 | tail -5`
Expected: 382개 테스트 통과(XCTest 364 + Swift Testing 18), 실패 0. 실패가 있으면 **작업을 멈추고 보고**(이번 변경과 무관한 회귀를 먼저 격리).

---

### Task 1: 단축키 4종 (AppShortcut 확장 + 메뉴 배선)

**Files:**
- Modify: `Sources/Models/Shortcuts.swift` (case 4개·title·defaultBinding)
- Modify: `Sources/App/CmdMDApp.swift` (Find 메뉴 항목 2개 신설, View 메뉴 토글 1개 신설, 기존 폴더 정리 항목에 단축키 부착)
- Test: `Tests/CmdMDTests/ShortcutDefaultsTests.swift` (신규)

**Interfaces:**
- Consumes: `AppState.keyBinding(for:)`(`settings.keyBindings[rawValue] ?? defaultBinding` — 새 case는 자동 폴백), `View.appShortcut(_:)`, AppState 플래그 `showIndexSearch`/`showAskCorpus`/`mainMode`/`resetCleanup()`+`showFolderCleanup`.
- Produces: `AppShortcut.indexSearch`/`.askCorpus`/`.toggleLibraryMode`/`.folderCleanup` (rawValue 동일 문자열). Shortcuts 설정 탭은 `ForEach(AppShortcut.allCases)`라 자동 노출.

- [ ] **Step 1: 실패하는 테스트 작성**

`Tests/CmdMDTests/ShortcutDefaultsTests.swift` 신규:

```swift
import XCTest
@testable import CmdMD

/// Phase 10 신규 단축키 4종의 기본값과, 리맵 기본값끼리의 중복 부재를 고정한다.
/// (하드코딩 단축키와의 충돌은 enum 밖이라 설계 단계 수동 검증으로 갈음 — 스펙 §2·§5)
final class ShortcutDefaultsTests: XCTestCase {
    func testPhase10ShortcutDefaults() {
        XCTAssertEqual(AppShortcut.indexSearch.defaultBinding,
                       KeyBinding(key: "f", command: true, option: true))
        XCTAssertEqual(AppShortcut.askCorpus.defaultBinding,
                       KeyBinding(key: "a", command: true, option: true))
        XCTAssertEqual(AppShortcut.toggleLibraryMode.defaultBinding,
                       KeyBinding(key: "l", command: true, shift: true))
        XCTAssertEqual(AppShortcut.folderCleanup.defaultBinding,
                       KeyBinding(key: "k", command: true, option: true))
    }

    func testDefaultBindingsAreUnique() {
        let bindings = AppShortcut.allCases.map(\.defaultBinding)
        XCTAssertEqual(Set(bindings).count, bindings.count,
                       "AppShortcut 기본 바인딩이 서로 겹칩니다")
    }
}
```

- [ ] **Step 2: 실패 확인**

Run: `swift test --filter ShortcutDefaultsTests 2>&1 | tail -5`
Expected: 컴파일 실패 — `type 'AppShortcut' has no member 'indexSearch'` 류.

- [ ] **Step 3: AppShortcut에 case 4개 구현**

`Sources/Models/Shortcuts.swift` — enum 본문의 `case askClaude` 아래에 추가:

```swift
    case indexSearch
    case askCorpus
    case toggleLibraryMode
    case folderCleanup
```

`title` switch의 `case .askClaude: return "Ask Claude"` 아래에 추가:

```swift
        case .indexSearch:       return "Search Index (내용 검색)"
        case .askCorpus:         return "Ask Corpus (자료에 묻기)"
        case .toggleLibraryMode: return "Toggle Reader/Library"
        case .folderCleanup:     return "Folder Cleanup (폴더 정리)"
```

`defaultBinding` switch의 `case .askClaude: …` 아래에 추가:

```swift
        case .indexSearch:       return KeyBinding(key: "f", command: true, option: true)
        case .askCorpus:         return KeyBinding(key: "a", command: true, option: true)
        case .toggleLibraryMode: return KeyBinding(key: "l", command: true, shift: true)
        case .folderCleanup:     return KeyBinding(key: "k", command: true, option: true)
```

- [ ] **Step 4: 테스트 통과 확인**

Run: `swift test --filter ShortcutDefaultsTests 2>&1 | tail -5`
Expected: 2개 테스트 PASS.

- [ ] **Step 5: 메뉴 배선 — Find 메뉴**

`Sources/App/CmdMDApp.swift`의 `CommandMenu("Find")` 안, "Find in Folder..." 버튼(`.keyboardShortcut("f", modifiers: [.command, .shift])`로 끝나는 블록) 바로 아래에 추가:

```swift
                Divider()

                Button("내용 검색 (인덱스)...") {
                    appState.showIndexSearch = true
                }
                .appShortcut(appState.keyBinding(for: .indexSearch))

                Button("자료에 묻기 (RAG)...") {
                    appState.showAskCorpus = true
                }
                .appShortcut(appState.keyBinding(for: .askCorpus))
```

- [ ] **Step 6: 메뉴 배선 — View 메뉴**

같은 파일 `CommandMenu("View")` 안:

(a) "Preview Only" 버튼 블록(`.appShortcut(appState.keyBinding(for: .previewMode))`) 바로 아래에 추가:

```swift
                Button("Toggle Reader/Library") {
                    appState.mainMode = appState.mainMode == .reader ? .library : .reader
                }
                .appShortcut(appState.keyBinding(for: .toggleLibraryMode))
```

(b) 기존 "폴더 정리 (배치)" 버튼에 단축키 부착 — 현행:

```swift
                Button("폴더 정리 (배치)") {
                    appState.resetCleanup()
                    appState.showFolderCleanup = true
                }
```

을 다음으로 변경(액션 불변, modifier만 추가):

```swift
                Button("폴더 정리 (배치)") {
                    appState.resetCleanup()
                    appState.showFolderCleanup = true
                }
                .appShortcut(appState.keyBinding(for: .folderCleanup))
```

- [ ] **Step 7: 빌드·전체 테스트**

Run: `swift build 2>&1 | tail -3 && swift test 2>&1 | tail -5`
Expected: 빌드 경고 0 유지, 기존 382 + 신규 2 = 384개 통과.

- [ ] **Step 8: 커밋**

```bash
git add Sources/Models/Shortcuts.swift Sources/App/CmdMDApp.swift Tests/CmdMDTests/ShortcutDefaultsTests.swift
git commit -m "기능(단축키): 신규 기능 4종 리맵 단축키 — 내용검색 ⌥⌘F·RAG ⌥⌘A·리더⇄라이브러리 ⇧⌘L·폴더정리 ⌥⌘K (⇧⌘F는 Find in Folder 선점이라 회피, 기본값 중복 부재 테스트)"
```

---

### Task 2: Tools 설정 탭

**Files:**
- Modify: `Sources/Views/SettingsView.swift` (6번째 탭 + `ToolsSettingsView` struct — 기존 탭 뷰들과 같은 파일 관례)

**Interfaces:**
- Consumes: `KordocService.resolveNpxPath() -> String?`(static·동기), `ClaudeService.resolveClaudePath() -> String?`(static·동기), `settings.claudeRoutingEnabled: Bool`, `settings.ragExpandQuery: Bool`, `settings.indexedFolders: [String]`, `appState.showIndexSearch`.
- Produces: 없음 (말단 뷰).

- [ ] **Step 1: 탭 등록**

`SettingsView.swift`의 `TabView` 안, `VaultSettingsView` `.tabItem` 블록 아래에 추가:

```swift
            ToolsSettingsView()
                .tabItem {
                    Label("Tools", systemImage: "wrench.and.screwdriver")
                }
```

- [ ] **Step 2: ToolsSettingsView 구현**

같은 파일 말미에 추가(경로 탐지는 열 때·새로고침 시에만 — 외부 프로세스 실행 없음, 스펙 §3 A안):

```swift
// MARK: - Tools (외부 CLI 상태·신규 기능 설정 통합)

/// kordoc·claude CLI 탐지 상태와 신규 기능(라우팅·검색 인덱스·RAG) 설정을 한 곳에 모은 탭.
/// 경로 탐지는 동기 리졸버만 호출한다(프로세스 실행·버전 프로브 없음 — 스펙 §3).
struct ToolsSettingsView: View {
    @Environment(AppState.self) private var appState

    @State private var kordocPath: String?
    @State private var claudePath: String?

    var body: some View {
        @Bindable var state = appState

        Form {
            Section {
                toolStatusRows(name: "kordoc (npx)", path: kordocPath,
                               missingHint: "미설치 — Node 18+와 npx가 필요합니다. 한글·오피스 문서 읽기/쓰기가 비활성화됩니다.")
            } header: {
                Text("kordoc")
            }

            Section {
                toolStatusRows(name: "claude CLI", path: claudePath,
                               missingHint: "미설치 — Claude 연동(패널·라우팅·RAG·폴더 정리)이 비활성화됩니다.")
                Toggle("Claude 스마트 라우팅 (PARA)", isOn: $state.settings.claudeRoutingEnabled)
                Text("볼트로 보낼 때 규칙에 안 맞으면 Claude가 PARA 폴더를 제안합니다. (Vault Manager의 PARA 탭과 같은 설정)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Claude")
            }

            Section {
                if appState.settings.indexedFolders.isEmpty {
                    Text("등록된 폴더 없음")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(appState.settings.indexedFolders, id: \.self) { path in
                        Text(path)
                            .font(.callout)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Toggle("질의 확장 (RAG)", isOn: $state.settings.ragExpandQuery)
                Button("내용 검색 열기…") {
                    appState.showIndexSearch = true
                }
            } header: {
                Text("검색 인덱스")
            } footer: {
                Text("폴더 등록·해제는 내용 검색 창에서 합니다. 질의 확장은 자료에 묻기(RAG)가 검색어를 넓히는 옵션입니다.")
                    .font(.caption)
            }

            Section {
                Button("상태 새로고침") { refresh() }
            }
        }
        .formStyle(.grouped)
        .onAppear { refresh() }
    }

    /// 경로를 찾으면 모노스페이스로, 못 찾으면 "미설치"와 안내 캡션을 표시한다.
    @ViewBuilder
    private func toolStatusRows(name: String, path: String?, missingHint: String) -> some View {
        LabeledContent(name) {
            if let path {
                Text(path)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text("미설치")
                    .foregroundStyle(.orange)
            }
        }
        if path == nil {
            Text(missingHint)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func refresh() {
        kordocPath = KordocService.resolveNpxPath()
        claudePath = ClaudeService.resolveClaudePath()
    }
}
```

- [ ] **Step 3: 빌드·전체 테스트** (뷰 전용 태스크 — 단위 테스트 없음, 검증은 수동 스모크 몫)

Run: `swift build 2>&1 | tail -3 && swift test 2>&1 | tail -5`
Expected: 빌드 경고 0, 384개 통과.

- [ ] **Step 4: 커밋**

```bash
git add Sources/Views/SettingsView.swift
git commit -m "기능(설정): Tools 탭 — kordoc·claude CLI 탐지 상태(동기 경로 표시+새로고침)와 라우팅·검색 인덱스·RAG 설정 통합(기존 시트 바인딩 재사용, 프로세스 실행 없음)"
```

---

### Task 3: VaultManagerView 배타성 트랩 수정

**Files:**
- Modify: `Sources/Views/VaultManagerView.swift` (약 :660 — 라우팅 규칙 조건 삭제 버튼)

**Interfaces:** 없음 (지역 수정).

**배경:** `ForEach($rule.conditions) { $condition in … }`의 바인딩 요소 `condition`을 `rule.conditions.removeAll`(쓰기 접근) 술어 클로저 안에서 재읽기 — 버킷 삭제 즉사(b0dce58)와 동형인 Swift 배타적 접근 위반. 트랩은 러너 프로세스를 죽이므로 스위트 내 회귀 테스트 불가(스펙 §4) — 코드 검증 + 수동 스모크로 확인한다.

- [ ] **Step 1: 동형 여부 최종 확인**

`VaultManagerView.swift` 약 :640-665를 읽고 다음 구조인지 확인: `ForEach($rule.conditions) { $condition in` 안에서 `Button { rule.conditions.removeAll { $0.id == condition.id } }`. 확인되면 Step 2로. 만약 구조가 다르면(값 복사 요소 등) 수정하지 말고 근거를 커밋 메시지 없이 보고로 남긴다.

- [ ] **Step 2: id를 removeAll 술어 밖으로 hoist**

현행:

```swift
                            Button {
                                rule.conditions.removeAll { $0.id == condition.id }
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
```

변경(배타적 접근이 시작되기 전에 id를 값으로 복사 — 버킷 삭제와 동일한 수정):

```swift
                            Button {
                                // 배타적 접근 위반 방지: removeAll(쓰기 접근) 중에 바인딩 요소
                                // condition을 재읽기하면 즉사한다(버킷 삭제 b0dce58과 동형).
                                let conditionID = condition.id
                                rule.conditions.removeAll { $0.id == conditionID }
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
```

- [ ] **Step 3: 빌드 확인**

Run: `swift build 2>&1 | tail -3`
Expected: 성공, 경고 0.

- [ ] **Step 4: 커밋**

```bash
git add Sources/Views/VaultManagerView.swift
git commit -m "수정(볼트): 라우팅 조건 삭제의 잠재 즉사 — removeAll 쓰기 접근 중 바인딩 요소 재읽기(버킷 삭제 b0dce58 동형)를 id hoist로 회피"
```

---

### Task 4: 소스 개명 치환 (cmd-docu → cmdALL) + 버전 폴백

**Files:**
- Modify: `Sources/App/CmdMDApp.swift`(:24, :284), `Sources/App/AppState.swift`(:226, :631), `Sources/Views/SettingsView.swift`(:136, :138, :142), `Sources/Views/MenuBarView.swift`(:18), `Sources/Views/MainEditorView.swift`(:416), `Sources/Views/ContentView.swift`(:317, :423 버전 폴백, :464), `Sources/Models/Brand.swift`(:112, :139 주석)
- Test: `Tests/CmdMDTests/AppWindowTitleTests.swift`(:23 어서션 갱신)

**Interfaces:** 없음 (표시 문자열만 — 로직·식별자 불변).

- [ ] **Step 1: 테스트 어서션 먼저 갱신 (RED)**

`Tests/CmdMDTests/AppWindowTitleTests.swift:23`:

```swift
        XCTAssertEqual(appState.windowTitle, "cmdALL")
```

Run: `swift test --filter AppWindowTitleTests 2>&1 | tail -5`
Expected: FAIL — `("cmd-docu") is not equal to ("cmdALL")`.

- [ ] **Step 2: 노출 문자열 치환 (GREEN)**

각 파일에서 아래와 같이 변경(**저장소 URL 3곳은 건드리지 않는다** — Global Constraints):

| 파일 | 현행 | 변경 |
|---|---|---|
| CmdMDApp.swift:24 | `Button("About cmd-docu")` | `Button("About cmdALL")` |
| CmdMDApp.swift:284 | `MenuBarExtra("cmd-docu", systemImage: "book.fill")` | `MenuBarExtra("cmdALL", systemImage: "book.fill")` |
| AppState.swift:226 | `return "cmd-docu"` | `return "cmdALL"` |
| AppState.swift:631 | `request.setValue("cmd-docu", forHTTPHeaderField: "User-Agent")` | `request.setValue("cmdALL", forHTTPHeaderField: "User-Agent")` |
| SettingsView.swift:136 | `Label("cmd-docu (GitHub)", …)` | `Label("cmdALL (GitHub)", …)` |
| SettingsView.swift:138 | `Button("About cmd-docu…")` | `Button("About cmdALL…")` |
| SettingsView.swift:142 | `Text("cmd-docu — CmdMD(© 2026 CMDSPACE) 포크 · MIT License")` | `Text("cmdALL — CmdMD(© 2026 CMDSPACE) 포크 · MIT License")` |
| MenuBarView.swift:18 | `Label("Open cmd-docu", systemImage: "macwindow")` | `Label("Open cmdALL", systemImage: "macwindow")` |
| MainEditorView.swift:416 | `Text("cmd-docu")` | `Text("cmdALL")` |
| ContentView.swift:317 | `Text("Welcome to cmd-docu")` | `Text("Welcome to cmdALL")` |
| ContentView.swift:464 | `Text("cmd-docu")` | `Text("cmdALL")` |
| Brand.swift:112 | `/// cmd-docu 마크 색(슬레이트 → 앰버). …` | `/// cmdALL 마크 색(슬레이트 → 앰버). …` |
| Brand.swift:139 | `/// cmd-docu 캐노니컬 마크: …` | `/// cmdALL 캐노니컬 마크: …` |

- [ ] **Step 3: swift run용 버전 폴백 갱신**

`Sources/Views/ContentView.swift:423`(`AppInfo.version` — 패키징 안 된 실행에서 Info.plist가 없을 때의 폴백):

```swift
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.9.0"
```

- [ ] **Step 4: 잔존 확인 + 테스트 통과**

Run: `grep -rn "cmd-docu" Sources/ Tests/ --include="*.swift"`
Expected: 정확히 4곳만 남음 — `AppState.swift`의 GitHub API/릴리스 URL 2곳, `ContentView.swift`의 GitHub URL 1곳(모두 저장소 주소), `RagPassageExtractorTests.swift:43`(테스트 데이터 본문 — 유지).

Run: `swift test 2>&1 | tail -5`
Expected: 384개 전부 통과(AppWindowTitleTests 포함).

- [ ] **Step 5: 커밋**

```bash
git add Sources/ Tests/
git commit -m "개명(겉면): 노출 문자열 cmd-docu→cmdALL 12곳+주석 2곳, swift run 버전 폴백 0.9.0 — 번들ID·바이너리명·URL스킴·데이터경로·저장소 URL 불변(스펙 §1.1)"
```

---

### Task 5: 스크립트·CI 개명·버전 0.9.0 + 패키징·DMG 검증

**Files:**
- Modify: `scripts/package_app.sh`, `scripts/make_dmg.sh`, `scripts/test_package_app.sh`, `scripts/sign_and_notarize.sh`, `.github/workflows/release.yml`

**Interfaces:**
- Produces: `dist/cmdALL.app`(실행파일은 `Contents/MacOS/CmdMD`), `dist/cmdALL-macos.zip`, `dist/cmdALL-0.9.0.dmg`. release.yml은 이 이름들을 소비.

- [ ] **Step 1: package_app.sh — 번들명/실행파일명 분리 + 표시명·버전**

상단 변수 블록을 다음으로 변경(현행은 `APP_NAME="CmdMD"` 하나가 번들명·실행파일명 겸용):

```bash
# 앱 번들 이름(겉면)과 실행파일 이름(내부 식별자)을 분리한다.
# 실행파일·CFBundleExecutable은 CmdMD 유지 — 데이터 디렉터리(Application
# Support/CmdMD)·업스트림 머지와 얽힌 내부 이름은 바꾸지 않는다(스펙 §1).
BUNDLE_NAME="cmdALL"
EXECUTABLE_NAME="CmdMD"
DIST_DIR="$ROOT_DIR/dist"
APP_DIR="$DIST_DIR/$BUNDLE_NAME.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
EXECUTABLE="$MACOS_DIR/$EXECUTABLE_NAME"
PLIST="$CONTENTS_DIR/Info.plist"
APP_ICON="$ROOT_DIR/Resources/AppIcon.icns"
ZIP_FILE="$DIST_DIR/$BUNDLE_NAME-macos.zip"
```

본문에서 옛 `$APP_NAME` 사용처를 정리:
- `echo "Building $APP_NAME release..."` → `echo "Building $BUNDLE_NAME release..."`
- `BUILT_EXECUTABLE="$BUILD_BIN_DIR/$APP_NAME"` → `BUILT_EXECUTABLE="$BUILD_BIN_DIR/$EXECUTABLE_NAME"` (swift build 산출 바이너리는 CmdMD)
- `echo "Ad-hoc signing $APP_NAME.app..."` → `echo "Ad-hoc signing $BUNDLE_NAME.app..."`
- zip 생성부 `zip -qry -X "$(basename "$ZIP_FILE")" "$APP_NAME.app"` → `"$BUNDLE_NAME.app"`

Info.plist heredoc에서 3줄 변경:
- `<key>CFBundleDisplayName</key>` 값 `<string>cmd-docu</string>` → `<string>cmdALL</string>`
- `<key>CFBundleName</key>` 값 `<string>cmd-docu</string>` → `<string>cmdALL</string>`
- `<key>CFBundleShortVersionString</key>` 값 `<string>0.8.5</string>` → `<string>0.9.0</string>`

유지 확인: `CFBundleExecutable=CmdMD`, `CFBundleIdentifier=work.cmdspace.cmddocu`, URL 스킴 `cmdmd`.

- [ ] **Step 2: make_dmg.sh — 기본 경로·볼륨·산출물명**

```bash
APP="${1:-dist/cmdALL.app}"
```

```bash
VOL_NAME="cmdALL ${VERSION}"
DMG="${2:-dist/cmdALL-${VERSION}.dmg}"

echo "==> Building DMG for cmdALL ${VERSION}"
```

헤더 주석의 `CmdMD.app`/`CmdMD-<version>.dmg` 언급도 `cmdALL.app`/`cmdALL-<version>.dmg`로 갱신.

- [ ] **Step 3: test_package_app.sh — 검증 경로 갱신**

```bash
APP_DIR="$DIST_DIR/cmdALL.app"
EXECUTABLE="$APP_DIR/Contents/MacOS/CmdMD"
PLIST="$APP_DIR/Contents/Info.plist"
ZIP_FILE="$DIST_DIR/cmdALL-macos.zip"
```

(실행파일은 CmdMD 유지 — 검증도 그 이름을 본다. cmdmd URL 스킴·NSPrincipalClass·Highlightr 번들 검증은 무수정.)

- [ ] **Step 4: sign_and_notarize.sh — 경로 일관성 갱신** (공증 실행은 비목표, 이름만)

- :2-3 주석의 `CmdMD` → `cmdALL`(산출물 설명)
- `APP="dist/CmdMD.app"` → `APP="dist/cmdALL.app"`
- `DMG="dist/CmdMD-${VERSION}.dmg"` → `DMG="dist/cmdALL-${VERSION}.dmg"`
- :67 zip 재생성 줄 → `( cd dist && rm -f cmdALL-macos.zip && ditto -c -k --sequesterRsrc --keepParent cmdALL.app cmdALL-macos.zip )`
- :73 완료 echo의 `dist/CmdMD-macos.zip` → `dist/cmdALL-macos.zip`

- [ ] **Step 5: release.yml — 산출물명 갱신**

- checksums 스텝: `shasum -a 256 CmdMD-macos.zip CmdMD-*.dmg > SHA256SUMS.txt` → `shasum -a 256 cmdALL-macos.zip cmdALL-*.dmg > SHA256SUMS.txt`
- release files: `dist/CmdMD-macos.zip`·`dist/CmdMD-*.dmg` → `dist/cmdALL-macos.zip`·`dist/cmdALL-*.dmg`
- 버전-태그 체크 스텝은 `CFBundleShortVersionString` grep이라 무수정 동작 확인만.

- [ ] **Step 6: 기타 스크립트 이름 언급 확인** (스펙 §1.2 마지막 항목)

Run: `grep -rn "CmdMD\|cmd-docu" scripts/ | grep -v "package_app\|make_dmg\|test_package\|sign_and_notarize"`
확인 기준: `fix-highlightr-bundle.py`·`vendor_web_assets.sh`·`make_icon.swift` 등에 남는 `CmdMD` 언급은 **빌드 내부 식별자**(바이너리명·번들 경로)라 유지가 맞다. 사용자 노출 산출물 이름(파일명·볼륨명·표시명)에 해당하는 것만 있으면 cmdALL로 갱신 — 예상은 0건.

- [ ] **Step 7: 패키징 실행 검증** (릴리스 빌드 포함 — 수 분 소요)

Run: `bash scripts/test_package_app.sh 2>&1 | tail -5`
Expected: `PASS: package app artifact checks passed`, `dist/cmdALL.app`·`dist/cmdALL-macos.zip` 생성.

- [ ] **Step 8: DMG 생성·번들 메타 검증**

Run: `bash scripts/make_dmg.sh && ls -lh dist/*.dmg`
Expected: `dist/cmdALL-0.9.0.dmg` 생성.

Run:
```bash
/usr/libexec/PlistBuddy -c 'Print :CFBundleDisplayName' -c 'Print :CFBundleName' -c 'Print :CFBundleExecutable' -c 'Print :CFBundleShortVersionString' -c 'Print :CFBundleIdentifier' dist/cmdALL.app/Contents/Info.plist
```
Expected(순서대로): `cmdALL` / `cmdALL` / `CmdMD` / `0.9.0` / `work.cmdspace.cmddocu`.

- [ ] **Step 9: 커밋** (dist/는 커밋하지 않는다)

```bash
git add scripts/package_app.sh scripts/make_dmg.sh scripts/test_package_app.sh scripts/sign_and_notarize.sh .github/workflows/release.yml
git commit -m "배포(개명·버전): 패키징 산출물 cmdALL.app·cmdALL-macos.zip·cmdALL-<ver>.dmg, 표시명 cmdALL·버전 0.9.0 — 번들명/실행파일명(CmdMD) 변수 분리, 번들ID·스킴 불변, CI 산출물명 동기화"
```

---

### Task 6: README 갱신

**Files:**
- Modify: `README.md`

**Interfaces:** 없음 (문서).

- [ ] **Step 1: 이름·설치 섹션 갱신** — 아래 항목을 각각 치환(저장소 URL·업스트림 링크는 유지):

1. 제목: `# CmdMD` → `# cmdALL`
2. 포크 고지(현행 `> **이 저장소는 [CmdMD](https://github.com/johnfkoo951/CmdMD)(MIT, 구요한/CMDSPACE)의 포크 \`cmd-docu\`입니다.**`)를 다음으로:

```markdown
> **이 저장소는 [CmdMD](https://github.com/johnfkoo951/CmdMD)(MIT, 구요한/CMDSPACE)의 포크 `cmdALL`입니다(저장소명은 `cmd-docu`).**
```

3. Install 섹션의 산출물 이름:
   - `**\`CmdMD-<version>.dmg\`** — open it and drag \`CmdMD.app\` onto …` → `**\`cmdALL-<version>.dmg\`** — open it and drag \`cmdALL.app\` onto …`
   - `**\`CmdMD-macos.zip\`** — unzip and move \`CmdMD.app\` to /Applications …` → `**\`cmdALL-macos.zip\`** — unzip and move \`cmdALL.app\` to /Applications …`
   - `xattr -dr com.apple.quarantine /Applications/CmdMD.app` → `xattr -dr com.apple.quarantine /Applications/cmdALL.app`
4. Build from source 출력 주석: `# → dist/CmdMD.app + dist/CmdMD-macos.zip` → `# → dist/cmdALL.app + dist/cmdALL-macos.zip`
5. 테스트 수치: `grep -n "382" README.md`로 찾아 실측(Task 4 완료 시점 `swift test` 수치, 384 예상)으로 갱신.
6. 유지: 아이콘 alt·hero 이미지 라벨(이미지 자산은 재생성 비목표), `Why CmdMD` 섹션(업스트림 제품 설명), 데이터 경로 문구 `~/Library/Application Support/CmdMD/`(내부 이름 불변 — 사실 그대로).

- [ ] **Step 2: 확인**

Run: `grep -n "CmdMD.app\|CmdMD-macos\|CmdMD-<version>" README.md`
Expected: 0건(전부 cmdALL 이름으로 갱신됨).

- [ ] **Step 3: 커밋**

```bash
git add README.md
git commit -m "문서(README): cmdALL 개명 반영 — 제목·포크 고지·DMG/zip 설치 파일명·xattr 경로·빌드 출력·테스트 수치, 업스트림 고지·데이터 경로 문구는 유지"
```

---

### Task 7: CLAUDE.md·PRD 완료 기록 + 데일리 로그

**Files:**
- Modify: `CLAUDE.md`(현재 상태·다음 액션), `CmdMD-fork_prd.md`(:15 상태 줄, :239 Phase 10 줄), `cmd-docu_개선작업_문서.md`(:7 진행 상황, :148 6번 항목)
- Modify: `/Users/ahbaik/coding/notebox/Calendar/2026-07-02.md`(있을 때만 — 줄 추가만)

**Interfaces:** 없음 (문서).

- [ ] **Step 1: CLAUDE.md 갱신**

「현재 상태」끝에 Phase 10 완료 항목 추가 — 형식은 기존 항목과 동일하게 한 문단: 겉면 개명(cmdALL — 노출 문자열 12곳+주석, 번들ID·바이너리 CmdMD·스킴·데이터경로 불변), 단축키 4종(⌥⌘F·⌥⌘A·⇧⌘L·⌥⌘K, ⇧⌘F 선점 회피, 기본값 유일성 테스트), Tools 설정 탭(동기 경로 표시), VaultManagerView 배타성 트랩 hoist 수정, 패키징 0.9.0(cmdALL.app·zip·DMG, CI 동기화), README 갱신, 테스트 수치(실측). 「다음 액션」줄을 갱신: 남은 별건 = 볼트용 LLM-Wiki 스키마(요청 시), Phase 9 후속 선택지(시맨틱 A안·RAG 스트리밍·답변 마크다운 렌더·AskCorpusView 리사이즈), 수동 스모크(DMG 설치·개명 표시·단축키·Tools 탭·조건 삭제).

- [ ] **Step 2: PRD·개선작업 문서 완료 표기**

- `CmdMD-fork_prd.md:15`: `Phase 0~9 완료(2026-07-01), Phase 10(다듬기·배포) 남음` → `Phase 0~10 완료(2026-07-02)`
- `CmdMD-fork_prd.md:239`: Phase 10 줄 끝에 ` — **완료(2026-07-02)**: cmdALL 겉면 개명·단축키 4종·Tools 설정 탭·0.9.0 DMG·README 갱신.` 추가
- `cmd-docu_개선작업_문서.md:7`·`:148`: 6번(개명) 항목 완료 표기 — `**← 유일하게 남은 항목, Phase 10 다듬기·배포와 함께.**` → `**완료(2026-07-02, Phase 10) — 겉면 개명(cmdALL): 표시명·.app 파일명·README. 내부 식별자(CmdMD·번들ID·스킴·데이터경로)는 유지.**`

- [ ] **Step 3: 데일리 로그** (파일이 있을 때만, 줄 추가만 — 기존 내용 수정·삭제 금지)

`/Users/ahbaik/coding/notebox/Calendar/2026-07-02.md`의 `## ✅ 오늘 한 일 #daily_donelist` 섹션 안 `**개발**` 소제목 아래(없으면 섹션 끝에 소제목 신설):

```markdown
- [cmd-docu] Phase 10 다듬기·배포 완료 — cmdALL 겉면 개명·신규 단축키 4종·Tools 설정 탭·배타성 트랩 수정·0.9.0 DMG 패키징 (다음: DMG 설치 수동 스모크, 남은 별건은 LLM-Wiki 스키마·Phase 9 후속 선택지)
```

- [ ] **Step 4: 최종 게이트 + 커밋**

Run: `swift test 2>&1 | tail -3`
Expected: 384개 통과.

```bash
git add CLAUDE.md CmdMD-fork_prd.md cmd-docu_개선작업_문서.md
git commit -m "문서: Phase 10 완료 기록 — CLAUDE.md 상태·다음 액션, PRD·개선작업 문서 완료 표기"
```

---

## 수동 스모크 (구현 완료 후 사용자)

- `dist/cmdALL-0.9.0.dmg` 마운트 → /Applications 드래그 → 실행(로컬 생성이라 quarantine 없음)
- 개명: 메뉴바·Dock·About·Welcome·라이브러리 히어로에 cmdALL 표시, 기존 설정·세션·인덱스 그대로 열림(데이터 경로 불변 확인)
- 단축키: ⌥⌘F 내용 검색, ⌥⌘A 자료에 묻기, ⇧⌘L 리더⇄라이브러리, ⌥⌘K 폴더 정리 + Shortcuts 탭에 4개 등장·리맵 동작
- Tools 탭: kordoc·claude 경로 표시, 새로고침, 라우팅·RAG 토글이 기존 화면과 동기화, 인덱스 폴더 목록
- VaultManager 라우팅 규칙 조건 삭제(minus.circle) 클릭 — 즉사 없음
