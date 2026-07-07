# 다중 문서 위키 인제스트 — 일괄 처리 큐 (2026-07-07)

## 결정 (사용자, 2026-07-07)
- **일괄 처리**: 여러 파일 선택 → 각 파일을 **자동 모드(규칙에 따름)** 로 각자 페이지에 순차 인제스트.
- 문서별 **독립 병합·독립 diff 승인·독립 백업** — [건너뛰기] [적용 후 다음 →] [중단].
- "한 페이지 병합"(N소스→1페이지)은 이번 범위 밖(단일 인제스트를 페이지에 반복하면 sources: 누적으로 동등).

## 왜 자동 모드 전제인가
일괄의 대상 페이지는 문서마다 다르다 — 문서별 수동 대상 선택은 일괄의 의미를 없앤다.
자동 모드는 규칙 요약이 전제(AppState.generateWikiMerge 가드) → 규칙 미파악 상태로 시트를 열면
안내만 표시(생성 불가). 자동 모드는 항상 **새 페이지**(점유 시 에러)라 더티 탭 가드도 자연 무관.

## 구성
- `WikiBatchQueue`(순수, Services/WikiBatchModels.swift): files·outcomes(적용(URL)/건너뜀/실패(String))·
  currentIndex·advance(with:)·abort()·집계(applied/skipped/failed/unprocessed)·progressLabel "(i/n)".
  abort = currentIndex를 끝으로 — 남은 항목은 outcome nil(미처리).
- `WikiBatchIngestRequest`(Identifiable, files: [URL]) + `AppState.wikiBatchRequest` +
  `requestWikiBatchIngest(sources:)`(파일만·비면 무동작·이전 제안/에러 클리어; busy 중이면 시트만 재표시 —
  단일 requestWikiIngest 패턴).
- `WikiBatchIngestView`(새 파일): 파일 목록 확인 → [일괄 인제스트 시작](제안→확인→실행 결) →
  문서별 startWikiMerge(.auto) → 제안 도착(onChange, sourceURL 일치 확인) → diff + 3버튼 →
  적용=applyWikiMerge(성공 시 advance(.applied)·다음 자동 시작 / 실패 시 에러 표시·재시도 가능) /
  건너뛰기=advance(.skipped)·다음 / 중단=cancelWikiMerge+abort → 요약(적용 목록·페이지 열기·건너뜀·실패·미처리).
  onDisappear=cancelWikiMerge. 생성 에러 시 [다시 시도] [건너뛰기] [중단].
- diff 렌더는 `WikiDiffListView`(새 파일)로 추출해 단일 시트와 공용.
- 진입점: `BatchSelectionMenu`에 "N개 파일을 위키에 인제스트…"(선택이 전부 파일일 때만) +
  ContentView `.sheet(item: $state.wikiBatchRequest)`.

## 재사용·불변
- 단일 인제스트의 상태(wikiMergeProposal/wikiIngestError/wikiIngestBusy)·API(startWikiMerge/
  applyWikiMerge/cancelWikiMerge)를 그대로 쓴다 — 배치 전용 상태는 큐(뷰 @State)와 request뿐.
- 두 시트는 동시에 열리지 않는다(공유 상태 충돌 없음). 각 적용은 기존 백업·기록 경로 그대로
  (문서별 undo 공짜). 쓰기는 승인된 적용뿐(무단 쓰기 없음).

## 테스트
- WikiBatchQueue 순수 전이(진행·건너뜀·실패·중단·집계·경계) — 단위.
- requestWikiBatchIngest 상태 배선 — 단위.
- 흐름(생성→diff→적용→다음)·요약·진입점은 실기 스모크(F 단계).
