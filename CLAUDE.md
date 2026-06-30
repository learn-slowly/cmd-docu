# cmd-docu — Claude Code 개발 지시서

> 이 파일은 cmd-docu 저장소 루트에 `CLAUDE.md`로 둔다. 앱을 만들 때 항상 이 규칙을 따른다.

## 프로젝트 개요
macOS 네이티브 리더 + 한글/오피스 문서 처리 + 내용 검색 도구. CmdMD(MIT, 구요한/CMDSPACE)를 포크해 만든다.
상세 사양은 같은 폴더의 PRD(`cmd-docu_prd.md` 또는 `CmdMD-fork_prd.md`)를 따른다.

## 기술 스택
- 앱: Swift 5.9+ / SwiftUI, Swift Package(SPM), macOS 14+
- 문서 엔진: kordoc CLI (Node 18+) — `Process`로 호출하는 외부 도구
- AI: claude CLI (`claude -p`) — `Process`로 호출하는 외부 도구
- 검색: SQLite FTS5 (macOS 내장)
- 보기: PDFKit(PDF), ImageIO/AppKit(이미지)

## 핵심 규칙 (반드시 지킨다)
- **비샌드박스 유지.** 샌드박스로 바꾸면 kordoc·claude 서브프로세스 호출이 막힌다.
- **kordoc·claude는 직접 구현하지 않는다.** Node/CLI를 `Process`로 부르고 결과(stdout/JSON)를 받는다. 경로 탐지 실패 시 사용자에게 안내만 하고 크래시하지 않는다.
- **Phase 게이트.** 각 Phase 시작 전후로 `swift test`를 돌려 기존 테스트(약 57개)가 깨지지 않는지 확인한 뒤 다음으로 넘어간다.
- **파일 변경은 제안→확인→실행.** 라우팅·폴더 정리·양식 채우기 등 파일을 옮기거나 바꾸는 동작은 사용자 승인 없이 자동 실행하지 않는다. 이동·이름변경만 하고 삭제는 하지 않는다. 실행분은 로그로 남겨 undo를 지원한다.
- **추정을 사실로 적지 않는다.** 특히 원본 프리뷰가 WebView 기반인지 등은 코드로 검증한 뒤 구현 방식을 확정한다. 불확실하면 "확인 필요"로 표시한다.
- **라이선스.** CmdMD·kordoc은 MIT라 사용 가능. Docufinder는 BSL 1.1이므로 **코드를 가져오지 않는다** — 아이디어/아키텍처만 독립 구현한다. LICENSE와 원작자 고지를 유지한다.
- **문서는 마크다운으로.** 새 산출 문서는 md로 만든다. PDF/HWPX 변환은 최종본 단계에서만.
- 신규 기능은 가능한 별도 파일·모듈로 분리해 업스트림(CmdMD) 변경 머지를 쉽게 둔다.

## 작업 순서 (PRD 우선순위 티어)
- 티어 1(당장): Phase 0 포크준비 → 1 이미지 → 2 PDF → 3 kordoc 읽기
- 티어 2(다음): 4 Claude 연동 → 5 kordoc 쓰기 → 6 PARA 라우팅
- 티어 3(나중): 7 내용검색(키워드) → 8 폴더정리 → 8.5 PARA 라이브러리 뷰 → 9 시맨틱+RAG → 10 다듬기·배포

## 언어
- 코드 주석·커밋 메시지는 한국어로 쓴다.
- 글에서 '박다/박는다/박았다' 표현은 쓰지 않는다.

