import Foundation
import AppKit
import WebKit

class ExportService {
    private let renderer = MarkdownRenderer()
    
    func exportToHTML(document: MarkdownDocument, theme: PreviewTheme = .github) -> String {
        let html = renderer.renderToHTML(
            markdown: document.content,
            baseURL: document.fileURL?.deletingLastPathComponent(),
            theme: theme
        )
        return html
    }
    
    func saveHTML(document: MarkdownDocument, theme: PreviewTheme = .github) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.html]
        panel.nameFieldStringValue = document.displayTitle + ".html"
        panel.title = "Export as HTML"
        
        guard panel.runModal() == .OK, let url = panel.url else { return }
        
        let html = exportToHTML(document: document, theme: theme)
        
        do {
            try html.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSAlert(error: error).runModal()
        }
    }
    
    func exportToPDF(document: MarkdownDocument, theme: PreviewTheme = .github, completion: @escaping (Result<Data, Error>) -> Void) {
        let html = exportToHTML(document: document, theme: theme)
        
        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 612, height: 792))
        webView.loadHTMLString(html, baseURL: document.fileURL?.deletingLastPathComponent())
        
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            let config = WKPDFConfiguration()
            config.rect = CGRect(x: 0, y: 0, width: 612, height: 792)
            
            webView.createPDF(configuration: config) { result in
                switch result {
                case .success(let data):
                    completion(.success(data))
                case .failure(let error):
                    completion(.failure(error))
                }
            }
        }
    }
    
    func savePDF(document: MarkdownDocument, theme: PreviewTheme = .github) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.nameFieldStringValue = document.displayTitle + ".pdf"
        panel.title = "Export as PDF"
        
        guard panel.runModal() == .OK, let url = panel.url else { return }
        
        exportToPDF(document: document, theme: theme) { result in
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
    }
    
    func copyAsHTML(document: MarkdownDocument, theme: PreviewTheme = .github) {
        let html = exportToHTML(document: document, theme: theme)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(html, forType: .html)
    }
}
