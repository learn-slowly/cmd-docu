# cmd-docu PRD (v2)

> CmdMD(MIT, 구요한/CMDSPACE)를 포크해 만든다. 리더(마크다운·PDF·이미지·HWP·오피스) + Claude 연동 + 한글문서 읽기·쓰기(kordoc) + 내용 검색(Docufinder 아이디어) + 파일 정리. 이 문서는 Claude Code에 그대로 넘기는 개발 지시서다. v1 대비 kordoc·내용검색을 추가하고 단계를 우선순위 3티어로 재정리했다.

## 1. 개요

| 항목 | 내용 |
| --- | --- |
| 프로젝트명 | cmd-docu (CmdMD의 "cmd" + Docufinder의 "docu") |
| 한 줄 설명 | 마크다운·PDF·이미지·HWP·오피스를 한 곳에서 읽고, Claude에게 묻고, 내용으로 검색하고, 알맞은 자리로 정리하는 macOS 네이티브 도구 |
| 목적 | 종류 가리지 않고 한 앱에서 읽기 → 본문 검색 → Claude 질의 → 정리/생성까지. 관공서 HWP·정부지원사업 서류·논문 PDF가 핵심 대상 |
| 타겟 사용자 | 레고 1인 (개인용). 배포는 비목표 |
| 기술 스택 | Swift/SwiftUI (앱) · Node 18+ (kordoc CLI) · SQLite FTS5 (검색 인덱스) · macOS 14+ |
| 배포 환경 | 로컬 빌드(`swift build -c release`) → `.app`, 본인 머신 설치 |
| 상태 | 구현 진행 — Phase 0~9 완료(2026-07-01), Phase 10(다듬기·배포) 남음 |

원본 리포: https://github.com/johnfkoo951/CmdMD (MIT, 최신 v1.4.6) 엔진: kordoc https://github.com/chrisryugj/kordoc (MIT) 아이디어 참고: Docufinder https://github.com/chrisryugj/Docufinder (BSL 1.1 — 코드 차용 금지, 아이디어만)

## 2. 배경 및 문제 정의

CmdMD는 "리뷰 우선" 마크다운 리더이자 Obsidian 볼트 라우터다. 강점은 분명하지만 마크다운만 본다.

레고의 실제 작업은 마크다운에 그치지 않는다. 관공서 HWP, 정부지원사업 서류, 논문·보고서 PDF를 읽고 검색하고 텍스트를 뽑는 일이 잦고, 스크린샷·도판 이미지도 자주 본다. 또한 읽은 다음이 문제다 — 어디 뒀는지 모르는 문서를 파일명이 아니라 내용으로 찾고 싶고, 읽던 문서를 두고 곧바로 Claude에게 묻고 싶고, 노트는 알맞은 PARA 폴더로 가야 하고, 성명·공보는 다시 공문서 양식으로 나가야 한다.

이 포크는 여섯 줄기로 그 간극을 메운다. (1) PDF·이미지를 같은 창에서 본다. (2) HWP·오피스를 kordoc으로 읽어 마크다운으로 렌더한다. (3) 같은 kordoc으로 마크다운을 다시 HWPX 공문서로 쓴다. (4) 읽던 문서를 Claude 구독으로 질의한다. (5) 노트를 Claude가 알맞은 PARA 폴더로 보낸다. (6) 여러 문서를 내용으로 가로질러 검색한다. (4)·(5)·(6)의 파일 변경은 "Claude가 제안 → 레고가 확인 → 실행" 순서를 지킨다.

## 3. 핵심 기능

### 3.1 PDF 리더 (PDFKit) — 보기

- `.pdf`를 PDFKit 뷰어로 연다. 페이지 이동·썸네일·문서 내 검색·텍스트 선택/복사·줌/맞춤·회전.
- PDF의 "보기"는 PDFKit, "내용 추출(검색·AI·마크다운화)"은 3.3 kordoc이 맡는다(역할 분리).
- 우선순위: 필수 / 티어 1

