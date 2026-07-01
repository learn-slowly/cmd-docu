# Phase 9 — 가벼운 RAG (자료에 묻기: FTS5 근거 + Claude 답변) 설계

> 작성일 2026-07-01. cmd-docu 티어 3. PRD Phase 9(시맨틱+RAG)의 **재정의(B안)**.
> 원칙: 비샌드박스 유지 · macOS 내장 + 기존 서비스만 재사용(새 패키지 의존성 없음) · 검색/읽기 전용(파일 이동·삭제 없음) · 제안만·근거 표시 · Phase 게이트(swift test).

## 0. 방향 재정의 (브레인스토밍 결론)

PRD 원안의 Phase 9는 "임베딩·벡터 인덱스 + 하이브리드 + RAG"(가장 무거움)였다. 브레인스토밍에서 **임베딩 없는 가벼운 RAG(B안)** 로 재정의했다.

- **왜 B:** 사용자가 보는 가치("내 자료 근거로 질문하면 출처와 함께 답")를 이미 있는 **FTS5(Phase 7) + ClaudeService(Phase 4)** 재사용으로 거의 새 인프라 없이 낸다. 가장 불확실한 리스크(한국어 임베딩 품질)를 뒤로 미룬다.
- **B vs C(위임):** B는 **앱이** 검색을 소유한다(FTS5로 근거를 골라 Claude에 붙임 → 앱이 무엇을 보냈는지 정확히 알아 **출처 클릭 점프**를 앱이 만든다, 1콜, 빠름·저렴·예측가능). C(폴더째 `claude -p`/Claude Code 위임)는 앱 코드가 얇고 출처가 부정확·느림·크레딧 과다라 채택 안 함.
- **A로 가는 길목:** B의 약점은 순수 키워드 검색이라 동의어를 놓치는 것. 1차로 **Claude 질의 확장**(값싼 대안)으로 recall을 메우고, 부족하면 훗날 이 검색 자리에 임베딩을 끼워 A로 진화시킨다(별건).

## 1. 목표

커맨드 팔레트/메뉴에서 **"자료에 묻기 (RAG)"** 시트를 열고 자연어로 질문하면, 앱이 **등록 폴더(Phase 7 `indexedFolders`)의 FTS5 인덱스**에서 근거 조각을 추려 Claude에 붙이고, **근거만 사용한 한국어 답변 + 출처 [1]..[N] 목록**을 보여준다. 출처 칩을 클릭하면 그 문서의 그 위치(text/md=줄, pdf=페이지, office=파일)로 연다.

Phase 4(열린 문서 하나에 질문)와 다르게 **등록 폴더 전체가 근거**다. Phase 7 인덱스 검색(키워드→파일+스니펫)과 다르게 **질문→합성 답변+출처**다. 셋은 별도 면으로 공존한다.

## 2. 검증 완료 / 재사용 확인 (CLAUDE.md "추정 금지" 준수)

브레인스토밍 단계에서 코드 매핑으로 확인한 사실:

- `ClaudeService.ask(prompt:context:) async throws -> String`(`Sources/Services/ClaudeService.swift`) — **수정 없이 재사용.** 프롬프트=`-p` 인자(지시), 컨텍스트=stdin. role 개념 없음 → "아래 근거만 써라"는 프롬프트에 명시. **타임아웃 120s 하드코딩**(상수). **스트리밍 미지원**(blocking, 종료 후 String 반환).
- `SearchIndex.search(query:limit:) -> [IndexHit]`(`Sources/Services/SearchIndex.swift`), `IndexHit{ path, snippet, isFilenameMatch }` — 재사용. 내부에서 `FTSQuery.sanitize`로 MATCH 조립(용어를 `"..."`로 감싸고 마지막에 prefix `*`, 사실상 AND).
- `ContentExtractor.localBody(for:) -> String?`(text/pdf 로컬), `.body(for:kordoc:) async -> String?`(office=kordoc) — 근거 원문 재추출에 재사용.
- `RouteHelper.buildRouteContext(noteBody:maxChars:)`(길이 절단+"…생략"), `parseRouteSuggestion`(stdout 첫 `{`~마지막 `}` → JSONDecoder) — 컨텍스트 예산·구조화 파싱 관용구 재사용.
- `AppState.loadAndActivateDocument(at:inNewTab:)`, `openIndexHit(_:)` — 문서 열기 재사용. PDF 페이지 점프는 CLAUDE.md 기록상 `.scrollToPDFPage` 알림 경로가 존재(정확한 시그니처는 Task에서 코드로 재확인).
- 커맨드 팔레트 항목/시트 배선 지점: `CommandPaletteView.swift`, `ContentView.swift`(`.sheet`), `CmdMDApp.swift`(메뉴). 기존 "내용 검색 (인덱스)"·"Ask Claude" 옆에 항목 추가.
- 새 패키지 의존성 **없음**(전부 macOS 내장 + 기존 서비스).

