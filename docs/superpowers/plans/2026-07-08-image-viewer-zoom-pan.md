# 이미지 뷰어 줌·팬 개선 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 이미지 뷰어에 휠 줌(장치 판정)·클릭-드래그 핸드툴 팬·상단 툴바(줌/맞춤/실제크기/회전)·키보드 단축키(⌘±/0/1·⌘화살표)를 더해 마우스·트랙패드 양쪽에서 줌·이동을 쉽게 만든다.

**Architecture:** 줌 수학은 AppKit 비의존 순수 헬퍼 `ImageZoomMath`로 분리(단위 테스트). `ImageReaderView`(NSViewRepresentable)는 컨테이너 `NSView`에 상단 툴바 `NSStackView` + 커스텀 스크롤/이미지 뷰를 얹는다. 포인터 이벤트(휠 줌·드래그 팬·커서)는 이벤트가 실제 도달하는 문서 뷰 `PannableImageView: NSImageView`가, 키보드 단축키는 `ZoomableScrollView: NSScrollView`의 `performKeyEquivalent`가 담당. PDF 뷰어(`PDFReaderView`)의 검증된 all-AppKit 패턴을 따라 SwiftUI/AppKit 상태 브리징을 피한다.

**Tech Stack:** Swift 5.9+ / SwiftUI + AppKit(NSViewRepresentable, NSScrollView magnification, NSImageView), 신규 패키지 의존성 0.

## Global Constraints

- 비샌드박스 유지 — 변경 없음(이 작업은 서브프로세스 무관).
- **원본 이미지 불변** — 회전은 표시 전용(디스크 미저장). 읽기/보기 전용.
- **신규 패키지 의존성 0** — AppKit·Foundation·CoreGraphics(시스템)만.
- 코드 주석·커밋 메시지는 **한국어**. '박다/박는다/박았다' 표현 금지.
- **호출부 시그니처 불변**: `ImageReaderView(url:)` 그대로(`MainEditorView.swift:27` 무변경).
- 줌 상수: `minMagnification = 0.1`, `maxMagnification = 16`(현행 유지), 버튼/키보드 스텝 `factor = 1.25`.
- **로컬 게이트 = `swift build` 성공 + 경고 0.** 로컬 환경은 CommandLineTools 전용이라 XCTest 실행 불가(`no such module 'XCTest'`) — XCTest **실행은 CI(풀 Xcode)** 에서. 그래도 테스트는 test-first로 작성한다(TDD 규율).
- 신규 기능은 별도 파일로 분리(업스트림 머지 용이) — CLAUDE.md 규칙.

## File Structure

- **Create `Sources/Models/ImageZoomMath.swift`** — 순수 줌 수학(fit/clamp/step/percentLabel/shouldZoom). AppKit 비의존. 유일한 단위 테스트 대상.
- **Create `Tests/CmdMDTests/ImageZoomMathTests.swift`** — `ImageZoomMath` XCTest.
- **Rewrite `Sources/Views/ImageReaderView.swift`** — `ImageReaderView`(개편) + `PannableImageView`(문서 뷰) + `ZoomableScrollView`(단축키). 툴바·회전·라벨 포함. AppKit UI라 단위 테스트 없음(수동 스모크).

---

## Task 1: `ImageZoomMath` 순수 줌 헬퍼

**Files:**
- Create: `Sources/Models/ImageZoomMath.swift`
- Test: `Tests/CmdMDTests/ImageZoomMathTests.swift`

**Interfaces:**
- Consumes: (없음)
- Produces:
  - `enum ImageZoomMath`
  - `static let factor: CGFloat` (1.25), `minMagnification: CGFloat` (0.1), `maxMagnification: CGFloat` (16)
  - `static func clamp(_ m: CGFloat, min: CGFloat = minMagnification, max: CGFloat = maxMagnification) -> CGFloat`
  - `static func fit(imageSize: CGSize, in viewSize: CGSize) -> CGFloat` (축소만, 1.0 상한, 0/음수→1)
  - `static func stepIn(_ m: CGFloat) -> CGFloat` (×factor 후 clamp)
  - `static func stepOut(_ m: CGFloat) -> CGFloat` (÷factor 후 clamp)
  - `static func percentLabel(_ m: CGFloat) -> String` ("42%")
  - `static func shouldZoom(hasPreciseDeltas: Bool, commandHeld: Bool) -> Bool`