### 3.2 이미지 리더 — 보기

- `.png .jpg .jpeg .heic .webp .gif` 단독 이미지를 같은 창에서. 화면맞춤 + 줌/팬.
- 구현은 WebView 재사용 또는 네이티브 `NSImage` 중 택1(Phase 0 확인 후).
- 우선순위: 필수 / 티어 1 (가장 작은 변경 → 코드 파악용)

### 3.3 한글·오피스 읽기 (kordoc) — 보기/추출

- **설명**: HWP3·HWP5·HWPX·HWPML·PDF·XLS·XLSX·DOCX를 kordoc으로 마크다운 변환 → 기존 마크다운 렌더 파이프라인에 태워 보여준다. LibreOffice 같은 무거운 의존성 불필요.
- **사용자 시나리오**: HWP 파일을 열면 kordoc이 마크다운으로 변환하고, 탭에 렌더된 본문이 뜬다. 표·각주·이미지도 함께.
- **연동 방식**: 앱이 `Process`로 `npx kordoc <파일> --format json` 호출 → markdown + blocks 수신. (대안: kordoc MCP 경유)
- **데이터**: 입력 = 로컬 문서 경로. 출력 = markdown + IRBlock 구조 + 메타데이터.
- 우선순위: 필수 / 티어 1 (레고 핵심 대상이 HWP·서류라 가치 큼)

### 3.4 한글·오피스 쓰기 (kordoc) — 생성/패치/양식

- **설명**: 마크다운을 다시 한글문서로. 세 가지 — (a) `kordoc generate`로 md → HWPX 생성(공문서 프리셋 기안문·보고서 등, 항목부호 8단계·공식 여백 자동), (b) `kordoc patch`로 원본 서식 1바이트도 안 건드리고 바뀐 텍스트만 무손실 교체, (c) `kordoc fill`로 양식 빈칸 자동 채우기(서식 보존).
- **사용자 시나리오**: 성명·공보를 마크다운으로 쓰고 → 공문서 HWPX로 출력. 또는 받은 양식(신청서)에 값을 채워 되돌려줌.
- **제약**: HWP5 바이너리는 패치(텍스트 교체)만, 새 문서 생성은 HWPX 기준.
- 우선순위: 필수 / 티어 2

### 3.5 Claude 구독 연동 (claude -p)

- **설명**: 열린 문서(또는 선택 영역)를 프롬프트와 함께 Claude에 보내고 답을 사이드 패널에 표시. 답은 노트에 마크다운으로 삽입/저장.
- **연동 방식**: `Process`로 로컬 `claude` CLI를 `claude -p`로 호출, stdout 수신. 인증은 구독 로그인(claude.ai 아님), 사용량은 월간 Agent SDK 크레딧 차감.
- **참고**: `claude -p`(Claude Code)는 레고의 kordoc MCP를 이미 쓸 수 있어, "이 HWP 뭐라 적혔어?"를 Claude가 알아서 kordoc으로 파싱하게도 된다.
- 우선순위: 필수 / 티어 2

### 3.6 Claude 스마트 라우팅 (노트 PARA 자동 분류)

- 보낼 때 규칙 미매칭이면 Claude가 본문을 읽고 PARA 목적지를 제안 → 레고 확인 → 기존 "볼트로 보내기" 이동.
- PARA 목적지(레고): `10000_Projects/{Living_with_Damage, Build_and_Deploy, Left_Forward}`, `20000_Areas`, `30000_Resources`, `40000_Archive`.
- 안전장치: 제안만, 확인 없는 자동 이동은 기본 OFF.
- 우선순위: 필수 / 티어 2

### 3.7 내용 검색 (Docufinder 아이디어)

