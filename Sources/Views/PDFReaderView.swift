import SwiftUI
import AppKit
import PDFKit

/// 단독 PDF 보기. NSSplitView에 썸네일(좌)·검색필드+PDFView(우)를 엮는다.
/// PDFView가 페이지 이동·줌·맞춤·텍스트 선택/복사·회전을 제공하고,
/// PDFThumbnailView가 페이지 썸네일·클릭 이동을, NSSearchField가 문서 내 검색을 담당.
/// 로드 실패 시 플레이스홀더(크래시 금지).
///
/// 탭 전환으로 같은 인스턴스가 재사용되므로, 로드 로직은 Coordinator.load(url:)로 빼서
/// makeNSView가 항상 안정적인 container 하나를 반환하도록 한다(실패해도 같은 container를 유지하고,
/// 이후 유효 URL로 바뀌면 재로딩이 정상 동작).
struct PDFReaderView: NSViewRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        context.coordinator.container = container
        context.coordinator.load(url: url)
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // 탭 재사용으로 url이 바뀌면 재로딩(성공·실패 모두 load가 currentURL을 갱신해 재시도 폭주 방지).
        guard context.coordinator.currentURL != url else { return }
        context.coordinator.load(url: url)
    }

    final class Coordinator: NSObject {
        weak var container: NSView?
        weak var pdfView: PDFView?
        weak var searchField: NSSearchField?
        var currentURL: URL?
        var matches: [PDFSelection] = []
        var matchIndex: Int = 0
        var lastQuery: String = ""
        var didSetDividerPosition = false

        /// url로 문서를 로드해 container의 뷰 트리를 구성한다. 재호출 가능(탭 전환·재시도).
        /// 실패해도 container 자체는 유지하고 플레이스홀더만 넣으므로, 이후 유효 URL 전환이 정상 복구된다.
        func load(url: URL) {
            guard let container else { return }

            // 1) currentURL을 무조건 먼저 갱신(실패해도 같은 나쁜 URL을 매번 재로딩하지 않게).
            currentURL = url

            // 2) 기존 뷰·검색 상태 초기화.
            container.subviews.forEach { $0.removeFromSuperview() }
            pdfView = nil
            searchField = nil
            matches = []
            matchIndex = 0
            lastQuery = ""

            // 3) 로드 실패 시 플레이스홀더 라벨만 붙이고 종료.
            guard let document = PDFDocument(url: url) else {
                let label = NSTextField(labelWithString: "PDF를 열 수 없습니다")
                label.alignment = .center
                label.textColor = .secondaryLabelColor
                label.translatesAutoresizingMaskIntoConstraints = false
                container.addSubview(label)
                NSLayoutConstraint.activate([
                    label.centerXAnchor.constraint(equalTo: container.centerXAnchor),
                    label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
                ])
                return
            }

            // 4) 성공: PDFView + 썸네일(좌) + 검색/PDFView(우) 구성.
            let pdfView = PDFView()
            pdfView.autoScales = true
            pdfView.displayMode = .singlePageContinuous
            pdfView.translatesAutoresizingMaskIntoConstraints = false
            pdfView.document = document
            self.pdfView = pdfView

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
            search.target = self
            search.action = #selector(searchChanged(_:))
            self.searchField = search
            // 검색이 가로폭을 차지하도록(버튼은 고정).
            search.setContentHuggingPriority(.defaultLow, for: .horizontal)

            // 회전 버튼 2개(검색 우측).
            let rotateLeftButton = NSButton(
                image: NSImage(systemSymbolName: "rotate.left", accessibilityDescription: "왼쪽으로 회전") ?? NSImage(),
                target: self,
                action: #selector(rotateLeft(_:))
            )
            rotateLeftButton.bezelStyle = .texturedRounded
            rotateLeftButton.translatesAutoresizingMaskIntoConstraints = false
            rotateLeftButton.setContentHuggingPriority(.required, for: .horizontal)

            let rotateRightButton = NSButton(
                image: NSImage(systemSymbolName: "rotate.right", accessibilityDescription: "오른쪽으로 회전") ?? NSImage(),
                target: self,
                action: #selector(rotateRight(_:))
            )
            rotateRightButton.bezelStyle = .texturedRounded
            rotateRightButton.translatesAutoresizingMaskIntoConstraints = false
            rotateRightButton.setContentHuggingPriority(.required, for: .horizontal)

            // 상단 가로바: 검색 + 회전 버튼.
            let topBar = NSStackView(views: [search, rotateLeftButton, rotateRightButton])
            topBar.orientation = .horizontal
            topBar.spacing = 6
            topBar.translatesAutoresizingMaskIntoConstraints = false

            // 우측: 상단 가로바 + PDFView 세로 스택.
            let rightStack = NSStackView(views: [topBar, pdfView])
            rightStack.orientation = .vertical
            rightStack.spacing = 0
            rightStack.edgeInsets = NSEdgeInsets(top: 6, left: 6, bottom: 0, right: 0)
            rightStack.translatesAutoresizingMaskIntoConstraints = false
            rightStack.setHuggingPriority(.defaultLow, for: .vertical)
            topBar.setContentHuggingPriority(.required, for: .vertical)

            // 분할: 썸네일 | 우측.
            let split = NSSplitView()
            split.isVertical = true
            split.dividerStyle = .thin
            split.translatesAutoresizingMaskIntoConstraints = false
            split.addArrangedSubview(thumbScroll)
            split.addArrangedSubview(rightStack)

            container.addSubview(split)
            NSLayoutConstraint.activate([
                split.topAnchor.constraint(equalTo: container.topAnchor),
                split.bottomAnchor.constraint(equalTo: container.bottomAnchor),
                split.leadingAnchor.constraint(equalTo: container.leadingAnchor),
                split.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            ])
            // 썸네일 패널 초기 폭(최초 1회만; 사용자가 드래그한 폭을 탭 전환 때 유지).
            if !didSetDividerPosition {
                didSetDividerPosition = true
                DispatchQueue.main.async {
                    split.setPosition(160, ofDividerAt: 0)
                }
            }
        }

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

        /// 현재 페이지를 왼쪽/오른쪽으로 90도 회전.
        /// PDFView의 rotatePageLeft/Right 공개 API는 버전 의존이 있어, PDFPage.rotation을 직접 조정한다.
        @objc func rotateLeft(_ sender: Any?) { rotate(by: -90) }
        @objc func rotateRight(_ sender: Any?) { rotate(by: 90) }
        private func rotate(by degrees: Int) {
            guard let pdfView, let page = pdfView.currentPage else { return }
            page.rotation += degrees           // PDFPage.rotation은 90단위, 음수/360+ 허용
            pdfView.layoutDocumentView()
        }
    }
}
