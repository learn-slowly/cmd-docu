# Phase 4 — Claude 연동 (`claude -p`) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 열린 문서(또는 마크다운 선택영역)를 프롬프트와 함께 로컬 `claude` CLI(`claude -p`)에 보내고 응답을 전용 사이드 패널에 표시한다.

**Architecture:** `KordocService`와 동일한 `actor` + `Process` 패턴으로 `ClaudeService`를 만든다. 순수 함수(에러 분류·입력 조립·컨텍스트 선택)는 단위 테스트하고, 실제 CLI 호출은 통합 동작으로 둔다(테스트 안 함). UI는 `ContentView`의 트레일링 리사이즈 컬럼으로 추가해 기존 `.inspector`와 공존시킨다.

**Tech Stack:** Swift 5.9+ / SwiftUI, SPM, macOS 14+, XCTest, `Process`로 외부 `claude` CLI.

## Global Constraints

- 비샌드박스 유지 — 서브프로세스 호출이 막히면 안 됨.
- `claude`는 직접 구현하지 않음 — `Process`로 호출, 결과(stdout)만 받음. 경로 탐지 실패 시 안내만, 크래시 금지.
- Phase 게이트 — 시작·종료 시 `swift test`로 기존 95개 테스트 유지(정식 Xcode 필요; CLT는 `swift build`만).
- 이번 Phase는 읽기·표시만 — 파일 이동/변경 없음(제안→확인 게이트 비해당).
- 신규 기능은 별도 파일로 분리해 업스트림(CmdMD) 머지를 쉽게.
- 코드 주석·커밋 메시지 한국어. '박다' 류 표현 금지. LICENSE·원작자 고지 유지.
- 응답 저장(노트 삽입/볼트)·스트리밍은 이번 범위 밖(후속 Phase).
- 테스트: XCTest, `@testable import CmdMD`. 순수 static 헬퍼는 직접 호출해 검증(`AppState.filenameMatch` 패턴).

## File Structure

- `Sources/Services/ClaudeService.swift` (생성) — `actor ClaudeService`, `enum ClaudeError`, 순수 `classify`/`makeInput`/`resolveClaudePath`, async `ask`.
- `Sources/Views/ClaudePanelView.swift` (생성) — 전용 사이드 패널 UI.
- `Sources/App/AppState.swift` (수정) — claude 상태 변수, `claudeService` 인스턴스, 순수 `claudeContext`/`claudeErrorMessage`, `askClaude()`.
- `Sources/Models/Shortcuts.swift` (수정) — `AppShortcut.askClaude` 케이스.
- `Sources/Views/ContentView.swift` (수정) — 트레일링 Claude 컬럼 + 리사이즈 디바이더.
- `Sources/Views/CommandPaletteView.swift` (수정) — "Ask Claude" 커맨드.
- `Sources/App/CmdMDApp.swift` (수정) — View 메뉴 "Ask Claude" 버튼.
- `Sources/Views/EditorTextView.swift` (수정) — `onSelectedTextChange` 콜백.
- `Sources/Views/MainEditorView.swift` (수정) — 선택영역 → `appState.currentSelectionText` 배선.
- `Tests/CmdMDTests/ClaudeServiceTests.swift` (생성) — `classify`/`makeInput` 테스트.
- `Tests/CmdMDTests/AppClaudeTests.swift` (생성) — `claudeContext`/`claudeErrorMessage`/`AppShortcut.askClaude` 테스트.

---

### Task 0: Phase 게이트 기준선 확인

- [ ] **Step 1: 기존 테스트 통과 확인**

Run: `swift test 2>&1 | tail -5`
Expected: 95개 테스트 통과(실패 0). 실패하면 멈추고 원인 보고.

---

### Task 1: ClaudeService — 에러 타입 + 순수 분류기/입력 조립기

**Files:**
- Create: `Sources/Services/ClaudeService.swift`
- Test: `Tests/CmdMDTests/ClaudeServiceTests.swift`

**Interfaces:**
- Produces:
  - `enum ClaudeError: Error { case toolNotFound, notLoggedIn, creditExhausted, timeout, failed(String) }`
  - `static func ClaudeService.classify(exitCode: Int32, stderr: String) -> ClaudeError`
  - `static func ClaudeService.makeInput(prompt: String, context: String) -> (arguments: [String], stdin: String)`

- [ ] **Step 1: 실패하는 테스트 작성**