- **설명**: 파일명이 아니라 본문으로 찾는다. 폴더를 등록하면 kordoc으로 본문을 마크다운으로 뽑아 SQLite FTS5에 인덱싱 → 키워드 검색. Everything 스타일 파일명 검색 병행. 파일 추가/수정 시 자동 재인덱싱(파일 감시).
- **사용자 시나리오**: 검색창에 키워드 → HWP·PDF·오피스 본문에서 결과를 1초 안에. 결과 클릭으로 미리보기, 더블클릭으로 열기.
- **참고**: Docufinder 발상을 따르되 코드는 차용하지 않는다(BSL). 엔진은 kordoc(MIT). 이 기능은 LLM-Wiki 패턴의 "원본 소스 검색" 층과 동일하다(§8).
- **구현 확정(2026-07-01)**: Phase 7로 완료 — kordoc/PDFKit 추출 + SQLite FTS5 영속 인덱스 + FSEvents 파일감시. 이후 Phase 9 후속으로 토크나이저를 `unicode61`→**`trigram`(부분일치)** 으로 전환해 한국어 조사·복합어를 해결("평가서"→"평가서에", "선거"→"지방선거"), 3글자 미만 용어는 같은 테이블 `LIKE`(body+filename) 폴백. 구 인덱스는 자동 감지해 재생성 후 등록 폴더를 재인덱싱. 감수: 영어도 단어 일치→부분일치로 바뀜(의도·승인).
- 우선순위: 선택 / 티어 3 (지금까지 중 가장 무거운 추가 — 인덱서·파일감시)

### 3.8 Claude 폴더 정리 (배치)

- 어수선한 폴더를 Claude가 종류·주제별 정리 계획으로 제안 → 레고가 승인한 만큼만 이동/이름변경. 삭제 없음, 이동 로그로 undo.
- **중복 인지**: Desktop Commander와 기능이 겹침. 그래도 리더 안에서 처리하려는 선택.
- 우선순위: 선택 / 티어 3

### 3.9 PARA 라이브러리 뷰 (리더 ⇄ 라이브러리)

- **설명**: 파일 하나를 여는 "리더" 위에, 폴더를 펼쳐 그 안의 파일을 격자/리스트로 훑는 "라이브러리" 모드를 더한다. PARA를 보내기(라우팅)뿐 아니라 탐색 축으로도 쓴다 — 첨부(사진·PDF·영상·오피스)를 텍스트의 곁다리가 아니라 그 자체로 본다.
- **모드 토글**: `mainMode`(reader/library)를 툴바 세그먼트로 전환. 하위 보조토글은 모드 따라 교체(리더=Source·Split·Preview, 라이브러리=List·Grid).
- **동선(절충)**: 파일 클릭→리더, 폴더 클릭→라이브러리 자동전환하되 토글이 우선(덮어쓰기). 관통축은 "현재 폴더".
- **PARA 렌즈**: 사이드바 트리를 `legoSeed` 기준 그룹·정렬, 경로로 분류 판별(Archive는 차분하게 dim, Projects는 또렷하게).
- **썸네일**: QuickLook(`QLThumbnailGenerator`)으로 전 종류, lazy 생성+캐시.
- **경계**: 읽기/탐색 전용 — 파일 이동·삭제는 하지 않는다(정리는 3.8). **Phase 8의 폴더 선택·미리보기 기반을 재사용·확장한다.**
- 우선순위: 선택 / 티어 3 (Phase 8 다음, 9 앞)

### 3.10 미리보기 속도 다듬기 (성능)

