import SwiftUI
import WebKit

/// 파일 드래그를 삼키지 않고 상위(SwiftUI 호스팅 뷰)로 흘려보내는 WKWebView.
/// 프리뷰가 리더를 채울 때, 기본 WKWebView는 자기 자신을 파일 드래그 목적지로 등록해
/// 창 레벨 .onDrop(외부 파일=열기)이 아예 발화하지 않는다. 드래그 목적지 등록을 영구 해제한다.
/// ⚠️ WebKit은 navigation/load 시점마다 드래그 타입을 재등록하므로, 단순히 init에서 한 번
/// unregister만 하면 이후 다시 등록된다 → registerForDraggedTypes를 no-op으로 덮어 opt-out을 영속화.
/// 위키링크·스크롤 싱크 등 드래그와 무관한 기능은 전혀 건드리지 않는다.
final class DropThroughWebView: WKWebView {
    override init(frame: CGRect, configuration: WKWebViewConfiguration) {
        super.init(frame: frame, configuration: configuration)
        unregisterDraggedTypes()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func registerForDraggedTypes(_ newTypes: [NSPasteboard.PasteboardType]) {
        // no-op — WebKit의 재등록을 차단해 파일 드래그가 창 레벨로 통과하도록 둔다.
    }
}

struct MarkdownPreviewView: NSViewRepresentable {
    /// Identity of the previewed document; a change means a tab switch, which
    /// renders immediately and resets scroll (vs. debounced live typing updates).
    let documentID: UUID?
    let markdown: String
    let baseURL: URL?
    let options: MarkdownRenderOptions
    let scrollSyncEnabled: Bool

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.preferences.isTextInteractionEnabled = true
        // Bridge for preview→app messages (interactive task checkboxes).
        config.userContentController.add(context.coordinator, name: "cmdmd")

        let webView = DropThroughWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView
        context.coordinator.scrollSyncEnabled = scrollSyncEnabled

        let prepared = context.coordinator.prepareDataview(markdown, baseURL: baseURL)
        let html = context.coordinator.renderer.renderToHTML(markdown: prepared, baseURL: baseURL, options: options)
        context.coordinator.lastSource = markdown
        context.coordinator.lastOptions = options
        context.coordinator.lastBaseURL = baseURL
        context.coordinator.currentDocumentID = documentID
        webView.loadHTMLString(html, baseURL: baseURL)

        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.scrollSyncEnabled = scrollSyncEnabled

        // Tab switch: render the new document at once (no debounce) and start at
        // the top, rather than carrying the previous document's scroll offset.
        if context.coordinator.currentDocumentID != documentID {
            context.coordinator.currentDocumentID = documentID
            // 문서 전환 — 클릭-투-런 승인은 이전 문서에 한정하므로 리셋.
            context.coordinator.dataviewApproved = false
            context.coordinator.renderImmediately(markdown: markdown, baseURL: baseURL, options: options)
            return
        }

        guard context.coordinator.lastSource != markdown || context.coordinator.lastOptions != options else {
            return
        }
        // Debounced + scroll-preserving: rendering happens inside the debounce so
        // fast typing doesn't pay a full markdown→HTML pass per keystroke.
        context.coordinator.scheduleRender(markdown: markdown, baseURL: baseURL, options: options)
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        nsView.configuration.userContentController.removeScriptMessageHandler(forName: "cmdmd")
        coordinator.tearDown()
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        weak var webView: WKWebView?
        let renderer = MarkdownRenderer()
        var lastSource: String = ""
        var lastOptions: MarkdownRenderOptions?
        var lastBaseURL: URL?
        var scrollSyncEnabled: Bool = true
        var currentDocumentID: UUID?

        // MARK: dataviewjs (스펙 §5·§7)
        var dataviewBlocks: [DataviewBlock] = []
        var dataviewApproved = false          // 클릭-투-런 승인 — 문서 바뀌면 리셋
        var dataviewRunToken = 0              // 재렌더/탭 전환 시 증가 — 스테일 주입 가드
        // 현재 토큰의 완료 주입 버퍼(blockId→html). 엔진이 페이지 커밋보다 빨리 끝나면
        // evaluateJavaScript가 옛 문서에 버려지므로(주입-로드 레이스), didFinish에서 이 버퍼를
        // 재주입해 새 DOM에 반영한다. prepareDataview의 토큰 증가 시 클리어.
        var dataviewPendingInjections: [Int: String] = [:]

        private var pendingScrollY: Double = 0
        private var renderDebounce: DispatchWorkItem?
        private var observers: [NSObjectProtocol] = []

        override init() {
            super.init()
            let center = NotificationCenter.default
            observers.append(center.addObserver(
                forName: .scrollToHeading,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let slug = notification.object as? String else { return }
                self?.scrollToHeadingSlug(slug)
            })
            observers.append(center.addObserver(
                forName: .editorDidScroll,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let self, self.scrollSyncEnabled,
                      let fraction = notification.object as? Double else { return }
                self.scrollToFraction(fraction)
            })
        }

        deinit {
            tearDown()
        }

        func tearDown() {
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers = []
            renderDebounce?.cancel()
        }

