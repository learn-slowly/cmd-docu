# 한국어 검색 근본 수정 — FTS5 trigram 부분일치 (조사·복합어) 설계

> 작성일 2026-07-01. cmd-docu. Phase 9 후속(공유 검색 인덱스 개선). PRD 티어 3 검색 품질.
> 원칙: 비샌드박스 유지 · macOS 내장(SQLite) 외 새 의존성 없음 · 검색/읽기 전용 · Phase 게이트(swift test).

## 0. 문제 (실측 확정)

`SearchIndex`의 FTS5 `docs`는 `tokenize='unicode61'`이라 **한국어 형태소를 못 나눈다.** "평가서"로 검색해도 문서의 "평가서에"(조사 붙음)를 못 찾고, "선거"로 "지방선거"(복합어)를 못 찾는다. 한국어 지식베이스 검색 recall에 치명적이며 Phase 7 키워드검색·Phase 9 RAG 검색 **둘 다** 이 한 인덱스를 쓴다.

**spike 실측(SQLite 3.51.0, 이 앱이 링크하는 시스템 libsqlite3):**
- `NLTokenizer(unit:.word)`는 한국어 조사를 **안 나눔**("평가서에"→한 토큰, "국회에서"·"정책의"도) → 형태소 분석기 아님, 탈락.
- unicode61 접두검색 `"평가서"*`는 명사→명사+조사(평가서→평가서에)만 잡고 **복합어(선거→지방선거)·역방향은 실패**.
- **`tokenize='trigram'`은 부분일치**라 평가서↔평가서에, 선거↔지방선거를 **양방향 다** 잡음. 유일 제약: **MATCH는 3글자 이상**만("선거" 2글자 → 0).
- 같은 trigram 테이블에서 **`body LIKE '%선거%'`(2글자)도 정상**(단, ≤2글자는 인덱스 미가속·스캔).
- **한 쿼리에서 `t MATCH '"평가서"' OR body LIKE '%예산%'` / `… AND …` 둘 다 동작**(union 불필요), 순수 MATCH OR(≥3글자)+`ORDER BY rank` OK, `snippet(docs,2,…)`도 trigram MATCH에서 정상(`…선거 [평가서]에 총평`).

## 1. 목표

`docs` FTS5 토크나이저를 **trigram**으로 바꿔 한국어 **부분일치**(조사·복합어 양방향)를 지원한다. trigram의 2글자 구멍은 **≤2글자 용어를 `LIKE '%…%'` 폴백**으로 메운다(같은 테이블, 한 쿼리). 검색 결과 순위는 ≥3글자 MATCH가 있을 때 BM25(`rank`) 유지. 기존 인덱스 DB는 스키마 버전으로 **자동 재구성 후 등록 폴더 재인덱싱**한다. Phase 7 키워드검색·Phase 9 RAG 검색이 함께 고쳐진다.

**감수하는 것:** 영어 검색이 단어→**부분일치**로 바뀐다("cat"이 "category"도 매치). 한국어 우선 KB에선 recall 이득이 크고 노이즈는 BM25·top-N으로 완화(레고 승인). trigram 인덱스는 unicode61보다 약간 크다(현 DB 32KB, 무시할 수준).

## 2. 아키텍처

`SearchIndex.swift` 한 파일이 스키마·마이그레이션·쿼리를 담당(기존 구조 유지, 신규 순수 헬퍼는 분리). RAG 검색 경로(`RagRetriever`)와 확장(`RagQueryExpansion`)이 새 쿼리 API에 맞게 조정된다.

### 2.1 스키마 + 마이그레이션 (`SearchIndex`)

토크나이저를 바꾼다:
```sql
CREATE VIRTUAL TABLE IF NOT EXISTS docs USING fts5(
  path UNINDEXED, filename, body, tokenize = 'trigram'
);
```
`CREATE … IF NOT EXISTS`는 기존 테이블의 토크나이저를 바꾸지 않으므로 **버전 기반 재구성**을 넣는다:
```sql
CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT);
```
- `init`에서 `meta`의 `schemaVersion`을 읽어 현재 상수(`SearchIndex.schemaVersion = 2`)와 다르면(또는 없으면) **`DROP TABLE docs; DROP TABLE files;` 후 trigram으로 재생성**하고 `schemaVersion`을 기록한다. DB는 재생성 가능한 캐시라 안전(기존 손상 복구 경로와 동일 철학).
- 재구성이 일어났는지 플래그로 노출: `init` 중 `private(set) var didResetForSchemaChange: Bool`. (actor 프로퍼티 — 호출자는 `await`.)
- 기존 열기/스키마 실패 시 DB 삭제·재생성 로직은 유지.

### 2.2 쿼리 빌더 (신규 순수 헬퍼) — `TrigramQuery`

