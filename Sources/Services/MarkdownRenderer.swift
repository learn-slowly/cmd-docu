import Foundation
import Markdown
import WebKit

class MarkdownRenderer {
    
    private let wikiLinkPattern = try! NSRegularExpression(
        pattern: #"(!?)\[\[(?:(.+?)\|)?(.+?)\]\]"#,
        options: []
    )
    
    private let calloutPattern = try! NSRegularExpression(
        pattern: #"^>\s*\[!(\w+)\]([+-])?\s*(.*)"#,
        options: [.anchorsMatchLines]
    )
    
    private let tagPattern = try! NSRegularExpression(
        pattern: #"(?<!\S)#([a-zA-Z][a-zA-Z0-9_/-]*)"#,
        options: []
    )
    
    func renderToHTML(markdown: String, baseURL: URL? = nil, theme: PreviewTheme = .github) -> String {
        var processedMarkdown = markdown
        
        processedMarkdown = processWikiLinks(processedMarkdown, baseURL: baseURL)
        processedMarkdown = processCallouts(processedMarkdown)
        processedMarkdown = processTags(processedMarkdown)
        
        let document = Document(parsing: processedMarkdown)
        var htmlVisitor = HTMLVisitor()
        let htmlBody = htmlVisitor.visit(document)
        
        return wrapWithHTML(body: htmlBody, theme: theme)
    }
    
    private func processWikiLinks(_ markdown: String, baseURL: URL?) -> String {
        let nsString = markdown as NSString
        let range = NSRange(location: 0, length: nsString.length)
        
        var result = markdown
        let matches = wikiLinkPattern.matches(in: markdown, range: range).reversed()
        
        for match in matches {
            let fullMatch = nsString.substring(with: match.range)
            let isEmbed = nsString.substring(with: match.range(at: 1)) == "!"
            let alias = match.range(at: 2).location != NSNotFound
                ? nsString.substring(with: match.range(at: 2))
                : nil
            let target = nsString.substring(with: match.range(at: 3))
            
            let displayText = alias ?? target
            
            if isEmbed {
                let imgExtensions = ["png", "jpg", "jpeg", "gif", "svg", "webp"]
                let ext = (target as NSString).pathExtension.lowercased()
                
                if imgExtensions.contains(ext) {
                    let imgPath = baseURL?.appendingPathComponent(target).path ?? target
                    result = (result as NSString).replacingCharacters(
                        in: match.range,
                        with: "<img src=\"file://\(imgPath)\" alt=\"\(displayText)\" class=\"embedded-image\" />"
                    )
                } else {
                    result = (result as NSString).replacingCharacters(
                        in: match.range,
                        with: "<span class=\"embedded-note\" data-note=\"\(target)\">\(displayText)</span>"
                    )
                }
            } else {
                let href = "cmdmd://open?note=\(target.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? target)"
                result = (result as NSString).replacingCharacters(
                    in: match.range,
                    with: "<a href=\"\(href)\" class=\"wiki-link\">\(displayText)</a>"
                )
            }
        }
        
        return result
    }
    
    private func processCallouts(_ markdown: String) -> String {
        let lines = markdown.components(separatedBy: "\n")
        var result: [String] = []
        var inCallout = false
        var calloutType = ""
        var calloutTitle = ""
        var calloutContent: [String] = []
        var isFoldable = false
        var isExpanded = true
        
        for line in lines {
            let nsLine = line as NSString
            let range = NSRange(location: 0, length: nsLine.length)
            
            if let match = calloutPattern.firstMatch(in: line, range: range) {
                if inCallout {
                    result.append(buildCalloutHTML(type: calloutType, title: calloutTitle, content: calloutContent, isFoldable: isFoldable, isExpanded: isExpanded))
                    calloutContent = []
                }
                
                inCallout = true
                calloutType = nsLine.substring(with: match.range(at: 1)).lowercased()
                
                if match.range(at: 2).location != NSNotFound {
                    let foldMarker = nsLine.substring(with: match.range(at: 2))
                    isFoldable = true
                    isExpanded = foldMarker == "+"
                } else {
                    isFoldable = false
                    isExpanded = true
                }
                
                calloutTitle = match.range(at: 3).location != NSNotFound
                    ? nsLine.substring(with: match.range(at: 3))
                    : calloutType.capitalized
                    
            } else if inCallout && line.hasPrefix(">") {
                let content = String(line.dropFirst().trimmingCharacters(in: .whitespaces))
                calloutContent.append(content)
            } else {
                if inCallout {
                    result.append(buildCalloutHTML(type: calloutType, title: calloutTitle, content: calloutContent, isFoldable: isFoldable, isExpanded: isExpanded))
                    calloutContent = []
                    inCallout = false
                }
                result.append(line)
            }
        }
        
        if inCallout {
            result.append(buildCalloutHTML(type: calloutType, title: calloutTitle, content: calloutContent, isFoldable: isFoldable, isExpanded: isExpanded))
        }
        
        return result.joined(separator: "\n")
    }
    