        /// Debounces preview rebuilds and restores the prior scroll offset after
        /// the reload, so typing in split view doesn't jump the preview to the top.
        /// Immediate (non-debounced) render that resets scroll to the top — used
        /// when the document changes (tab switch) so the new note renders at once.
        func renderImmediately(markdown: String, baseURL: URL?, options: MarkdownRenderOptions) {
            renderDebounce?.cancel()
            guard let webView else { return }
            let prepared = prepareDataview(markdown, baseURL: baseURL)
            let html = renderer.renderToHTML(markdown: prepared, baseURL: baseURL, options: options)
            lastSource = markdown
            lastOptions = options
            lastBaseURL = baseURL
            pendingScrollY = 0
            webView.loadHTMLString(html, baseURL: baseURL)
        }

        func scheduleRender(markdown: String, baseURL: URL?, options: MarkdownRenderOptions) {
            renderDebounce?.cancel()
            // Capture the document this render belongs to. A DispatchWorkItem that
            // has already begun executing can't be cancelled, and its async
            // evaluateJavaScript completion can fire after a tab switch — so both
            // the work item and the completion re-check the id and bail if the
            // document changed, preventing the old note from clobbering the new one.
            let docID = currentDocumentID
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.currentDocumentID == docID, let webView = self.webView else { return }
                let prepared = self.prepareDataview(markdown, baseURL: baseURL)
                let html = self.renderer.renderToHTML(markdown: prepared, baseURL: baseURL, options: options)
                self.lastSource = markdown
                self.lastOptions = options
                self.lastBaseURL = baseURL
                webView.evaluateJavaScript("window.scrollY") { [weak self] value, _ in
                    guard let self, self.currentDocumentID == docID, let webView = self.webView else { return }
                    self.pendingScrollY = (value as? Double) ?? 0
                    webView.loadHTMLString(html, baseURL: baseURL)
                }
            }
            renderDebounce = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            if pendingScrollY > 0 {
                webView.evaluateJavaScript("window.scrollTo(0, \(pendingScrollY));", completionHandler: nil)
                pendingScrollY = 0
            }
            // 주입-로드 레이스 복구: 엔진이 페이지 커밋 전에 끝나 즉시 주입이 옛 DOM에 버려졌다면,
            // 이제 새 DOM이 준비됐으니 버퍼의 전 결과를 재주입한다(innerHTML 멱등).
            for (blockId, html) in dataviewPendingInjections {
                injectDataviewResult(blockId: blockId, html: html)
            }
        }

        private func scrollToHeadingSlug(_ slug: String) {
            let escaped = slug.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'")
            let js = """
            (function() {
                var el = document.getElementById('\(escaped)');
                if (el) {
                    el.scrollIntoView({ behavior: 'smooth', block: 'start' });
                }
            })();
            """
            webView?.evaluateJavaScript(js, completionHandler: nil)
        }

        private func scrollToFraction(_ fraction: Double) {
            let js = "window.scrollTo(0, \(fraction) * (document.documentElement.scrollHeight - window.innerHeight));"
            webView?.evaluateJavaScript(js, completionHandler: nil)
        }

        // MARK: Preview → app messages

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "cmdmd",
                  let body = message.body as? [String: Any],
                  let type = body["type"] as? String else { return }

            if type == "toggleTask",
               let line = body["line"] as? Int {
                let checked = body["checked"] as? Bool ?? true
                AppState.shared?.toggleTask(atLine: line, checked: checked)
            }