- [ ] **Step 1: 실패하는 테스트 작성**

Create `Tests/CmdMDTests/ImageZoomMathTests.swift`:

```swift
import XCTest
@testable import CmdMD

final class ImageZoomMathTests: XCTestCase {
    func testFitConstrainedByWidth() {
        // 800x100 이미지를 400x400 뷰에 → 폭 제약 400/800 = 0.5
        let m = ImageZoomMath.fit(imageSize: CGSize(width: 800, height: 100),
                                  in: CGSize(width: 400, height: 400))
        XCTAssertEqual(m, 0.5, accuracy: 0.0001)
    }

    func testFitConstrainedByHeight() {
        let m = ImageZoomMath.fit(imageSize: CGSize(width: 100, height: 800),
                                  in: CGSize(width: 400, height: 400))
        XCTAssertEqual(m, 0.5, accuracy: 0.0001)
    }

    func testFitSmallImageCapsAtOne() {
        // 뷰보다 작은 이미지는 100% 유지(확대 안 함).
        let m = ImageZoomMath.fit(imageSize: CGSize(width: 50, height: 50),
                                  in: CGSize(width: 400, height: 400))
        XCTAssertEqual(m, 1.0, accuracy: 0.0001)
    }

    func testFitZeroSizeDefendsToOne() {
        XCTAssertEqual(ImageZoomMath.fit(imageSize: .zero,
                                         in: CGSize(width: 400, height: 400)), 1.0)
        XCTAssertEqual(ImageZoomMath.fit(imageSize: CGSize(width: 100, height: 100),
                                         in: .zero), 1.0)
    }

    func testClampBounds() {
        XCTAssertEqual(ImageZoomMath.clamp(0.01), ImageZoomMath.minMagnification, accuracy: 0.0001)
        XCTAssertEqual(ImageZoomMath.clamp(100), ImageZoomMath.maxMagnification, accuracy: 0.0001)
        XCTAssertEqual(ImageZoomMath.clamp(2), 2, accuracy: 0.0001)
    }

    func testStepInOut() {
        XCTAssertEqual(ImageZoomMath.stepIn(1.0), 1.25, accuracy: 0.0001)
        XCTAssertEqual(ImageZoomMath.stepOut(1.0), 0.8, accuracy: 0.0001)
    }

    func testStepClampsAtBounds() {
        XCTAssertEqual(ImageZoomMath.stepIn(ImageZoomMath.maxMagnification),
                       ImageZoomMath.maxMagnification, accuracy: 0.0001)
        XCTAssertEqual(ImageZoomMath.stepOut(ImageZoomMath.minMagnification),
                       ImageZoomMath.minMagnification, accuracy: 0.0001)
    }

    func testPercentLabel() {
        XCTAssertEqual(ImageZoomMath.percentLabel(1.0), "100%")
        XCTAssertEqual(ImageZoomMath.percentLabel(0.5), "50%")
        XCTAssertEqual(ImageZoomMath.percentLabel(1.5), "150%")
        XCTAssertEqual(ImageZoomMath.percentLabel(0.333), "33%")
    }

    func testShouldZoomTruthTable() {
        // 휠 마우스(저정밀) → 줌
        XCTAssertTrue(ImageZoomMath.shouldZoom(hasPreciseDeltas: false, commandHeld: false))
        XCTAssertTrue(ImageZoomMath.shouldZoom(hasPreciseDeltas: false, commandHeld: true))
        // 트랙패드(정밀) → 팬
        XCTAssertFalse(ImageZoomMath.shouldZoom(hasPreciseDeltas: true, commandHeld: false))
        // ⌘ 누르면 장치 무관 줌
        XCTAssertTrue(ImageZoomMath.shouldZoom(hasPreciseDeltas: true, commandHeld: true))
    }
}
```