    private func buildCalloutHTML(type: String, title: String, content: [String], isFoldable: Bool, isExpanded: Bool) -> String {
        let icon = calloutIcon(for: type)
        let contentHTML = content.joined(separator: "\n")
        
        if isFoldable {
            return """
            <details class="callout callout-\(type)" \(isExpanded ? "open" : "")>
                <summary><span class="callout-icon">\(icon)</span> <span class="callout-title">\(title)</span></summary>
                <div class="callout-content">\(contentHTML)</div>
            </details>
            """
        } else {
            return """
            <div class="callout callout-\(type)">
                <div class="callout-header"><span class="callout-icon">\(icon)</span> <span class="callout-title">\(title)</span></div>
                <div class="callout-content">\(contentHTML)</div>
            </div>
            """
        }
    }
    
    private func calloutIcon(for type: String) -> String {
        switch type {
        case "note": return "📝"
        case "abstract", "summary", "tldr": return "📋"
        case "info": return "ℹ️"
        case "todo": return "☑️"
        case "tip", "hint", "important": return "💡"
        case "success", "check", "done": return "✅"
        case "question", "help", "faq": return "❓"
        case "warning", "caution", "attention": return "⚠️"
        case "failure", "fail", "missing": return "❌"
        case "danger", "error": return "🚨"
        case "bug": return "🐛"
        case "example": return "📖"
        case "quote", "cite": return "💬"
        default: return "📌"
        }
    }
    
    private func processTags(_ markdown: String) -> String {
        let nsString = markdown as NSString
        let range = NSRange(location: 0, length: nsString.length)
        
        var result = markdown
        let matches = tagPattern.matches(in: markdown, range: range).reversed()
        
        for match in matches {
            let fullMatch = nsString.substring(with: match.range)
            let tagName = nsString.substring(with: match.range(at: 1))
            
            result = (result as NSString).replacingCharacters(
                in: match.range,
                with: "<span class=\"tag\" data-tag=\"\(tagName)\">\(fullMatch)</span>"
            )
        }
        
        return result
    }
    
    private func wrapWithHTML(body: String, theme: PreviewTheme) -> String {
        let hasMermaid = body.contains("class=\"mermaid\"")
        
        let mermaidScript = hasMermaid ? """
            <script src="https://cdn.jsdelivr.net/npm/mermaid@10/dist/mermaid.min.js"></script>
            <script>
                document.addEventListener('DOMContentLoaded', function() {
                    mermaid.initialize({
                        startOnLoad: true,
                        theme: window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'default',
                        securityLevel: 'loose',
                        fontFamily: '-apple-system, BlinkMacSystemFont, sans-serif'
                    });
                });
            </script>
            """ : ""
        
        let mermaidCSS = hasMermaid ? """
            .mermaid {
                text-align: center;
                margin: 24px 0;
                padding: 16px;
                background: var(--bg-secondary, #f6f8fa);
                border-radius: 8px;
            }
            .mermaid svg {
                max-width: 100%;
                height: auto;
            }
            """ : ""
        
        return """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="UTF-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <style>
                \(theme.css)
                \(obsidianExtensionsCSS)
                \(mermaidCSS)
            </style>
            \(mermaidScript)
        </head>
        <body class="markdown-body">
            \(body)
        </body>
        </html>
        """
    }
    