            if type == "dataviewRun", body["id"] is Int {
                // 클릭-투-런 승인 — 이 탭·이 문서가 열려 있는 동안 유지(스펙 §7), 재렌더로 실행.
                dataviewApproved = true
                rerenderCurrentMarkdown()
            }
        }

        // MARK: dataviewjs 실행 배선 (스펙 §5·§7)

        /// dataviewjs 블록을 추출하고 placeholder를 끼운 마크다운을 돌려준다.
        /// renderToHTML의 코드 마스킹 전에 원문에서 떼어내야 하므로 모든 렌더 경로가 이걸 먼저 거친다.
        /// 자동(볼트 안 또는 승인됨)이면 스피너 카드+백그라운드 실행 예약, 아니면 "실행" 버튼 카드를 남긴다.
        func prepareDataview(_ markdown: String, baseURL: URL?) -> String {
            dataviewRunToken += 1
            dataviewPendingInjections.removeAll()   // 새 렌더 — 이전 토큰의 완료 버퍼 폐기
            let (vaults, indexed) = Self.dataviewPolicyInputs()
            let notePath = activeNoteURL(baseURL: baseURL)?.path ?? ""
            let auto = dataviewApproved
                || DataviewRunPolicy.isAutoRun(notePath: notePath, vaultPaths: vaults, indexedFolders: indexed)

            // extract 클로저는 코드 원문을 모르므로(runButtonCard가 필요) 유니크 sentinel을 먼저 끼우고,
            // blocks를 얻은 뒤 sentinel을 최종 HTML로 치환하는 2단계.
            let result = DataviewBlockExtractor.extract(markdown) { id in
                Self.dataviewSentinel(id)
            }
            dataviewBlocks = result.blocks
            guard !result.blocks.isEmpty else { return result.markdown }

            var out = result.markdown
            for block in result.blocks {
                let replacement = auto
                    ? "<div class=\"dataview-block\" id=\"dv-b\(block.id)\">\(DataviewHTMLSerializer.pendingCard())</div>"
                    : DataviewHTMLSerializer.runButtonCard(blockId: block.id, code: block.code)
                out = out.replacingOccurrences(of: Self.dataviewSentinel(block.id), with: replacement)
            }
            if auto { scheduleDataviewRuns(baseURL: baseURL) }
            return out
        }

        /// 마크다운 본문에 나타날 리 없는 sentinel(제어문자 경계) — prepareDataview 안에서만 쓰고 반환 전 전부 치환됨.
        private static func dataviewSentinel(_ id: Int) -> String { "\u{0}dv-block-\(id)\u{0}" }

        /// 이 프리뷰가 보여주는 노트의 URL — 활성 탭 파일 URL(dataview 컨텍스트), 없으면 baseURL 폴백.
        private func activeNoteURL(baseURL: URL?) -> URL? {
            AppState.shared?.currentTabFileURL ?? baseURL
        }

        private static func dataviewPolicyInputs() -> ([String], [String]) {
            guard let state = AppState.shared else { return ([], []) }
            return (state.vaults.map { $0.rootPath.path }, state.settings.indexedFolders)
        }

        func scheduleDataviewRuns(baseURL: URL?) {
            guard !dataviewBlocks.isEmpty else { return }
            let token = dataviewRunToken
            let blocks = dataviewBlocks
            let (vaults, indexed) = Self.dataviewPolicyInputs()
            guard let noteURL = activeNoteURL(baseURL: baseURL) else { return }
            let rootPath = DataviewRunPolicy.rootPath(for: noteURL.path, vaultPaths: vaults, indexedFolders: indexed)
            let rootURL = rootPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? noteURL.deletingLastPathComponent()

            Task.detached(priority: .userInitiated) { [weak self] in
                for block in blocks {
                    let result = DataviewEngine.run(code: block.code,
                                                    context: DataviewRunContext(noteURL: noteURL, rootURL: rootURL))
                    let html: String
                    switch result {
                    case .success(let items): html = DataviewHTMLSerializer.html(for: items)
                    case .failure(.timeout):
                        html = DataviewHTMLSerializer.errorCard(message: "실행이 3초를 넘어 중단했습니다", code: block.code)
                    case .failure(.assetsMissing):
                        html = DataviewHTMLSerializer.errorCard(message: "렌더 자산을 찾지 못했습니다", code: block.code)
                    case .failure(.script(let msg)):
                        html = DataviewHTMLSerializer.errorCard(message: msg, code: block.code)
                    }
                    await MainActor.run { [weak self] in
                        guard let self, self.dataviewRunToken == token else { return }   // 스테일 가드
                        self.injectDataviewResult(blockId: block.id, html: html)
                    }
                }
            }
        }

        private func injectDataviewResult(blockId: Int, html: String) {
            // 버퍼에 저장하고(didFinish 재주입 대비) evaluateJavaScript도 즉시 시도한다 —
            // 두 순서(엔진이 커밋보다 먼저/나중) 모두 커버. innerHTML 재설정은 멱등이라 이중 주입 무해.
            dataviewPendingInjections[blockId] = html
            guard let data = try? JSONEncoder().encode(html),
                  let quoted = String(data: data, encoding: .utf8) else { return }
            let js = "(function(){var el=document.getElementById('dv-b\(blockId)');if(el){el.innerHTML=\(quoted);}})();"
            webView?.evaluateJavaScript(js, completionHandler: nil)
        }

        /// 클릭-투-런 승인 후 현재 마크다운을 다시 렌더(스크롤 보존 디바운스 경로 재사용).
        private func rerenderCurrentMarkdown() {
            guard let options = lastOptions else { return }
            scheduleRender(markdown: lastSource, baseURL: lastBaseURL, options: options)
        }

        // MARK: Navigation policy

        func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let url = navigationAction.request.url else {
                return .allow
            }

            if url.scheme == "cmdmd" {
                NotificationCenter.default.post(name: .openInternalLink, object: url)
                return .cancel
            }

            if url.scheme == "obsidian" {
                NSWorkspace.shared.open(url)
                return .cancel
            }

            if url.scheme == "http" || url.scheme == "https" {
                NSWorkspace.shared.open(url)
                return .cancel
            }

            // A clicked relative link to another note opens in the app instead
            // of rendering the raw file inside the preview WebView.
            if navigationAction.navigationType == .linkActivated, url.isFileURL {
                let ext = url.pathExtension.lowercased()
                if ["md", "markdown", "txt"].contains(ext) {
                    Task { @MainActor in
                        AppState.shared?.openDocument(at: url, inNewTab: true)
                    }
                } else {
                    NSWorkspace.shared.open(url)
                }
                return .cancel
            }

            return .allow
        }
    }
}
