# Phase 5a — kordoc patch (편집 후 서식 보존 저장) 설계

작성일: 2026-06-29
대상: cmd-docu (CmdMD 포크), 티어 2 Phase 5(쓰기)의 첫 사이클
PRD: `CmdMD-fork_prd.md` Phase 5 — 단, 아래 "PRD 정정" 반영

## PRD 정정 (kordoc 실제 API 검증, 2026-06-29)

`npx -y kordoc --help`로 확인한 실제 쓰기 명령:
- **`generate`는 존재하지 않는다.** kordoc은 맨바닥에서 새 HWPX를 만들지 못한다. PRD의 "md → HWPX generate" 항목은 폐기.
- **`patch <원본> <편집>`** — 편집한 마크다운을 원본 HWPX/HWP에 서식 보존하며 in-place 반영 → 새 파일 출력. 옵션 `-o <출력>`(기본 `<원본>.patched.hwpx|.hwp`), `--no-verify`, `--silent`. **HWPX/HWP 전용.**
- **`fill <템플릿>`** — 서식 빈칸 채우기. `-f 'key=value,...'` 또는 `-j json`, `--dry-run`(빈칸 목록만), `--format hwpx-preserve|hwpx|markdown`, `-o`.

따라서 Phase 5는 **patch + fill** 두 기능으로 좁혀진다. 이 문서는 **patch만** 다룬다(사용자 결정: patch 먼저, fill은 별도 사이클).

## 목표

Phase 3에서 읽기전용으로 보던 한글 문서(hwp/hwpx)를 **편집모드**로 전환해 변환 마크다운을 수정하고, `kordoc patch`로 **원본 서식을 보존한 채** 새 파일로 저장한다. kordoc은 직접 구현하지 않고 `Process`로 호출한다. **원본은 절대 덮어쓰거나 삭제하지 않는다.** 쓰기 전 출력 경로를 제안→확인한다.

### 사용자 확정 결정 (2026-06-29)
- 범위: patch 먼저, fill은 다음 사이클.
- 출력·안전: 원본 옆 새 파일 + 실행 전 경로 확인. 원본 불변.
- patch 편집 UX: 오피스 프리뷰에 편집모드 토글.
- (fill 값은 수동 입력 — 다음 사이클 사안.)

## 핵심 흐름

1. 오피스 탭(hwp/hwpx) 프리뷰 우상단 "편집" 토글 → 변환 마크다운이 편집 가능한 에디터로 바뀐다.
2. 사용자가 마크다운을 수정한다.
3. "서식 보존 저장" → 제안 경로(원본 옆 `"<이름> (편집).<확장자>"`) 확인 시트 → 확인 시 `kordoc patch <원본> <임시.md> -o <새파일>` 실행.
4. 원본은 손대지 않고 새 파일로 출력. 성공 토스트(출력 경로)·열기 옵션. 실패 시 안내.

## 아키텍처 (신규 기능은 별도 파일로 분리)

### 신규 파일
- `Sources/Services/KordocWriteService.swift` — `actor KordocWriteService`, `enum KordocWriteError { case toolNotFound, patchFailed(String), timeout }`.
  - `func patch(original: URL, editedMarkdown: String, output: URL) async throws` — 편집 마크다운을 임시 `.md`로 쓰고 `npx -y kordoc patch <원본> <임시.md> -o <출력> --silent` 실행, 120s 타임아웃, stderr→에러. 경로 탐지는 기존 `KordocService.resolveNpxPath()` 재사용.
- `Sources/Views/OfficeSaveConfirmView.swift` — 저장 확인 시트: 제안 경로 표시 → "저장" / "위치 변경…"(NSSavePanel) / "취소".

### 기존 파일 변경
- `Sources/Models/DocumentKind.swift` — `static let patchableExtensions: Set<String> = ["hwp", "hwpx"]` + `static func isPatchable(_ url: URL) -> Bool`.
- `Sources/Views/OfficeReaderView.swift` — `.loaded` 케이스에 편집 토글, 편집 시 `MarkdownTextEditor`(기존 에디터 재사용)로 `appState.officeEditBuffers[tabID]` 바인딩, 저장 바("서식 보존 저장"/"취소"). hwp/hwpx에서만 "편집" 노출.
- `Sources/App/AppState.swift` — 편집 상태/버퍼/메서드 + 순수 헬퍼.
- `Sources/Views/MainEditorView.swift` 또는 `ContentView.swift` — `officeSaveConfirm` 시트 표시 배선(오피스 탭 표시 지점).