## 3. 아키텍처

신규 파일로 모듈화(업스트림 머지 안전). 순수 헬퍼는 단위테스트, Claude/UI 경유는 수동. SearchIndex/ClaudeService 등 기존 파일은 **가산(additive)만** 손댄다.

### 3.0 파이프라인 한눈에
```
질문
  └─(선택, 기본 ON) RagQueryExpansion → Claude로 동의어/관련어 → FTS OR 용어
  → RagRetriever: SearchIndex(원질문 + 확장 OR) → 파일 top-N 병합·중복제거
  → RagPassageExtractor: 각 파일에서 질의어 주변 문단창 + 위치(줄/페이지)
  → RagContextBuilder: 근거 [1]..[N] 번호부여 + 총 예산 절단 → context + [RagSource]
  → RagPromptBuilder: "아래 [1..N] 근거만 써라…" 프롬프트
  → ClaudeService.ask(prompt, context) → 답변(String)
  → UI: 답변 + 출처 칩[1..N] → 클릭 열기(줄/페이지 점프)
```

### 3.1 `Sources/Models/RagSource.swift` (신규)
근거 1건 + 위치.
```swift
struct RagSource: Equatable, Identifiable {
    let index: Int          // [n] (1-based, 프롬프트/표시 공용)
    let path: String        // 원본 파일 절대경로
    let snippet: String     // 표시용 발췌(패시지 앞부분 또는 FTS 스니펫)
    let location: RagLocation
    var id: Int { index }
}
enum RagLocation: Equatable {
    case line(Int)          // text/md: 1-based 줄
    case page(Int)          // pdf: 1-based 페이지
    case none               // office 등 위치 매핑 불가 → 파일만 열기
}
```

### 3.2 `Sources/Services/RagPassageExtractor.swift` (신규)
파일 URL + 질의어 → 근거 문단창 + 위치. **text 경로는 순수(테스트 대상)**, pdf/office는 기존 추출 재사용.
```swift
enum RagPassageExtractor {
    struct Passage: Equatable { let text: String; let location: RagLocation }

    /// 순수: 본문 문자열에서 질의어 첫 매치를 찾아 그 주변 창(문단/섹션 경계 우선, maxChars 상한)을 뽑고
    /// 매치 시작의 1-based 줄 번호를 계산. 매치 없으면 본문 앞 maxChars(줄 1).
    static func passage(inText body: String, terms: [String], maxChars: Int = 1200) -> Passage

    /// 종류별: text/md=localBody+passage(줄), pdf=페이지별 검색으로 매치 페이지 텍스트+page(n),
    /// office=kordoc markdown에서 passage(위치 none). 실패 시 nil.
    static func passage(for url: URL, terms: [String], kordoc: KordocService, maxChars: Int = 1200) async -> Passage?
}
```
- text 창 규칙(순수·결정적): 매치 오프셋 기준 앞뒤로 확장하되 가능하면 빈 줄(문단) 경계에서 자르고, 넘치면 매치 중심 ±maxChars/2. 줄 번호 = 매치 이전 `\n` 개수 + 1.
- pdf: `PDFDocument` 페이지 순회하며 `.string`에 질의어 포함 첫 페이지 → 그 페이지 텍스트(창 상한) + `.page(idx+1)`. 매치 없으면 1페이지.
- office: `ContentExtractor.body(for:kordoc:)`(마크다운) → text 창 규칙 적용, 위치 `.none`.

