# 작업 B — 음악·동영상 플레이어 + 짝꿍 노트 설계

> 2026-07-02. 출처: `cmd-docu_개선작업_문서.md` §3(작업 B). 선행조건인 작업 A(속도)는 Phase 8.7로 완료.
> 브레인스토밍으로 확정: 노트 규칙 `파일명.mp3.md` / 확장자 AVFoundation 지원 전부 / 플레이어+노트 한 화면 /
> B Phase 1+2+3 전부 한 사이클 / 짝꿍 노트 목록 숨김+배지 / 노트 편집 = 임베디드 편집기(접근법 1).

## 0. 핵심 개념

목표는 플레이어가 아니라 **"재생하지 않고도 그 파일이 뭔지 아는 것"**. 미디어 파일마다 마크다운
짝꿍 노트를 두고, 이 앱이 이미 잘하는 것(편집·미리보기·검색·정리)에 파일 하나를 짝지어 준다.
메모는 DB가 아니라 **파일 옆 `.md`** — Dropbox 동기화·볼트 이동·옵시디언 호환(평문·이식성 철학).

## 1. 목표

- 미디어 파일(음악·동영상)을 열면 **플레이어 + 짝꿍 노트**가 한 화면에 뜬다. 재생하지 않아도 메모가 보인다.
- 노트가 없으면 "메모 만들기" 버튼 → AVFoundation 메타데이터(길이·내장 제목 등)를 frontmatter에 자동으로 채운 노트 생성 → 바로 편집.
- 짝꿍 노트는 기존 검색(FTS5 인덱스·Omnisearch·RAG)에 자연히 걸린다 — "삐약이 추모곡 첫 데모"로 검색하면 노트가 그 음원을 찾아준다.
- 목록(사이드바·라이브러리)에서 미디어 행이 대표가 되고, 짝꿍 노트는 숨기되 배지로 존재를 알린다.

## 2. 검증 완료 / 재사용 확인 (추정 금지 준수)

- `DocumentKind`(`Sources/Models/DocumentKind.swift`) = 확장자→종류 단일 판별원. 현재 미디어 확장자는 기본값 markdown으로 오분류됨(확인).
- `MainEditorView.readerLayout`이 `currentTabKind`로 이미지/PDF/오피스 뷰를 분기(확인) — media 분기 추가 자리.
- `EditorTab.kind: DocumentKind`(`Workspace.swift:40`)는 String raw Codable — 케이스 추가는 구 세션 복원에 안전(확인).
- `AppState.isListableInFileTree`(AppState.swift:1207)가 사이드바 표시 확장자 단일 게이트(확인).
- `OfficeReaderView`가 읽기전용 프리뷰 + `MarkdownTextEditor` 편집 토글 패턴을 이미 검증(확인) — 노트 패널이 재사용.
- `ThumbnailService`는 전 파일에 QuickLook 시도 + 실패 시 아이콘 폴백(확인) — 동영상 썸네일 신규 작업 불필요.
- `SearchIndexer`/`ContentExtractor`는 `.md`를 이미 인덱싱(확인) — `파일명.mp3.md`는 확장자가 md라 자동 포함.
- `LinkedNoteResolver`의 점-이름 처리(`strippingSupportedExtension`)는 2026-07-01 수정 완료 — `파일명.mp3.md` 같은 점 든 이름 안전(확인).
- AVKit/AVFoundation은 현재 미사용(확인) — 시스템 프레임워크라 **새 패키지 의존성 0**.
- 〔구현 중 실확인〕 SwiftUI `VideoPlayer`가 오디오 전용 파일에서 컨트롤 바로 쓸 만한지 — 아니면 컴팩트 커스텀 바(AVPlayer + 재생/일시정지·시크·시간 표시)로 대체.

## 3. 데이터 설계

### 3.1 짝꿍 노트 규칙