- **설명**: 기능을 쌓는 동안 미뤄둔 프리뷰 병목을 제거한다(코드 검증 2026-06-30 반영). (a) 코드 색칠(highlight.js)을 CDN→앱 번들 로컬 로드로, (b) 파일 트리 스캔을 메인 스레드→백그라운드로. 라이선스 고지(highlight.js 누락) 정정 동반.
- **배경**: 미리보기는 `WKWebView` 기반이고 코드/수식/다이어그램 자산을 매 렌더 `cdn.jsdelivr.net`에서 받는다 → 오프라인 취약. **highlight.js는 이미 Highlightr 패키지가 로컬 번들(1MB)로 동봉**(`package_app.sh`가 `Contents/Resources`로 복사)하는데 미리보기만 별도 CDN을 또 써서 중복 → 기존 번들 인라인 주입으로 거의 공짜 로컬화. 파일 트리(`buildFileTree`)는 메인 스레드 동기 재귀(depth 10, 펼친 폴더만)라 큰 볼트에서 멈춘다.
- **검증으로 정정된 것**: 미리보기 렌더는 **이미 250ms 디바운스**가 있다(`PreviewView.swift`). "타이핑마다 통째 리로드"는 사실이 아니며(멈춘 뒤 1회·스크롤 보존), **DOM 부분갱신(A-3)은 실익 작고 리스크(JS 재초기화·체크박스 리스너·레이스) 커 보류**. **KaTeX/Mermaid 로컬화는 별도 자산 동봉 필요해 후속**(KaTeX 기본 비활성).
- **경계**: 동작·기능은 그대로 두고 로드 출처/실행 위치만 바꾸는 성능 작업. 9(RAG) 앞으로 당겨 바닥을 다진다.
- 우선순위: 필수 / 티어 3 (Phase 8.5 다음, 9 앞)

### 3.11 자료에 묻기 — 가벼운 RAG (구현 확정: B안, 임베딩 없음)

- **설명**: 원안(임베딩·벡터·하이브리드)을 브레인스토밍으로 **B안(임베딩 없이 FTS5 근거 + Claude 답변)** 으로 재정의해 구현(2026-07-01). 근거 회수 = 원질문 AND 검색 + 원질문 토큰·확장어 OR 재검색(질의 확장 토글은 Claude 확장어 생성만 제어, 기본 ON — OR 재검색 자체는 항상 수행). Claude(`claude -p`)가 **근거만으로** 한국어 답변. 답변의 출처 `[n]` 클릭 → 해당 문서 위치로 점프(마크다운=줄 / PDF=페이지 / 한글·오피스=파일 열기까지).
- **사용자 시나리오**: 커맨드 팔레트 "자료에 묻기 (RAG)" → 시트에서 질문 → 답변 + 번호 출처 목록 → 출처 클릭으로 원문 위치 확인.
- **안전장치**: 근거 0건이면 **답변용 Claude 호출을 생략**(무근거 생성 차단·크레딧 절약; 질의 확장 ON이면 확장어 생성용 호출 1회는 검색 전에 선행됨). 근거 컨텍스트는 12k자 예산으로 절단. 원본 파일 불변(읽기 전용).
- **구성**: 전부 별도 파일 — 순수 헬퍼(`RagQueryExpansion`·`RagContextBuilder`·`RagPromptBuilder`·모델 `RagSource`) + I/O 헬퍼(`RagRetriever`=인덱스 질의, `RagPassageExtractor`=PDF/kordoc 접근·text 경로는 순수) + `RagService`(actor) + `AskCorpusView`(시트). 기존 `ClaudeService`·`ContentExtractor`·`SearchIndex` 재사용, **새 패키지 의존성 0**.
- **후속(A안·선택, 2026-07-01 조사 메모 — 코드 외 실측)**: 임베딩 업그레이드 — `NLEmbedding`은 한국어 미지원이라 `NLContextualEmbedding` CJK(무설치·512차원) 또는 Ollama `bge-m3`(고품질·설치 부담) 후보. **sqlite-vec는 macOS 시스템 SQLite에서 로드 불가** → 임베딩 BLOB 저장 + Swift 브루트포스 코사인(vDSP)이 현실적.
- 우선순위: 완료 / 티어 3 (Phase 9)

## 4. 기술 아키텍처

### 4.1 기술 스택

- 앱: Swift 5.9+ / SwiftUI (원본 유지), Swift Package(SPM), macOS 14+
- 문서 엔진: Node 18+ / kordoc CLI (서브프로세스 호출)
- 검색 인덱스: SQLite FTS5 (macOS 기본 내장)
- 추가 프레임워크(모두 macOS 기본): PDFKit(PDF 보기), ImageIO/AppKit(이미지), Foundation `Process`(CLI 호출), `FileManager`(이동/이름변경)
- 원본 의존성 유지: swift-markdown · Highlightr · Yams · Mermaid·KaTeX (원본은 CDN → **Phase 8.7에서 highlight.js와 함께 로컬 번들로 전환**)