`Tests/CmdMDTests/ClaudeServiceTests.swift`:
```swift
import XCTest
@testable import CmdMD

final class ClaudeServiceTests: XCTestCase {
    func testClassifyDetectsNotLoggedIn() {
        let e = ClaudeService.classify(exitCode: 1, stderr: "Error: Not logged in. Run `claude` to authenticate.")
        guard case .notLoggedIn = e else { return XCTFail("기대: notLoggedIn, 실제: \(e)") }
    }

    func testClassifyDetectsCreditExhausted() {
        let e = ClaudeService.classify(exitCode: 1, stderr: "You have exceeded your usage limit / credit balance.")
        guard case .creditExhausted = e else { return XCTFail("기대: creditExhausted, 실제: \(e)") }
    }

    func testClassifyFallsBackToFailedWithStderrPrefix() {
        let e = ClaudeService.classify(exitCode: 2, stderr: "boom: something unexpected broke")
        guard case .failed(let msg) = e else { return XCTFail("기대: failed, 실제: \(e)") }
        XCTAssertTrue(msg.contains("boom"))
    }

    func testMakeInputPassesPromptAsArgAndContextAsStdin() {
        let (args, stdin) = ClaudeService.makeInput(prompt: "이 문서 요약해줘", context: "  # 제목\n본문  ")
        XCTAssertEqual(args, ["-p", "이 문서 요약해줘"])
        XCTAssertEqual(stdin, "# 제목\n본문")   // 앞뒤 공백 트림
    }

    func testMakeInputEmptyContextYieldsEmptyStdin() {
        let (args, stdin) = ClaudeService.makeInput(prompt: "안녕", context: "   ")
        XCTAssertEqual(args, ["-p", "안녕"])
        XCTAssertEqual(stdin, "")
    }
}
```

- [ ] **Step 2: 테스트 실패 확인**

Run: `swift test --filter ClaudeServiceTests 2>&1 | tail -5`
Expected: FAIL — `ClaudeService`/`ClaudeError` 미정의 컴파일 에러.

- [ ] **Step 3: 최소 구현 작성**

`Sources/Services/ClaudeService.swift`:
```swift
import Foundation

enum ClaudeError: Error {
    case toolNotFound
    case notLoggedIn
    case creditExhausted
    case timeout
    case failed(String)
}

/// claude CLI를 Process로 호출해 열린 문서를 질의한다.
/// claude 자체는 구현하지 않는다(외부 도구). 실패는 throw로만 — 크래시 금지.
actor ClaudeService {
    private let timeout: TimeInterval = 120

    /// claude CLI 종료코드/stderr를 사용자 분기 에러로 분류한다(순수 함수).
    static func classify(exitCode: Int32, stderr: String) -> ClaudeError {
        let s = stderr.lowercased()
        if s.contains("not logged in") || s.contains("unauthorized")
            || s.contains("authenticate") || s.contains("login") {
            return .notLoggedIn
        }
        if s.contains("credit") || s.contains("quota")
            || s.contains("usage limit") || s.contains("rate limit") || s.contains("insufficient") {
            return .creditExhausted
        }
        return .failed(String(stderr.prefix(500)))
    }

    /// claude 호출 인자/stdin을 만든다(순수 함수). 프롬프트=`-p` 인자, 컨텍스트=stdin.
    static func makeInput(prompt: String, context: String) -> (arguments: [String], stdin: String) {
        let trimmed = context.trimmingCharacters(in: .whitespacesAndNewlines)
        return (["-p", prompt], trimmed)
    }
}
```

- [ ] **Step 4: 테스트 통과 확인**

Run: `swift test --filter ClaudeServiceTests 2>&1 | tail -5`
Expected: PASS (5 테스트).

- [ ] **Step 5: 커밋**

```bash
git add Sources/Services/ClaudeService.swift Tests/CmdMDTests/ClaudeServiceTests.swift
git commit -m "기능(claude): ClaudeService 에러 분류기·입력 조립기 추가

claude CLI 종료코드/stderr를 미로그인·크레딧소진·일반실패로 분류하는
순수 classify와, 프롬프트=-p 인자·컨텍스트=stdin으로 나누는 makeInput.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01S2QuZUALidkTNRswXFL6xM"
```

---

### Task 2: ClaudeService — claude 경로 탐지 + ask() 호출

**Files:**
- Modify: `Sources/Services/ClaudeService.swift`

**Interfaces:**
- Consumes: `ClaudeService.makeInput`, `ClaudeService.classify`, `ClaudeError` (Task 1).
- Produces:
  - `static func ClaudeService.resolveClaudePath() -> String?`
  - `func ask(prompt: String, context: String) async throws -> String`