- 미디어 `삐약이_데모.mp3` ↔ 노트 `삐약이_데모.mp3.md` (원본 확장자 뒤에 `.md`를 덧붙임).
  - 같은 이름의 mp3/mp4가 공존해도 노트 충돌 없음. 짝이 이름만으로 명확.
- **생성은 "메모 만들기" 버튼으로만** — 자동 생성 없음. 원본 미디어는 절대 불변(읽기 전용). 앱이 쓰는 파일은 짝꿍 `.md`뿐.

### 3.2 노트 초기 내용 (frontmatter 자동 채움)

```yaml
---
media: 삐약이_데모.mp3     # 짝 미디어 파일명(같은 폴더 상대)
duration: "3:42"          # AVFoundation (실패 시 "")
format: mp3               # 소문자 확장자
created: 2026-07-02       # 미디어 파일 생성일 (실패 시 오늘)
summary: ""               # 사용자가 채우는 한 줄 요약
tags: []
---

```

- 내장 제목(ID3 등)이 읽히면 본문 첫 줄에 `# 제목`으로 넣는다(없으면 파일명).
- frontmatter 키는 위 6개로 고정(최소셋). 이후 필요 시 가산.

## 4. 아키텍처 (전부 별도 파일 가산, 기존 최소 수정)

### 4.1 `DocumentKind` 가산 (`Sources/Models/DocumentKind.swift`)

- `case media` 추가.
- `audioExtensions: Set<String> = ["mp3","m4a","aac","wav","aiff","flac"]`
- `videoExtensions: Set<String> = ["mp4","mov","m4v"]`
- `mediaExtensions = audioExtensions ∪ videoExtensions`
- `init(from:)` 분기: 이미지 → PDF → 오피스 → **미디어** → 마크다운(기본).
- `static func isVideo(_ url: URL) -> Bool` (레이아웃 분기용).

### 4.2 `Sources/Models/CompanionNote.swift` (신규, 순수)

- `static func noteURL(for mediaURL: URL) -> URL` — `appendingPathExtension("md")`.
- `static func mediaURL(for noteURL: URL) -> URL?` — `*.md`를 벗겼을 때 미디어 확장자면 그 URL, 아니면 nil.
- `static func isCompanionNote(_ url: URL, siblings: Set<String>) -> Bool` — **같은 폴더 열거 목록(siblings)에 대응 미디어 파일명이 있을 때만** 짝꿍으로 판별. 렌더·빌드 중 추가 FS 호출 없음(8.5-②a 교훈).
- `static func initialContent(mediaFileName:metadata:) -> String` — §3.2 frontmatter + 제목 본문 생성(순수).

### 4.3 `Sources/Services/MediaMetadataService.swift` (신규)

- `struct MediaMetadata { durationSeconds: Double?; embeddedTitle: String?; format: String; createdAt: Date? }`
- `static func load(url: URL) async -> MediaMetadata` — `AVURLAsset.load(.duration)` + common metadata(제목). 어느 필드든 실패하면 nil로 두고 **노트 생성은 계속 진행**(차단 없음).
- duration 표시 포맷터(`m:ss` / `h:mm:ss`)는 순수 static — 테스트 대상.

### 4.4 `Sources/Views/MediaReaderView.swift` (신규)

- `MainEditorView.readerLayout`에 `.media` 분기 추가(이미지/PDF/오피스와 동형).
- 레이아웃: **동영상** = 좌 플레이어 / 우 노트 패널(HSplit, 기존 리더들의 분할 관례를 따름). **음악** = 상단 컴팩트 재생 바 + 아래 노트 전체.
- 플레이어: AVKit `VideoPlayer(player:)`. `.task(id: url)`로 파일 변경 시 AVPlayer 교체, `onDisappear`/탭 전환 시 `pause()`. 재생 불가(코덱 미지원 등)면 플레이스홀더(PDF 실패 패턴).
- 노트 패널(뷰 내부 상태, 기존 문서/탭 모델 불변):
  - 노트 있음 → 읽기전용 미리보기(오피스 리더의 프리뷰 방식 재사용), 툴바 토글로 편집(`MarkdownTextEditor`, 자동완성 off).
  - 저장 = 편집 토글 종료 시 자동 저장 + 명시 저장 버튼. 저장 실패 시 에러 표시·편집 내용 유지.
  - 노트 없음 → 빈 상태 + "메모 만들기" 버튼: 메타데이터 로드 → `CompanionNote.initialContent`로 파일 생성 → 곧장 편집 모드. 이미 같은 이름 파일이 생겨 있으면(레이스) 그 파일을 연다(덮어쓰기 금지).