## 현재 상태
- Phase 0 완료(2026-06-29). CmdMD v1.4.8 포크·클론, `cmd-docu` 브랜치에서 작업(`main`은 upstream 추적용, 원격 `upstream`=원작자 저장소).
  - 빌드·테스트 기준선 확보: `swift build` OK + 57개 테스트 통과. **swift test엔 정식 Xcode 필요**(CLT는 build만).
  - 프리뷰는 WebView(`WKWebView`) 기반 확정. 파일 열기 디스패치 진입점 = `AppState.loadAndActivateDocument`(`Sources/App/AppState.swift`). 현재 모델은 마크다운 단일(`MarkdownDocument`) — kind 분기 미존재.
  - 표시명 cmd-docu 적용(노출 텍스트·번들ID `work.cmdspace.cmddocu`). 내부 식별자·바이너리명 `CmdMD`·URL 스킴 `cmdmd`·원작자 고지 유지. `.app` 파일명 변경은 Phase 10으로 미룸.
- Phase 1 완료(2026-06-29). 이미지 리더 — `DocumentKind`(확장자 매핑)·`EditorTab.kind`·`ImageReaderView`(NSScrollView+NSImageView, 줌/팬/맞춤/GIF), 사이드바 목록에도 이미지 표시. 72개 테스트 통과.
- Phase 2 완료(2026-06-29). PDF 리더 — `DocumentKind.pdf` + `PDFReaderView`(PDFKit `PDFView`+`PDFThumbnailView`+검색필드+회전버튼, 페이지·줌·선택/복사·회전·문서내검색, 로드실패 플레이스홀더). 사이드바 목록·패널에 .pdf.
- 폴더 검색 확장 완료(2026-06-29). 사이드바 "Search in folder"가 파일명(md/txt·이미지·pdf)+텍스트 본문(md/markdown/txt)+PDF 본문 검색. 결과 라벨 이름/Line N/p.N, PDF 결과는 페이지 점프(`.scrollToPDFPage`). Omnisearch는 기존 동작 유지(opt-out). 84개 테스트 통과.
- Phase 3 완료(2026-06-29). 한글·오피스 읽기 — `DocumentKind.office` + `KordocService`(actor: npx 절대경로 탐지, `Process`로 `kordoc … --format json -o tmp --silent`, `KordocResult` 디코드) + `OfficeReaderView`(로딩/완료=읽기전용 프리뷰/실패+재시도). hwp/hwpx/hwpml/doc/docx/xls/xlsx. 원본 read-only. 미설치/실패/타임아웃 안내.
- 오피스 본문 검색 완료(2026-06-29). 폴더 검색이 HWP/오피스 본문까지(kordoc 변환 + 세션 캐시 by 경로+mtime), 결과 라벨 "내용"·클릭 시 열기. Omnisearch는 opt-out(실시간 변환 금지). `searchInFolder` 이전 Task 취소+검색어 가드(stale 결과 방지). 95개 테스트 통과.
- Phase 4 완료(2026-06-29). Claude 연동 — `ClaudeService`(actor: claude 절대경로 탐지, `Process`로 `claude -p`, 컨텍스트=stdin·프롬프트=`-p` 인자, 드레인 먼저 시작 후 stdin write 별도 detached로 교착 방지, 120s 타임아웃, stderr→미로그인/크레딧소진/일반실패 분류) + `ClaudePanelView`(전용 트레일링 리사이즈 패널: 프롬프트 ⌘↩·로딩/에러/응답·복사). 컨텍스트=선택영역>마크다운 본문>오피스 변환 마크다운. ContentView는 `.inspector`와 공존하도록 HStack 트레일링 컬럼(드래그 280~600). 진입점 ⇧⌘A·커맨드 팔레트·View 메뉴. 응답 저장(노트/볼트)·스트리밍은 후속. 109개 테스트 통과.
- Phase 5a 완료(2026-06-29). kordoc patch(편집 후 서식 보존 저장) — kordoc 실제 API 검증으로 **generate 부재 확인**(PRD 정정), patch/fill만 실재. `KordocWriteService`(actor: 편집 마크다운을 임시 .md로 적고 `kordoc patch <원본> <편집.md> -o <출력> --silent`, 120s 타임아웃, 출력 존재 확인, `KordocService.resolveNpxPath` 재사용) + `OfficeReaderView` 편집모드 토글(hwp/hwpx만, `MarkdownTextEditor` 재사용·자동완성 off) + `OfficeSaveConfirmView`(제안 경로 확인·위치변경 NSSavePanel). **원본 불변, 새 uniquified 출력**(`patchedOutputURL`), 제안→확인→실행. 약 121개 테스트 통과.
- Phase 5b 완료(2026-06-30). kordoc fill(양식 채우기) — CLI 검증으로 **fill은 `-o`를 무시하고 채운 hwpx를 stdout으로 스트리밍**·dry-run은 stdout JSON·출력은 항상 hwpx-preserve 확인. `KordocFillService`(actor: `kordoc fill --dry-run --silent`로 서식 필드 JSON 조회→`FillDetection` 디코드, `kordoc fill <원본> -j <값.json> --silent`로 채움, **stdout을 임시 .hwpx FileHandle로 받아 output으로 이동**(파이프 교착 회피), 매칭실패 경고 파싱, 120s, isSameFile 가드) + `FillField`/`FillDetection` 모델 + `DocumentKind.isFillable`(hwp/hwpx) + `OfficeFillView`(모달 시트: 필드 입력 폼·confidence·저장경로 NSSavePanel). 출력 항상 `(채움).hwpx`(uniquify), 원본 불변, 제안→확인→실행. 변경·비어있지 않은 값만 label 키로 전송(중복 label은 last-wins). 진입점=오피스 프리뷰 툴바 "양식 채우기"(비편집 시). 139개 테스트 통과.
- Phase 6 완료(2026-06-30). Claude 스마트 라우팅(PARA 분류) — 노트를 볼트로 보낼 때 규칙 미매칭이면 Claude가 본문을 읽고 설정된 PARA 폴더 중 하나를 제안. `ParaFolder` 모델·`legoSeed`(레고 구조) + `AppSettings`(paraVaultId·paraFolders·claudeRoutingEnabled, 하위호환 디코드) + `RouteHelper`(프롬프트·컨텍스트 truncate·stdout 첫 `{…}` JSON 추출/검증, **Claude는 설정 폴더 id 중에서만 선택**) + `AppState.requestClaudeRoute`(claudeService 재사용, 미설정 가드, claudeErrorMessage 재사용) + Send 시트 "Claude에게 맡기기"(제안→Vault/Folder 프리필+이유 캡션, 이동은 Send 눌러야; loadFolders(ensuring:)+suppressVaultReset로 onChange 레이스/클로버 방지) + VaultManager "PARA" 탭(볼트·폴더 CRUD·기본구조채우기·자동토글 기본 OFF) + autoRoute 미매칭 분기에 autoTriggerClaudeRoute. 제안→확인→실행, 무단 이동·삭제 없음. 154개 테스트 통과.
- Phase 7 완료(2026-06-30). 내용 검색(FTS5 영속 인덱스+파일감시) — `import SQLite3`(무依存, SPM 빌드·FTS5·snippet·한글 검증)·FSEvents 둘 다 macOS 내장. `SearchIndex`(actor: FTS5 docs/files 테이블, snippet·needsIndex(mtime)·remove/removeUnder·search, 통계누수 없음·TRANSIENT 바인딩·읽기전용; filename 매칭은 INSTR — FTS5 filename MATCH 무효 확인) + `ContentExtractor`(text/pdf 로컬·office는 kordoc) + `SearchIndexer`(actor: 폴더 워킹·mtime 스킵·삭제 제거; **경로 canonical(/var→/private/var) 정규화** `static canonicalURL`) + `FolderWatcher`(FSEvents, **`kFSEventStreamCreateFlagUseCFTypes` 필수** — 없으면 eventPaths가 char**라 콜백 크래시) + `AppSettings.indexedFolders` + `IndexSearchView`(전용 시트: 등록폴더·진행률·디바운스 검색·파일+스니펫·클릭 열기, 커맨드팔레트 진입). 등록 시 canonical 경로 저장(namespace 일관), 인덱싱 읽기전용·삭제 없음(등록 해제는 DB만), normalizedIndexFolders 정규화(중복/중첩). 175개 테스트(SQLite in-process라 인덱스·인덱서·sanitize·추출기·설정·정규화 단위테스트; FSEvents·kordoc·UI는 수동).
- Phase 8 완료(2026-06-30). 폴더 정리(배치) — 어수선한 폴더를 Claude가 종류·주제별로 제안→승인분만 이동, 배치 단위 undo, 삭제 없음. 두 모드(subfolder/PARA)를 제네릭 이동 목록 한 경로로 통합. 순수 헬퍼: `CleanupModels`·`FileScanner`(top-level 메타 스캔)·`CleanupPlanner`(스킴/배정 프롬프트·strict JSON 추출/디코드·허용 bucketId 검증·confidence 클램프·`sanitizeBucketName`·`destinationDir` 경로탈출 방지·`merge`·`buildMoves`). actor: `CleanupService`(스킴 제안→1차 배정→confidence<0.6만 본문발췌 2차 재배정→병합; ClaudeService·ContentExtractor 재사용)·`MoveExecutor`(승인&분류된 move만 `moveItem`, 충돌 `uniquified()`·덮어쓰기 금지, **삭제 없음**, undo=역이동+우리가 만든 빈 폴더만 제거(`missingAncestors`로 중첩 중간폴더 추적), 부분 실패 시 로그 보존)·`MoveLogStore`(배치 로그 영속 JSON). `CleanupPlan`이 `mode`를 직접 보유(apply 시 live 상태 desync/TOCTOU 방지). UI `FolderCleanupView`(시트: 폴더선택→**스킴 만들기→편집→배정하기** 2단계 C안 흐름→행별 승인 미리보기→적용, 정리기록 되돌리기; busy 중 폴더선택 잠금; 에러 전용 `cleanupError`). 진입점: 커맨드팔레트 "폴더 정리 (배치)"(reset 후 열기)·VaultManager PARA 탭 "이 볼트를 PARA로 정리…". 자동 OFF, 제안→확인→실행. 208개 테스트(모델·스캐너·플래너·로그·실행기·배선 단위; CleanupService·UI는 수동). 잔여 Minor(선택): View 메뉴 진입점·`ForEach(indices)` 삭제 애니메이션·PARA dismiss-then-present 수동 스모크.
- GitHub: `origin` = https://github.com/learn-slowly/cmd-docu (Public), `upstream` = 원작자 CmdMD. PR #1·#2·#3 머지 완료. main·cmd-docu 동기화(3cfc5e5).
  - 주의: `gh pr` 등은 `upstream` 원격 때문에 베이스를 원작자 저장소로 오인 → `--repo learn-slowly/cmd-docu` 명시 필요.
  - kordoc은 실재 npm 패키지(v3.5.1). 검증 샘플 HWP: `/Users/ahbaik/Downloads/제9회_전국동시지방선거_정의당_평가서.hwp`.