- [ ] **Step 2: RED 확인**

로컬은 CLT 전용이라 XCTest 실행 불가(`swift test` → `no such module 'XCTest'`). RED은 논리적으로 성립(`ImageZoomMath` 미존재로 컴파일 실패). CI/Xcode에서 실제 실행. 여기서는 다음 단계로 진행.

- [ ] **Step 3: 최소 구현**

Create `Sources/Models/ImageZoomMath.swift`:

```swift
import CoreGraphics

/// 이미지 뷰어 줌 수학(AppKit 비의존·순수). 배율 클램프·맞춤 계산·스텝·라벨·스크롤 휠 장치 판정.
/// ImageReaderView가 사용하며, 여기 로직만 단위 테스트한다.
enum ImageZoomMath {
    static let factor: CGFloat = 1.25
    static let minMagnification: CGFloat = 0.1
    static let maxMagnification: CGFloat = 16

    /// 배율을 [min, max]로 제한.
    static func clamp(_ m: CGFloat,
                      min lo: CGFloat = minMagnification,
                      max hi: CGFloat = maxMagnification) -> CGFloat {
        Swift.min(Swift.max(m, lo), hi)
    }

    /// 창에 맞춤 배율 — 축소만(작은 이미지는 100% 유지). 0/음수 크기는 1로 방어.
    static func fit(imageSize: CGSize, in viewSize: CGSize) -> CGFloat {
        guard imageSize.width > 0, imageSize.height > 0,
              viewSize.width > 0, viewSize.height > 0 else { return 1 }
        return Swift.min(viewSize.width / imageSize.width,
                         viewSize.height / imageSize.height, 1.0)
    }

    /// 한 스텝 확대(×factor) 후 클램프.
    static func stepIn(_ m: CGFloat) -> CGFloat { clamp(m * factor) }

    /// 한 스텝 축소(÷factor) 후 클램프.
    static func stepOut(_ m: CGFloat) -> CGFloat { clamp(m / factor) }

    /// 배율을 정수 퍼센트 문자열로("100%"). 반올림.
    static func percentLabel(_ m: CGFloat) -> String {
        "\(Int((m * 100).rounded()))%"
    }

    /// 스크롤 휠 이벤트를 줌으로 볼지 판정.
    /// - ⌘가 눌려 있으면 장치 무관 항상 줌.
    /// - 아니면 저정밀 델타(휠 마우스)만 줌, 정밀 델타(트랙패드/Magic Mouse)는 팬.
    static func shouldZoom(hasPreciseDeltas: Bool, commandHeld: Bool) -> Bool {
        commandHeld || !hasPreciseDeltas
    }
}
```

- [ ] **Step 4: 빌드로 컴파일 확인(로컬 게이트)**

Run: `swift build`
Expected: `Build complete!` (경고 0). CI에서 `ImageZoomMathTests` 전부 통과.

- [ ] **Step 5: 커밋**

```bash
git add Sources/Models/ImageZoomMath.swift Tests/CmdMDTests/ImageZoomMathTests.swift
git commit -m "기능(이미지): 줌 수학 순수 헬퍼 ImageZoomMath + 단위 테스트

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: `ImageReaderView` 개편(툴바·휠 줌·드래그 팬·단축키·회전)

**Files:**
- Rewrite: `Sources/Views/ImageReaderView.swift` (전체 교체)

**Interfaces:**
- Consumes (Task 1):
  - `ImageZoomMath.{minMagnification, maxMagnification, clamp, fit, stepIn, stepOut, percentLabel, shouldZoom}`
- Produces:
  - `struct ImageReaderView: NSViewRepresentable` — `init(url:)` 불변, `makeNSView`가 컨테이너 `NSView` 반환.
  - `final class PannableImageView: NSImageView` — `weak var coordinator`, 휠 줌·드래그 팬·커서.
  - `final class ZoomableScrollView: NSScrollView` — `weak var coordinator`, `performKeyEquivalent`.
  - Coordinator 공개 메서드(커스텀 뷰가 호출): `zoomIn()`, `zoomOut()`, `fitPressed()`, `actualSize()`, `fitToWindow()`, `toggleZoom(at:)`, `panByKey(dx:dy:)`, `updatePercentLabel()`, `setMagnification(_:centered:)`.

- [ ] **Step 1: 전체 파일 재작성**

Replace the entire contents of `Sources/Views/ImageReaderView.swift` with:

```swift
import SwiftUI
import AppKit