### 4.5 목록 표시 (Phase 3)

- `AppState.isListableInFileTree`에 `mediaExtensions` 추가.
- **숨김**: `buildFileTree`·`LibraryListing.entries`가 폴더 열거 결과 안에서 `CompanionNote.isCompanionNote(url, siblings:)`인 항목 제외.
- **배지**: 트리/라이브러리 항목에 `hasCompanionNote: Bool`을 빌드 시 채워 저장(렌더 중 FS 호출 없음). 사이드바 행·라이브러리 셀에 작은 메모 배지 표시.
- 라이브러리 **리스트** 셀: 짝꿍 노트의 `summary`를 부제로 lazy 표시(`.task(id:)`, ThumbnailService 패턴 — 셀 사라지면 취소). 그리드 셀은 배지만.
- 폴더 검색(파일명 매칭)에 미디어 확장자 추가.

### 4.6 열기 리다이렉트 (`AppState.loadAndActivateDocument`)

- 여는 URL이 짝꿍 노트(`CompanionNote.mediaURL(for:)` 성립 + 그 미디어 파일이 실존)면 **대응 미디어를 media로 연다**.
  검색·위키링크·최근 파일 등 모든 진입로에 일관 적용. 노트는 미디어 뷰 안에서 어차피 열람·편집 가능하므로 기능 손실 없음.
- 대응 미디어가 없으면(고아 노트) 일반 마크다운으로 연다.

## 5. 에러·안전

- 원본 미디어 파일은 어떤 경로에서도 쓰지 않는다(읽기 전용). 이동·삭제 없음.
- 노트 생성은 사용자가 버튼으로 명시 요청했을 때만. 기존 파일 덮어쓰기 금지.
- AVFoundation 로드 실패는 기능 저하(플레이스홀더·빈 메타데이터)로만, 크래시·차단 없음.
- kordoc·claude와 무관한 기능 — 외부 도구 미설치와 상관없이 동작.

## 6. 범위 밖 (안 만드는 것)

- 플레이리스트·연속 재생, 커스텀 재생 컨트롤(배속·구간반복·챕터), 영상 편집, 오디오 파형 표시.
- 신규 썸네일 파이프라인(기존 `ThumbnailService`가 담당), 미디어 본문(음성 인식 등) 검색 인덱싱.
- Inspector 개조(노트는 미디어 뷰 안에서 처리).

## 7. 테스트 (Phase 게이트: 전후 `swift test`)

- `CompanionNote`: noteURL/mediaURL 왕복, 점 든 이름·대소문자 확장자, siblings 기반 판별(대응 미디어 없으면 숨기지 않음), initialContent frontmatter 필드·YAML 이스케이프.
- `DocumentKind`: 미디어 확장자 매핑·isVideo·기존 종류 회귀.
- `MediaMetadataService`: 테스트가 작은 WAV(PCM 헤더)를 코드로 생성해 duration 실검증 + 포맷터 순수 테스트.
- 트리/라이브러리: 숨김·`hasCompanionNote` 플래그·미디어 확장자 표시 (임시 디렉터리 fixture).
- 열기 리다이렉트: 짝꿍 노트 URL → media 탭, 고아 노트 → markdown 탭 (`TempDataDirectory` 주입).
- 수동 스모크: 실제 mp3/mp4 재생, 오디오 `VideoPlayer` 컨트롤 확인(§2 실확인), 메모 만들기→검색→점프 왕복.