> 실제 CLI 호출은 외부 도구라 단위 테스트하지 않는다(KordocService와 동일). 빌드 통과로만 검증.

- [ ] **Step 1: 경로 탐지 + ask 구현 추가**

`Sources/Services/ClaudeService.swift`의 `actor ClaudeService` 안에 추가(makeInput 아래):
```swift
    /// 열린 문서 컨텍스트와 프롬프트를 claude -p로 보내고 stdout 응답을 반환한다.
    func ask(prompt: String, context: String) async throws -> String {
        guard let claudePath = Self.resolveClaudePath() else { throw ClaudeError.toolNotFound }
        let (arguments, stdin) = Self.makeInput(prompt: prompt, context: context)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: claudePath)
        process.arguments = arguments

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw ClaudeError.toolNotFound
        }

        // 컨텍스트를 stdin으로 주입하고 닫는다.
        if let data = stdin.data(using: .utf8), !data.isEmpty {
            stdinPipe.fileHandleForWriting.write(data)
        }
        stdinPipe.fileHandleForWriting.closeFile()

        // 파이프 버퍼가 차서 교착되지 않게 stdout/stderr를 백그라운드에서 비운다.
        let outHandle = stdoutPipe.fileHandleForReading
        let errHandle = stderrPipe.fileHandleForReading
        async let outData = Task.detached { outHandle.readDataToEndOfFile() }.value
        async let errData = Task.detached { errHandle.readDataToEndOfFile() }.value

        // 타임아웃 감시(협조적 폴링).
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            if Date() > deadline {
                process.terminate()
                throw ClaudeError.timeout
            }
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s
        }

        let out = String(data: await outData, encoding: .utf8) ?? ""
        let err = String(data: await errData, encoding: .utf8) ?? ""

        if process.terminationStatus != 0 {
            throw Self.classify(exitCode: process.terminationStatus, stderr: err)
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// GUI 앱(.app)은 로그인 셸 PATH를 상속하지 않으므로 claude 절대경로를 탐지한다.
    /// 흔한 설치 경로 → 그래도 없으면 로그인 셸의 `which claude`.
    static func resolveClaudePath() -> String? {
        let home = NSHomeDirectory()
        let candidates = [
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(home)/.claude/local/claude",
            "\(home)/.local/bin/claude",
            "/usr/bin/claude",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/bin/zsh")
        probe.arguments = ["-lc", "which claude"]
        let pipe = Pipe()
        probe.standardOutput = pipe
        probe.standardError = FileHandle.nullDevice
        do {
            try probe.run()
            probe.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let out = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !out.isEmpty, FileManager.default.isExecutableFile(atPath: out) {
                return out
            }
        } catch { }
        return nil
    }
```

- [ ] **Step 2: 빌드 + 기존 테스트 확인**

Run: `swift build 2>&1 | tail -5 && swift test --filter ClaudeServiceTests 2>&1 | tail -3`
Expected: 빌드 성공, ClaudeServiceTests 5개 통과.

- [ ] **Step 3: 커밋**

```bash
git add Sources/Services/ClaudeService.swift
git commit -m "기능(claude): claude 경로 탐지·ask() 호출 추가

흔한 설치 경로 후보→로그인 셸 which로 claude 절대경로 탐지. ask는
컨텍스트를 stdin, 프롬프트를 -p로 보내고 stdout/stderr를 백그라운드로
비워 교착을 막으며 120s 타임아웃을 건다.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01S2QuZUALidkTNRswXFL6xM"
```

---

### Task 3: AppState — claude 상태 + 순수 컨텍스트/에러 헬퍼 + askClaude()

**Files:**
- Modify: `Sources/App/AppState.swift`
- Test: `Tests/CmdMDTests/AppClaudeTests.swift`

**Interfaces:**
- Consumes: `ClaudeService.ask` (Task 2), `ClaudeError` (Task 1), `OfficeState.loaded(KordocResult)` (기존).
- Produces:
  - 상태: `claudePanelVisible: Bool`, `claudePanelWidth: CGFloat`, `claudePrompt: String`, `claudeResponse: String?`, `claudeError: String?`, `claudeBusy: Bool`, `currentSelectionText: String`
  - `static func AppState.claudeContext(selection: String, markdown: String?, officeMarkdown: String?) -> String`
  - `static func AppState.claudeErrorMessage(_ error: Error) -> String`
  - `func askClaude()`