`FTSQuery.sanitize`(unicode61용 접두검색)를 대체한다. 용어 목록 + 결합모드 → SQL 조각·바인딩.
```swift
enum SearchMode { case and, or }

enum TrigramQuery {
    struct Built: Equatable {
        let whereClause: String     // 예: "(docs MATCH ?) OR (body LIKE ? ESCAPE '\\')"
        let matchArg: String?       // MATCH 바인딩(있으면), 없으면 nil
        let likeArgs: [String]      // LIKE 바인딩("%term%"), 순서=whereClause의 ? 순서(match 다음)
        let hasMatch: Bool          // ORDER BY rank 사용 여부
    }
    /// 용어를 길이로 분할: ≥3글자→trigram MATCH 구(구절=부분일치), ≤2글자(1~2)→LIKE.
    /// 빈 용어 무시. 유효 용어 0이면 nil(검색 안 함).
    /// - MATCH 구: 각 용어를 "…"로 감싸고 내부 " 는 "" 로 이스케이프, mode에 따라 공백(AND)/ OR 로 결합.
    /// - LIKE: 각 ≤2글자 용어를 %…% 로, %/_/\ 이스케이프(ESCAPE '\').
    /// - 결합: matchClause 와 likeClauses 를 mode 커넥터(AND/OR)로 이어붙임. 한쪽이 비면 다른 쪽만.
    static func build(terms: [String], mode: SearchMode) -> Built?
}
```
- `term.count`(Swift Character 수) ≥ 3 → matchTerms, 1~2 → likeTerms.
- 근거: §0 실측 — MATCH/LIKE를 한 WHERE에서 AND/OR 결합 가능.

### 2.3 검색 실행 (`SearchIndex`)

핵심 저수준 메서드 신설:
```swift
/// 용어 목록을 trigram MATCH(≥3글자)+LIKE(≤2글자)로 검색한다. filenameMatch 판정 옵션.
func searchTerms(_ terms: [String], mode: SearchMode, flagFilename: Bool = false, limit: Int = 200) -> [IndexHit]
```
- `TrigramQuery.build`로 WHERE·바인딩 구성. SQL:
  ```sql
  SELECT path, <snippetExpr>, <fnameExpr>
  FROM docs WHERE <whereClause> [ORDER BY rank] LIMIT ?;
  ```
  - `<snippetExpr>`: `hasMatch`면 `snippet(docs, 2, '[', ']', '…', 10)`, 아니면(LIKE 전용) `''`(스니펫은 호출측/뷰가 수동 생성 — 아래).
  - `<fnameExpr>`: `flagFilename`이고 첫 용어가 있으면 `(INSTR(lower(filename), lower(?)) > 0)`, 아니면 `0`.
  - `ORDER BY rank`는 **hasMatch일 때만**(LIKE 전용 쿼리엔 rank 없음 → 생략, rowid 순).
  - 바인딩 순서: [fnameArg(옵션)] → matchArg(옵션) → likeArgs → limit. (SQL 조립 시 ? 순서와 정확히 일치시킴.)
- 기존 공개 API 재구성:
  - `search(query:limit:)` → 질의를 공백 토큰화 → `searchTerms(tokens, mode:.and, flagFilename:true)`. 시그니처·반환(`[IndexHit]`) 보존(IndexSearchView·AppState.runIndexSearch 호환). 이제 조사·복합어·부분일치로 매치.
  - **`searchMatch(_:limit:)` 제거** — Phase 9 Task 2에서 넣은 raw-MATCH-문자열 API. ≤2글자 LIKE 폴백을 문자열로 표현할 수 없어 용어배열 API(`searchTerms`)로 대체. 유일 호출자 `RagRetriever`를 아래처럼 전환하므로 제거(+ `SearchIndexMatchTests` 제거).
- **LIKE 전용 결과의 스니펫**: `hasMatch`가 false면 `snippet()` 대신 빈 문자열(`''`)을 반환한다. **RAG 경로는 스니펫을 안 쓰므로**(RagRetriever는 경로만 반환, 근거 본문은 `RagPassageExtractor`가 재추출) 영향 없음. IndexSearchView 표시만 해당하며, 빈 스니펫이면 뷰가 본문 앞부분을 보여주는 폴백으로 충분(정밀 수동 스니펫은 §5 후속). 이 경우(전부 ≤2글자 단독 쿼리)는 드물다.

### 2.4 RAG 검색 경로 조정

- `RagRetriever.topFiles(question:expandedTerms:limit:)`:
  - `primary = searchTerms(questionTokens, mode:.and)` (질문 전 토큰이 부분일치로 다 든 문서).
  - `secondary = searchTerms(questionTokens + expandedTerms, mode:.or)` (원질문 토큰·확장어 중 하나라도 — recall).
  - `mergePaths(primary, secondary, limit)` 그대로. **원질문 토큰이 OR에 들어가는 최종리뷰 fix는 유지**(이제 trigram이라 부분일치까지).
  - 토큰화 헬퍼는 기존 `RagRetriever.tokens(_:)` 재사용(fix wave에서 추가됨).
