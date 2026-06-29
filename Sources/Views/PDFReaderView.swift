import SwiftUI
import AppKit
import PDFKit

/// 단독 PDF 보기. NSSplitView에 썸네일(좌)·검색필드+PDFView(우)를 엮는다.
/// PDFView가 페이지 이동·줌·맞춤·텍스트 선택/복사·회전을 제공하고,
/// PDFThumbnailView가 페이지 썸네일·클릭 이동을, NSSearchField가 문서 내 검색을 담당.
/// 로드 실패 시 플레이스홀더(크래시 금지).
struct PDFReaderView: NSViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let container = NSView()

        let pdfView = PDFView()
        pdfView.autoScales = true
        pdfView.displayMode = .singlePageContinuous
        pdfView.translatesAutoresizingMaskIntoConstraints = false
        context.coordinator.pdfView = pdfView

        // 문서 로드(실패 시 플레이스홀더).
        guard let document = PDFDocument(url: url) else {
            return Self.placeholderView()
        }
        pdfView.document = document
        context.coordinator.currentURL = url

        // 썸네일(좌).
        let thumbnailView = PDFThumbnailView()
        thumbnailView.pdfView = pdfView
        thumbnailView.thumbnailSize = NSSize(width: 100, height: 130)
        thumbnailView.translatesAutoresizingMaskIntoConstraints = false
        let thumbScroll = NSScrollView()
        thumbScroll.documentView = thumbnailView
        thumbScroll.hasVerticalScroller = true
        thumbScroll.translatesAutoresizingMaskIntoConstraints = false

        // 검색 필드(상).
        let search = NSSearchField()
        search.placeholderString = "이 문서에서 검색"
        search.translatesAutoresizingMaskIntoConstraints = false
        search.target = context.coordinator
        search.action = #selector(Coordinator.searchChanged(_:))
        context.coordinator.searchField = search

        // 우측: 검색 + PDFView 세로 스택.
        let rightStack = NSStackView(views: [search, pdfView])
        rightStack.orientation = .vertical
        rightStack.spacing = 0
        rightStack.edgeInsets = NSEdgeInsets(top: 6, left: 6, bottom: 0, right: 0)
        rightStack.translatesAutoresizingMaskIntoConstraints = false
        rightStack.setHuggingPriority(.defaultLow, for: .vertical)
        search.setContentHuggingPriority(.required, for: .vertical)

        // 분할: 썸네일 | 우측.
        let split = NSSplitView()
        split.isVertical = true
        split.dividerStyle = .thin
        split.translatesAutoresizingMaskIntoConstraints = false
        split.addArrangedSubview(thumbScroll)
        split.addArrangedSubview(rightStack)
        context.coordinator.split = split
        context.coordinator.thumbPane = thumbScroll

        container.addSubview(split)
        NSLayoutConstraint.activate([
            split.topAnchor.constraint(equalTo: container.topAnchor),
            split.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            split.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            split.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        // 썸네일 패널 초기 폭.
        DispatchQueue.main.async {
            split.setPosition(160, ofDividerAt: 0)
        }
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // 탭 재사용으로 url이 바뀌면 문서 재로딩 + 검색 초기화.
        guard context.coordinator.currentURL != url else { return }
        if let document = PDFDocument(url: url) {
            context.coordinator.pdfView?.document = document
            context.coordinator.currentURL = url
            context.coordinator.searchField?.stringValue = ""
            context.coordinator.matches = []
            context.coordinator.matchIndex = 0
            context.coordinator.lastQuery = ""
            context.coordinator.pdfView?.highlightedSelections = nil
        }
    }

    private static func placeholderView() -> NSView {
        let label = NSTextField(labelWithString: "PDF를 열 수 없습니다")
        label.alignment = .center
        label.textColor = .secondaryLabelColor
        let host = NSView()
        label.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: host.centerYAnchor),
        ])
        return host
    }

    final class Coordinator: NSObject {
        weak var pdfView: PDFView?
        weak var searchField: NSSearchField?
        weak var split: NSSplitView?
        weak var thumbPane: NSView?
        var currentURL: URL?
        var matches: [PDFSelection] = []
        var matchIndex: Int = 0
        var lastQuery: String = ""

        /// 검색어 변경 시: 일치 목록을 갱신하고 첫 일치로 이동.
        /// 같은 검색어로 Enter를 반복하면 다음 일치로 순회한다.
        @objc func searchChanged(_ sender: NSSearchField) {
            guard let pdfView, let document = pdfView.document else { return }
            let text = sender.stringValue
            guard !text.isEmpty else {
                matches = []
                matchIndex = 0
                lastQuery = ""
                pdfView.highlightedSelections = nil
                return
            }
            if text == lastQuery, !matches.isEmpty {
                matchIndex = (matchIndex + 1) % matches.count
            } else {
                lastQuery = text
                matches = document.findString(text, withOptions: [.caseInsensitive])
                matchIndex = 0
            }
            guard !matches.isEmpty else {
                pdfView.highlightedSelections = nil
                return
            }
            pdfView.highlightedSelections = matches
            let current = matches[matchIndex]
            pdfView.setCurrentSelection(current, animate: true)
            pdfView.scrollSelectionToVisible(nil)
        }
    }
}