- [ ] **Step 1: 실패하는 테스트 작성**

`Tests/CmdMDTests/AppClaudeTests.swift`:
```swift
import XCTest
@testable import CmdMD

final class AppClaudeTests: XCTestCase {
    func testContextPrefersSelectionWhenPresent() {
        let r = AppState.claudeContext(selection: "선택한 문장", markdown: "전체 본문", officeMarkdown: nil)
        XCTAssertEqual(r, "선택한 문장")
    }

    func testContextFallsBackToMarkdownWhenNoSelection() {
        let r = AppState.claudeContext(selection: "   ", markdown: "전체 본문", officeMarkdown: nil)
        XCTAssertEqual(r, "전체 본문")
    }

    func testContextUsesOfficeMarkdownWhenNoSelectionOrMarkdown() {
        let r = AppState.claudeContext(selection: "", markdown: nil, officeMarkdown: "# 한글 문서")
        XCTAssertEqual(r, "# 한글 문서")
    }

    func testContextEmptyWhenNothingAvailable() {
        let r = AppState.claudeContext(selection: "", markdown: nil, officeMarkdown: nil)
        XCTAssertEqual(r, "")
    }

    func testErrorMessageMapsToolNotFound() {
        let m = AppState.claudeErrorMessage(ClaudeError.toolNotFound)
        XCTAssertTrue(m.contains("claude"))
    }

    func testErrorMessageMapsNotLoggedIn() {
        let m = AppState.claudeErrorMessage(ClaudeError.notLoggedIn)
        XCTAssertTrue(m.contains("로그인"))
    }

    func testErrorMessageMapsCreditExhausted() {
        let m = AppState.claudeErrorMessage(ClaudeError.creditExhausted)
        XCTAssertTrue(m.contains("크레딧") || m.contains("사용량"))
    }
}
```

- [ ] **Step 2: 테스트 실패 확인**

Run: `swift test --filter AppClaudeTests 2>&1 | tail -5`
Expected: FAIL — `claudeContext`/`claudeErrorMessage` 미정의.

- [ ] **Step 3: 상태 변수 추가**

`Sources/App/AppState.swift`의 `var showAbout: Bool = false`(49행) 아래에 추가:
```swift

    // Claude 연동
    var claudePanelVisible: Bool = false
    var claudePanelWidth: CGFloat = 340
    var claudePrompt: String = ""
    var claudeResponse: String?
    var claudeError: String?
    var claudeBusy: Bool = false
    /// 마크다운 에디터의 현재 선택영역 텍스트(없으면 빈 문자열). 질의 컨텍스트 우선순위 1.
    var currentSelectionText: String = ""
```

- [ ] **Step 4: claudeService 인스턴스 추가**

`Sources/App/AppState.swift`의 `private let kordocService = KordocService()`(85행) 아래에 추가:
```swift
    private let claudeService = ClaudeService()
```

- [ ] **Step 5: 순수 헬퍼 + askClaude() 추가**

`Sources/App/AppState.swift`의 `keyBinding(for:)` 함수(178~180행) 바로 아래에 추가:
```swift

    // MARK: - Claude 연동

    /// 질의 컨텍스트를 고른다(순수 함수). 선택영역 > 마크다운 본문 > 오피스 변환 마크다운 > 빈 문자열.
    static func claudeContext(selection: String, markdown: String?, officeMarkdown: String?) -> String {
        let sel = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        if !sel.isEmpty { return sel }
        if let md = markdown, !md.isEmpty { return md }
        if let om = officeMarkdown, !om.isEmpty { return om }
        return ""
    }

    /// ClaudeError를 사용자용 한국어 안내로 변환한다(순수 함수).
    static func claudeErrorMessage(_ error: Error) -> String {
        switch error {
        case ClaudeError.toolNotFound:
            return "claude CLI를 찾을 수 없습니다. 설치 후 터미널에서 `claude`로 로그인하고 다시 시도하세요."
        case ClaudeError.notLoggedIn:
            return "Claude Code 로그인이 필요합니다. 터미널에서 `claude`를 실행해 로그인한 뒤 다시 시도하세요."
        case ClaudeError.creditExhausted:
            return "Claude 사용량(크레딧)이 소진되었습니다. 잠시 후 다시 시도하세요."
        case ClaudeError.timeout:
            return "응답이 너무 오래 걸려 중단했습니다."
        case ClaudeError.failed(let m):
            return "Claude 호출에 실패했습니다: \(m)"
        default:
            return "Claude 호출에 실패했습니다: \(error.localizedDescription)"
        }
    }

    /// 현재 문서(또는 선택영역)를 프롬프트와 함께 claude에 보내고 응답을 패널에 표시한다.
    func askClaude() {
        let prompt = claudePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, !claudeBusy else { return }

        let officeMarkdown: String? = {
            guard let tab = activeTab, case .loaded(let result)? = officeStates[tab.id] else { return nil }
            return result.markdown
        }()
        let context = Self.claudeContext(selection: currentSelectionText,
                                         markdown: currentDocument?.content,
                                         officeMarkdown: officeMarkdown)

        claudeBusy = true
        claudeError = nil
        claudeResponse = nil

        Task { @MainActor in
            do {
                let answer = try await claudeService.ask(prompt: prompt, context: context)
                claudeResponse = answer
            } catch {
                claudeError = Self.claudeErrorMessage(error)
            }
            claudeBusy = false
        }
    }
```