    private var obsidianExtensionsCSS: String {
        """
        .wiki-link {
            color: var(--link-color, #7c3aed);
            text-decoration: none;
            border-bottom: 1px dashed var(--link-color, #7c3aed);
        }
        .wiki-link:hover {
            border-bottom-style: solid;
        }
        .embedded-image {
            max-width: 100%;
            border-radius: 8px;
        }
        .embedded-note {
            background: var(--bg-secondary, #f3f4f6);
            padding: 2px 6px;
            border-radius: 4px;
            font-style: italic;
        }
        .tag {
            background: var(--tag-bg, #e0e7ff);
            color: var(--tag-color, #4338ca);
            padding: 2px 8px;
            border-radius: 12px;
            font-size: 0.875em;
            font-weight: 500;
        }
        .callout {
            border-radius: 8px;
            padding: 12px 16px;
            margin: 16px 0;
            border-left: 4px solid;
        }
        .callout-header {
            font-weight: 600;
            margin-bottom: 8px;
            display: flex;
            align-items: center;
            gap: 8px;
        }
        .callout-content {
            margin-left: 28px;
        }
        .callout-note { background: #eff6ff; border-color: #3b82f6; }
        .callout-info { background: #ecfeff; border-color: #06b6d4; }
        .callout-tip, .callout-hint, .callout-important { background: #fefce8; border-color: #eab308; }
        .callout-warning, .callout-caution, .callout-attention { background: #fff7ed; border-color: #f97316; }
        .callout-danger, .callout-error { background: #fef2f2; border-color: #ef4444; }
        .callout-success, .callout-check, .callout-done { background: #f0fdf4; border-color: #22c55e; }
        .callout-quote, .callout-cite { background: #f9fafb; border-color: #6b7280; }
        .callout-bug { background: #fdf4ff; border-color: #d946ef; }
        .callout-example { background: #faf5ff; border-color: #a855f7; }
        details.callout > summary {
            cursor: pointer;
            list-style: none;
            display: flex;
            align-items: center;
            gap: 8px;
            font-weight: 600;
        }
        details.callout > summary::-webkit-details-marker {
            display: none;
        }
        details.callout > summary::before {
            content: "▶";
            font-size: 0.75em;
            transition: transform 0.2s;
        }
        details.callout[open] > summary::before {
            transform: rotate(90deg);
        }
        """
    }
}

struct HTMLVisitor: MarkupVisitor {
    typealias Result = String
    
    mutating func defaultVisit(_ markup: Markup) -> String {
        markup.children.map { visit($0) }.joined()
    }
    
    mutating func visitDocument(_ document: Document) -> String {
        document.children.map { visit($0) }.joined()
    }
    
    mutating func visitParagraph(_ paragraph: Paragraph) -> String {
        "<p>\(paragraph.children.map { visit($0) }.joined())</p>\n"
    }
    
    mutating func visitText(_ text: Text) -> String {
        text.string
    }
    
    mutating func visitEmphasis(_ emphasis: Emphasis) -> String {
        "<em>\(emphasis.children.map { visit($0) }.joined())</em>"
    }
    
    mutating func visitStrong(_ strong: Strong) -> String {
        "<strong>\(strong.children.map { visit($0) }.joined())</strong>"
    }
    
    mutating func visitHeading(_ heading: Heading) -> String {
        let level = heading.level
        let content = heading.children.map { visit($0) }.joined()
        let id = content
            .lowercased()
            .replacingOccurrences(of: " ", with: "-")
            .replacingOccurrences(of: "[^a-z0-9\\-]", with: "", options: .regularExpression)
        return "<h\(level) id=\"\(id)\">\(content)</h\(level)>\n"
    }
    
    mutating func visitCodeBlock(_ codeBlock: CodeBlock) -> String {
        let lang = codeBlock.language ?? ""
        let code = codeBlock.code
        
        // Special handling for Mermaid diagrams
        if lang.lowercased() == "mermaid" {
            // Don't escape HTML for mermaid - it needs raw content
            return "<div class=\"mermaid\">\(code)</div>\n"
        }
        
        let escapedCode = code.replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        return "<pre><code class=\"language-\(lang)\">\(escapedCode)</code></pre>\n"
    }
    
    mutating func visitInlineCode(_ inlineCode: InlineCode) -> String {
        let code = inlineCode.code.replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        return "<code>\(code)</code>"
    }
    
    mutating func visitLink(_ link: Link) -> String {
        let href = link.destination ?? ""
        let content = link.children.map { visit($0) }.joined()
        return "<a href=\"\(href)\">\(content)</a>"
    }
    
