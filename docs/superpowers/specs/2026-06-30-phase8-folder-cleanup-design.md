# Phase 8 — 폴더 정리(배치) 설계

> 작성일: 2026-06-30 · 대상: cmd-docu · 우선순위: 티어 3
> 관련 PRD: `CmdMD-fork_prd.md` §3.8, Phase 8, §9 파일 이동 안전

## 1. 목적

어수선한 폴더를 Claude가 종류·주제별 정리 계획으로 제안하면, 레고가 승인한 만큼만
이동/이름변경한다. **삭제는 절대 없고**, 모든 이동은 from→to 로그로 남겨 undo한다.
"제안 → 확인 → 실행"을 강제하며 자동 정리는 두지 않는다(배치는 항상 수동).

핵심 대상: ~/Downloads 같은 잡다한 수집 폴더, 정부지원사업 서류·논문 PDF·HWP가 섞인 폴더.

## 2. 정리 목적지 — 두 모드 지원

플랜은 두 모드 공통으로 **제네릭 이동 목록**(`[from→to]`)으로 모델링한다. 모드는
"프롬프트 + 허용 목적지(스킴)"만 바꾸므로 실행·미리보기·검증 로직은 하나로 통합된다.

- **subfolder 모드** — 선택한 폴더 하나를 고르면, 그 안에 종류·주제별 하위폴더를
  만들어 모은다. 예: `~/Downloads` → `Downloads/문서`, `Downloads/이미지`, `Downloads/세금2026`.
- **PARA 모드** — Phase 6의 설정된 PARA 폴더(Projects/Areas/Resources/Archive)로 일괄 라우팅.

## 3. 하위폴더 모드의 폴더 결정 방식 — C안(스킴 제안 → 배정)

Claude가 1차로 폴더 전체를 보고 **하위폴더 스킴(몇 개의 폴더명 + 설명)을 먼저 제안**한다.
사용자가 그 스킴을 보고 편집(이름 수정·버킷 추가/삭제)한 뒤, **확정된 스킴 안으로만**
파일을 배정한다.

- Claude 출력이 스킴(허용 목록) 안으로 한정 → 리뷰·검증이 쉽다.
- `RouteHelper`의 "허용 목록 id 중에서만 선택" 검증 패턴을 그대로 재사용.
- PARA 모드는 후보가 고정(설정된 PARA 폴더)이라 자연히 같은 "허용 목록 배정" 형태로 수렴
  → 두 모드가 하나의 배정·검증 로직으로 통합된다(PARA 모드는 1차 스킴 생성만 생략).

## 4. 컴포넌트 & 파일 구조

CLAUDE.md 규칙대로 전부 신규 별도 파일(업스트림 머지 용이). 기존
`RouteHelper`·`ClaudeService`·`ContentExtractor`·`resolveConflict`/uniquify를 재사용한다.

### Models — `CleanupModels.swift`
- `CleanupMode` — `.subfolder(root: URL)` / `.para(vault: Vault)`
- `CleanupBucket` — `{ id, name, hint }` (스킴의 한 폴더)
- `CleanupScheme` — `[CleanupBucket]` (C안의 "스킴"; 사용자 편집 대상)
- `FileMeta` — `{ url, name, ext, size, createdAt, modifiedAt }` (스캔 결과)
- `CleanupMove` — `{ source: URL, bucketId, reason, confidence: Double, approved: Bool }`
  (목적지 URL은 실행 시 bucket + root/vault에서 해석)
- `CleanupPlan` — `{ mode, scheme, moves: [CleanupMove] }`
- `MoveRecord` — `{ from: URL, to: URL }`
- `MoveBatch` — `{ id, date, mode 설명, records: [MoveRecord], createdDirs: [URL] }` (undo 단위)

### Services (순수 헬퍼, 테스트 대상) — `CleanupPlanner.swift`
`RouteHelper`와 동형의 `enum`.
- `buildSchemePrompt(metadata:) -> String` — 1차: 파일 메타데이터 목록 → 스킴 JSON 제안
- `parseScheme(_:) -> CleanupScheme?` — stdout에서 첫/끝 `{…}` 추출·디코드, 실패 시 nil
- `buildAssignPrompt(scheme:metadata:) -> String` — 2차: 확정 스킴 안으로 배정(bucket id만 선택)
- `buildAssignContext(meta:bodyExcerpt:) -> String` — 모호 파일만 본문 발췌 첨부, truncate
- `parseAssignments(_:scheme:) -> [Assignment]?` — strict JSON 추출·디코드 + **허용 bucketId 검증**
  (목록 밖 id는 거부), confidence 범위 클램프, 미분류 허용

### Services (actor, 부수효과)
- `CleanupService.swift` — 오케스트레이션: 스캔 → 1차 스킴(subfolder 모드만) → 2차 배정
  → confidence 낮은 파일만 본문 발췌(ContentExtractor) 재배정 → `CleanupPlan` 조립.
  `ClaudeService` 재사용.
- `MoveExecutor.swift` — 승인된 move만 `FileManager.moveItem`, 대상 폴더 생성(생성분 추적),
  충돌은 기존 uniquify로 회피(덮어쓰기 금지), **삭제 없음**. 실행분을 `MoveLogStore`에 영속.
  `undo(batch:)` = 역방향 이동 + 비게 된 *우리가 생성한* 폴더만 제거.
