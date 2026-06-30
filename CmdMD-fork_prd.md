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
| 상태 | 기획 단계 |

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

## 4. 기술 아키텍처

### 4.1 기술 스택

- 앱: Swift 5.9+ / SwiftUI (원본 유지), Swift Package(SPM), macOS 14+
- 문서 엔진: Node 18+ / kordoc CLI (서브프로세스 호출)
- 검색 인덱스: SQLite FTS5 (macOS 기본 내장)
- 추가 프레임워크(모두 macOS 기본): PDFKit(PDF 보기), ImageIO/AppKit(이미지), Foundation `Process`(CLI 호출), `FileManager`(이동/이름변경)
- 원본 의존성 유지: swift-markdown · Highlightr · Yams · Mermaid·KaTeX(CDN)

### 4.2 외부 도구/데이터 소스

| 도구/소스 | 용도 | 키 필요 | 비고 |
| --- | --- | --- | --- |
| 로컬 `kordoc` CLI | HWP/오피스/PDF 읽기·쓰기·양식·패치 | 불필요 | Node 18+ 필요. MIT |
| 로컬 `claude` CLI | Claude 질의·라우팅·정리·RAG | 불필요(구독) | Claude Code 로그인 선행. Agent SDK 크레딧 차감 |
| SQLite FTS5 | 내용 검색 인덱스 | 불필요 | macOS 내장 |
| Mermaid/KaTeX CDN | 다이어그램·수식 | 불필요 | 원본 그대로 |

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
SearchIndex (SQLite FTS5):  { path, title, bodyMarkdown, mtime, kind }
RouteSuggestion:  { folder, filename?, reason }          # 노트 1건 분류
CleanupPlan:      [ { from, to, action: move|rename, reason } ]
MainMode:         reader | library                       # 메인 영역 모드(리더/라이브러리)
LibraryLayout:    list | grid                            # 폴더별 표시 기억(URL→layout)
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

**Phase 9: 시맨틱 검색 + Claude RAG (LLM-Wiki 질의층)** — (가장 무거움) 임베딩·벡터 인덱스 추가, 하이브리드 검색, Claude로 RAG 답변(근거 문서+위치 표시)

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
- 이 앱의 역할은 그 위키의 **뷰어 + Ingest/Query 손잡이**다. 3.5(Claude 연동)·3.6(라우팅)·3.7(내용검색)이 각각 Query·Ingest·소스검색에 대응한다.
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
- 내용 검색(티어 3)은 규모가 커서 분리. 키워드(FTS5)부터, 시맨틱·임베딩·RAG는 Phase 9로 미룸.
- Phase마다 `swift test`로 기존 테스트 유지 확인 후 진행. 추정을 사실로 적지 않음.

---

## 부록 A. Claude Code 시작 프롬프트 (예시)

> "이 저장소는 CmdMD(Swift/SwiftUI, SPM) 포크다. 먼저 `swift build`·`swift test`로 빌드·테스트를 확인하고, `Sources/`를 읽어 파일 열기/탭/프리뷰 디스패치 위치와 프리뷰가 WebView 기반인지 보고해라. 그다음 PRD 티어 1의 Phase 1(이미지)→2(PDF)→3(kordoc 읽기) 순으로 진행한다. kordoc·claude는 `Process`로 호출하는 외부 CLI다. 각 Phase는 기존 테스트를 깨지 않는 선에서, 마치면 변경 요약을 보고해라."