- [ ] **Step 6: 테스트 통과 + 빌드 확인**

Run: `swift build 2>&1 | tail -5 && swift test --filter AppClaudeTests 2>&1 | tail -5`
Expected: 빌드 성공, AppClaudeTests 7개 통과.

- [ ] **Step 7: 커밋**

```bash
git add Sources/App/AppState.swift Tests/CmdMDTests/AppClaudeTests.swift
git commit -m "기능(claude): AppState에 claude 상태·컨텍스트/에러 헬퍼·askClaude 추가

선택영역>마크다운>오피스 변환 순으로 컨텍스트를 고르는 claudeContext와
ClaudeError→한국어 안내 매핑. askClaude는 ClaudeService를 비동기 호출해
응답/에러/로딩 상태를 갱신한다(메인 액터).

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01S2QuZUALidkTNRswXFL6xM"
```

---

### Task 4: 마크다운 선택영역 → currentSelectionText 배선

**Files:**
- Modify: `Sources/Views/EditorTextView.swift`
- Modify: `Sources/Views/MainEditorView.swift`

**Interfaces:**
- Consumes: `appState.currentSelectionText` (Task 3).
- Produces: `MarkdownTextEditor.onSelectedTextChange: ((String) -> Void)?` — 선택영역 변경 시 선택 텍스트(없으면 "")를 전달.

> NSView 콜백 배선이라 단위 테스트 대신 빌드로 검증.

- [ ] **Step 1: 콜백 프로퍼티 선언 추가**

`Sources/Views/EditorTextView.swift`의 `var onSelectionChange: ((Int, Int) -> Void)?`(215행) 아래에 추가:
```swift
    var onSelectedTextChange: ((String) -> Void)?
```

- [ ] **Step 2: reportSelection에서 선택 텍스트도 전달**

`Sources/Views/EditorTextView.swift`의 `reportSelection(of:)`(667~672행)을 아래로 교체:
```swift
        private func reportSelection(of textView: NSTextView) {
            let range = textView.selectedRange()
            if let onSelectedTextChange = parent.onSelectedTextChange {
                let selected = range.length > 0
                    ? (textView.string as NSString).substring(with: range)
                    : ""
                onSelectedTextChange(selected)
            }
            guard let onSelectionChange = parent.onSelectionChange else { return }
            let (line, column) = lineIndex.lineAndColumn(at: range.location)
            onSelectionChange(line, column)
        }
```

- [ ] **Step 3: MainEditorView에서 콜백을 AppState로 배선**

`Sources/Views/MainEditorView.swift`의 `onSelectionChange:` 클로저(286~288행) 바로 아래(`completionsProvider:` 위)에 추가:
```swift
            onSelectedTextChange: { selected in
                appState.currentSelectionText = selected
            },
```

- [ ] **Step 4: 빌드 + 기존 테스트 확인**

Run: `swift build 2>&1 | tail -5 && swift test 2>&1 | tail -5`
Expected: 빌드 성공, 전체 테스트(기존 95 + 신규 12) 통과.

- [ ] **Step 5: 커밋**

```bash
git add Sources/Views/EditorTextView.swift Sources/Views/MainEditorView.swift
git commit -m "기능(claude): 마크다운 선택영역을 currentSelectionText로 배선

에디터 선택 변경 시 선택 텍스트(없으면 빈 문자열)를 AppState로 전달해
claude 질의 컨텍스트 우선순위에 쓰이게 한다.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01S2QuZUALidkTNRswXFL6xM"
```

---

