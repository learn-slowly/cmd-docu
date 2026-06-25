import SwiftUI
import WebKit

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

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView
        context.coordinator.scrollSyncEnabled = scrollSyncEnabled

        let html = context.coordinator.renderer.renderToHTML(markdown: markdown, baseURL: baseURL, options: options)
        context.coordinator.lastSource = markdown
        context.coordinator.lastOptions = options
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
        var scrollSyncEnabled: Bool = true
        var currentDocumentID: UUID?

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
            let html = renderer.renderToHTML(markdown: markdown, baseURL: baseURL, options: options)
            lastSource = markdown
            lastOptions = options
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
                let html = self.renderer.renderToHTML(markdown: markdown, baseURL: baseURL, options: options)
                self.lastSource = markdown
                self.lastOptions = options
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