### 4.2 외부 도구/데이터 소스

| 도구/소스 | 용도 | 키 필요 | 비고 |
| --- | --- | --- | --- |
| 로컬 `kordoc` CLI | HWP/오피스/PDF 읽기·쓰기·양식·패치 | 불필요 | Node 18+ 필요. MIT |
| 로컬 `claude` CLI | Claude 질의·라우팅·정리·RAG | 불필요(구독) | Claude Code 로그인 선행. Agent SDK 크레딧 차감 |
| SQLite FTS5 | 내용 검색 인덱스 + RAG 근거 회수 | 불필요 | macOS 내장. `trigram` 토크나이저(한국어 부분일치), ≤2글자 `LIKE` 폴백 |
| Mermaid/KaTeX (+highlight.js) | 다이어그램·수식·코드 색칠 | 불필요 | 원본은 CDN → **Phase 8.7에서 로컬 번들화** |

### 4.3 프로젝트 구조 (원본, Phase 0에서 실제 확인)

```
CmdMD/
├── Package.swift          # SPM 매니페스트
├── Sources/               # Swift/SwiftUI 소스 (앱 본체)
├── Tests/CmdMDTests/      # 테스트 57개
├── Resources/  docs/  landing/  scripts/
└── LICENSE (MIT)
```

신규 기능은 `Sources/`의 "파일 종류 → 뷰 디스패치" 한 곳을 중심으로. 마크다운=기존 렌더러, PDF=PDFKit, 이미지=이미지 뷰, HWP/오피스=kordoc→마크다운 렌더. 정확한 위치는 Phase 0에서 특정.

## 5. 데이터 모델

별도 서버·외부 DB 없음. 모든 입력은 로컬 파일.

```
DocumentKind:  markdown | pdf | image | office   # office = kordoc 경유 렌더
SearchIndex (SQLite FTS5, trigram):  { path, title, bodyMarkdown, mtime, kind }
RouteSuggestion:  { folder, filename?, reason }          # 노트 1건 분류
CleanupPlan:      [ { from, to, action: move|rename, reason } ]
MainMode:         reader | library                       # 메인 영역 모드(리더/라이브러리)
LibraryLayout:    list | grid                            # 폴더별 표시 기억(URL→layout)
RagSource:        { index, path, snippet, location(line|page|unknown) }  # RAG 근거 — [n] 클릭 시 줄/페이지 점프(오피스는 파일 열기)
```

- Claude 응답은 영구 저장하지 않음(세션 표시 + 노트 삽입 옵션). 보관은 claude.ai가 아니라 볼트 마크다운으로.
- 폴더 정리 실행 시 이동 로그(from→to)를 남겨 undo. 삭제 없음.
- 검색 인덱스는 파생물(재생성 가능). 원본은 불변, 인덱스만 생성.

## 6. 개발 단계 (우선순위 3티어)

### 티어 1 — 당장 (리더 코어)

**Phase 0: 포크 준비 & 아키텍처 파악**

- [ ] 포크·클론, `swift build`/`swift run` 빌드 확인, `swift test`로 기존 테스트 57개 기준선 확보

- [ ] 소스 읽기 — 파일 열기/탭/프리뷰 디스패치 위치 특정. 프리뷰가 WebView 기반인지 코드로 검증(추정 금지)

- [ ] 표시명 cmd-docu로 교체, 번들 ID는 역도메인 형식(예: work.cmdspace.cmddocu — 하이픈 회피). LICENSE·원작자 고지 유지

**Phase 1: 이미지 리더** — 디스패치에 image 분기, 뷰 구현, 줌/팬, 최소 테스트