### Task 5: ClaudePanelView UI

**Files:**
- Create: `Sources/Views/ClaudePanelView.swift`

**Interfaces:**
- Consumes: `appState.claudePrompt`, `claudeResponse`, `claudeError`, `claudeBusy`, `claudePanelVisible`, `askClaude()` (Task 3).

> SwiftUI 뷰라 빌드로 검증.

- [ ] **Step 1: 패널 뷰 작성**

`Sources/Views/ClaudePanelView.swift`:
```swift
import SwiftUI
import AppKit

/// 전용 Claude 사이드 패널. 프롬프트 입력 + 응답/로딩/에러 표시.
/// 응답 저장(노트 삽입·볼트)은 후속 Phase — 이번엔 세션 표시 + 복사만.
struct ClaudePanelView: View {
    @Environment(AppState.self) private var appState
    @FocusState private var promptFocused: Bool

    var body: some View {
        @Bindable var state = appState

        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .foregroundStyle(.cmdsAccent)
                Text("Claude")
                    .font(.headline)
                Spacer()
                Button {
                    appState.claudePanelVisible = false
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .help("Close Claude panel")
            }
            .padding(10)

            Divider()

            ScrollView {
                Group {
                    if appState.claudeBusy {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Claude에게 묻는 중…").foregroundStyle(.secondary)
                        }
                    } else if let err = appState.claudeError {
                        Text(err)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    } else if let resp = appState.claudeResponse {
                        Text(resp)
                            .textSelection(.enabled)
                    } else {
                        Text("열린 문서에 대해 Claude에게 물어보세요. 마크다운에서 선택영역이 있으면 그 부분만 전송됩니다.")
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }

            if let resp = appState.claudeResponse, !appState.claudeBusy {
                HStack {
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(resp, forType: .string)
                    } label: {
                        Label("복사", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
            }

            Divider()

            VStack(spacing: 8) {
                TextEditor(text: $state.claudePrompt)
                    .font(.body)
                    .frame(height: 72)
                    .focused($promptFocused)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.gray.opacity(0.25), lineWidth: 1)
                    )
                HStack {
                    Spacer()
                    Button("질문 (⌘↩)") {
                        appState.askClaude()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.cmdsAccent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(appState.claudeBusy
                        || appState.claudePrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(10)
        }
        .frame(maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { promptFocused = true }
    }
}
```

- [ ] **Step 2: 빌드 확인**

Run: `swift build 2>&1 | tail -5`
Expected: 빌드 성공.

- [ ] **Step 3: 커밋**

```bash
git add Sources/Views/ClaudePanelView.swift
git commit -m "기능(claude): 전용 Claude 사이드 패널 뷰 추가

프롬프트 입력(⌘↩)·로딩/에러/응답 표시·응답 복사 버튼. 저장은 후속 Phase로
세션 표시만.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01S2QuZUALidkTNRswXFL6xM"
```

---

### Task 6: ContentView — 트레일링 Claude 컬럼 + 리사이즈 디바이더

**Files:**
- Modify: `Sources/Views/ContentView.swift`

**Interfaces:**
- Consumes: `ClaudePanelView` (Task 5), `appState.claudePanelVisible`, `appState.claudePanelWidth` (Task 3).

> SwiftUI 레이아웃이라 빌드로 검증. `.inspector`는 SwiftUI에서 1개만 가능하므로 Claude 패널은 NavigationSplitView 바깥 HStack 트레일링 컬럼으로 둔다.

- [ ] **Step 1: body를 HStack으로 감싸 트레일링 컬럼 추가**

`Sources/Views/ContentView.swift`의 `var body: some View {` 본문에서, 기존 `NavigationSplitView(...) { ... } detail: { MainEditorView() } .navigationTitle(...) .inspector(...) ...` 전체 체인을 `HStack`으로 감싼다. 구체적으로 17행 `@Bindable var state = appState` 아래 `NavigationSplitView(`부터 109행 `.focusedSceneValue(...)`까지가 하나의 식이므로, 그 앞에 `HStack(spacing: 0) {` 를 열고, `NavigationSplitView` 체인을 그 안에 두고, 체인 끝(`.focusedSceneValue(...)` 다음)에 아래 트레일링 컬럼 + 닫는 `}`를 붙인다:

체인 시작 직전:
```swift
        HStack(spacing: 0) {
```