### 3.3 `Sources/Services/RagRetriever.swift` (신규)
FTS5 검색 + 확장 병합. **병합 로직은 순수(테스트 대상).**
```swift
struct RagRetriever {
    let index: SearchIndex
    /// 원질문 히트 + (확장 시) OR 히트를 합쳐 파일 경로 top-N 반환(중복 제거, 원질문 우선·등장 순 보존).
    func topFiles(question: String, expandedTerms: [String], limit: Int = 8) async -> [String]

    /// 순수: 여러 [IndexHit] 목록을 경로 기준 병합·중복제거·상한.
    static func mergePaths(primary: [IndexHit], secondary: [IndexHit], limit: Int) -> [String]
}
```
- 확장 OR 검색은 **SearchIndex에 가산 메서드**를 하나 추가해 지원(아래 3.7). 원질문은 기존 `search`, 확장은 OR MATCH.
- 병합: primary(원질문 BM25 순) 먼저, 이어서 secondary에서 새 경로만, 합쳐 limit개.

### 3.4 `Sources/Services/RagQueryExpansion.swift` (신규, 선택 경로·기본 ON)
질문 → Claude → FTS 확장 용어. **파싱은 순수(테스트 대상).**
```swift
enum RagQueryExpansion {
    static func prompt() -> String     // "질문의 동의어/관련 검색어를 JSON 배열로만…(최대 6개)"
    /// 순수: stdout에서 첫 '['~마지막 ']' 추출 → [String] 디코드, 공백/중복 정리. 실패 시 [].
    static func parse(_ stdout: String) -> [String]
    /// 순수: 용어들 → FTS5 OR MATCH ("a" OR "b" OR …), 각 용어 따옴표 이스케이프. 빈 배열이면 nil.
    static func orMatch(_ terms: [String]) -> String?
}
```
- 실패/빈 결과여도 안전: 확장 없이 원질문만으로 진행(그레이스풀). 토글 OFF면 이 단계 스킵.

### 3.5 `Sources/Services/RagContextBuilder.swift` (신규, 순수·테스트 대상)
패시지들 → 번호부여 컨텍스트 + 출처 목록.
```swift
enum RagContextBuilder {
    struct Built: Equatable { let context: String; let sources: [RagSource] }
    /// 각 패시지에 [n] 라벨 부여, 파일명·위치 헤더 + 본문을 이어붙이되 총 budget 초과 시 절단(초과 패시지는 버림).
    /// 최소 1건은 포함. 빈 입력이면 context "" · sources [].
    static func build(paths: [String], passages: [RagPassageExtractor.Passage], budget: Int = 12000) -> Built
}
```
- 컨텍스트 블록 형식(각 근거):
  ```
  [1] 파일명.md (줄 42)
  <패시지 텍스트>
  ---
  ```

### 3.6 `Sources/Services/RagPromptBuilder.swift` (신규, 순수·테스트 대상)
```swift
enum RagPromptBuilder {
    /// 지시 + 질문. grounding 강제: 근거만 사용, 없으면 "자료에 없음", 사용 근거에 [n] 표기, 한국어.
    static func prompt(question: String) -> String
}
```

### 3.7 `SearchIndex` 가산 (`Sources/Services/SearchIndex.swift`)
기존 API 불변. OR 재검색용 저수준 메서드만 **추가**:
```swift
/// 호출자가 만든 MATCH 문자열로 직접 검색(sanitize 안 함). RAG 확장 OR 질의용.
func searchMatch(_ match: String, limit: Int = 200) -> [IndexHit]
```
- 기존 `search(query:)`는 내부적으로 `FTSQuery.sanitize` 후 이 경로를 태워도 되고(리팩터 선택), 최소 변경으로 별도 추가만 해도 된다. **기존 동작·시그니처는 보존**한다.

