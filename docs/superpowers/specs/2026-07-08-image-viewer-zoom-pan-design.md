# 이미지 뷰어 줌·팬 개선 설계

- 날짜: 2026-07-08
- 대상 파일: `Sources/Views/ImageReaderView.swift`(개편), 신규 순수 헬퍼 `Sources/Models/ImageZoomMath.swift`
- 상태: 설계 확정용 (브레인스토밍 산출물)

## 1. 배경 / 문제

현재 `ImageReaderView`는 `NSScrollView` 매그니피케이션 기반이며 조작 수단이 빈약하다.

- **줌**: 트랙패드 핀치(또는 ⌘+스크롤) + 더블클릭 맞춤↔100% 토글뿐. 줌 버튼·키보드 단축키·배율 표시가 없다.
- **팬(이동)**: 스크롤바 + 트랙패드 두손가락 드래그뿐. **클릭-드래그(핸드툴) 팬이 없어** 마우스 사용자는 줌인 후 이동이 매우 불편하다.

사용자 요구: 줌인/줌아웃을 쉽게, 줌인 상태에서 이미지 이동을 쉽게. 마우스·트랙패드를 **둘 다** 사용.

## 2. 목표 / 비목표

### 목표
- 마우스·트랙패드 양쪽에서 자연스러운 줌·팬.
- 클릭-드래그 핸드툴 팬(손모양 커서).
- 마우스 휠 = 커서 위치 기준 줌(장치 판정).
- 상단 툴바: 축소/배율%/확대, 맞춤, 실제 크기(100% 리셋), 회전.
- 키보드: `⌘=`·`⌘+` 확대, `⌘-` 축소, `⌘0` 맞춤, `⌘1` 실제 크기, `⌘←/→/↑/↓` 이미지 이동.

### 비목표 (YAGNI)
- 탭별 줌/스크롤 위치 영속(로드 시 항상 맞춤).
- 배율 프리셋 드롭다운(25/50/…).
- 원본 파일 수정 — 회전은 **표시 전용**, 디스크에 저장하지 않는다(핵심 규칙: 원본 불변·읽기 전용).

## 3. 조작 모델

| 동작 | 마우스 | 트랙패드 | 구현 근거 |
|---|---|---|---|
| 팬(이동) | 이미지 **클릭-드래그(핸드툴)** ✨ | 두손가락 드래그 / 클릭-드래그 | 커스텀 `NSScrollView.mouseDown/Dragged/Up`; 커서 open/closedHand |
| 줌 | **휠 스크롤 = 커서 위치 기준 줌** ✨ | 핀치(현행) | `scrollWheel` 오버라이드 + `allowsMagnification` |
| ⌘+스크롤 | 줌 | 줌 | 장치 무관 명시 줌 경로 |
| 더블클릭 | 맞춤 ↔ 실제크기 토글(현행) | 동일 | 기존 `NSClickGestureRecognizer` 유지 |

### 3.1 스크롤 휠 장치 판정
- `NSEvent.hasPreciseScrollingDeltas == false` → 저정밀(휠 마우스) → **줌**.
- `== true` → 정밀(트랙패드/Magic Mouse) → **팬**(super로 위임).
- **단, ⌘ 수정자가 눌려 있으면 장치 무관 항상 줌.**
- 판정은 순수 함수 `ImageZoomMath.shouldZoom(hasPreciseDeltas:commandHeld:)`로 분리해 단위 테스트.
- **수용 트레이드오프**: Magic Mouse는 정밀 스크롤을 보고하므로 스와이프=팬이 된다. 줌은 ⌘+스크롤·버튼·키보드·더블클릭으로 가능. 이는 표준 macOS 휴리스틱이며 문서화한다.

### 3.2 클릭-드래그 팬
- 커스텀 `NSScrollView` 서브클래스가 `mouseDown`에서 시작점 기록 → `mouseDragged`에서 `contentView`의 bounds origin을 델타만큼 이동(`reflectScrolledClipView`)으로 스크롤 → `mouseUp` 종료.
- 커서: 이미지 위 hover 시 `NSCursor.openHand`, 드래그 중 `NSCursor.closedHand`(트래킹 영역 또는 push/pop).
- 이미지가 뷰보다 작아 스크롤 여지가 없으면 팬은 무동작(자연스럽게 clamp).
- 기존 더블클릭 제스처와 공존(단일 클릭+드래그=팬, 빠른 더블클릭=토글).

## 4. 상단 툴바

PDF 뷰어와 동일한 인라인 상단 바(컨테이너 `NSView` 안에 상단 `NSStackView` + 하단 스크롤뷰). 레이아웃:

```
[ − ]  [ 42% ]  [ + ]    |    [ 맞춤 ]  [ 실제 크기 ]    |    [ ↺ ]  [ ↻ ]
```

- **`−` / `+`**: 배율 ÷/×1.25(클램프). 뷰 중심 기준.
- **`42%` 라벨**: 현재 배율 실시간 표시(핀치·휠·버튼·키보드 모두 반영). **클릭 시 100%로 리셋.**
- **맞춤**: 창에 맞춤 배율(축소만, 1.0 상한).
- **실제 크기**: 100%(1.0).
- **↺ / ↻**: 왼쪽/오른쪽 90° 회전 — **표시 전용**. 회전 후 폭·높이가 뒤바뀌므로 맞춤 배율 재계산. 원본 미저장.
- 버튼 아이콘은 SF Symbol(`minus.magnifyingglass`/`plus.magnifyingglass`/`arrow.up.left.and.arrow.down.right`/`1.magnifyingglass`/`rotate.left`/`rotate.right`), 로드 실패 시 빈 이미지 폴백(PDF 뷰어 관례).