체인 끝(`.focusedSceneValue(\.document, appState.currentDocument)`) 바로 다음 줄에:
```swift

            if appState.claudePanelVisible {
                Divider()
                    .frame(width: 6)
                    .background(Color.gray.opacity(0.001)) // 히트 영역 확보
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                let next = appState.claudePanelWidth - value.translation.width
                                appState.claudePanelWidth = min(600, max(280, next))
                            }
                    )

                ClaudePanelView()
                    .frame(width: appState.claudePanelWidth)
                    .transition(.move(edge: .trailing))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: appState.claudePanelVisible)
```

> 주의: `@Bindable var state = appState`는 이미 17행에 선언돼 있으니 재선언하지 않는다. HStack 첫 자식이 NavigationSplitView 체인, 둘째가 조건부 디바이더+패널이다.

- [ ] **Step 2: 빌드 확인**

Run: `swift build 2>&1 | tail -5`
Expected: 빌드 성공.

- [ ] **Step 3: 커밋**

```bash
git add Sources/Views/ContentView.swift
git commit -m "기능(claude): Claude 패널을 트레일링 리사이즈 컬럼으로 통합

inspector와 공존하도록 NavigationSplitView를 HStack으로 감싸고, 토글 시
드래그로 너비(280~600) 조절 가능한 Claude 컬럼을 트레일링에 둔다.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01S2QuZUALidkTNRswXFL6xM"
```

---

### Task 7: 진입점 — AppShortcut + 커맨드 팔레트 + View 메뉴

**Files:**
- Modify: `Sources/Models/Shortcuts.swift`
- Modify: `Sources/Views/CommandPaletteView.swift`
- Modify: `Sources/App/CmdMDApp.swift`
- Test: `Tests/CmdMDTests/AppClaudeTests.swift` (Task 3에서 생성한 파일에 추가)

**Interfaces:**
- Consumes: `appState.claudePanelVisible` (Task 3), `appState.keyBinding(for:)` (기존).
- Produces: `AppShortcut.askClaude` (기본 ⇧⌘A).

- [ ] **Step 1: 실패하는 테스트 추가**

`Tests/CmdMDTests/AppClaudeTests.swift`의 클래스 안에 추가:
```swift
    func testAskClaudeShortcutExistsWithDefaultBinding() {
        XCTAssertTrue(AppShortcut.allCases.contains(.askClaude))
        let b = AppShortcut.askClaude.defaultBinding
        XCTAssertEqual(b.key, "a")
        XCTAssertTrue(b.command)
        XCTAssertTrue(b.shift)
    }

    func testAskClaudeShortcutHasTitle() {
        XCTAssertFalse(AppShortcut.askClaude.title.isEmpty)
    }
```

- [ ] **Step 2: 테스트 실패 확인**

Run: `swift test --filter AppClaudeTests 2>&1 | tail -5`
Expected: FAIL — `AppShortcut.askClaude` 미정의.

- [ ] **Step 3: AppShortcut에 케이스 추가**

`Sources/Models/Shortcuts.swift`의 `enum AppShortcut`에서:

(a) `case openFolder` 아래에 추가:
```swift
    case askClaude
```

(b) `title` switch의 `case .openFolder: return "Open Folder…"` 아래에 추가:
```swift
        case .askClaude:      return "Ask Claude"
```

(c) `defaultBinding` switch의 `case .openFolder: return KeyBinding(key: "o", command: true, option: true)` 아래에 추가:
```swift
        case .askClaude:       return KeyBinding(key: "a", command: true, shift: true)
```

- [ ] **Step 4: 테스트 통과 확인**

Run: `swift test --filter AppClaudeTests 2>&1 | tail -5`
Expected: PASS (9 테스트).

- [ ] **Step 5: 커맨드 팔레트에 "Ask Claude" 추가**

`Sources/Views/CommandPaletteView.swift`의 `allCommands(appState:)` 배열에서 "Omnisearch" Command 블록(241~259행) 아래에 추가:
```swift

            Command(
                title: "Ask Claude",
                subtitle: "Ask Claude about the open document",
                icon: "sparkles",
                shortcut: appState.keyBinding(for: .askClaude).displayString,
                keywords: ["claude", "ai", "ask", "assistant", "chat"]
            ) {
                appState.claudePanelVisible = true
            },
```

- [ ] **Step 6: View 메뉴에 "Ask Claude" 버튼 추가**

`Sources/App/CmdMDApp.swift`의 "Toggle Inspector" 버튼(138~143행) 아래, `Divider()`(145행) 위에 추가:
```swift

                Button("Ask Claude") {
                    appState.claudePanelVisible = true
                }
                .appShortcut(appState.keyBinding(for: .askClaude))
```