### 3.8 `Sources/Services/RagService.swift` (신규 actor)
오케스트레이션. Claude/추출 경유라 수동 검증.
```swift
actor RagService {
    init(index: SearchIndex, claude: ClaudeService, kordoc: KordocService)
    struct Answer: Equatable { let text: String; let sources: [RagSource] }
    enum RagOutcome { case answered(Answer); case noEvidence; case failed(ClaudeError) }

    /// 확장(옵션) → 검색 → 패시지 → 컨텍스트 → Claude. 근거 0건이면 Claude 호출 없이 .noEvidence.
    func ask(question: String, expandQuery: Bool) async -> RagOutcome
}
```
- **근거 0건이면 Claude를 호출하지 않고** `.noEvidence`("자료에서 관련 내용을 찾지 못했습니다"). 크레딧 절약 + 무근거 답변 방지(지식베이스 보수성).
- Claude 실패는 `.failed`로 `AppState.claudeErrorMessage` 재사용.
- **`ask` 내부 흐름(명시):** ① `expandQuery`면 `claude.ask(prompt: RagQueryExpansion.prompt(), context: question)` 1콜 → `parse`로 확장 용어(실패 시 `[]`). ② **검색/하이라이트 공용 `terms` = 질문을 공백 분해한 토큰 + 확장 용어**(중복 제거) — 이 `terms`를 `RagRetriever.topFiles`(OR 검색)와 `RagPassageExtractor.passage`(문단창 매치)에 함께 넘겨 검색과 근거 추출을 정렬한다. ③ 파일 top-N → 각 패시지 → `RagContextBuilder.build` → `RagPromptBuilder.prompt` → `claude.ask`(답변).

### 3.9 `AppSettings` 필드 (`Sources/Models/Settings.swift`)
```swift
var ragExpandQuery: Bool = true   // 질의 확장 토글(기본 ON). 하위호환 디코드.
```

### 3.10 AppState 배선 (`Sources/App/AppState.swift`)
- 인스턴스: `ragService = RagService(index: searchIndex, claude: claudeService, kordoc: kordoc)`(모두 기존 인스턴스 재사용).
- 상태: `showAskCorpus: Bool`, `ragQuestion: String`, `ragAnswer: String?`, `ragSources: [RagSource]`, `ragBusy: Bool`, `ragMessage: String?`(noEvidence/에러 안내).
- 메서드:
  - `runRagQuery()` — trim 가드 → busy → `ragService.ask(question:expandQuery: settings.ragExpandQuery)` → outcome 분기로 `ragAnswer`/`ragSources`/`ragMessage` 반영.
  - `openRagSource(_:)` — path로 `loadAndActivateDocument(at:inNewTab:)` + 위치에 따라 줄/페이지 점프(pdf=`.scrollToPDFPage`), 시트 닫기.
- 인덱스가 비어있으면(등록 폴더 0) 시트에서 안내 + Phase 7 등록 UI로 유도(등록은 재사용, RAG는 새 등록 안 만듦).

### 3.11 UI — `Sources/Views/AskCorpusView.swift` (신규 시트)
- 진입: `showAskCorpus` 시트(`ContentView`의 `.sheet`), 커맨드 팔레트 "자료에 묻기 (RAG)", View 메뉴, 단축키(충돌 없는 키).
- 레이아웃:
  - 상단 질문 입력(`TextEditor`/`TextField`, 자동 포커스) + "질문 (⌘↩)" 버튼(`.keyboardShortcut(.return,.command)`, busy/빈 질문 disabled) + 질의 확장 토글(`settings.ragExpandQuery` 바인딩).
  - 본문: busy면 스피너("자료에서 찾아 Claude에게 묻는 중…"), 아니면 답변(선택가능 텍스트, ClaudePanelView 스타일; 복사 버튼), 그 아래 **근거 목록**: [n] · 파일명 · 위치 · 발췌 → 행 클릭 = `openRagSource`.
  - `ragMessage`(noEvidence/에러)는 빨간/회색 안내.
  - 빈 상태: 등록 폴더 없으면 "인덱스 검색에서 폴더를 먼저 등록하세요".