    mutating func visitImage(_ image: Image) -> String {
        let src = image.source ?? ""
        let alt = image.title ?? ""
        return "<img src=\"\(src)\" alt=\"\(alt)\" />"
    }
    
    mutating func visitUnorderedList(_ list: UnorderedList) -> String {
        "<ul>\n\(list.children.map { visit($0) }.joined())</ul>\n"
    }
    
    mutating func visitOrderedList(_ list: OrderedList) -> String {
        "<ol>\n\(list.children.map { visit($0) }.joined())</ol>\n"
    }
    
    mutating func visitListItem(_ item: ListItem) -> String {
        let checkbox = item.checkbox
        let checkboxHTML: String
        switch checkbox {
        case .checked:
            checkboxHTML = "<input type=\"checkbox\" checked disabled /> "
        case .unchecked:
            checkboxHTML = "<input type=\"checkbox\" disabled /> "
        case .none:
            checkboxHTML = ""
        }
        return "<li>\(checkboxHTML)\(item.children.map { visit($0) }.joined())</li>\n"
    }
    
    mutating func visitBlockQuote(_ blockQuote: BlockQuote) -> String {
        "<blockquote>\(blockQuote.children.map { visit($0) }.joined())</blockquote>\n"
    }
    
    mutating func visitThematicBreak(_ thematicBreak: ThematicBreak) -> String {
        "<hr />\n"
    }
    
    mutating func visitTable(_ table: Table) -> String {
        var html = "<table>\n"
        
        let head = table.head
        html += "<thead><tr>\n"
        for cell in head.cells {
            html += "<th>\(cell.children.map { visit($0) }.joined())</th>\n"
        }
        html += "</tr></thead>\n"
        
        html += "<tbody>\n"
        for row in table.body.rows {
            html += "<tr>\n"
            for cell in row.cells {
                html += "<td>\(cell.children.map { visit($0) }.joined())</td>\n"
            }
            html += "</tr>\n"
        }
        html += "</tbody>\n</table>\n"
        
        return html
    }
    
    mutating func visitSoftBreak(_ softBreak: SoftBreak) -> String {
        "\n"
    }
    
    mutating func visitLineBreak(_ lineBreak: LineBreak) -> String {
        "<br />\n"
    }
}

enum PreviewTheme: String, CaseIterable, Codable {
    case github = "GitHub"
    case obsidian = "Obsidian"
    case minimal = "Minimal"
    
    var css: String {
        switch self {
        case .github:
            return githubCSS
        case .obsidian:
            return obsidianCSS
        case .minimal:
            return minimalCSS
        }
    }
    
    private var githubCSS: String {
        """
        :root {
            --bg-primary: #ffffff;
            --bg-secondary: #f6f8fa;
            --text-primary: #24292f;
            --text-secondary: #57606a;
            --link-color: #0969da;
            --border-color: #d0d7de;
            --code-bg: #f6f8fa;
        }
        @media (prefers-color-scheme: dark) {
            :root {
                --bg-primary: #0d1117;
                --bg-secondary: #161b22;
                --text-primary: #c9d1d9;
                --text-secondary: #8b949e;
                --link-color: #58a6ff;
                --border-color: #30363d;
                --code-bg: #161b22;
            }
        }
        body {
            font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', 'Noto Sans', Helvetica, Arial, sans-serif;
            font-size: 16px;
            line-height: 1.6;
            color: var(--text-primary);
            background: var(--bg-primary);
            max-width: 900px;
            margin: 0 auto;
            padding: 32px;
        }
        h1, h2, h3, h4, h5, h6 { margin-top: 24px; margin-bottom: 16px; font-weight: 600; }
        h1 { font-size: 2em; border-bottom: 1px solid var(--border-color); padding-bottom: 0.3em; }
        h2 { font-size: 1.5em; border-bottom: 1px solid var(--border-color); padding-bottom: 0.3em; }
        a { color: var(--link-color); text-decoration: none; }
        a:hover { text-decoration: underline; }
        code { background: var(--code-bg); padding: 0.2em 0.4em; border-radius: 6px; font-size: 85%; }
        pre { background: var(--code-bg); padding: 16px; border-radius: 6px; overflow-x: auto; }
        pre code { background: none; padding: 0; }
        blockquote { border-left: 4px solid var(--border-color); margin: 0; padding-left: 16px; color: var(--text-secondary); }
        table { border-collapse: collapse; width: 100%; }
        th, td { border: 1px solid var(--border-color); padding: 8px 12px; }
        th { background: var(--bg-secondary); }
        img { max-width: 100%; }
        hr { border: none; border-top: 1px solid var(--border-color); margin: 24px 0; }
        ul, ol { padding-left: 2em; }
        li { margin: 4px 0; }
        input[type="checkbox"] { margin-right: 8px; }
        """
    }
    