**Phase 2: PDF 리더 (PDFKit)** — `PDFView` 래핑, 탭 표시, 페이지/썸네일/검색/선택·복사/줌/회전

**Phase 3: 한글·오피스 읽기 (kordoc)**

- [ ] Node/kordoc 존재 확인(`npx kordoc` 경로 탐지), 미설치 안내

- [ ] 디스패치에 office 분기 — `npx kordoc <파일> --format json` 호출 → markdown 수신 → 기존 렌더러로 표시

- [ ] HWP3/5·HWPX·HWPML·XLS/XLSX·DOCX 열기 확인, 표/이미지 렌더 점검

### 티어 2 — 다음 (Claude + 생성)

**Phase 4: Claude 연동 (claude -p)**

- [ ] `claude` 바이너리 경로 탐지, 미설치/미로그인/크레딧소진 메시지 분기

- [ ] 커맨드 팔레트 + 단축키로 "Claude에게 질문" 진입점, 문서 본문 동봉 전달, 응답 패널 표시

- [ ] 응답을 노트에 마크다운으로 삽입/볼트 저장(보관은 볼트로)

**Phase 5: 한글·오피스 쓰기 (kordoc)**

- [ ] md → HWPX 생성(`kordoc generate`, 공문서 프리셋/글꼴/크기 옵션)

- [ ] 무손실 패치(`kordoc patch`) — 원본 서식 보존 텍스트 교체

- [ ] 양식 자동 채우기(`kordoc fill`) — 라벨-값 매칭, 서식 보존

**Phase 6: 스마트 라우팅 (PARA 분류)**

- [ ] 설정에 PARA 목적지 목록(레고 구조 시드)

- [ ] 보내기에 "Claude에게 맡기기" 분기 → `RouteSuggestion` 수신 → 확인 → 기존 이동 로직

- [ ] 자동 라우팅에 Claude 끼우기 옵션(기본 OFF)

### 티어 3 — 나중/선택 (검색·정리·시맨틱)

**Phase 7: 내용 검색 (Docufinder식, 키워드)**

- [ ] 폴더 등록 → kordoc 파싱 → SQLite FTS5 인덱싱(본문 마크다운)

- [ ] 키워드 검색 + Everything식 파일명 검색, 결과 미리보기/열기

- [ ] 파일 감시로 추가/수정 자동 재인덱싱

**Phase 8: 폴더 정리 (배치)** — 폴더 선택 → 메타데이터(+모호 파일만 내용) → `CleanupPlan` → 미리보기·승인 → `FileManager` 이동, 로그·undo

**Phase 8.5: PARA 라이브러리 뷰 (리더 ⇄ 라이브러리)** — `AppState.mainMode`(reader/library) + `MainEditorView` 분기 + 툴바 모드 세그먼트(하위토글 Source·Split·Preview ⇄ List·Grid). `selectedFolder` 선택 개념 신설(**Phase 8과 공유** — 폴더 선택·미리보기 기반 재사용). detail에 `LazyVGrid`/`List`(썸네일=QuickLook `QLThumbnailGenerator` lazy+`NSCache`). 사이드바 PARA 렌즈(`legoSeed` 그룹·Archive dim·Projects 또렷). 폴더별 뷰 기억(URL→layout). 클릭이 모드 견인+토글 우선. **읽기 전용(이동은 Phase 8 몫)**. 단계: ①PARA 렌즈 → ②메인 그리드+모드토글 → ③뷰 기억·다듬기.

**Phase 8.7: 미리보기 속도 다듬기** — 코드 검증(2026-06-30, 5렌즈)으로 확정된 것만. **8.5 다음·9 앞**, 작업 전후 `swift test` 통과 확인. 신규 분은 별도 파일/모듈로 분리.

