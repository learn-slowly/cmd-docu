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
- 티어 3(나중): 7 내용검색(키워드) → 8 폴더정리 → 9 시맨틱+RAG → 10 다듬기·배포

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
- GitHub: `origin` = https://github.com/learn-slowly/cmd-docu (Public), `upstream` = 원작자 CmdMD. PR #1·#2 머지 완료. main·cmd-docu 동기화.
  - 주의: `gh pr` 등은 `upstream` 원격 때문에 베이스를 원작자 저장소로 오인 → `--repo learn-slowly/cmd-docu` 명시 필요.
- 다음 액션: Phase 3 — 한글·오피스 읽기(kordoc): `npx kordoc <파일> --format json` → 마크다운 렌더. Node/kordoc 경로 탐지·미설치 안내.

## 세션 종료 기록 (옵시디언 데일리 로그)

작업 세션을 마무리할 때, 오늘 한 일을 옵시디언 데일리 노트에 기록할 것.

- 파일: `/Users/ahbaik/coding/notebox/Calendar/YYYY-MM-DD.md` (오늘 날짜, KST 기준)
- 위치: `## ✅ 오늘 한 일 #daily_donelist` 섹션 안. `**개발**` 소제목이 있으면 그 아래에 줄 추가, 없으면 섹션 끝(다음 `##` 헤딩 직전)에 `**개발**` 소제목을 만들고 그 아래에 추가
- 형식: `- [cmd-docu] 한 일 요약 한 줄 (다음: 다음 액션 한 줄)`
- 규칙: 기존 내용은 절대 수정·삭제하지 말고 줄 추가만 할 것. 오늘 날짜 파일이 없으면 새로 만들지 말고 기록을 건너뛸 것.
