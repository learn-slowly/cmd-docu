import Foundation
import Markdown
import WebKit

// MARK: - Shared rendering helpers

/// Slugifies heading text into an anchor id. Unicode-aware so non-ASCII headings
/// (e.g. Korean) produce a real id instead of an empty one. Shared by the
/// renderer (id emission) and the preview scroll handler so the ids always match.
func markdownHeadingSlug(_ text: String) -> String {
    var slug = ""
    for character in text.lowercased() {
        if character.isLetter || character.isNumber {
            slug.append(character)
        } else if character == " " || character == "-" || character == "_" {
            slug.append("-")
        }
    }
    while slug.contains("--") {
        slug = slug.replacingOccurrences(of: "--", with: "-")
    }
    return slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
}

/// HTML-escapes document-derived text before it is interpolated into the preview
/// HTML. Prevents stored-XSS via crafted Markdown in the JS-enabled WebView.
func htmlEscape(_ string: String) -> String {
    var result = string
    result = result.replacingOccurrences(of: "&", with: "&amp;")
    result = result.replacingOccurrences(of: "<", with: "&lt;")
    result = result.replacingOccurrences(of: ">", with: "&gt;")
    result = result.replacingOccurrences(of: "\"", with: "&quot;")
    result = result.replacingOccurrences(of: "'", with: "&#39;")
    return result
}

/// Escapes a URL for an href/src attribute and neutralizes script-bearing
/// schemes (javascript:, vbscript:, data:text/html).
func sanitizeURL(_ url: String) -> String {
    let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
    let lower = trimmed.lowercased()
    if lower.hasPrefix("javascript:") || lower.hasPrefix("vbscript:") || lower.hasPrefix("data:text/html") {
        return "#"
    }
    return htmlEscape(trimmed)
}

class MarkdownRenderer {
    private static let internalLinkQueryValueAllowed: CharacterSet = {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&=?+")
        return allowed
    }()
    
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
        // Mask fenced/inline code first so the wiki-link/callout/tag regex passes
        // don't rewrite Markdown-looking text INSIDE code (e.g. `#define`, `[[x]]`,
        // a leading `> [!note]` in a shell snippet).
        var (processedMarkdown, codeTokens) = maskCodeRegions(markdown)

        processedMarkdown = processWikiLinks(processedMarkdown, baseURL: baseURL)
        processedMarkdown = processCallouts(processedMarkdown)
        processedMarkdown = processTags(processedMarkdown)

        processedMarkdown = restoreCodeRegions(processedMarkdown, tokens: codeTokens)

        let document = Document(parsing: processedMarkdown)
        var htmlVisitor = HTMLVisitor()
        let htmlBody = htmlVisitor.visit(document)