- Phase 8.5-① 완료(2026-06-30). 사이드바 PARA 렌즈 — 파일 트리를 PARA 분류대로 정렬·스타일(데이터·상태 불변, 렌더/순수만). `ParaLens`(순수 헬퍼: `classify(_:under:)` 숫자 접두사 10000_→projects/20000_→areas/30000_→resources/40000_→archive, **현재폴더 root 기준 상대경로만 스캔**해 조상 PARA 접두사 오분류 방지(root 자기 이름은 포함 → Archive 폴더 진입 시 내부 archive 유지), `sorted(_:under:)` 분류순(archive 맨 끝)·폴더먼저·이름순) + `SidebarView`(FileTreeView 루트·FileTreeItemRow 자식 ForEach에 sorted, 행 스타일=projects 아이콘 cmdsAccent+이름 medium·archive 라벨 opacity 0.45(자식 비상속·이중dim 없음)). 읽기/탐색 전용·이동삭제 없음. 워크플로(구현+3렌즈 적대적 검증)로 조상 오분류·이중 opacity 2건 잡아 수정, opus 재검증 clean. ParaLensTests 18개(Swift Testing). ⚠️ 기존 `AppParaRoutingTests` 1건은 실제 앱이 쓴 settings.json(paraVaultId)을 테스트가 읽어 실패하는 환경 격리 약점(이번 변경 무관, 후속 정리 대상). 다음: 단계 ②(메인 라이브러리 그리드+`mainMode` 토글) → ③(폴더별 뷰 기억).
- Phase 8.5-②a 완료(2026-06-30). 메인 라이브러리 뷰 + 모드 토글(썸네일 제외, 종류별 아이콘 셀). `MainMode`(reader/library)·`LibraryLayout`(list/grid)·`AppState.selectedFolder` + `LibraryListing.entries`(폴더 직속 폴더+파일 열거, 숨김 제외; 정렬은 ParaLens 재사용) + `LibraryView`(헤더↑·LazyVGrid/List·아이콘 셀·archive dim·폴더 드릴인·파일→리더; entries는 @State 캐시·`.task(id: folderKey)`로 폴더 변경 시만 열거·`ForEach(id:\.url)`로 동일성 안정) + `MainEditorView` mainMode 분기(readerLayout 추출) + 툴바 `MainModePicker`/`LibraryLayoutPicker`(보조토글 모드별 교체) + `SidebarView` Finder식 행(수동 디스클로저: chevron=펼침/라벨 탭=폴더 선택→라이브러리·파일 열기→리더; ①의 PARA 스타일·별·컨텍스트 보존, 행 maxWidth+contentShape로 히트영역 확보). selectedFolder 리셋은 currentFolder 변경 2곳에만(loadFileTree 새로고침엔 보존). 읽기/탐색 전용. 워크플로(구현 4태스크 + 4렌즈 적대적 검증)로 실제 결함 4건(loadFileTree 과잉리셋·LibraryView 매렌더 FS+UUID 동일성파괴·사이드바 우클릭 히트영역·경로 prefix 경계) 잡아 수정, opus 재검증 clean. AppLibraryStateTests·LibraryListingTests 통과(전체 229 XCTest + ParaLens). ⚠️ `AppParaRoutingTests` **2건** 실패는 테스트가 실제 settings.json(paraVaultId 설정됨)을 읽어 발생하는 환경 격리 약점(이번 변경 무관, 1건은 실제 claude 호출로 16s 타임아웃) — 후속 정리 권장(임시 데이터 디렉터리 주입). 다음: ②b(QLThumbnailGenerator 썸네일+NSCache) → ③(폴더별 뷰 기억).
- Phase 8.5-②b 완료(2026-07-01). 라이브러리 그리드 썸네일 — 종류별 SF 아이콘을 QuickLook 썸네일로(전 파일 시도+실패 시 아이콘 폴백, 그리드만, 폴더는 폴더 아이콘). `ThumbnailService`(@MainActor, `QLThumbnailGenerator`+`NSCache`, `thumbnail(for:pointSize:scale:) async→NSImage?` 실패 시 nil, `cacheKey` 순수·mtime 포함해 편집 시 갱신) + `LibraryGridCell`(@State thumbnail, `.task(id:url)`로 파일만 생성·셀 사라지면 취소, 있으면 `Image(nsImage)`·없으면 SF 아이콘, `clipShape(.rect)`). LazyVGrid라 보이는 셀만 생성(1000+ 안전). 읽기 전용. 워크플로(구현 2태스크+3렌즈 검증)로 minor 1건(cornerRadius deprecated) 수정, 2렌즈 clean. 253 테스트(신규 ThumbnailServiceTests). 다음: 8.5-③(폴더별 뷰 기억).
- Phase 8.5-③ 완료(2026-07-01) → **Phase 8.5 전체 완결**(①PARA렌즈·②a라이브러리/모드·②b썸네일·③폴더별 기억). 폴더별 뷰 기억 — `AppSettings.libraryLayouts[폴더경로: LibraryLayout]` 영속(settings.json, 하위호환 디코드) + `AppState`의 `selectedFolder`/`libraryLayout` `didSet`(폴더 바뀌면 기억된 layout 복원·없으면 유지, 토글 시 현재 폴더에 저장+`saveUserData()` 명시 호출, `isRestoringLayout` 플래그로 되먹임/중복저장 방지). 키=standardizedFileURL.path. 워크플로(구현 2태스크+3렌즈 검증). LibraryLayoutSettingsTests 2·AppLibraryLayoutMemoryTests 4.
- 테스트 격리 근본 수정(2026-07-01). `AppState(dataDirectory: URL? = nil)` 주입 — 기본 nil이면 실제 app-support/CmdMD, 테스트는 per-test 임시 디렉터리(`TempDataDirectory` 헬퍼) 주입해 모든 영속(settings/session/drafts/index)을 격리. 그동안 AppState 테스트가 **실제 settings.json을 읽고 써서** 발생하던 (a) 사용자 설정 오염 (b) 세션 복원 의존 비결정성 (c) **`AppParaRoutingTests` 2건 환경실패**를 모두 해소. AppLibraryLayoutMemoryTests·AppLibraryStateTests·AppParaRoutingTests·AppCleanupStateTests 전환. 277 테스트(XCTest 259+Testing 18) 전부 통과. (후속: AppFillState·AppImageTab 등 나머지 App* 테스트도 동일 전환하면 완전 격리.)
- Phase 8.5(완료 — 아래는 원설계 참고) — PARA 라이브러리 뷰. "파일 하나 읽는 리더" 위에 "폴더를 펼쳐 훑는 라이브러리"를 더하고, PARA를 출력(라우팅)뿐 아니라 **탐색 축**으로도 쓴다(`legoSeed` 재사용). (1) `AppState.mainMode`(reader/library) 추가, `MainEditorView`가 분기, 툴바에 리더⇄라이브러리 세그먼트(하위 보조토글은 모드 따라 Source·Split·Preview ⇄ List·Grid 교체). (2) 클릭 동선 절충 — 파일 클릭→reader, 폴더 클릭→library 자동전환하되 토글이 우선(덮어쓰기), 관통축은 "현재 폴더". (3) 폴더 **선택** 개념 신설 — 현재 트리는 펼치기만 있고 선택이 없음. `selectedFolder`(폴더 탭 시 set) 도입, 펼치기(disclosure)와 별개. (4) 라이브러리 뷰 = detail에 `LazyVGrid`/`List`, 항목은 `selectedFolder` 직속 파일+하위폴더, 그리드셀=썸네일+이름+종류, 파일 클릭→리더로 줌인. (5) 썸네일 = `QLThumbnailGenerator`(QuickLook)로 이미지·PDF·영상·오피스 전 타입, lazy 생성+`NSCache`, 화면 밖 생성 보류(1,000+ 대비). (6) PARA 렌즈 = 사이드바 트리 루트를 `legoSeed` 기준 정렬/그룹, 경로로 분류 판별(`40000_Archive` 하위 dim·`10000_Projects` 하위 또렷). (7) 폴더별 뷰 기억 = `[URL: LibraryLayout]`(list/grid)을 `SessionState`/설정에 저장·복원. 안 만드는 것: 편집·동기화·모바일·신규 영상플레이어(썸네일까지만). **읽기/탐색 전용 — 파일 이동·삭제 없음**(정리는 Phase 8 몫). 단계: ①사이드바 PARA 렌즈(가벼움·즉시 PARA 느낌) → ②메인 라이브러리 그리드+모드토글 → ③폴더별 뷰 기억·다듬기. 비고: Phase 8(폴더정리)과 "폴더 한눈에 보기" 화면을 공유 — 8.5 그리드가 8 정리의 무대가 되도록 둘을 잇는다.
- Phase 8.7 완료(2026-07-01). 미리보기 속도 다듬기(검증 확정분만). **highlight.js 로컬화** — CDN 대신 이미 동봉된 Highlightr 번들을 인라인 주입(`LocalWebAssets`: 번들 탐색·lazy static 캐시·`hljsBlock`은 JS·라이트·다크 CSS **셋 다 있을 때만**, 없으면 CDN 폴백)·`MarkdownRenderer.hljsIncludes` 수정. **THIRD-PARTY-NOTICES** §1·§4에 highlight.js 추가(헤더 실확인=**BSD-3-Clause**, © Josh Goebel 외 — 기존 §1 Highlightr의 기저 라이브러리). **파일트리 백그라운드** — `AppState.buildFileTree`를 순수 static(`at:expanded:depth:`)으로 전환, `loadFileTree`가 메인에서 스냅샷 캡처→`Task.detached` 스캔→`MainActor`에서 `self.fileTree` 반영(선행 `fileTreeTask?.cancel()`+`isCancelled` 가드). 워크플로(구현 2태스크+3렌즈 적대적 검증)로 결함 3건(hljsBlock 가드 불충분→폴백 누락·loadFileTree가 self 대신 shared 대입·RendererFeatureTests가 인라인 경로 미검증) 잡아 수정. 250 테스트(신규 `LocalWebAssetsTests`·`FileTreeBuildTests`). 보류: **미리보기 렌더는 이미 250ms 디바운스 있음(검증)→DOM 부분갱신 A-3 보류**, KaTeX/Mermaid 로컬화(자산 동봉 필요·KaTeX 기본 비활성)는 후속.
- 위키링크 점-이름 버그 수정(2026-07-01). `[[1.1.1_미디어_개념과_특징]]`처럼 점(.) 든 노트 이름이 "찾을 수 없음"으로 실패하던 버그 — `LinkedNoteResolver`의 `findLinkedNote`/`fileNameVariants`가 마지막 점 뒤를 무조건 파일 확장자로 오인(`NSString.deletingPathExtension`·`pathExtension`)해 이름을 "1.1"로 잘랐다(공백 든 이름·경로형 링크는 우회돼 정상이라 증상이 헷갈렸음). 지원 확장자(md/markdown/txt)가 명시된 경우에만 떼도록 정정(`strippingSupportedExtension`). systematic-debugging으로 진단(NFC/NFD 가설 기각→점-확장자 오인 확정), 실데이터(notebox) 검증 + 회귀 테스트 3건.
- 다음 액션: Phase 9 시맨틱+RAG → 10 다듬기·배포. 별건 후보: 작업 B(미디어 플레이어+짝꿍 노트, `cmd-docu_개선작업_문서.md`), KaTeX/Mermaid 로컬화(Phase 8.7 후속), 나머지 App* 테스트 임시 디렉터리 전환.

## 세션 종료 기록 (옵시디언 데일리 로그)

작업 세션을 마무리할 때, 오늘 한 일을 옵시디언 데일리 노트에 기록할 것.

- 파일: `/Users/ahbaik/coding/notebox/Calendar/YYYY-MM-DD.md` (오늘 날짜, KST 기준)
- 위치: `## ✅ 오늘 한 일 #daily_donelist` 섹션 안. `**개발**` 소제목이 있으면 그 아래에 줄 추가, 없으면 섹션 끝(다음 `##` 헤딩 직전)에 `**개발**` 소제목을 만들고 그 아래에 추가
- 형식: `- [cmd-docu] 한 일 요약 한 줄 (다음: 다음 액션 한 줄)`
- 규칙: 기존 내용은 절대 수정·삭제하지 말고 줄 추가만 할 것. 오늘 날짜 파일이 없으면 새로 만들지 말고 기록을 건너뛸 것.