- 스트리밍 없음(질문→로딩→완성). 답변은 우선 선택가능 텍스트(마크다운 렌더는 후속 다듬기).

## 4. 에러·안전

- **읽기/검색 전용** — 어떤 파일도 이동/이름변경/삭제하지 않는다.
- 근거 0건 → Claude 미호출, "자료에 없음" 안내(무근거 생성 차단).
- Claude 미설치/미로그인/크레딧소진/타임아웃 → `ClaudeError` 분류 그대로 `claudeErrorMessage`로 한국어 안내(신규 인프라 불필요).
- kordoc 실패(office 근거 추출) → 그 근거만 스킵, 나머지로 진행, 크래시 없음.
- 컨텍스트 예산(기본 12k자)·파일 수(기본 8)로 과대 전송/느린 응답 방지. 민감 문서 전송 인지: 시트에 "선택 폴더 근거가 Claude로 전송됨" 안내 문구.
- 질의 확장 실패/빈 결과 → 원질문만으로 그레이스풀 폴백.
- PDF 페이지 점프 API는 Task에서 실제 코드로 시그니처 재확인(추정 금지) 후 배선.

## 5. 테스트 (Phase 게이트)

순수 헬퍼는 단위테스트(현 방식), Claude/kordoc/FSEvents/UI는 수동. AppState 테스트는 기존 `AppState(dataDirectory:)` 임시 디렉터리 주입으로 격리.

**단위테스트(신규):**
- `RagPassageExtractor.passage(inText:terms:)`: 매치 주변 창 추출, 줄 번호 정확, 문단 경계 자르기, 매치 없을 때 앞부분+줄1, maxChars 상한.
- `RagRetriever.mergePaths`: 원질문 우선·중복 제거·상한, secondary 신규 경로만 추가.
- `RagQueryExpansion.parse`: 정상 JSON 배열, 앞뒤 잡텍스트 섞인 stdout에서 `[...]` 추출, 실패 시 `[]`. `orMatch`: 따옴표 이스케이프·빈 배열 nil.
- `RagContextBuilder.build`: [n] 번호부여, budget 절단(초과 버림·최소 1건), 빈 입력 처리, 헤더 형식.
- `RagPromptBuilder.prompt`: grounding 지시·[n] 규칙·한국어·질문 포함.
- `SearchIndex.searchMatch`(in-process SQLite, 임시 DB): OR MATCH가 여러 용어 히트, 기존 `search` 동작 불변 회귀.
- `AppSettings.ragExpandQuery` 하위호환 디코드(구 JSON→기본 true).

**수동 검증:** `RagService.ask`(실제 claude·kordoc), `AskCorpusView` 동선, PDF 페이지/텍스트 줄 점프, office 근거 파일 열기, 실파일(notebox·정의당 평가서 HWP) 스모크.

게이트: 시작·종료 시 `swift test`로 기존 277개 + 신규 통과(정식 Xcode 필요).

## 6. 범위 밖 (후속)

- **임베딩·벡터 검색(A안)** — B의 recall이 질의 확장으로도 부족하면 이 검색 자리에 `NLContextualEmbedding`(무설치·한국어 지원 CJK) 또는 Ollama `bge-m3`(고품질)를 끼워 하이브리드로. 별건 spec.
- **Claude 스트리밍**(토큰 점진 표시) — `ClaudeService`에 신규 경로 필요. Phase 10 다듬기.
- 답변 마크다운 렌더링(현재 선택가능 텍스트), 근거 인라인 하이라이트, 폴더 스코프 선택(현재 등록 폴더 전체).
- 대화형(멀티턴) RAG, 답변 저장(노트/볼트) — 후속.
