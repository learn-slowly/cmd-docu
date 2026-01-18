import Foundation
import AppKit
import Highlightr

class SyntaxHighlighter {
    private let highlightr: Highlightr?
    private var editorTheme: EditorTheme = .oneDark
    
    private let headingPattern = try! NSRegularExpression(pattern: "^(#{1,6})\\s+(.+)$", options: .anchorsMatchLines)
    private let boldPattern = try! NSRegularExpression(pattern: "(\\*\\*|__)(.*?)\\1", options: [])
    private let italicPattern = try! NSRegularExpression(pattern: "(\\*|_)(.*?)\\1", options: [])
    private let codeInlinePattern = try! NSRegularExpression(pattern: "`([^`]+)`", options: [])
    private let linkPattern = try! NSRegularExpression(pattern: "\\[([^\\]]+)\\]\\(([^)]+)\\)", options: [])
    private let wikiLinkPattern = try! NSRegularExpression(pattern: "\\[\\[([^\\]|]+)(\\|([^\\]]+))?\\]\\]", options: [])
    private let tagPattern = try! NSRegularExpression(pattern: "(?<![\\w#])#([a-zA-Z][a-zA-Z0-9_/-]*)", options: [])
    private let blockquotePattern = try! NSRegularExpression(pattern: "^>\\s*(.*)$", options: .anchorsMatchLines)
    private let listPattern = try! NSRegularExpression(pattern: "^(\\s*)([-*+]|\\d+\\.)\\s+", options: .anchorsMatchLines)
    private let codeBlockPattern = try! NSRegularExpression(pattern: "```(\\w+)?\\n([\\s\\S]*?)```", options: [])
    private let hrPattern = try! NSRegularExpression(pattern: "^([-*_]){3,}\\s*$", options: .anchorsMatchLines)
    private let calloutPattern = try! NSRegularExpression(pattern: "^>\\s*\\[!([a-zA-Z]+)\\]([+-])?\\s*(.*)?$", options: .anchorsMatchLines)
    
    init() {
        self.highlightr = Highlightr()
        highlightr?.setTheme(to: "github")
    }
    
    func setEditorTheme(_ theme: EditorTheme) {
        self.editorTheme = theme
        
        let highlightrThemeName: String
        switch theme {
        case .oneDark: highlightrThemeName = "atom-one-dark"
        case .dracula: highlightrThemeName = "dracula"
        case .github: highlightrThemeName = "github"
        case .nord: highlightrThemeName = "nord"
        case .tokyoNight: highlightrThemeName = "tokyo-night-dark"
        case .gruvbox: highlightrThemeName = "gruvbox-dark"
        case .solarizedDark: highlightrThemeName = "solarized-dark"
        case .materialDark: highlightrThemeName = "androidstudio"
        }
        highlightr?.setTheme(to: highlightrThemeName)
    }
    
    func setTheme(_ theme: HighlightrTheme) {
        switch theme {
        case .light:
            highlightr?.setTheme(to: "github")
        case .dark:
            highlightr?.setTheme(to: "monokai-sublime")
        case .system:
            let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            highlightr?.setTheme(to: isDark ? "monokai-sublime" : "github")
        }
    }
    
    func highlight(markdown: String, font: NSFont) -> NSAttributedString {
        highlight(markdown: markdown, font: font, theme: editorTheme)
    }
    
    func highlight(markdown: String, font: NSFont, theme: EditorTheme) -> NSAttributedString {
        let string = NSMutableAttributedString(string: markdown)
        let fullRange = NSRange(location: 0, length: string.length)
        
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 4
        
        let textColor = NSColor(theme.textColor)
        
        string.addAttributes([
            .font: font,
            .foregroundColor: textColor,
            .paragraphStyle: paragraphStyle
        ], range: fullRange)
        
        highlightHeadings(in: string, font: font, theme: theme)
        highlightCallouts(in: string, font: font, theme: theme)
        highlightCodeBlocks(in: string, font: font, theme: theme)
        highlightInlineCode(in: string, font: font, theme: theme)
        highlightBold(in: string, font: font, theme: theme)
        highlightItalic(in: string, font: font, theme: theme)
        highlightLinks(in: string, theme: theme)
        highlightWikiLinks(in: string, theme: theme)
        highlightTags(in: string, theme: theme)
        highlightBlockquotes(in: string, theme: theme)
        highlightLists(in: string, theme: theme)
        highlightHorizontalRules(in: string, theme: theme)
        
        return string
    }
    