- [ ] **Step 7: 빌드 + 전체 테스트 확인**

Run: `swift build 2>&1 | tail -5 && swift test 2>&1 | tail -5`
Expected: 빌드 성공, 전체 테스트(기존 95 + 신규 14) 통과.

- [ ] **Step 8: 커밋**

```bash
git add Sources/Models/Shortcuts.swift Sources/Views/CommandPaletteView.swift Sources/App/CmdMDApp.swift Tests/CmdMDTests/AppClaudeTests.swift
git commit -m "기능(claude): Ask Claude 진입점(단축키 ⇧⌘A·팔레트·View 메뉴) 추가

AppShortcut.askClaude(기본 ⇧⌘A) + 커맨드 팔레트 'Ask Claude' + View 메뉴
버튼으로 Claude 패널을 연다.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01S2QuZUALidkTNRswXFL6xM"
```

---

### Task 8: Phase 게이트 마감 — 전체 테스트 + CLAUDE.md 상태 갱신

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: 전체 테스트 통과 확인**

Run: `swift test 2>&1 | tail -8`
Expected: 전체 통과(실패 0). 신규 14개 포함 약 109개.

- [ ] **Step 2: CLAUDE.md "현재 상태"에 Phase 4 완료 줄 추가**

`CLAUDE.md`의 "## 현재 상태" 섹션에서 Phase 3/오피스 본문 검색 줄 아래에 추가:
```markdown
- Phase 4 완료(2026-06-29). Claude 연동 — `ClaudeService`(actor: claude 절대경로 탐지, `Process`로 `claude -p`, 컨텍스트=stdin·프롬프트=-p 인자, 120s 타임아웃, stderr→미로그인/크레딧소진/일반실패 분류) + `ClaudePanelView`(전용 트레일링 리사이즈 패널: 프롬프트 ⌘↩·로딩/에러/응답·복사). 컨텍스트=선택영역>마크다운 본문>오피스 변환 마크다운. 진입점 ⇧⌘A·커맨드 팔레트·View 메뉴. 저장(노트/볼트)·스트리밍은 후속. 약 109개 테스트 통과.
```

그리고 "다음 액션" 줄을 Phase 5로 갱신:
```markdown
- 다음 액션: Phase 5 kordoc 쓰기(generate/patch/fill) → Phase 6 PARA 라우팅.
```

- [ ] **Step 3: 커밋**

```bash
git add CLAUDE.md
git commit -m "문서: Phase 4 Claude 연동 완료 상태 기록

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01S2QuZUALidkTNRswXFL6xM"
```

---

## Self-Review

**1. Spec coverage:**
- `claude` 경로 탐지 + 미설치/미로그인/크레딧소진 분기 → Task 2(resolveClaudePath) + Task 1(classify) + Task 3(claudeErrorMessage). ✓
- 커맨드 팔레트 + 단축키 진입점 → Task 7. ✓
- 문서 본문 동봉 전달 → Task 3(claudeContext) + Task 4(선택영역). ✓
- 응답 패널 표시 → Task 5 + Task 6. ✓
- 완료까지 대기 + 로딩 상태 → Task 2(ask) + Task 3(claudeBusy) + Task 5(ProgressView). ✓
- 저장 보류(세션 표시만) → Task 5 복사만, 명시적 범위 밖. ✓
- Phase 게이트 → Task 0, Task 8. ✓

**2. Placeholder scan:** 모든 코드 스텝에 실제 코드 포함. TBD/TODO 없음. ✓

**3. Type consistency:** `ClaudeError`(toolNotFound/notLoggedIn/creditExhausted/timeout/failed) — Task 1 정의, Task 2·3에서 동일 사용. `classify`/`makeInput`/`resolveClaudePath`/`ask` 시그니처 일관. `claudeContext`/`claudeErrorMessage`/`askClaude`/상태 변수명 Task 3↔5↔6↔7 일관. `onSelectedTextChange` Task 4 내부 일관. ✓

## 미해결 가정 (실행 중 확인)

- `claude -p "<prompt>"`가 stdin 파이프를 컨텍스트로 사용한다는 전제. 실행 중 동작이 다르면(예: stdin 무시) Task 2의 `makeInput`을 `arguments=["-p", "\(prompt)\n\n\(context)"]`로 바꾸고 stdin 비우는 방식으로 전환. 이 경우 Task 1의 `testMakeInput*` 테스트도 함께 갱신.
