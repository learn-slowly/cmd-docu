# LLM-Wiki 인제스트(단일 문서) — 설계

날짜: 2026-07-06
상태: 설계 확정(사용자 구두 승인) — 스펙 리뷰 대기
배경: PRD §8 — LLM-Wiki(Karpathy 패턴)에서 위키 = 볼트의 md 파일, 앱의 역할 = 뷰어 + **Ingest**/Query 손잡이. Query(검색·RAG)는 완료 상태, 이번이 Ingest 손잡이.

## §0 사용자 결정 (2026-07-06 브레인스토밍)

1. 인제스트 산출물 = **기존 위키 페이지에 병합**(Karpathy 원형 — 페이지가 유기적으로 자란다). 새 페이지 생성도 가능.
2. 병합 대상 페이지 = **사용자가 직접 선택**(자동 매칭 없음).
3. 적용 방식 = **diff 미리보기 + 백업 후 덮어쓰기**(기존 페이지 본문을 수정하는 첫 기능 — 안전장치 필수).
4. 범위 = **한 번에 단일 문서만**(주 대상 PDF). 다중 파일·파일별 대상 지정은 후속.

## §1 목표·흐름

읽던 자료(주로 PDF)를 위키 페이지에 녹여 넣는다. 원본 파일은 불변 — 쓰기는 위키 페이지(md) 하나뿐.

```
파일 1개 선택 → "위키에 인제스트…" 시트
  → 대상 선택: 위키 폴더의 md 목록 Picker ─또는─ "새 페이지…" 이름 입력
  → [병합 생성]: Claude가 [기존 페이지 전문 + 소스 발췌 + 페이지 규칙] → 갱신된 페이지 전문
  → diff 미리보기(줄 단위 추가/삭제 하이라이트)
  → [적용]: 직전 본 백업 → 덮어쓰기(새 페이지면 생성) → 완료 안내
```

진입점 2곳:
- **①트리/라이브러리 단일 파일 컨텍스트 메뉴** "위키에 인제스트…" — 다중 선택 상태(`fileSelection.count > 1`)에선 표시하지 않음(배치 메뉴와 혼동 방지).
- **②커맨드 팔레트** "현재 문서를 위키에 인제스트" — 활성 탭의 `fileURL` 대상(주 사용 흐름: PDF 읽다가 바로). 활성 탭이 없거나 fileURL 없으면 안내.

## §2 구성요소 (전부 별도 파일 — 업스트림 머지 용이성 관례)

### §2.1 `WikiIngestModels` (순수 헬퍼)

- `WikiIngestTarget`: `.existing(URL)` | `.new(name: String)`(위키 폴더에 `이름.md` 생성 — 이름 정제는 `CleanupPlanner.sanitizeBucketName` 재사용·경로탈출 방지·충돌 시 기존 `uniquified()` 재사용).
- `mergePrompt(pageTitle:pageBody:sourceName:sourceExcerpt:) -> (prompt: String, context: String)` — 병합 프롬프트 빌더. 규칙(프롬프트에 내장 = 앱 안의 페이지 스키마):
  - 출력은 **갱신된 페이지 전문 md만**(서문·코드펜스 금지).
  - frontmatter `sources:` 목록에 `- <원본 파일명> (YYYY-MM-DD)` 항목 누적(기존 항목 보존). frontmatter가 없던 페이지면 만든다.
  - 기존 페이지의 정보를 유실하지 말 것(재구성·중복 제거는 허용, 삭제는 금지).
  - 새 페이지(`pageBody` 빈 값)면 제목 헤딩 + 소스 요약으로 신설.
  - 이미 `sources:`에 있는 원본을 재인제스트하면 "갱신"으로 다뤄 중복 서술을 만들지 말 것.
  - 한국어로 답할 것(소스가 외국어라도 위키 본문은 한국어).
- `extractMarkdown(from stdout: String) -> String?` — 응답 검증·정리: 앞뒤 잡담 제거, 전체가 코드펜스로 감싸였으면 벗김, frontmatter(`---`)로 시작하는 본문 우선. 빈 결과는 항상 실패, 기존 페이지 병합에 한해 급격 축소(길이 < 기존의 40%)도 실패로 판정(유실 방어 1차 — 최종 방어는 diff 승인. 새 페이지는 기존 본문이 없어 미적용).
- 크기 한도(타임아웃 방어 — 폴더 정리 교훈: 출력이 입력 규모에 비례):
  - 소스 발췌 한도 60,000자(초과분 truncate + 프롬프트에 "발췌본" 명시).
    > **정정(2026-07-06 실사용):** 최초값 12,000자(RagContextBuilder 전례 이식)는 주 사용례인
    > 학술 논문(36쪽=48,273자 실측)의 25%만 전달해 페이지가 "앞부분 발췌 기반"으로만 생성됐다
    > (신진욱2011 사례 — 절단 지점과 페이지 중단 문장이 일치). 단일 문서 전체 이해가 목적이고
    > 타임아웃의 실제 제약은 출력(페이지 한도)이므로 60,000자로 상향.
  - 대상 페이지 한도 24,000자 — 초과 시 병합 거부·안내("페이지가 너무 큽니다 — 분할 후 재시도"). 출력=페이지 전문이라 이 한도가 곧 출력 상한.

### §2.2 `LineDiff` (순수 헬퍼)

