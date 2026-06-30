# Task 11 — 최종리뷰 반영 Fix Report

## 적용 일시
2026-06-30

## FIX 1 — CleanupPlan.mode 추가
- `Sources/Models/CleanupModels.swift`: `CleanupPlan`에 `let mode: CleanupMode` 첫 번째 저장 프로퍼티 추가.
- `Tests/CmdMDTests/MoveExecutorTests.swift`: 내부 `plan(scheme:moves:)` 헬퍼에 `mode` 파라미터 추가(기본값 `.subfolder(root:"/tmp")`).

## FIX 2 — 2단계 스킴 흐름
- `Sources/App/AppState.swift`:
  - `runCleanupPlan()` 삭제.
  - `proposeCleanupScheme()` 추가 (1단계: 스킴 제안, plan은 nil 유지).
  - `assignCleanupPlan()` 추가 (2단계: 배정 후 `CleanupPlan(mode:scheme:moves:)` 생성).
  - `resetCleanup()` 추가 (커맨드팔레트 재진입 시 전체 초기화).
  - `startCleanup(folder:)`, `startCleanupToPara(vault:)`에 `cleanupError = nil` 추가.
  - `applyCleanup()`에서 `mode` 지역 바인딩 제거 → `plan.mode` 직접 사용.

## FIX 3 — PARA 진입점
- `Sources/Views/VaultManagerView.swift` `ParaManagerPane`:
  - `@Environment(\.dismiss)` 추가.
  - "폴더 정리" Section 추가: "이 볼트를 PARA로 정리…" 버튼 + `.disabled(!appState.isParaRoutingConfigured())`.

## FIX 4 — FolderCleanupView 2단계 흐름
- `Sources/Views/FolderCleanupView.swift`:
  - `planActionsView`: `runCleanupPlan` 단일 버튼 → 상태에 따른 "스킴 만들기"(1단계) / "배정하기"(2단계) 분기.
  - "폴더 선택…" 버튼에 `.disabled(appState.cleanupBusy)` 추가.
- `Sources/Views/CommandPaletteView.swift`: "폴더 정리 (배치)" 액션에 `appState.resetCleanup()` 선행 호출 추가.

## FIX 5 — 테스트
- `Tests/CmdMDTests/CleanupModelsTests.swift`: `testCleanupPlanCarriesMode()` 추가 — `CleanupPlan.mode`가 `.subfolder` 그대로 전달됨을 검증.

## 빌드/테스트 결과
- `swift build`: Build complete (오류 0)
- `swift test`: 208 tests, 0 failures — 기준 207개 대비 1개 증가 (FIX 5 신규 테스트)
