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
            guard imageView != nil else { return }
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
            // 문서 경계 밖으로 나가지 않도록 클램프(AppKit 표준 방식).
            let constrained = clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin
            clip.scroll(to: constrained)
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
        // 문서 경계 밖으로 나가지 않도록 클램프(AppKit 표준 방식).
        let constrained = clip.constrainBoundsRect(NSRect(origin: origin, size: clip.bounds.size)).origin
        clip.scroll(to: constrained)
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

/// 이미지 탭이 마운트돼 있고, 텍스트 입력·자체 편집 뷰(사이드바 검색·WKWebView·PDFView 등)가
/// 포커스가 아닐 때만 ⌘ 줌/이동 단축키를 처리한다(`AppState.responderYieldsFileKeys`로 판정).
/// performKeyEquivalent는 창 전체 뷰 계층으로 전달되므로 first-responder 확인 없이는 다른 화면의
/// 단축키를 가로챌 수 있어, 양보 대상이거나 처리하지 않는 키는 super로 위임한다.
final class ZoomableScrollView: NSScrollView {
    weak var coordinator: ImageReaderView.Coordinator?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command), let coordinator else {
            return super.performKeyEquivalent(with: event)
        }
        // 텍스트 입력·자체 편집 뷰(사이드바 검색·미리보기 등)가 포커스면 표준 단축키를 양보한다.
        // performKeyEquivalent는 창 전체 뷰 계층으로 전달되므로 first-responder를 확인하지 않으면
        // 이미지 탭이 활성이기만 해도 다른 텍스트필드의 ⌘←/→ 등을 가로챈다.
        if AppState.responderYieldsFileKeys(window?.firstResponder) {
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