/// 단독 이미지 보기.
/// - 상단 툴바: 축소 · 배율% · 확대 | 맞춤 · 실제 크기 | 왼쪽·오른쪽 회전.
/// - PannableImageView(문서 뷰): 마우스 휠 줌(장치 판정)·클릭-드래그 팬(핸드툴)·손모양 커서·더블클릭 토글.
/// - ZoomableScrollView: ⌘=/⌘+ 확대·⌘- 축소·⌘0 맞춤·⌘1 실제크기·⌘화살표 이동(performKeyEquivalent).
/// - NSImageView(animates)로 GIF 재생. 로드 실패 시 플레이스홀더(크래시 금지).
/// - 회전은 표시 전용(원본 파일 불변). 줌 수학은 순수 헬퍼 ImageZoomMath.
struct ImageReaderView: NSViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        context.coordinator.build(in: container)
        context.coordinator.load(url: url)
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // 탭 재사용으로 url이 바뀌면 재로딩(회전 초기화 포함).
        if context.coordinator.currentURL != url {
            context.coordinator.load(url: url)
        }
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject {
        weak var scrollView: ZoomableScrollView?
        weak var imageView: NSImageView?
        weak var percentLabel: NSTextField?
        var currentURL: URL?

        private var originalImage: NSImage?
        private var rotationDegrees: Int = 0
        private var fitMagnification: CGFloat = 1

        // MARK: 뷰 구성

        func build(in container: NSView) {
            let scrollView = ZoomableScrollView()
            scrollView.allowsMagnification = true
            scrollView.minMagnification = ImageZoomMath.minMagnification
            scrollView.maxMagnification = ImageZoomMath.maxMagnification
            scrollView.hasVerticalScroller = true
            scrollView.hasHorizontalScroller = true
            scrollView.borderType = .noBorder
            scrollView.backgroundColor = .textBackgroundColor
            scrollView.translatesAutoresizingMaskIntoConstraints = false
            scrollView.coordinator = self

            let imageView = PannableImageView()
            imageView.imageScaling = .scaleNone
            imageView.animates = true
            imageView.coordinator = self
            scrollView.documentView = imageView

            self.scrollView = scrollView
            self.imageView = imageView

            // 핀치 줌 종료 시 배율 라벨 갱신.
            NotificationCenter.default.addObserver(
                self, selector: #selector(magnificationDidChange),
                name: NSScrollView.didEndLiveMagnifyNotification, object: scrollView)

            let toolbar = makeToolbar()

            container.addSubview(toolbar)
            container.addSubview(scrollView)
            NSLayoutConstraint.activate([
                toolbar.topAnchor.constraint(equalTo: container.topAnchor),
                toolbar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                toolbar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                scrollView.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
                scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
                scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            ])
        }

        private func makeToolbar() -> NSView {
            let zoomOutButton = toolbarButton("minus.magnifyingglass", "축소", #selector(zoomOut))

            let label = NSTextField(labelWithString: "100%")
            label.alignment = .center
            label.textColor = .secondaryLabelColor
            label.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
            label.toolTip = "클릭하면 100%"
            label.translatesAutoresizingMaskIntoConstraints = false
            label.setContentHuggingPriority(.required, for: .horizontal)
            label.widthAnchor.constraint(greaterThanOrEqualToConstant: 46).isActive = true
            let labelClick = NSClickGestureRecognizer(target: self, action: #selector(actualSize))
            label.addGestureRecognizer(labelClick)
            self.percentLabel = label

            let zoomInButton = toolbarButton("plus.magnifyingglass", "확대", #selector(zoomIn))
            let fitButton = toolbarButton("arrow.up.left.and.arrow.down.right", "맞춤", #selector(fitPressed))
            let actualButton = toolbarButton("1.magnifyingglass", "실제 크기", #selector(actualSize))
            let rotateLeftButton = toolbarButton("rotate.left", "왼쪽으로 회전", #selector(rotateLeft))
            let rotateRightButton = toolbarButton("rotate.right", "오른쪽으로 회전", #selector(rotateRight))

            let spacer = NSView()
            spacer.translatesAutoresizingMaskIntoConstraints = false
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

            let bar = NSStackView(views: [
                zoomOutButton, label, zoomInButton,
                separator(), fitButton, actualButton,
                separator(), rotateLeftButton, rotateRightButton,
                spacer,
            ])
            bar.orientation = .horizontal
            bar.alignment = .centerY
            bar.spacing = 6
            bar.edgeInsets = NSEdgeInsets(top: 6, left: 8, bottom: 6, right: 8)
            bar.translatesAutoresizingMaskIntoConstraints = false
            bar.setContentHuggingPriority(.required, for: .vertical)
            return bar
        }

        private func toolbarButton(_ symbol: String, _ tip: String, _ action: Selector) -> NSButton {
            let image = NSImage(systemSymbolName: symbol, accessibilityDescription: tip) ?? NSImage()
            let button = NSButton(image: image, target: self, action: action)
            button.bezelStyle = .texturedRounded
            button.toolTip = tip
            button.translatesAutoresizingMaskIntoConstraints = false
            button.setContentHuggingPriority(.required, for: .horizontal)
            return button
        }

        private func separator() -> NSView {
            let box = NSBox()
            box.boxType = .separator
            box.translatesAutoresizingMaskIntoConstraints = false
            box.heightAnchor.constraint(equalToConstant: 18).isActive = true
            return box
        }

        // MARK: 로드 / 표시

        func load(url: URL) {
            currentURL = url
            rotationDegrees = 0
            guard let imageView else { return }
            guard let image = NSImage(contentsOf: url) else {
                originalImage = nil
                showPlaceholder()
                return
            }
            originalImage = image
            applyDisplayImage()
            // 레이아웃이 잡힌 뒤 맞춤 배율 계산.
            DispatchQueue.main.async { [weak self] in self?.fitToWindow() }
        }

        private func applyDisplayImage() {
            guard let imageView, let original = originalImage else { return }
            let displayed = rotationDegrees == 0
                ? original
                : Coordinator.rotated(original, degrees: rotationDegrees)
            imageView.imageScaling = .scaleNone
            imageView.image = displayed
            imageView.frame = NSRect(origin: .zero, size: displayed.size)
        }

        private func showPlaceholder() {
            guard let imageView else { return }
            imageView.imageScaling = .scaleProportionallyDown
            imageView.image = NSImage(systemSymbolName: "exclamationmark.triangle",
                                      accessibilityDescription: "이미지를 열 수 없음")
            imageView.frame = NSRect(x: 0, y: 0, width: 240, height: 240)
            percentLabel?.stringValue = "—"
        }

        // MARK: 줌 액션(툴바·키보드 공용)

        private var currentMagnification: CGFloat { scrollView?.magnification ?? 1 }

        @objc func zoomIn() { setMagnification(ImageZoomMath.stepIn(currentMagnification), centered: nil) }
        @objc func zoomOut() { setMagnification(ImageZoomMath.stepOut(currentMagnification), centered: nil) }
        @objc func fitPressed() { fitToWindow() }
        @objc func actualSize() { setMagnification(1.0, centered: nil) }

        /// centered=nil이면 현재 보이는 영역의 중심 기준으로 확대(문서 뷰 좌표).
        func setMagnification(_ magnification: CGFloat, centered point: NSPoint?) {
            guard let scrollView else { return }
            let clamped = ImageZoomMath.clamp(magnification)
            let center: NSPoint
            if let point {
                center = point
            } else {
                let visible = scrollView.documentVisibleRect
                center = NSPoint(x: visible.midX, y: visible.midY)
            }
            scrollView.setMagnification(clamped, centeredAt: center)
            updatePercentLabel()
        }

        func fitToWindow() {
            guard let scrollView, let image = imageView?.image else { return }
            let viewSize = scrollView.contentView.bounds.size
            let scale = ImageZoomMath.fit(imageSize: image.size, in: viewSize)
            fitMagnification = scale
            scrollView.magnification = scale
            updatePercentLabel()
        }

        /// 더블클릭 토글: 실제크기(100%) ↔ 맞춤.
        func toggleZoom(at point: NSPoint) {
            guard let scrollView else { return }
            if abs(scrollView.magnification - 1.0) < 0.001 {
                scrollView.setMagnification(fitMagnification, centeredAt: point)
            } else {
                scrollView.setMagnification(1.0, centeredAt: point)
            }
            updatePercentLabel()
        }

        func updatePercentLabel() {
            guard let scrollView else { return }
            percentLabel?.stringValue = ImageZoomMath.percentLabel(scrollView.magnification)
        }

        @objc private func magnificationDidChange() { updatePercentLabel() }

        // MARK: ⌘화살표 이동(팬)

        /// dx/dy ∈ {-1,0,+1}. 클립뷰(보이는 영역)를 짧은 변의 20%씩 스크롤.
        func panByKey(dx: Int, dy: Int) {
            guard let scrollView else { return }
            let clip = scrollView.contentView
            let step = min(clip.bounds.width, clip.bounds.height) * 0.2
            var origin = clip.bounds.origin
            origin.x += CGFloat(dx) * step
            origin.y += CGFloat(dy) * step
            clip.scroll(to: origin)
            scrollView.reflectScrolledClipView(clip)
        }

        // MARK: 회전(표시 전용·원본 불변)

        @objc func rotateLeft() { rotate(by: 270) }
        @objc func rotateRight() { rotate(by: 90) }

        private func rotate(by delta: Int) {
            guard originalImage != nil else { return }
            rotationDegrees = (rotationDegrees + delta) % 360
            applyDisplayImage()
            fitToWindow()   // 폭·높이 교환 → 맞춤 재계산.
        }

        /// 원본을 degrees(0/90/180/270)만큼 회전한 새 NSImage(원본 불변). 90/270은 폭·높이 교환.
        static func rotated(_ image: NSImage, degrees: Int) -> NSImage {
            let size = image.size
            let swapped = (degrees % 180 != 0)
            let newSize = swapped ? NSSize(width: size.height, height: size.width) : size
            let result = NSImage(size: newSize)
            result.lockFocus()
            let transform = NSAffineTransform()
            transform.translateX(by: newSize.width / 2, yBy: newSize.height / 2)
            transform.rotate(byDegrees: CGFloat(degrees))
            transform.translateX(by: -size.width / 2, yBy: -size.height / 2)
            transform.concat()
            image.draw(at: .zero, from: NSRect(origin: .zero, size: size),
                       operation: .copy, fraction: 1.0)
            result.unlockFocus()
            return result
        }

        deinit { NotificationCenter.default.removeObserver(self) }
    }
}

// MARK: - PannableImageView (문서 뷰: 휠 줌·드래그 팬·손모양 커서)

/// 스크롤뷰의 문서 뷰. 포인터 이벤트가 실제로 도달하는 곳이라 휠 줌·드래그 팬·커서를 여기서 처리.
final class PannableImageView: NSImageView {
    weak var coordinator: ImageReaderView.Coordinator?
    private var isPanning = false
    private var lastDragPoint = NSPoint.zero

    override func scrollWheel(with event: NSEvent) {
        let commandHeld = event.modifierFlags.contains(.command)
        guard ImageZoomMath.shouldZoom(hasPreciseDeltas: event.hasPreciseScrollingDeltas,
                                       commandHeld: commandHeld),
              let scrollView = enclosingScrollView else {
            super.scrollWheel(with: event)   // 트랙패드 두손가락 = 팬(스크롤뷰로 버블)
            return
        }
        let delta = event.scrollingDeltaY
        guard delta != 0 else { return }
        // 위로 스크롤(delta>0) = 확대.
        let factor: CGFloat = delta > 0 ? 1.1 : (1.0 / 1.1)
        let target = ImageZoomMath.clamp(scrollView.magnification * factor)
        let point = convert(event.locationInWindow, from: nil)   // 문서 뷰 좌표(커서 위치)
        scrollView.setMagnification(target, centeredAt: point)
        coordinator?.updatePercentLabel()
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            coordinator?.toggleZoom(at: convert(event.locationInWindow, from: nil))
            return
        }
        isPanning = true
        lastDragPoint = event.locationInWindow
        NSCursor.closedHand.set()
    }

    override func mouseDragged(with event: NSEvent) {
        guard isPanning, let scrollView = enclosingScrollView else { return }
        let now = event.locationInWindow
        let dx = now.x - lastDragPoint.x
        let dy = now.y - lastDragPoint.y
        lastDragPoint = now
        // 그랩 팬: 콘텐츠가 커서를 따라오도록 origin을 반대로 이동(배율 보정).
        let clip = scrollView.contentView
        var origin = clip.bounds.origin
        origin.x -= dx / scrollView.magnification
        origin.y -= dy / scrollView.magnification
        clip.scroll(to: origin)
        scrollView.reflectScrolledClipView(clip)
    }

    override func mouseUp(with event: NSEvent) {
        isPanning = false
        NSCursor.openHand.set()
        window?.invalidateCursorRects(for: self)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .openHand)
    }
}

// MARK: - ZoomableScrollView (⌘ 단축키)

/// 이미지 탭이 키 윈도우에 있을 때 ⌘ 줌/이동 단축키를 responder chain에서 처리.
/// 이미지 탭이 없으면 super로 위임해 다른 화면과 충돌하지 않는다.
final class ZoomableScrollView: NSScrollView {
    weak var coordinator: ImageReaderView.Coordinator?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command), let coordinator else {
            return super.performKeyEquivalent(with: event)
        }
        // ⌘+화살표: 이미지 이동(팬). 화살표는 keyCode로 판정(IME 무관).
        switch event.keyCode {
        case 123: coordinator.panByKey(dx: -1, dy: 0); return true   // ←
        case 124: coordinator.panByKey(dx: +1, dy: 0); return true   // →
        case 125: coordinator.panByKey(dx: 0, dy: -1); return true   // ↓
        case 126: coordinator.panByKey(dx: 0, dy: +1); return true   // ↑
        default: break
        }
        // ⌘ 줌 키(숫자·기호라 IME 영향 없음).
        switch event.charactersIgnoringModifiers {
        case "=", "+": coordinator.zoomIn(); return true
        case "-", "_": coordinator.zoomOut(); return true
        case "0": coordinator.fitPressed(); return true
        case "1": coordinator.actualSize(); return true
        default: return super.performKeyEquivalent(with: event)
        }
    }
}
```

- [ ] **Step 2: 빌드 확인(로컬 게이트)**

Run: `swift build`
Expected: `Build complete!` (경고 0). 컴파일 에러·경고가 있으면 수정 후 재빌드.

- [ ] **Step 3: 커밋**

```bash
git add Sources/Views/ImageReaderView.swift
git commit -m "기능(이미지): 뷰어 줌·팬 개편 — 툴바·휠 줌(장치 판정)·클릭드래그 팬·⌘±/0/1·⌘화살표·회전

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

- [ ] **Step 4: 수동 스모크(실앱, 사용자 또는 실기 자동화)**

설치본 재빌드·교체 후 실이미지(가로/세로 큰 이미지·작은 이미지·GIF) 로 확인. NSView 상호작용이라 단위 테스트 원리상 불가.

  - [ ] 툴바 표시: `− 100% + | 맞춤 실제크기 | ↺ ↻`, 로드 시 맞춤 배율로 라벨 표시.
  - [ ] **마우스 휠 = 커서 위치 기준 줌**(확대/축소, 방향 자연스러움). 반대로 느껴지면 `PannableImageView.scrollWheel`의 `delta > 0` 부호 교환.
  - [ ] **트랙패드 두손가락 드래그 = 팬**, 핀치 = 줌(라벨 갱신).
  - [ ] **클릭-드래그 = 핸드툴 팬**(줌인 상태에서 이동), 커서 open/closedHand 전환.
  - [ ] 더블클릭 = 맞춤 ↔ 실제크기 토글.
  - [ ] 툴바 버튼: −/+ 스텝 줌, 맞춤, 실제 크기, 배율 라벨 클릭 = 100%.
  - [ ] 회전 ↺/↻ = 90° 표시 회전 + 맞춤 재계산(원본 파일 불변 — 디스크 미변경 확인). 방향 반대면 `rotateLeft/Right` 각도 교환.
  - [ ] 키보드: `⌘=`·`⌘+` 확대, `⌘-` 축소, `⌘0` 맞춤, `⌘1` 실제크기.
  - [ ] `⌘←/→/↑/↓` = 이미지 이동(줌인 상태에서). 주의: 이미지 리더가 열려 있으면 ⌘↑가 이 이동을 하고 라이브러리 "상위 폴더"(⌘↑)는 리더에서 동작 안 함 — 의도된 동작(문서화).
  - [ ] 로드 실패 이미지 = 경고 아이콘 플레이스홀더(크래시 없음), 라벨 "—".
  - [ ] 탭 전환 후 다른 이미지 = 재로드·회전 초기화·맞춤.

---

## Self-Review

**1. Spec coverage:**
- §3 조작 모델(휠 줌·핀치·⌘스크롤·더블클릭) → Task 2 `PannableImageView.scrollWheel` + `toggleZoom`. ✅
- §3.1 장치 판정 → `ImageZoomMath.shouldZoom` (Task 1, 테스트 포함). ✅
- §3.2 클릭-드래그 팬 + 커서 → `PannableImageView.mouseDown/Dragged/Up` + `resetCursorRects`. ✅
- §4 툴바(−/%/+/맞춤/실제크기/회전·라벨 클릭 100%) → `makeToolbar`. ✅
- §5 회전 표시 전용 → `rotate`/`rotated`, 원본 불변. ✅
- §6 키보드(⌘=/+/-/0/1·⌘화살표) → `ZoomableScrollView.performKeyEquivalent`. ✅
- §7 컴포넌트(ImageZoomMath / ImageReaderView / 커스텀 뷰). ✅
- §8 엣지(로드 실패·0크기·clamp·작은 이미지·탭 재사용) → showPlaceholder·fit 방어·clamp·load. ✅
- §9 테스트(ImageZoomMathTests 순수·수동 스모크). ✅

**2. Placeholder scan:** TBD/TODO 없음. 모든 코드 단계에 완전한 코드 포함. ✅

**3. Type consistency:** Task 1이 정의한 `ImageZoomMath.{clamp, fit, stepIn, stepOut, percentLabel, shouldZoom, minMagnification, maxMagnification}`를 Task 2가 동일 시그니처로 사용. Coordinator 공개 메서드명(zoomIn/zoomOut/fitPressed/actualSize/fitToWindow/toggleZoom/panByKey/updatePercentLabel/setMagnification)이 커스텀 뷰 호출부와 일치. ✅

**참고(수동 검증 항목):** 휠 줌 방향(delta 부호)·회전 방향·⌘화살표 이동 방향은 런타임 시각 확인 항목으로 스모크 체크리스트에 명시. Magic Mouse는 정밀 스크롤이라 스와이프=팬(줌은 ⌘+스크롤·버튼·키보드)로 문서화됨(§3.1 트레이드오프).