- `MoveLogStore.swift` — Application Support에 배치 로그 JSON 영속(load/append/remove).

### Views — `FolderCleanupView.swift` (시트)
폴더 선택 → 모드 토글 → 스캔/플랜 진행률 → **스킴 편집** → 플랜 미리보기 표
(행별 체크박스로 부분 승인, confidence·이유 표시) → Apply.
하단 "정리 기록" 영역에서 배치별 되돌리기.
진입점: 커맨드 팔레트 + View 메뉴(IndexSearchView와 동일 패턴).

## 5. 데이터 흐름 (제안 → 확인 → 실행)

```
1. 폴더 선택 + 모드 선택
2. 스캔: 폴더 1단계(top-level) 파일 열거 → 메타데이터 수집.
        숨김파일·기존 하위폴더 제외.
3. 1차 (스킴):
   - subfolder 모드: buildSchemePrompt → Claude → parseScheme
   - PARA 모드: 스킴 = 설정된 PARA 폴더(고정), Claude 호출 생략
   → 사용자에게 스킴 제시 (이름 편집·버킷 추가/삭제 가능)
4. 2차 (배정): buildAssignPrompt(확정 스킴) → Claude → parseAssignments
   - 각 파일 {bucketId, reason, confidence}
   - confidence < 임계(0.6)인 파일만 모아 본문 발췌(ContentExtractor) 첨부해 재배정
5. CleanupPlan 미리보기 표 (source → bucket, 이유, confidence, 체크박스)
   - 기본 전체 체크, 낮은 confidence 강조
6. Apply → MoveExecutor: 승인된 것만 이동, MoveLog 배치 기록
7. 정리 기록: 배치별 "되돌리기"
```

## 6. 안전 (CLAUDE.md + PRD §9)

- **제안만, 자동 OFF.** 승인 없이 어떤 파일도 안 움직인다. 자동 정리 토글을 두지 않는다.
- **이동·이름변경만, 삭제 절대 없음.** undo의 폴더 정리도 *빈* 폴더 + *우리가 생성한*
  폴더만 제거(생성 목록 추적), 파일은 안 지운다.
- **충돌**: 대상에 동명 파일이 있으면 기존 uniquify(`name 2.ext`)로 회피, 덮어쓰기 금지.
- **경로 검증**: bucket 폴더는 항상 선택 root(또는 PARA 볼트) 하위로만. Claude가 준
  이름은 sanitize(경로구분자·`..` 제거)해 디렉터리 탈출을 막는다.

## 7. 에러 처리 (크래시 금지, 안내만)

- claude 미설치/미로그인/크레딧소진 → 기존 `claudeErrorMessage` 분류 재사용, 시트에 메시지.
- 스킴/배정 JSON 파싱 실패 → 해당 단계 중단, "Claude 응답을 해석하지 못함" 안내(부분 결과 버림).
- 배정 못 받은 파일 → "미분류"로 남기고 이동 대상에서 제외(승인 표에 표시).
- 이동 중 개별 실패(권한 등) → 그 파일만 skip + 기록, 배치는 계속. 실패 목록 토스트.
- kordoc 본문 추출 실패(HWP 등) → 그 파일은 메타데이터만으로 배정(2차 생략).

## 8. 테스트 전략

Phase 7 패턴(순수 로직은 in-process 단위테스트, Claude·UI는 수동).

- `CleanupPlannerTests`
  - `buildSchemePrompt`/`buildAssignPrompt` 형태·메타데이터 직렬화
  - `parseScheme` — 정상 JSON, 잡텍스트 둘러싼 JSON, 깨진 JSON → nil
  - `parseAssignments` — **허용 bucketId 외 값 거부**, confidence 범위, 미분류 처리
  - `buildAssignContext` — 모호 파일만 본문 첨부, truncate
- `MoveExecutorTests` (임시 디렉터리에서 실제 FileManager)
  - 이동 성공 → MoveBatch 1건, from→to 정확
  - 충돌 → uniquify 적용, 원본 덮어쓰기 안 함
  - **undo** → 파일 원위치 복귀, 생성된 빈 폴더만 제거, 원래 폴더·파일 불변
  - 경로 sanitize — `..`·경로구분자 든 bucket 이름이 root 밖으로 못 나감
  - 삭제 호출 없음(권한 실패 파일 skip)
- `MoveLogStoreTests` — append/load/remove 라운드트립, 영속 인코딩 안정성
- `CleanupModelsTests` — Codable 라운드트립, 하위호환 디코드

수동 검증: 실제 claude 호출(스킴·배정 품질), 시트 UI, ~/Downloads 실폴더 정리·되돌리기 1회.

## 9. Phase 게이트 (CLAUDE.md)

- 시작 전: `swift test`로 현재 ~175개 통과 확인(기준선).
- 완료 후: 기존 + 신규 단위테스트 전부 통과 확인 후 커밋.
- ⚠️ `swift test`엔 정식 Xcode 필요. CLT만 있으면 `swift build`까지만 가능 —
  그 경우 빌드 + 수동검증으로 게이트.

## 10. 범위 밖 (YAGNI / 후속)

- 재귀(하위폴더 깊이) 스캔 — v1은 top-level 1단계만.
- 자유 파일명 변경 규칙·일괄 리네임 패턴 — v1은 모드별 폴더 이동이 핵심.
- 자동 정리(파일 감시 연동) — 두지 않음.
