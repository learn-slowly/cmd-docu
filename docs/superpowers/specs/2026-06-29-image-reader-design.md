# Phase 1 — 이미지 리더 설계

- 날짜: 2026-06-29
- 대상: cmd-docu (CmdMD v1.4.8 포크), `cmd-docu` 브랜치
- 범위: PRD 티어 1 / Phase 1 — 이미지 단독 파일 보기(줌·팬·맞춤, 애니메이션 GIF 재생)
- 통합 방식: **A안 — 탭 kind 분기** (최소 침습, 기존 마크다운 경로 무변경)

## 1. 목표 / 비목표

**목표**
- `.png .jpg .jpeg .heic .webp .gif` 단독 이미지를 기존 탭 UX로 같은 창에서 연다.
- 화면 맞춤(fit) + 줌(스크롤휠/핀치) + 팬(드래그). 더블클릭으로 맞춤↔100% 토글.
- 애니메이션 GIF 자동 재생.
- 로드 실패 시 크래시 없이 뷰 안 플레이스홀더.

**비목표 (YAGNI — PRD에 없음)**
- 회전, EXIF 방향 보정, 여러 장 갤러리/슬라이드쇼, 썸네일 스트립, 이미지 편집/내보내기/복사.
- PDF·오피스(각각 Phase 2·3). 단, `DocumentKind`는 이후 케이스 추가만으로 확장되도록 설계.

## 2. 통합 방식 (A안) 선택 근거

현 구조는 모든 탭이 `MarkdownDocument` + `WKWebView` 프리뷰에 묶여 있다. 대안 비교:

- **A. 탭 kind 분기 (채택)**: `DocumentKind` 신설 + `EditorTab.kind` 추가, 뷰 레벨에서 분기. 신규 코드는 별도 파일. 기존 마크다운 경로 무변경. 변경 표면 최소 → 업스트림 머지 안전(CLAUDE.md 규칙).
- B. Document 추상화 리팩터(`enum TabContent`): 장기적으로 깔끔하나 `AppState.documents`·`currentDocument`·저장 로직 광범위 수정 → 머지 고통. 기각.
- C. WebView에 `<img>` 재사용: 줌/팬 UX 조잡, heic/webp는 WebKit 의존, 렌더러 오염, "보기=네이티브" 취지 위배. 기각.

## 3. 구성요소

### 3.1 `Sources/Models/DocumentKind.swift` (신규)
```
enum DocumentKind { case markdown, image }
extension DocumentKind {
    init(from url: URL)   // 확장자(소문자) 기반 매핑
}
```
- 매핑: `png jpg jpeg heic webp gif` → `.image`. 그 외(빈 확장자 포함) → `.markdown`(현행 기본 동작 유지).
- 대소문자 무시(`pathExtension.lowercased()`).
- 지원 이미지 확장자 집합은 이 파일의 `static let imageExtensions: Set<String>` 한 곳에서 관리(패널 UTType·드롭 필터와 공유).

### 3.2 `Sources/Views/ImageReaderView.swift` (신규)
- `NSViewRepresentable`로 AppKit 뷰 래핑. 입력: `let url: URL`.
- 구조: `NSScrollView`
  - `allowsMagnification = true`, `minMagnification = 0.1`, `maxMagnification = 16`
  - `documentView = NSImageView` (`imageScaling = .scaleNone`, `animates = true` → GIF 재생)
- 이미지 로드: `NSImage(contentsOf: url)`. 성공 시 `imageView`를 이미지 픽셀 크기로 설정.
- 맞춤(fit): `makeNSView`/`updateNSView`에서 스크롤뷰 가시영역 대비 이미지 크기로 초기 `magnification` 계산(축소만, 1배 초과 확대는 안 함 → 작은 이미지는 100%).
- 더블클릭: 맞춤 배율 ↔ 1.0 토글(Coordinator가 클릭 위치 기준 `setMagnification(_:centeredAt:)`).
- 실패: 이미지가 nil이면 documentView를 "이미지를 열 수 없음" 플레이스홀더(SF Symbol + 텍스트)로 대체. 크래시 금지(CLAUDE.md).
- `url` 변경 시(탭 교체로 동일 뷰 재사용될 경우) `updateNSView`에서 이미지 재로딩.

### 3.3 `Sources/Models/Workspace.swift` — `EditorTab` 확장
- `var kind: DocumentKind` 추가. 멤버와이즈 `init` 기본값 `.markdown`.
- `DocumentKind`는 `String` rawValue `Codable`(`"markdown"`/`"image"`).
- Codable 하위호환(단일 방식 확정): `EditorTab`에 커스텀 `init(from decoder:)`를 구현해 `try container.decodeIfPresent(DocumentKind.self, forKey: .kind) ?? .markdown` 로 디코딩. 기존 세션 JSON엔 `kind` 키가 없으므로 자동으로 `.markdown`. 인코딩은 합성 또는 명시 모두 무방하되 키는 항상 기록.