        return wrapWithHTML(body: htmlBody, theme: theme)
    }

    /// Replaces fenced and inline code spans with private-use placeholder tokens
    /// so downstream regex pre-processing leaves code untouched. Restored before
    /// the Markdown parse so the code blocks render (and escape) normally.
    private func maskCodeRegions(_ markdown: String) -> (String, [String: String]) {
        var tokens: [String: String] = [:]
        var index = 0
        var result = markdown

        func mask(_ pattern: String) {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else { return }
            while true {
                let ns = result as NSString
                guard let match = regex.firstMatch(in: result, range: NSRange(location: 0, length: ns.length)) else { break }
                let token = "\u{E000}CMDMDCODE\(index)\u{E000}"
                tokens[token] = ns.substring(with: match.range)
                result = ns.replacingCharacters(in: match.range, with: token)
                index += 1
            }
        }

        // Line-anchored fences (``` at the start of a line, optional indent) so a
        // stray inline ``` can't pair with a real fence and swallow content
        // between two separate code blocks.
        mask("(?m)^[ \\t]*```[\\s\\S]*?^[ \\t]*```")   // fenced code blocks
        mask("`[^`\n]+`")                                // inline code
        return (result, tokens)
    }

    private func restoreCodeRegions(_ markdown: String, tokens: [String: String]) -> String {
        var result = markdown
        for (token, original) in tokens {
            result = result.replacingOccurrences(of: token, with: original)
        }
        return result
    }
    
    private func processWikiLinks(_ markdown: String, baseURL: URL?) -> String {
        let nsString = markdown as NSString
        let range = NSRange(location: 0, length: nsString.length)
        
        var result = markdown
        let matches = wikiLinkPattern.matches(in: markdown, range: range).reversed()
        
        for match in matches {
            let isEmbed = nsString.substring(with: match.range(at: 1)) == "!"
            let alias = match.range(at: 2).location != NSNotFound
                ? nsString.substring(with: match.range(at: 2))
                : nil
            let target = nsString.substring(with: match.range(at: 3))

            let displayText = htmlEscape(alias ?? target)

            if isEmbed {
                let imgExtensions = ["png", "jpg", "jpeg", "gif", "svg", "webp"]
                let ext = (target as NSString).pathExtension.lowercased()

                if imgExtensions.contains(ext) {
                    let imgPath = baseURL?.appendingPathComponent(target).path ?? target
                    result = (result as NSString).replacingCharacters(
                        in: match.range,
                        with: "<img src=\"file://\(htmlEscape(imgPath))\" alt=\"\(displayText)\" class=\"embedded-image\" />"
                    )
                } else {
                    result = (result as NSString).replacingCharacters(
                        in: match.range,
                        with: "<span class=\"embedded-note\" data-note=\"\(htmlEscape(target))\">\(displayText)</span>"
                    )
                }
            } else {
                let encoded = target.addingPercentEncoding(withAllowedCharacters: Self.internalLinkQueryValueAllowed) ?? target
                let href = "cmdmd://open?note=\(encoded)"
                result = (result as NSString).replacingCharacters(
                    in: match.range,
                    with: "<a href=\"\(htmlEscape(href))\" class=\"wiki-link\">\(displayText)</a>"
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
        let safeType = htmlEscape(type)
        let safeTitle = htmlEscape(title)
        // Escape each content line and join with <br> so multi-line callouts keep
        // their breaks and can't inject markup.
        let contentHTML = content.map { htmlEscape($0) }.joined(separator: "<br>\n")

        if isFoldable {
            return """
            <details class="callout callout-\(safeType)" \(isExpanded ? "open" : "")>
                <summary><span class="callout-icon">\(icon)</span> <span class="callout-title">\(safeTitle)</span></summary>
                <div class="callout-content">\(contentHTML)</div>
            </details>
            """
        } else {
            return """
            <div class="callout callout-\(safeType)">
                <div class="callout-header"><span class="callout-icon">\(icon)</span> <span class="callout-title">\(safeTitle)</span></div>
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
                with: "<span class=\"tag\" data-tag=\"\(htmlEscape(tagName))\">\(htmlEscape(fullMatch))</span>"
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
        htmlEscape(text.string)
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
        // Slug from the heading's plain text via the shared, Unicode-aware
        // function so non-ASCII (e.g. Korean) headings get a usable anchor id
        // that matches what the preview scroll handler looks up.
        let id = markdownHeadingSlug(heading.plainText)
        return "<h\(level) id=\"\(id)\">\(content)</h\(level)>\n"
    }

    mutating func visitCodeBlock(_ codeBlock: CodeBlock) -> String {
        let lang = codeBlock.language ?? ""
        let code = codeBlock.code

        // Mermaid: escape too. The browser decodes the entities back to the
        // original text in the DOM text node, so Mermaid still parses the
        // diagram correctly while `<script>` can't break out of the container.
        if lang.lowercased() == "mermaid" {
            return "<div class=\"mermaid\">\(htmlEscape(code))</div>\n"
        }

        return "<pre><code class=\"language-\(htmlEscape(lang))\">\(htmlEscape(code))</code></pre>\n"
    }

    mutating func visitInlineCode(_ inlineCode: InlineCode) -> String {
        "<code>\(htmlEscape(inlineCode.code))</code>"
    }

    mutating func visitInlineHTML(_ inlineHTML: InlineHTML) -> String {
        inlineHTML.rawHTML
    }

    mutating func visitHTMLBlock(_ html: HTMLBlock) -> String {
        html.rawHTML
    }

    mutating func visitLink(_ link: Link) -> String {
        let href = sanitizeURL(link.destination ?? "")
        let content = link.children.map { visit($0) }.joined()
        return "<a href=\"\(href)\">\(content)</a>"
    }

    mutating func visitImage(_ image: Image) -> String {
        let src = sanitizeURL(image.source ?? "")
        let alt = htmlEscape(image.plainText)
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