    private func highlightHeadings(in string: NSMutableAttributedString, font: NSFont, theme: EditorTheme) {
        let text = string.string
        let range = NSRange(location: 0, length: string.length)
        
        headingPattern.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let match = match else { return }
            
            let hashRange = match.range(at: 1)
            let contentRange = match.range(at: 2)
            let level = hashRange.length
            
            let headingSizes: [Int: CGFloat] = [1: 28, 2: 24, 3: 20, 4: 18, 5: 16, 6: 14]
            let fontSize = headingSizes[level] ?? font.pointSize
            let headingFont = NSFont.systemFont(ofSize: fontSize, weight: .bold)
            
            string.addAttributes([
                .foregroundColor: NSColor(theme.commentColor),
                .font: font
            ], range: hashRange)
            
            string.addAttributes([
                .font: headingFont,
                .foregroundColor: NSColor(theme.headingColor)
            ], range: contentRange)
        }
    }
    
    private func highlightBold(in string: NSMutableAttributedString, font: NSFont, theme: EditorTheme) {
        let text = string.string
        let range = NSRange(location: 0, length: string.length)
        
        boldPattern.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let match = match else { return }
            
            let boldFont = NSFont.systemFont(ofSize: font.pointSize, weight: .bold)
            string.addAttribute(.font, value: boldFont, range: match.range)
        }
    }
    
    private func highlightItalic(in string: NSMutableAttributedString, font: NSFont, theme: EditorTheme) {
        let text = string.string
        let range = NSRange(location: 0, length: string.length)
        
        italicPattern.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let match = match else { return }
            
            let matchText = (text as NSString).substring(with: match.range)
            let isBoldMarker = matchText.hasPrefix("**") || matchText.hasPrefix("__")
            if isBoldMarker { return }
            
            let italicFont = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
            string.addAttribute(.font, value: italicFont, range: match.range)
        }
    }
    
    private func highlightInlineCode(in string: NSMutableAttributedString, font: NSFont, theme: EditorTheme) {
        let text = string.string
        let range = NSRange(location: 0, length: string.length)
        
        codeInlinePattern.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let match = match else { return }
            
            let monoFont = NSFont.monospacedSystemFont(ofSize: font.pointSize - 1, weight: .regular)
            string.addAttributes([
                .font: monoFont,
                .foregroundColor: NSColor(theme.stringColor),
                .backgroundColor: NSColor(theme.selectionColor).withAlphaComponent(0.5)
            ], range: match.range)
        }
    }
    
    private func highlightCodeBlocks(in string: NSMutableAttributedString, font: NSFont, theme: EditorTheme) {
        let text = string.string
        let range = NSRange(location: 0, length: string.length)
        
        codeBlockPattern.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let match = match else { return }
            
            let monoFont = NSFont.monospacedSystemFont(ofSize: font.pointSize - 1, weight: .regular)
            let langRange = match.range(at: 1)
            let codeRange = match.range(at: 2)
            
            string.addAttributes([
                .font: monoFont,
                .backgroundColor: NSColor(theme.selectionColor).withAlphaComponent(0.3)
            ], range: match.range)
            
            let hasLanguage = langRange.location != NSNotFound && codeRange.location != NSNotFound
            if hasLanguage, let highlightr = highlightr {
                let lang = (text as NSString).substring(with: langRange)
                let code = (text as NSString).substring(with: codeRange)
                
                if let highlighted = highlightr.highlight(code, as: lang) {
                    highlighted.enumerateAttributes(in: NSRange(location: 0, length: highlighted.length)) { attrs, attrRange, _ in
                        let targetRange = NSRange(location: codeRange.location + attrRange.location, length: attrRange.length)
                        let isValidRange = targetRange.location + targetRange.length <= string.length
                        if isValidRange {
                            for (key, value) in attrs where key != .font {
                                string.addAttribute(key, value: value, range: targetRange)
                            }
                        }
                    }
                }
            }
        }
    }
    
    private func highlightLinks(in string: NSMutableAttributedString, theme: EditorTheme) {
        let text = string.string
        let range = NSRange(location: 0, length: string.length)
        
        linkPattern.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let match = match else { return }
            
            let linkTextRange = match.range(at: 1)
            let linkUrlRange = match.range(at: 2)
            
            string.addAttributes([
                .foregroundColor: NSColor(theme.linkColor),
                .underlineStyle: NSUnderlineStyle.single.rawValue
            ], range: linkTextRange)
            
            string.addAttribute(.foregroundColor, value: NSColor(theme.commentColor), range: linkUrlRange)
        }
    }
    
    private func highlightWikiLinks(in string: NSMutableAttributedString, theme: EditorTheme) {
        let text = string.string
        let range = NSRange(location: 0, length: string.length)
        
        wikiLinkPattern.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let match = match else { return }
            
            string.addAttributes([
                .foregroundColor: NSColor(theme.keywordColor),
                .underlineStyle: NSUnderlineStyle.single.rawValue
            ], range: match.range)
        }
    }
    
    private func highlightTags(in string: NSMutableAttributedString, theme: EditorTheme) {
        let text = string.string
        let range = NSRange(location: 0, length: string.length)
        
        tagPattern.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let match = match else { return }
            
            string.addAttributes([
                .foregroundColor: NSColor(theme.linkColor),
                .backgroundColor: NSColor(theme.linkColor).withAlphaComponent(0.15)
            ], range: match.range)
        }
    }
    
    private func highlightBlockquotes(in string: NSMutableAttributedString, theme: EditorTheme) {
        let text = string.string
        let range = NSRange(location: 0, length: string.length)
        
        blockquotePattern.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let match = match else { return }
            
            string.addAttributes([
                .foregroundColor: NSColor(theme.commentColor),
                .backgroundColor: NSColor(theme.selectionColor).withAlphaComponent(0.2)
            ], range: match.range)
        }
    }
    
    private func highlightLists(in string: NSMutableAttributedString, theme: EditorTheme) {
        let text = string.string
        let range = NSRange(location: 0, length: string.length)
        
        listPattern.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let match = match else { return }
            
            let markerRange = match.range(at: 2)
            string.addAttribute(.foregroundColor, value: NSColor(theme.keywordColor), range: markerRange)
        }
    }
    
    private func highlightHorizontalRules(in string: NSMutableAttributedString, theme: EditorTheme) {
        let text = string.string
        let range = NSRange(location: 0, length: string.length)
        
        hrPattern.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let match = match else { return }
            
            string.addAttribute(.foregroundColor, value: NSColor(theme.commentColor), range: match.range)
        }
    }
    
    private func highlightCallouts(in string: NSMutableAttributedString, font: NSFont, theme: EditorTheme) {
        let text = string.string
        let range = NSRange(location: 0, length: string.length)
        
        calloutPattern.enumerateMatches(in: text, range: range) { match, _, _ in
            guard let match = match else { return }
            
            let typeRange = match.range(at: 1)
            let calloutType = (text as NSString).substring(with: typeRange).lowercased()
            
            let color = calloutColor(for: calloutType)
            
            string.addAttributes([
                .foregroundColor: color,
                .backgroundColor: color.withAlphaComponent(0.1)
            ], range: match.range)
            
            let calloutTypeFont = NSFont.systemFont(ofSize: font.pointSize, weight: .semibold)
            string.addAttribute(.font, value: calloutTypeFont, range: typeRange)
        }
    }
    
    private func calloutColor(for type: String) -> NSColor {
        switch type {
        case "note": return .systemBlue
        case "abstract", "summary", "tldr": return .systemCyan
        case "info": return .systemTeal
        case "todo": return .systemMint
        case "tip", "hint", "important": return .systemYellow
        case "success", "check", "done": return .systemGreen
        case "question", "help", "faq": return .systemYellow
        case "warning", "caution", "attention": return .systemOrange
        case "failure", "fail", "missing": return .systemRed
        case "danger", "error": return .systemRed
        case "bug": return .systemPink
        case "example": return .systemPurple
        case "quote", "cite": return .systemGray
        default: return .systemGray
        }
    }
}

enum HighlightrTheme: String, CaseIterable, Codable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"
}