- [ ] **highlight.js 로컬화(최우선·거의 공짜)** — `MarkdownRenderer.hljsIncludes()`(`MarkdownRenderer.swift:657`)가 매 렌더 `cdn.jsdelivr.net/gh/highlightjs/cdn-release@11`을 로드. **highlight.js는 이미 `Highlightr_Highlightr.bundle`(1MB JS + github/github-dark CSS)로 동봉**돼 있으니 CDN 대신 그 번들을 읽어 `<script>` 인라인 주입(lazy static 캐시로 매 렌더 I/O 방지). `loadHTMLString` baseURL 유지. `SyntaxHighlighter.highlightrResourceBundleIsPresent()`의 번들 탐색 로직 재사용(`swift run`·패키지 경로 둘 다).

- [ ] **THIRD-PARTY-NOTICES.md 정정** — highlight.js가 현재 §1·§2·§3 어디에도 **누락**(CDN 상태인 지금도 고지 의무 미이행). highlight.js(Ivan Sagalaev, MIT) 항목 추가. 로컬화 후 §2→§1 이동 + MIT 저작권 줄. Highlightr(기저=highlight.js) 비고로 중복 혼동 방지.

- [ ] **파일 트리 백그라운드화** — `AppState.buildFileTree`(`AppState.swift:1110`)가 `contentsOfDirectory`를 메인 스레드 동기 재귀(depth 10, 펼친 폴더만). 스캔을 `Task.detached`(이미 `AppState:702` 패턴 존재)로 옮기고 `await MainActor.run`으로 `fileTree`만 반영. **선행 task `.cancel()`로 연타 레이스 방지**, `expandedFolders` 스냅샷 캡처, Sendable·@Observable 메인스레드 대입 주의.

- [ ] ~~(보류) 미리보기 DOM 부분 갱신(A-3)~~ — 검증 결과 **이미 250ms 디바운스 존재**(`PreviewView.swift:139`)·스크롤 보존. 통째 reload는 맞으나 실익은 깜빡임 제거뿐이고 JS 재초기화·체크박스 리스너·evaluateJavaScript 레이스 리스크가 커 **보류**. (실제 병목이 Swift측 `renderToHTML` 전처리라면 별도 검토.)

- [ ] ~~(후속) KaTeX/Mermaid 로컬화~~ — 로컬 번들 없어 npm 자산 동봉(KaTeX ~370KB+CSS·Mermaid UMD ~2MB) 필요. KaTeX 기본 비활성이라 우선순위 낮음. highlight.js 로컬화 패턴 확립 후 동일 방식.

**Phase 9: 자료에 묻기 — 가벼운 RAG (LLM-Wiki 질의층)** — **완료(2026-07-01, §3.11)**. 원안(임베딩·벡터·하이브리드)을 **B안(임베딩 없이 FTS5 근거 + Claude 답변)** 으로 재정의해 구현 — 질의 확장 OR 재검색 → 근거 회수 → 패시지 추출 → Claude 답변(`[n]` 출처, 클릭 시 문서 위치 점프), 근거 0건이면 답변용 Claude 호출 생략. 후속으로 **한국어 검색 근본 수정**(FTS5 `unicode61`→`trigram` 전환 + ≤2글자 `LIKE` 폴백 + 구 인덱스 자동 마이그레이션·등록 폴더 재인덱싱 — Phase 7 키워드검색·Phase 9 RAG 공통 개선)까지 반영. 시맨틱·임베딩(A안)은 선택 후속(§3.11 후속 참고).

**Phase 10: 다듬기 & 배포** — 단축키·설정 정리, `package_app.sh` 패키징·ad-hoc 서명·격리 해제, README 포크판 갱신(출처·라이선스)

## 7. UI/UX 가이드

- 데스크탑 전용. 원본의 "리뷰 우선·키보드 중심" 톤 유지.
- 문서 종류가 바뀌어도 탭·사이드바·단축키 경험은 일관. PDF·이미지·HWP·오피스 모두 마크다운처럼 탭으로 열고 닫음.
- Claude 패널·검색 패널은 토글 가능한 보조 영역. 읽는 문서를 가리지 않게.
- 라우팅·정리·검색의 파일 변경은 항상 미리보기/확인을 거친다.
- 리더(파일 한 장 줌인)와 라이브러리(폴더 펼쳐 줌아웃)는 같은 "현재 폴더"를 공유하는 두 시점. 전환은 토글, 클릭이 기본 견인.
- 색·테마는 원본 CMDS 라이트/다크 유지.

