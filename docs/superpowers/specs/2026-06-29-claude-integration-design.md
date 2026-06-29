# Phase 4 — Claude 연동 (`claude -p`) 설계

작성일: 2026-06-29
대상: cmd-docu (CmdMD 포크), 티어 2 Phase 4
PRD: `CmdMD-fork_prd.md` §3.5, Phase 4

## 목표

열린 문서(또는 선택 영역)를 프롬프트와 함께 로컬 `claude` CLI(`claude -p`)에 보내고, 응답을 전용 사이드 패널에 표시한다. claude는 직접 구현하지 않고 `Process`로 호출하는 외부 도구다. 미설치/미로그인/크레딧소진 등 실패는 크래시 없이 패널 안내로만 처리한다.

### 이번 Phase 범위 결정 (사용자 확정 2026-06-29)
- **응답 패널**: 기존 Inspector와 별개인 전용 Claude 트레일링 사이드 패널.
- **전송 컨텍스트**: 마크다운 에디터에 선택영역이 있으면 그 텍스트, 없으면 현재 표시 본문 전체.
- **저장**: 세션 표시만. 노트 삽입·볼트 저장(PRD Phase 4 항목 3)은 이번 범위에서 보류, 후속으로 분리. 응답 복사만 허용.
- **호출 방식**: 완료까지 대기 + 로딩 상태. 스트리밍은 후속 Phase.

## 아키텍처

신규 기능은 별도 파일로 분리해 업스트림(CmdMD) 머지를 쉽게 둔다.

### 신규 파일
- `Sources/Services/ClaudeService.swift` — `actor`. `KordocService`와 동일 패턴.
  - `resolveClaudePath() -> String?`: 후보 절대경로 → 없으면 로그인 셸 `which claude`.
  - `ask(prompt:context:) async throws -> String`: `Process`로 `claude -p "<prompt>"`, 컨텍스트는 stdin 파이프. 타임아웃 120s. stdout 반환.
  - `ClaudeError`: `toolNotFound`, `notLoggedIn`, `creditExhausted`, `timeout`, `failed(String)`.
  - `static func classify(exitCode:stderr:) -> ClaudeError`: 순수 함수(단위 테스트 대상). stderr 신호 문자열로 notLoggedIn/creditExhausted/failed 분류.
- `Sources/Views/ClaudePanelView.swift` — 전용 트레일링 사이드 패널.
  - 프롬프트 입력 필드 + "질문" 버튼(⌘↵).
  - 응답 영역(스크롤), 로딩 스피너, 에러 안내, 응답 복사 버튼.

### 기존 파일 최소 변경
- `Sources/App/AppState.swift`:
  - 상태: `claudePanelVisible: Bool`, `claudePrompt: String`, `claudeResponse: String?`, `claudeError: String?`, `claudeBusy: Bool`, `currentSelectionText: String`(에디터 선택영역 캡처).
  - `askClaude()`: 컨텍스트 수집 → `ClaudeService.ask` 호출 → 상태 갱신. 에러는 `claudeError`로.
  - 컨텍스트 수집 헬퍼를 순수 함수로 분리해 테스트(`claudeContext(selection:markdown:officeMarkdown:) -> String`).
- `Sources/Views/ContentView.swift`: `.inspector`는 SwiftUI에서 1개만 가능하므로 Claude 패널은 메인 영역 트레일링에 `claudePanelVisible` 토글 컬럼(리사이즈 가능)으로 추가. Inspector와 공존.
- `Sources/Views/CommandPaletteView.swift`: "Ask Claude" 커맨드 추가.
- `Sources/Views/EditorTextView.swift` / `MainEditorView.swift`: 선택영역 텍스트를 AppState `currentSelectionText`로 전달(기존 `onSelectionChange` 배선 확장).
- `Sources/Models/Shortcuts.swift`: "Ask Claude" 단축키 항목 추가.

## 데이터 흐름

1. "Ask Claude"(팔레트/단축키) → `claudePanelVisible = true`, 프롬프트 포커스.
2. 프롬프트 입력 → ⌘↵ 또는 버튼.
3. `askClaude()`:
   - 컨텍스트 = 마크다운 에디터 선택영역(`currentSelectionText` 비어있지 않으면) 우선, 없으면 현재 표시 본문 전체.
     - markdown: `currentDocument.content`
     - office: `officeConversions[tabId]`의 로드된 마크다운
     - pdf/이미지: 본문 텍스트 없으면 프롬프트만 전송
   - `claudeBusy = true`.
4. `ClaudeService.ask(prompt:context:)`:
   - `Process` executableURL = 탐지된 claude 경로.
   - arguments = `["-p", prompt]`.
   - 컨텍스트는 stdin 파이프로 주입(`<context>\n\n<prompt>`가 아니라 stdin=context, arg=prompt).
   - 타임아웃 120s 협조적 폴링(KordocService와 동일).
5. 완료 후 stdout = 답변. 종료코드≠0이면 `classify`로 에러 분기.
6. `claudeResponse` 갱신, `claudeBusy = false`. 패널에 표시.

## 에러 처리 (전부 크래시 없이 패널 안내)

- `toolNotFound` → "claude CLI를 찾을 수 없습니다. 설치하고 `claude` 로그인 후 다시 시도하세요."
- `notLoggedIn` → "Claude Code 로그인이 필요합니다. 터미널에서 `claude` 로그인 후 다시 시도하세요."
- `creditExhausted` → "Claude 사용량(크레딧)이 소진되었습니다."
- `timeout` → 프로세스 종료 + "응답이 너무 오래 걸려 중단했습니다."
- `failed(msg)` → stderr 앞부분(최대 500자) 표시.

`resolveClaudePath()` 후보: `/opt/homebrew/bin/claude`, `/usr/local/bin/claude`, `~/.claude/local/claude`, `~/.local/bin/claude`, `/usr/bin/claude` → 없으면 `/bin/zsh -lc "which claude"`.

## 테스트 (Phase 게이트)

- Phase 시작·종료 시 `swift test` 실행, 기존 95개 테스트 유지(정식 Xcode 필요).
- 신규 테스트(실제 claude 호출 없음, 외부 CLI):
  - `ClaudeService.classify`: stderr 샘플 문자열 → 올바른 `ClaudeError` 매핑.
  - 컨텍스트 수집 헬퍼: 선택영역 있음/없음, markdown/office/빈 본문 분기.
  - 패널 토글·커맨드 등록 상태 전이.
- 예상 신규 테스트 5~8개.

## 핵심 규칙 준수

- 비샌드박스 유지(서브프로세스 호출 필요).
- claude는 `Process` 외부 호출만, 직접 구현 안 함. 경로 탐지 실패 시 안내만, 크래시 금지.
- 이번 Phase는 읽기·표시만 — 파일 이동/변경 없음(제안→확인 게이트 비해당).
- LICENSE·원작자 고지 유지. 코드 주석·커밋 메시지 한국어.

## 보류 (후속 Phase 후보)

- 응답 노트 삽입 / 볼트 저장(PRD Phase 4 항목 3).
- 스트리밍 표시.
- pdf/이미지 본문 텍스트 동봉(kordoc/PDFKit 추출 연동).