## 5. 회전 (표시 전용)

- 회전 상태 `rotationDegrees ∈ {0,90,180,270}` 유지.
- 표시 이미지는 원본 `NSImage`를 회전각에 맞게 다시 그린 새 `NSImage`로 교체(원본 파일·원본 `NSImage` 불변).
- 90/270°에서 폭·높이 교환 → `imageView.frame`·맞춤 배율 재계산 후 맞춤 적용.
- 탭 전환/재로드 시 회전 상태는 0으로 초기화(영속 안 함).

## 6. 키보드 단축키

커스텀 `NSScrollView`가 `performKeyEquivalent(with:)`를 오버라이드해 키 윈도우 내에서 처리(첫 응답자 여부와 무관하게 responder chain으로 전달되어 안정적).

| 키 | 동작 |
|---|---|
| `⌘=` / `⌘+` | 확대 (⌘= 는 shift 없이도) |
| `⌘-` | 축소 |
| `⌘0` | 맞춤 |
| `⌘1` | 실제 크기(100%) |
| `⌘←` `⌘→` `⌘↑` `⌘↓` | 이미지 이동(팬) — 뷰 한 변의 일정 비율(예: 20%)만큼 스크롤 |

- 이미지 뷰가 키 윈도우에 없으면 아무 처리 없이 `super`로 위임 → 다른 화면과 충돌 없음.
- 기존 앱 단축키 스캔 결과 ⌘+/-/0/1·⌘화살표는 **미사용**(충돌 없음, 코드 확인 완료).

## 7. 컴포넌트 구조

작은 단위로 분리(브레인스토밍 격리 원칙). PDF 뷰어의 검증된 all-AppKit 패턴을 따라 SwiftUI/AppKit 상태 브리징을 피한다.

### 7.1 `ImageZoomMath` (신규 · 순수 · 테스트 대상)
AppKit 비의존 순수 함수 모음. 앱의 순수헬퍼 관례(ParaLens·LibrarySorting) 그대로 XCTest.

```
static func fit(imageSize: CGSize, in viewSize: CGSize) -> CGFloat        // 축소만, 1.0 상한, 0/음수 방어→1
static func clamp(_ m: CGFloat, min: CGFloat, max: CGFloat) -> CGFloat
static func stepIn(_ m: CGFloat, factor: CGFloat, max: CGFloat) -> CGFloat  // ×factor 후 clamp
static func stepOut(_ m: CGFloat, factor: CGFloat, min: CGFloat) -> CGFloat // ÷factor 후 clamp
static func percentLabel(_ m: CGFloat) -> String                           // "42%" (반올림)
static func shouldZoom(hasPreciseDeltas: Bool, commandHeld: Bool) -> Bool  // 장치 판정
```

- 상수: `factor = 1.25`, `minMagnification = 0.1`, `maxMagnification = 16`(현행 유지).

### 7.2 `ImageReaderView` (개편 · NSViewRepresentable)
- 호출부 `ImageReaderView(url:)` 시그니처 불변(MainEditorView 무변경).
- `makeNSView`: 컨테이너 `NSView` 반환 → 상단 툴바 `NSStackView` + 커스텀 `ZoomableScrollView`.
- `Coordinator`: 로드/맞춤/줌 액션/회전/배율 라벨 갱신 담당. `ImageZoomMath` 사용.
- 커스텀 `ZoomableScrollView: NSScrollView`: `scrollWheel`(장치별 줌/팬)·`mouseDown/Dragged/Up`(드래그 팬)·커서·`performKeyEquivalent`(단축키). 배율 변경 시 coordinator 콜백으로 라벨 갱신.
- 로드 실패 플레이스홀더·GIF `animates`·더블클릭 토글은 현행 유지.

## 8. 에러 / 엣지 케이스
- 이미지 로드 실패 → 기존 플레이스홀더(경고 아이콘), 줌·팬·회전 무해(이미지 nil 가드).
- 0/음수 크기 방어(`fit`가 1 반환).
- 배율은 항상 `[minMagnification, maxMagnification]`로 clamp.
- 작은 이미지(뷰보다 작음): 맞춤=100%, 팬은 스크롤 여지 없을 때 무동작.
- 탭 재사용(url 변경): `updateNSView`가 재로드 + 회전 초기화 + 맞춤.

## 9. 테스트 전략
- **단위(XCTest)**: `ImageZoomMathTests` — `fit`(가로/세로 제약·1.0 상한·0 방어), `clamp`, `stepIn/stepOut`(경계 클램프), `percentLabel`(반올림), `shouldZoom`(4조합 진리표). 앱 순수헬퍼 관례와 동일.
- **수동 스모크**: 실이미지로 휠 줌(마우스)·핀치 줌(트랙패드)·클릭-드래그 팬·⌘±/0/1·⌘화살표 팬·회전·배율 라벨/100% 리셋·맞춤. NSView 상호작용은 단위 테스트 원리상 불가 → 수동.
- Phase 게이트: 변경 전후 `swift test`(로컬은 CLT 제약으로 Swift Testing만; 전체 수치는 CI). 신규 순수헬퍼 테스트는 로컬 실행 가능.

## 10. 범위 밖
탭별 줌/위치 영속, 배율 프리셋 드롭다운, 회전 디스크 저장, 이미지 편집. 원본 이미지 불변 — 읽기 전용.