## 8. LLM-Wiki 연동 (운영 패턴 — 앱 밖)

- Karpathy LLM-Wiki 패턴은 "앱에 넣는 것"이 아니라 **Claude Code + 볼트 안 CLAUDE.md 스키마**로 굴린다. 위키 = 볼트의 마크다운 파일.
- 이 앱의 역할은 그 위키의 **뷰어 + Ingest/Query 손잡이**다. 3.5(Claude 연동)·3.6(라우팅)·3.7(내용검색)·3.11(RAG)이 각각 Query·Ingest·소스검색·근거 기반 질의응답에 대응한다.
- 별도 산출물: 레고 PARA에 맞춘 **볼트용 LLM-Wiki 스키마(CLAUDE.md)** — 앱 개발용 CLAUDE.md와는 다른 파일. 요청 시 작성.

## 9. 제약 사항 및 주의점

**라이선스**

- CmdMD: MIT — 포크·수정·재배포 자유, LICENSE·원작자 고지 유지.
- kordoc: MIT — 엔진으로 직접 사용 가능.
- **Docufinder: BSL 1.1 — 코드 차용 금지.** 아이디어/아키텍처만 독립 구현하고, 실제 엔진은 kordoc으로 대체한다. (2030-04-15 Apache 2.0 자동 전환 전까지 프로덕션 사용은 별도 라이선스 필요)
- 원본 CmdMD가 활발히 개발 중이라 포크는 갈라진다. 신규 기능은 별도 파일·모듈로 분리해 업스트림 머지 용이성 확보.

**파일 이동 안전(라우팅·정리 공통)**

- Claude는 제안만. 레고 승인 없이 어떤 파일도 이동/이름변경 금지(자동은 기본 OFF).
- 이동·이름변경만, 삭제 없음. 실행분은 로그로 undo.
- 건강·정치 자료가 섞인 지식베이스이므로 보수적으로.

**Claude 비용·보안**

- 사용량은 월간 Agent SDK 크레딧 차감(한도·비이월·개인용). 소진 시 중단 또는 API 요금.
- `claude -p`에 보내는 본문은 Claude로 전송됨. 민감 문서는 전송 전 인지.
- 개인용. 포크를 여러 사람이 쓰게 배포 금지(구독 하나로 다수 트래픽 불가).

**기술**

- 비샌드박스 유지(샌드박스면 `Process` CLI 호출 막힘).
- Node 18+ 필요(kordoc). LibreOffice보다 가벼움.
- kordoc HWP5 쓰기는 패치(텍스트)만, 새 문서는 HWPX. 한글 충실도는 레고 실파일로 먼저 테스트.
- 내용 검색(티어 3)은 규모가 커서 분리. 키워드(FTS5)는 Phase 7, RAG는 Phase 9에서 임베딩 없이(B안) 구현 완료. 시맨틱·임베딩(A안)은 선택 후속.
- Phase마다 `swift test`로 기존 테스트 유지 확인 후 진행. 추정을 사실로 적지 않음.

---

## 부록 A. Claude Code 시작 프롬프트 (예시)

> "이 저장소는 CmdMD(Swift/SwiftUI, SPM) 포크다. 먼저 `swift build`·`swift test`로 빌드·테스트를 확인하고, `Sources/`를 읽어 파일 열기/탭/프리뷰 디스패치 위치와 프리뷰가 WebView 기반인지 보고해라. 그다음 PRD 티어 1의 Phase 1(이미지)→2(PDF)→3(kordoc 읽기) 순으로 진행한다. kordoc·claude는 `Process`로 호출하는 외부 CLI다. 각 Phase는 기존 테스트를 깨지 않는 선에서, 마치면 변경 요약을 보고해라."