    private var obsidianCSS: String {
        """
        :root {
            --bg-primary: #ffffff;
            --bg-secondary: #f5f6f8;
            --text-primary: #2e3338;
            --text-secondary: #6c7489;
            --link-color: #7c3aed;
            --border-color: #e3e5e8;
            --code-bg: #f5f6f8;
            --tag-bg: #e0e7ff;
            --tag-color: #4338ca;
        }
        @media (prefers-color-scheme: dark) {
            :root {
                --bg-primary: #1e1e1e;
                --bg-secondary: #262626;
                --text-primary: #dcddde;
                --text-secondary: #888;
                --link-color: #a78bfa;
                --border-color: #3c3c3c;
                --code-bg: #2d2d2d;
                --tag-bg: #312e81;
                --tag-color: #c4b5fd;
            }
        }
        body {
            font-family: -apple-system, BlinkMacSystemFont, Inter, 'Segoe UI', Roboto, sans-serif;
            font-size: 16px;
            line-height: 1.75;
            color: var(--text-primary);
            background: var(--bg-primary);
            max-width: 800px;
            margin: 0 auto;
            padding: 40px;
        }
        h1, h2, h3, h4, h5, h6 { margin-top: 1.5em; margin-bottom: 0.5em; font-weight: 700; }
        h1 { font-size: 1.875em; }
        h2 { font-size: 1.5em; }
        h3 { font-size: 1.25em; }
        a { color: var(--link-color); text-decoration: none; }
        a:hover { text-decoration: underline; }
        code { background: var(--code-bg); padding: 2px 6px; border-radius: 4px; font-family: 'SF Mono', Menlo, monospace; font-size: 0.875em; }
        pre { background: var(--code-bg); padding: 16px; border-radius: 8px; overflow-x: auto; }
        pre code { background: none; padding: 0; }
        blockquote { border-left: 3px solid var(--link-color); margin: 16px 0; padding-left: 16px; color: var(--text-secondary); font-style: italic; }
        table { border-collapse: collapse; width: 100%; margin: 16px 0; }
        th, td { border: 1px solid var(--border-color); padding: 10px 14px; text-align: left; }
        th { background: var(--bg-secondary); font-weight: 600; }
        img { max-width: 100%; border-radius: 8px; }
        hr { border: none; border-top: 1px solid var(--border-color); margin: 32px 0; }
        ul, ol { padding-left: 1.5em; }
        li { margin: 6px 0; }
        li::marker { color: var(--text-secondary); }
        input[type="checkbox"] { margin-right: 8px; accent-color: var(--link-color); }
        """
    }
    
    private var minimalCSS: String {
        """
        body {
            font-family: 'SF Pro Text', -apple-system, BlinkMacSystemFont, sans-serif;
            font-size: 17px;
            line-height: 1.8;
            color: #1d1d1f;
            background: #fff;
            max-width: 680px;
            margin: 0 auto;
            padding: 48px 24px;
        }
        @media (prefers-color-scheme: dark) {
            body { background: #1d1d1f; color: #f5f5f7; }
            a { color: #0a84ff; }
            code, pre { background: #2c2c2e; }
        }
        h1, h2, h3, h4 { font-weight: 600; margin-top: 2em; margin-bottom: 0.5em; }
        h1 { font-size: 2em; }
        h2 { font-size: 1.5em; }
        a { color: #0066cc; text-decoration: none; }
        code { background: #f5f5f7; padding: 2px 6px; border-radius: 4px; font-size: 0.9em; }
        pre { background: #f5f5f7; padding: 20px; border-radius: 12px; overflow-x: auto; }
        pre code { background: none; }
        blockquote { margin: 24px 0; padding-left: 20px; border-left: 3px solid #d1d1d6; color: #6e6e73; }
        img { max-width: 100%; border-radius: 12px; }
        hr { border: none; border-top: 1px solid #d1d1d6; margin: 40px 0; }
        """
    }
}