### 3.4 `Sources/App/AppState.swift`
- `loadAndActivateDocument(at:)` 분기:
  - `let kind = DocumentKind(from: url)`
  - `.image`: `MarkdownDocument` 로드/`documents[]`/`originalContents`/파일워처 **생략**. URL·title(파일명)·`kind: .image`만 가진 `EditorTab` 생성·활성화. `addToRecentFiles(url)`는 유지.
  - `.markdown`: 기존 경로 그대로.
  - 탭 교체(in-place) 로직은 양 kind 공통으로 동작하도록 유지(이미지 탭에는 정리할 documents/워처가 없으니 안전).
- `openFile()`의 `allowedContentTypes`에 이미지 UTType 추가(`.png .jpeg .heic .webP .gif` + `UTType(filenameExtension:)`로 보강). md/txt도 계속 허용.
- 현재 활성 탭의 kind를 노출하는 계산 프로퍼티 추가(예: `var currentTabKind: DocumentKind`), `MainEditorView` 분기에 사용.
- `windowTitle`: 이미지 탭이면 `currentDocument`가 nil이므로, 활성 탭의 파일명으로 제목을 내도록 보강(없으면 "cmd-docu").

### 3.5 `Sources/Views/MainEditorView.swift`
- 본문 분기:
  - 활성 탭 `kind == .image` → `ImageReaderView(url: tab.fileURL!)`
  - else → 기존 `currentDocument`/`DocumentEditorView`/`WelcomeView` 경로.
- 브레드크럼(SimpleBreadcrumbView)은 fileURL 기반이라 이미지 탭에서도 동작(그대로 재사용).
- 상태바(StatusBarView)는 마크다운 통계 의존이므로 이미지 탭에선 숨김(분기).

## 4. 데이터 흐름

```
열기(openFile / 드롭 / openDocument(at:))
  → DocumentKind(from: url)
    ├─ .image  → EditorTab(kind:.image, fileURL:url, title:파일명)  [documents/워처/originalContents 생략]
    │            → MainEditorView: ImageReaderView(url:)
    └─ .markdown → (기존) FileService.loadDocument → documents[] → DocumentEditorView
```
마크다운 흐름·저장·세션 복원은 무변경. 세션에 저장된 이미지 탭은 복원 시 `kind:.image`로 다시 `ImageReaderView`로 감.

## 5. 에러 처리

- 이미지 로드 실패(손상·미지원 내부 포맷): 뷰 내 플레이스홀더, 크래시·예외 없음.
- 이미지 탭인데 `fileURL == nil`(이론상 없음): 방어적으로 플레이스홀더.
- 패널/드롭으로 비이미지가 image 분기에 잘못 들어오는 일은 `DocumentKind`가 단일 판별원이라 발생하지 않음.

## 6. 테스트 (Phase 게이트)

**신규(XCTest, TDD 우선):** `DocumentKindTests`
- `png/jpg/jpeg/heic/webp/gif` → `.image`
- 대문자(`PNG`)·혼합(`Jpg`) → `.image`
- `md/markdown/txt/빈 확장자/알 수 없는 확장자` → `.markdown`
- `imageExtensions` 집합과 매핑 일관성

**게이트:** 기존 57개 + 신규 케이스 모두 통과(정식 Xcode 필요). 뷰(`ImageReaderView`)는 UI라 자동 테스트 제외 — 실제 png/jpg/heic/webp/gif로 수동 확인(열기·맞춤·줌·팬·GIF 재생·실패 플레이스홀더).

## 7. 파일 변경 요약

| 파일 | 변경 |
| --- | --- |
| `Sources/Models/DocumentKind.swift` | 신규 — enum + `init(from:URL)` + `imageExtensions` |
| `Sources/Views/ImageReaderView.swift` | 신규 — NSScrollView+NSImageView 래퍼 |
| `Sources/Models/Workspace.swift` | `EditorTab.kind` 추가(기본 .markdown, Codable 하위호환) |
| `Sources/App/AppState.swift` | 로드 분기, 패널 UTType, currentTabKind, windowTitle 보강 |
| `Sources/Views/MainEditorView.swift` | kind별 본문 분기, 상태바 분기 |
| `Tests/CmdMDTests/DocumentKindTests.swift` | 신규 — 매핑 테스트 |

신규 로직은 가능한 별도 파일에 격리(업스트림 머지 용이). 기존 파일 변경은 분기 추가 위주, 마크다운 동작 불변.