- `RagQueryExpansion`: **`orMatch(_:) 제거**(이제 검색은 용어배열로 함) + 해당 테스트 제거. `prompt()`/`parse(_:)`는 유지(확장어 추출은 그대로).
- `RagService.ask` 흐름 불변(retriever가 내부에서 새 API 사용).

### 2.5 마이그레이션 재인덱싱 (`AppState`)

스키마 재구성 후 인덱스가 비므로 등록 폴더를 **1회 자동 재인덱싱**한다.
- `init`(loadUserData·searchIndex 생성 이후): `if await searchIndex.didResetForSchemaChange { 등록 폴더 각각 background reindex }`. 기존 `reindexFolder(_:)`(진행률 `indexInProgress`/`indexProgress` UI 재사용)를 등록 폴더마다 호출. off-main.
- 등록 폴더 없으면 아무 일도 안 함. 재인덱싱은 읽기 전용(원본 불변).

## 3. 에러·안전

- 인덱스는 **읽기/재구성만** — 원본 파일 불변, 삭제 없음. 재구성은 캐시 DB만.
- LIKE 폴백은 ≤2글자에만(스캔). 개인 KB(수천~수만 문서)에서 허용. 대부분 쿼리는 ≥3글자 포함 → MATCH 인덱스 사용.
- `ORDER BY rank`는 MATCH 있을 때만(없으면 rank 미존재 → 에러) — 빌더의 `hasMatch`로 분기.
- 마이그레이션 실패해도 크래시 없음(빈 인덱스로 시작 → 사용자가 재인덱싱 가능, 기존 안전망 유지).
- 영어 부분일치 전환은 의도된 동작(레고 승인). 문서화만.

## 4. 테스트 (Phase 게이트)

SQLite in-process라 인덱스·빌더를 단위테스트. Claude/kordoc/UI/마이그레이션-후-앱재인덱싱은 수동/부분.
- `TrigramQuery.build`(순수): ≥3/≤2 분할, AND/OR MATCH 구 문자열·LIKE 절 생성·이스케이프(", %, _, \), 빈 용어·전부 빈→nil, hasMatch 플래그, 바인딩 순서.
- `SearchIndex.searchTerms`(임시 trigram DB):
  - 조사: 본문 "평가서에" → `["평가서"]`(.and/.or 둘 다) 히트.
  - 복합어(2글자 LIKE): 본문 "지방선거" → `["선거"]` 히트.
  - 3글자 부분일치: 본문 "지방선거" → `["지방선"]`·`["방선거"]` 히트, 무관 문서 미히트.
  - AND: 두 부분일치 모두 있는 문서만. OR: 하나라도.
  - hasMatch(≥3 포함) 시 결과 존재·rank 순; LIKE 전용(≤2만) 시도 히트.
- `SearchIndex.search(query:)` 회귀: `[IndexHit]` 반환·filename 매치 플래그·한국어 조사/복합어 이제 매치(개선 확인).
- 마이그레이션: 구 스키마 DB(수동으로 `docs … unicode61` + 행 1개, meta 없음) 작성 후 `SearchIndex(dbURL:)` → 재구성됨(구 행 사라짐 `count()==0`, `didResetForSchemaChange==true`), 이후 upsert "지방선거"→`searchTerms(["선거"])` 히트(trigram 활성 확인).
- `RagRetriever`(임시 trigram DB): 부분단어 질문("정의당 평가서에 뭐라고 썼더라", expandedTerms=[])이 "정의당 평가서 초안" 문서를 회수(조사 무관, .and/.or 경로).
- 제거 반영: `SearchIndexMatchTests`·`RagQueryExpansion.orMatch` 테스트 삭제, `RagQueryExpansionTests`는 parse/prompt만.
- LIKE 전용 히트의 빈 스니펫 허용(뷰 폴백은 수동).

게이트: 시작·종료 `swift test` 통과. 현재 307에서 제거(`SearchIndexMatchTests` 2 + `RagQueryExpansion` orMatch 2 = −4) + 신규(빌더·searchTerms·마이그레이션·검색회귀·RagRetriever)만큼 순증. 정식 Xcode 필요.

## 5. 범위 밖(후속)

- LIKE 전용(≤2글자) 히트의 정밀 수동 스니펫(현재 뷰 폴백).
- 시맨틱/임베딩(A안) — 별건.
- 한국어 형태소 분석기(mecab-ko 등) 도입 — trigram으로 충분치 않다고 판명될 때만(의존성 큼).
- 영어 전용 단어검색 모드 토글(현재 전역 부분일치) — 필요 시 다듬기.
