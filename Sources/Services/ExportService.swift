import Foundation
import AppKit
import WebKit

final class ExportService {
    private let renderer = MarkdownRenderer()
    /// PDF rendering is async; exporters must stay alive until their WebView
    /// finishes, so they're retained here for the duration.
    private var activePDFExporters: [ObjectIdentifier: PDFExporter] = [:]

    func exportToHTML(document: MarkdownDocument, options: MarkdownRenderOptions) -> String {
        // Exports are static artifacts — interactive checkboxes can't post back.
        var exportOptions = options
        exportOptions.interactiveTasks = false
        return renderer.renderToHTML(
            markdown: document.content,
            baseURL: document.fileURL?.deletingLastPathComponent(),
            options: exportOptions
        )
    }

    func saveHTML(document: MarkdownDocument, options: MarkdownRenderOptions) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.html]
        panel.nameFieldStringValue = document.displayTitle + ".html"
        panel.title = "Export as HTML"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        let html = exportToHTML(document: document, options: options)

        do {
            try html.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    func savePDF(document: MarkdownDocument, options: MarkdownRenderOptions) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = document.displayTitle + ".pdf"
        panel.title = "Export as PDF"

        guard panel.runModal() == .OK, let url = panel.url else { return }

        let html = exportToHTML(document: document, options: options)
        let exporter = PDFExporter(
            html: html,
            baseURL: document.fileURL?.deletingLastPathComponent()
        ) { [weak self] result, exporter in
            self?.activePDFExporters.removeValue(forKey: ObjectIdentifier(exporter))
            DispatchQueue.main.async {
                switch result {
                case .success(let data):
                    do {
                        try data.write(to: url)
                    } catch {
                        NSAlert(error: error).runModal()
                    }
                case .failure(let error):
                    NSAlert(error: error).runModal()
                }
            }
        }
        activePDFExporters[ObjectIdentifier(exporter)] = exporter
        exporter.start()
    }

    func copyAsHTML(document: MarkdownDocument, options: MarkdownRenderOptions) {
        let html = exportToHTML(document: document, options: options)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(html, forType: .html)
        NSPasteboard.general.setString(document.content, forType: .string)
    }
}

/// Renders HTML in an offscreen WebView and produces a full-height PDF.
/// Waits for the actual page load (the old fixed 0.5s sleep truncated slow
/// documents) and sizes the PDF to the rendered content height instead of a
/// fixed US-Letter rect that cut everything past page one.
private final class PDFExporter: NSObject, WKNavigationDelegate {
    private let webView: WKWebView
    private let html: String
    private let baseURL: URL?
    private let completion: (Result<Data, Error>, PDFExporter) -> Void
    private static let pageWidth: CGFloat = 800

    init(html: String, baseURL: URL?, completion: @escaping (Result<Data, Error>, PDFExporter) -> Void) {
        self.webView = WKWebView(frame: NSRect(x: 0, y: 0, width: Self.pageWidth, height: 1000))
        self.html = html
        self.baseURL = baseURL
        self.completion = completion
        super.init()
        webView.navigationDelegate = self
    }

    func start() {
        webView.loadHTMLString(html, baseURL: baseURL)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Grace period for CDN-loaded extras (syntax highlighting, math,
        // diagrams) to settle before measuring.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in
            self?.measureAndRender()
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        completion(.failure(error), self)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        completion(.failure(error), self)
    }

    private func measureAndRender() {
        webView.evaluateJavaScript("document.body.scrollHeight") { [weak self] value, _ in
            guard let self else { return }
            let contentHeight = max(400, (value as? Double).map { CGFloat($0) } ?? 1000) + 40
            self.webView.frame = NSRect(x: 0, y: 0, width: Self.pageWidth, height: contentHeight)

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                let config = WKPDFConfiguration()
                config.rect = CGRect(x: 0, y: 0, width: Self.pageWidth, height: contentHeight)
                self.webView.createPDF(configuration: config) { result in
                    self.completion(result, self)
                }
            }
        }
    }
}