## AppState 상태·메서드

- 상태:
  - `officeEditing: Set<UUID>` — 편집 중 탭.
  - `officeEditBuffers: [UUID: String]` — 편집 마크다운(탭 전환에도 보존).
  - `officePatchInProgress: Set<UUID>` — 저장 진행 중.
  - `officeSaveConfirm: OfficeSaveRequest?` — 확인 시트 구동(tabID·fileURL·proposedURL 보유).
- 메서드:
  - `beginOfficeEdit(tabID:)` — `officeStates[tabID]`의 `.loaded` 마크다운을 버퍼로 복사, `officeEditing`에 추가.
  - `cancelOfficeEdit(tabID:)` — 버퍼·편집 상태 제거.
  - `requestOfficeSave(tabID:fileURL:)` — `patchedOutputURL(for:)`로 제안 경로 만들어 `officeSaveConfirm` 설정.
  - `confirmOfficeSave(tabID:fileURL:output:)` — `KordocWriteService.patch` 실행(메인 액터 상태 갱신), 성공 토스트/실패 `errorMessage`.
- 순수 헬퍼(테스트 대상):
  - `static func patchedOutputURL(for original: URL) -> URL` — 같은 폴더, `"<이름> (편집).<확장자>"`, 충돌 시 기존 `URL.uniquified()` 사용, 확장자 보존.
  - `static func kordocWriteErrorMessage(_ error: Error) -> String`.

## 에러 처리·안전

- `KordocWriteError` → 한국어 안내(기존 `kordocErrorMessage` 패턴):
  - `toolNotFound` → "kordoc 실행에 필요한 Node(18+)/kordoc을 찾을 수 없습니다…"
  - `patchFailed(msg)` → "서식 보존 저장에 실패했습니다: <msg 앞부분>"
  - `timeout` → "변환이 너무 오래 걸려 중단했습니다."
- **비파괴 모델**: 원본 미변경, 출력은 새 uniquified 경로, 쓰기 전 확인 시트. 미설치/실패/타임아웃은 크래시 없이 안내.
- **편집 게이트**: `DocumentKind.isPatchable`로 hwp/hwpx만 "편집" 노출. docx/xls 등은 읽기전용 유지.
- **로그/undo**: 쓰기는 비파괴(새 파일·원본 불변)라 본질적으로 사용자가 되돌릴 수 있다(새 파일 삭제). 실행분은 성공 토스트로 출력 경로를 노출해 참조 가능하게 한다. 자동 삭제 undo는 두지 않는다(no-delete 규칙 준수).

## 테스트 (Phase 게이트)

- 시작·종료 시 `swift test`, 기존 112개 유지(정식 Xcode 필요).
- 신규(실제 kordoc 호출 없음):
  - `AppState.patchedOutputURL` — 접미사·확장자 보존·충돌 uniquify.
  - `DocumentKind.isPatchable` — hwp/hwpx true, docx/pdf/md false.
  - `AppState.kordocWriteErrorMessage` — 각 케이스 매핑.
  - 편집 버퍼 begin/cancel 상태 전이.
- 예상 신규 6~9개.

## 핵심 규칙 준수

- 비샌드박스 유지. kordoc은 `Process` 외부 호출만, 직접 구현 안 함.
- 파일 변경은 제안→확인→실행. 원본 이동/삭제 없음(새 파일만 생성).
- LICENSE·원작자 고지 유지. 코드 주석·커밋 메시지 한국어.

## 보류 (다음 사이클)

- **fill**(양식 채우기, `--dry-run` 라벨 조회 + 수동 값) — 별도 spec→plan.
- docx/xlsx 편집(kordoc patch 비대상).
- Claude 값 제안(fill), 편집 중 라이브 프리뷰.