- LCS 기반 줄 diff: `diff(old: String, new: String) -> [Line]`, `Line = (kind: .same|.added|.removed, text: String)`.
- 시트 렌더용(추가=초록 배경·삭제=빨강 취소선). 성능: 페이지 한도 24k자·수백 줄 규모라 O(n·m) LCS로 충분.

### §2.3 `WikiIngestService` (actor)

- `ingest(source: URL, target: WikiIngestTarget, wikiFolder: URL) async throws -> WikiMergeProposal`
  1. 소스 본문: `ContentExtractor.body(for:kordoc:)` 재사용(pdf/md=로컬, hwp 등 office=kordoc). nil이면 `.sourceUnreadable`.
  2. 대상 본문: existing이면 읽기(실패 시 에러), new면 빈 값.
  3. 한도 검사 → `mergePrompt` → `ClaudeAsking.ask`(120s — `CleanupService.askWithRetry`와 동형의 타임아웃 1회 재시도를 서비스 안에 둠).
  4. `extractMarkdown` 검증 → `WikiMergeProposal(target:oldBody:newBody:)` 반환. **여기서는 쓰지 않는다**(제안→확인→실행).
- 의존은 `ClaudeAsking` 프로토콜로 좁혀 FakeClaude 주입 테스트(폴더 정리 전례).

### §2.4 `WikiBackupStore` (actor)

- 적용 직전 본을 앱 데이터 디렉터리 `wiki-backups/`에 저장: `<페이지파일명>-<타임스탬프>.md` + `wiki-ingest-log.json`(페이지 경로·백업 파일·소스·일시). 볼트 안엔 잡파일을 만들지 않는다.
- `restore(entry)` — 백업본을 페이지 경로에 되돌려 쓰기(현재 본은 다시 백업 후 교체 — 왕복 안전). 로그는 보존.
- 새 페이지 생성의 "백업"은 없음 — 복원 = 생성 파일을 휴지통 이동(`FileOperations.trash` 재사용, 삭제 없음 규칙).

### §2.5 `WikiIngestView` (시트) + 배선

- 시트 구성: 소스 파일 표시 → 대상 Picker(위키 폴더 최상위 `.md` 목록, 이름순) / "새 페이지…" 선택 시 이름 TextField → [병합 생성](busy 스피너·진행 문구) → diff 스크롤 뷰 → [적용]/[취소]. 적용 후 "열기" 버튼(해당 페이지 탭으로).
- 시트 하단 "인제스트 기록" — `wiki-ingest-log.json` 목록 + 행별 [되돌리기].
- `AppState`: `showWikiIngest(source: URL)`(시트 상태·소스), `applyWikiMerge(proposal:)`(백업→쓰기→토스트·완료), busy 가드(폴더 정리 전례 — busy 중 재진입 방지).
- `AppSettings.wikiFolder: String?`(절대 경로, 하위호환 decodeIfPresent) + Tools 탭 "LLM-Wiki" 섹션(폴더 선택 NSOpenPanel·현재 경로 표시). 미설정 상태에서 진입 시 시트가 안내 + 바로 지정 버튼.
- 진입점: §1의 2곳. 다중 선택 컨텍스트 메뉴(`BatchSelectionMenu`)에는 넣지 않는다.

## §3 안전·정책

- **제안→확인→실행**: Claude 결과는 diff 승인 전까지 디스크에 닿지 않는다. 원본 소스 파일 불변.
- 덮어쓰기 전 백업 + 기록 복원(§2.4). 삭제 없음(새 페이지 복원도 휴지통).
- `claude -p`로 소스 발췌·페이지 본문이 전송됨 — 민감 문서 주의는 기존 Claude 기능들과 동일(PRD §9).
- 위키 페이지가 앱의 검색 인덱스 등록 폴더면 기존 FSEvents 감시가 자동 재인덱싱(추가 작업 없음).

## §4 테스트

순수·주입 가능한 것 단위(관례: Claude/kordoc/UI는 수동):
1. `mergePrompt` — 규칙 문구·frontmatter 지시·발췌 한도 truncate 반영.
2. `extractMarkdown` — 코드펜스 벗김·서문 제거·빈/급축소 거부.
3. 페이지 한도 초과 거부, 새 페이지 이름 sanitize·경로탈출 방지·uniquify.
4. `LineDiff` — 추가/삭제/동일 케이스·빈 문서·전체 교체.
5. `WikiIngestService` — FakeClaude 주입: 정상 병합 제안 생성, 타임아웃 1회 재시도, 검증 실패 에러, 쓰기 없음(제안 단계) 확인.
6. `WikiBackupStore` — 백업 생성·로그·복원 왕복(임시 디렉터리).
7. `AppSettings.wikiFolder` 하위호환 디코드.

수동 스모크: 실제 PDF → 기존 페이지 병합 diff·적용·복원, 새 페이지 생성, hwp 소스(kordoc), 한도 초과 안내, 팔레트 진입(활성 PDF 탭).

## §5 비범위 (후속 후보)

- 다중 파일 인제스트·파일별 대상 지정(§0-4에서 축소).
- 자동 대상 매칭·MOC/인덱스 페이지 갱신.
- 볼트용 LLM-Wiki 스키마 CLAUDE.md(PRD §8 별도 산출물 — 앱 밖 Claude Code 운영용, 요청 시 별도 작성).
- 임베딩·시맨틱(RAG A안 계열 — 사용자 보류 결정 유지).
