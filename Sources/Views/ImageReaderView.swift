import SwiftUI
import AppKit

/// 단독 이미지 보기. NSScrollView 매그니피케이션으로 줌/팬/맞춤,
/// NSImageView(animates)로 GIF 재생. 로드 실패 시 플레이스홀더(크래시 금지).
struct ImageReaderView: NSViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.allowsMagnification = true
        scrollView.minMagnification = 0.1
        scrollView.maxMagnification = 16
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.borderType = .noBorder
        scrollView.backgroundColor = .textBackgroundColor

        let imageView = NSImageView()
        imageView.imageScaling = .scaleNone
        imageView.animates = true
        scrollView.documentView = imageView

        context.coordinator.scrollView = scrollView
        context.coordinator.imageView = imageView

        let dbl = NSClickGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleDoubleClick(_:))
        )
        dbl.numberOfClicksRequired = 2
        scrollView.contentView.addGestureRecognizer(dbl)

        context.coordinator.load(url: url)
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        if context.coordinator.currentURL != url {
            context.coordinator.load(url: url)
        }
    }

    final class Coordinator: NSObject {
        weak var scrollView: NSScrollView?
        weak var imageView: NSImageView?
        var currentURL: URL?
        private var fitMagnification: CGFloat = 1

        func load(url: URL) {
            currentURL = url
            guard let imageView else { return }
            guard let image = NSImage(contentsOf: url) else {
                showPlaceholder()
                return
            }
            imageView.imageScaling = .scaleNone
            imageView.image = image
            imageView.frame = NSRect(origin: .zero, size: image.size)
            // 레이아웃이 잡힌 뒤 맞춤 배율 계산.
            DispatchQueue.main.async { [weak self] in self?.fitToWindow() }
        }

        func fitToWindow() {
            guard let scrollView, let image = imageView?.image else { return }
            let viewSize = scrollView.contentView.bounds.size
            let imgSize = image.size
            guard imgSize.width > 0, imgSize.height > 0,
                  viewSize.width > 0, viewSize.height > 0 else { return }
            // 축소만(작은 이미지는 100% 유지).
            let scale = min(viewSize.width / imgSize.width,
                            viewSize.height / imgSize.height, 1.0)
            fitMagnification = scale
            scrollView.magnification = scale
        }

        @objc func handleDoubleClick(_ g: NSClickGestureRecognizer) {
            guard let scrollView else { return }
            let point = g.location(in: scrollView.documentView)
            if abs(scrollView.magnification - 1.0) < 0.001 {
                scrollView.setMagnification(fitMagnification, centeredAt: point)
            } else {
                scrollView.setMagnification(1.0, centeredAt: point)
            }
        }

        private func showPlaceholder() {
            guard let imageView else { return }
            imageView.imageScaling = .scaleProportionallyDown
            imageView.image = NSImage(systemSymbolName: "exclamationmark.triangle",
                                      accessibilityDescription: "이미지를 열 수 없음")
            imageView.frame = NSRect(x: 0, y: 0, width: 240, height: 240)
        }
    }
}
