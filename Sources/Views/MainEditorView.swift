import SwiftUI
import WebKit

struct MainEditorView: View {
    @Environment(AppState.self) private var appState
    
    var body: some View {
        VStack(spacing: 0) {
            if appState.settings.showTabBar && !appState.tabs.isEmpty {
                TabBarView()
            }
            
            if let document = appState.currentDocument, let fileURL = document.fileURL {
                SimpleBreadcrumbView(fileURL: fileURL, folderURL: appState.currentFolder)
            }
            
            Group {
                if let document = appState.currentDocument {
                    // .id ties the editor/preview subtree to the document identity,
                    // so switching tabs gives a fresh NSTextView instead of reusing
                    // one (which bled undo history and scroll state across tabs).
                    DocumentEditorView(document: document)
                        .id(document.id)
                } else {
                    WelcomeView()
                }
            }
            
            if appState.settings.showStatusBar, appState.currentDocument != nil {
                StatusBarView()
            }
        }
    }
}

struct SimpleBreadcrumbView: View {
    let fileURL: URL
    let folderURL: URL?
    
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(computePathParts(), id: \.self) { part in
                    if part != computePathParts().first {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                    
                    HStack(spacing: 3) {
                        Image(systemName: part == fileURL.lastPathComponent ? "doc.text" : "folder")
                            .font(.system(size: 10))
                        Text(part)
                            .font(.system(size: 11))
                            .lineLimit(1)
                    }
                    .foregroundStyle(part == fileURL.lastPathComponent ? .primary : .secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        }
        .frame(height: 24)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .overlay(alignment: .bottom) {
            Divider()
        }
    }
    
    private func computePathParts() -> [String] {
        var parts: [String] = []
        var currentURL = fileURL.deletingLastPathComponent()
        
        if let folderURL = folderURL {
            while currentURL.path != "/" && currentURL.path.hasPrefix(folderURL.path) {
                parts.insert(currentURL.lastPathComponent, at: 0)
                currentURL = currentURL.deletingLastPathComponent()
            }
        } else {
            for _ in 0..<2 {
                if currentURL.path == "/" { break }
                parts.insert(currentURL.lastPathComponent, at: 0)
                currentURL = currentURL.deletingLastPathComponent()
            }
        }
        
        parts.append(fileURL.lastPathComponent)
        return parts
    }
}



struct DocumentEditorView: View {
    @Environment(AppState.self) private var appState
    let document: MarkdownDocument
    
    var body: some View {
        switch appState.viewMode {
        case .source:
            EditorPane()
        case .split:
            ZStack(alignment: .top) {
                HSplitView {
                    EditorPane()
                        .frame(minWidth: 300)
                    PreviewPane()
                        .frame(minWidth: 300)
                }
                
                ScrollSyncButton()
            }
        case .preview:
            PreviewPane()
        }
    }
}

struct ScrollSyncButton: View {
    @Environment(AppState.self) private var appState
    
    var body: some View {
        @Bindable var state = appState
        
        Button {
            state.settings.scrollSyncEnabled.toggle()
            state.saveUserData()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: appState.settings.scrollSyncEnabled ? "link" : "link.badge.plus")
                    .font(.system(size: 10))
                Text(appState.settings.scrollSyncEnabled ? "Sync" : "Unsynced")
                    .font(.system(size: 10))
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(appState.settings.scrollSyncEnabled ? Color.accentColor.opacity(0.15) : Color(nsColor: .controlBackgroundColor))
            .foregroundStyle(appState.settings.scrollSyncEnabled ? Color.accentColor : Color.secondary)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .padding(.top, 8)
        .help(appState.settings.scrollSyncEnabled ? "Click to disable scroll sync" : "Click to enable scroll sync")
    }
}

struct EditorPane: View {
    @Environment(AppState.self) private var appState
    @State private var isDropTargeted = false
    
    /// Resolves the editor font from settings.fontName, falling back to the
    /// system monospaced font if the named font isn't installed.
    private func editorFont() -> NSFont {
        let size = appState.settings.fontSize
        let name = appState.settings.fontName
        if !name.isEmpty, let custom = NSFont(name: name, size: size) {
            return custom
        }
        return .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    var body: some View {
        @Bindable var state = appState
        let theme = appState.settings.editorTheme

        VStack(spacing: 0) {
            if appState.settings.showLineNumbers {
                HStack(spacing: 0) {
                    LineNumbersView(text: appState.currentDocument?.content ?? "", theme: theme)
                        .frame(width: 50)
                        .background(theme.backgroundColor.opacity(0.8))

                    Divider()

                    MarkdownTextEditor(
                        text: Binding(
                            get: { appState.currentDocument?.content ?? "" },
                            set: { appState.updateContent($0) }
                        ),
                        font: editorFont(),
                        syntaxHighlighting: true,
                        editorTheme: theme,
                        softWrap: appState.settings.softWrap,
                        onImageDrop: { imageURL in
                            handleImageDrop(imageURL)
                        }
                    )
                }
            } else {
                MarkdownTextEditor(
                    text: Binding(
                        get: { appState.currentDocument?.content ?? "" },
                        set: { appState.updateContent($0) }
                    ),
                    font: editorFont(),
                    syntaxHighlighting: true,
                    editorTheme: theme,
                    softWrap: appState.settings.softWrap,
                    onImageDrop: { imageURL in
                        handleImageDrop(imageURL)
                    }
                )
            }
        }
        .background(theme.backgroundColor)
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.accentColor, lineWidth: 3)
                    .background(Color.accentColor.opacity(0.1))
            }
        }
        .onDrop(of: [.image, .fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
        }
    }
    
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier("public.image") {
                provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                    if let data = item as? Data,
                       let url = URL(dataRepresentation: data, relativeTo: nil) {
                        DispatchQueue.main.async {
                            handleImageDrop(url)
                        }
                    }
                }
                return true
            }
        }
        return false
    }
    
    private func handleImageDrop(_ imageURL: URL) {
        guard let documentURL = appState.currentDocument?.fileURL else {
            insertImageMarkdown(imageURL, relativePath: imageURL.path)
            return
        }
        
        let documentFolder = documentURL.deletingLastPathComponent()
        let assetsFolder = documentFolder.appendingPathComponent("assets")
        
        do {
            if !FileManager.default.fileExists(atPath: assetsFolder.path) {
                try FileManager.default.createDirectory(at: assetsFolder, withIntermediateDirectories: true)
            }
            
            let filename = imageURL.lastPathComponent
            let destinationURL = assetsFolder.appendingPathComponent(filename)
            
            if !FileManager.default.fileExists(atPath: destinationURL.path) {
                try FileManager.default.copyItem(at: imageURL, to: destinationURL)
            }
            
            let relativePath = "assets/\(filename)"
            insertImageMarkdown(destinationURL, relativePath: relativePath)
            appState.showToast("Image added")
        } catch {
            insertImageMarkdown(imageURL, relativePath: imageURL.path)
        }
    }
    
    private func insertImageMarkdown(_ url: URL, relativePath: String) {
        let imageName = url.deletingPathExtension().lastPathComponent
        let markdown = "![\(imageName)](\(relativePath))"
        
        if var content = appState.currentDocument?.content {
            if content.isEmpty || content.hasSuffix("\n") {
                content += markdown + "\n"
            } else {
                content += "\n" + markdown + "\n"
            }
            appState.updateContent(content)
        }
    }
}

struct LineNumbersView: View {
    let text: String
    var theme: EditorTheme = .oneDark
    
    var lineCount: Int {
        max(1, text.components(separatedBy: .newlines).count)
    }
    
    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .trailing, spacing: 0) {
                ForEach(1...lineCount, id: \.self) { lineNumber in
                    Text("\(lineNumber)")
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(theme.commentColor)
                        .frame(height: 20)
                }
            }
            .padding(.top, 8)
            .padding(.horizontal, 8)
        }
    }
}

struct MarkdownTextEditor: NSViewRepresentable {
    @Binding var text: String
    let font: NSFont
    let syntaxHighlighting: Bool
    let editorTheme: EditorTheme
    let softWrap: Bool
    var onImageDrop: ((URL) -> Void)?

    private let highlighter = SyntaxHighlighter()

    init(text: Binding<String>, font: NSFont, syntaxHighlighting: Bool = true, editorTheme: EditorTheme = .oneDark, softWrap: Bool = true, onImageDrop: ((URL) -> Void)? = nil) {
        self._text = text
        self.font = font
        self.syntaxHighlighting = syntaxHighlighting
        self.editorTheme = editorTheme
        self.softWrap = softWrap
        self.onImageDrop = onImageDrop
    }

    /// Clamp previously-selected ranges to the current text, measuring in UTF-16
    /// code units (NSRange's unit) rather than grapheme clusters — mixing the two
    /// corrupted selections in documents containing emoji/composed characters.
    private func clampedRanges(_ ranges: [NSValue], to nsString: NSString) -> [NSValue] {
        let length = nsString.length
        return ranges.compactMap { value in
            let range = value.rangeValue
            guard range.location <= length else { return nil }
            let clampedLength = min(range.length, length - range.location)
            return NSValue(range: NSRange(location: range.location, length: clampedLength))
        }
    }

    /// Configures soft-wrap vs. horizontal-scroll behavior for the text view.
    private func applyWrapMode(to textView: NSTextView, scrollView: NSScrollView) {
        guard let container = textView.textContainer else { return }
        let big = CGFloat.greatestFiniteMagnitude
        if softWrap {
            scrollView.hasHorizontalScroller = false
            textView.isHorizontallyResizable = false
            container.widthTracksTextView = true
            container.size = NSSize(width: scrollView.contentSize.width, height: big)
        } else {
            scrollView.hasHorizontalScroller = true
            textView.isHorizontallyResizable = true
            container.widthTracksTextView = false
            container.size = NSSize(width: big, height: big)
        }
        textView.maxSize = NSSize(width: big, height: big)
    }
    
    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else {
            return scrollView
        }
        
        context.coordinator.textView = textView
        textView.delegate = context.coordinator
        textView.font = font
        textView.isRichText = syntaxHighlighting
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.usesFontPanel = false
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.backgroundColor = NSColor(editorTheme.backgroundColor)
        textView.insertionPointColor = NSColor(editorTheme.textColor)

        // Native find/replace bar (⌘F / ⌘⌥F) — previously the app had no
        // in-document search at all.
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true

        applyWrapMode(to: textView, scrollView: scrollView)

        textView.registerForDraggedTypes([.fileURL, .png, .tiff])
        
        if syntaxHighlighting {
            let attributed = highlighter.highlight(markdown: text, font: font, theme: editorTheme)
            textView.textStorage?.setAttributedString(attributed)
        } else {
            textView.string = text
        }
        
        return scrollView
    }
    
    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else { return }

        textView.backgroundColor = NSColor(editorTheme.backgroundColor)
        textView.insertionPointColor = NSColor(editorTheme.textColor)
        textView.font = font
        applyWrapMode(to: textView, scrollView: nsView)

        let currentText = textView.string
        if currentText != text || context.coordinator.currentTheme != editorTheme {
            context.coordinator.currentTheme = editorTheme
            let selectedRanges = textView.selectedRanges

            if syntaxHighlighting {
                let attributed = highlighter.highlight(markdown: text, font: font, theme: editorTheme)
                textView.textStorage?.setAttributedString(attributed)
            } else {
                textView.string = text
            }

            let validRanges = clampedRanges(selectedRanges, to: textView.string as NSString)
            if !validRanges.isEmpty {
                textView.selectedRanges = validRanges
            }
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownTextEditor
        var currentTheme: EditorTheme
        private var isUpdating = false
        private let highlighter = SyntaxHighlighter()
        private var debounceWorkItem: DispatchWorkItem?
        private var observers: [NSObjectProtocol] = []
        weak var textView: NSTextView?

        private let unorderedRegex = try! NSRegularExpression(pattern: #"^(\s*)([-*+])\s+(\[[ xX]\]\s+)?(.*)$"#)
        private let orderedRegex = try! NSRegularExpression(pattern: #"^(\s*)(\d+)([.)])\s+(.*)$"#)
        private let quoteRegex = try! NSRegularExpression(pattern: #"^(\s*>+\s?)(.*)$"#)

        init(_ parent: MarkdownTextEditor) {
            self.parent = parent
            self.currentTheme = parent.editorTheme
            super.init()

            let center = NotificationCenter.default
            observers.append(center.addObserver(forName: .scrollToLine, object: nil, queue: .main) { [weak self] note in
                guard let lineNumber = note.object as? Int else { return }
                self?.scrollToLine(lineNumber)
            })
            observers.append(center.addObserver(forName: .showDocumentSearch, object: nil, queue: .main) { [weak self] _ in
                self?.showFindBar()
            })
            observers.append(center.addObserver(forName: .formatBold, object: nil, queue: .main) { [weak self] _ in
                self?.wrapSelection(token: "**", placeholder: "bold")
            })
            observers.append(center.addObserver(forName: .formatItalic, object: nil, queue: .main) { [weak self] _ in
                self?.wrapSelection(token: "*", placeholder: "italic")
            })
            observers.append(center.addObserver(forName: .formatLink, object: nil, queue: .main) { [weak self] _ in
                self?.insertLink()
            })
        }

        deinit {
            observers.forEach { NotificationCenter.default.removeObserver($0) }
        }

        /// Only the editor that currently owns focus should react to global
        /// format notifications. Menu-driven shortcuts don't change the window's
        /// first responder, so an exact match is correct (and avoids acting on an
        /// unfocused editor).
        private var isActiveEditor: Bool {
            guard let textView = textView, let window = textView.window else { return false }
            return window.firstResponder === textView
        }

        private func showFindBar() {
            guard let textView = textView, textView.window != nil else { return }
            let item = NSMenuItem()
            item.tag = Int(NSTextFinder.Action.showFindInterface.rawValue)
            textView.performTextFinderAction(item)
        }

        private func scrollToLine(_ lineNumber: Int) {
            guard let textView = textView else { return }
            let text = textView.string
            let lines = text.components(separatedBy: .newlines)

            var characterIndex = 0
            for (index, line) in lines.enumerated() {
                if index + 1 == lineNumber {
                    let range = NSRange(location: characterIndex, length: 0)
                    textView.scrollRangeToVisible(range)
                    textView.setSelectedRange(range)
                    return
                }
                characterIndex += (line as NSString).length + 1
            }
        }

        // MARK: - Markdown formatting

        private func wrapSelection(token: String, placeholder: String) {
            guard isActiveEditor, let textView = textView else { return }
            let sel = textView.selectedRange()
            let nsText = textView.string as NSString
            let selected = nsText.substring(with: sel)
            let inner = selected.isEmpty ? placeholder : selected
            let replacement = token + inner + token
            guard textView.shouldChangeText(in: sel, replacementString: replacement) else { return }
            textView.textStorage?.replaceCharacters(in: sel, with: replacement)
            textView.didChangeText()
            let innerLocation = sel.location + (token as NSString).length
            textView.setSelectedRange(NSRange(location: innerLocation, length: (inner as NSString).length))
        }

        private func insertLink() {
            guard isActiveEditor, let textView = textView else { return }
            let sel = textView.selectedRange()
            let nsText = textView.string as NSString
            let selected = nsText.substring(with: sel)
            let label = selected.isEmpty ? "text" : selected
            let replacement = "[\(label)](url)"
            guard textView.shouldChangeText(in: sel, replacementString: replacement) else { return }
            textView.textStorage?.replaceCharacters(in: sel, with: replacement)
            textView.didChangeText()
            // Select the "url" placeholder for immediate typing.
            let urlLocation = sel.location + (replacement as NSString).length - 4
            textView.setSelectedRange(NSRange(location: urlLocation, length: 3))
        }

        // MARK: - Smart list continuation

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                return handleNewline(in: textView)
            }
            return false
        }

        private func handleNewline(in textView: NSTextView) -> Bool {
            let sel = textView.selectedRange()
            guard sel.length == 0 else { return false }
            let nsText = textView.string as NSString
            let lineRange = nsText.lineRange(for: NSRange(location: sel.location, length: 0))
            let lineToCaret = nsText.substring(with: NSRange(location: lineRange.location, length: sel.location - lineRange.location))

            guard let marker = listMarker(for: lineToCaret) else { return false }

            if marker.isEmptyItem {
                // Enter on an empty list/quote item terminates the list: clear the
                // marker and leave the caret on the now-blank line.
                let clearRange = NSRange(location: lineRange.location, length: sel.location - lineRange.location)
                if textView.shouldChangeText(in: clearRange, replacementString: "") {
                    textView.textStorage?.replaceCharacters(in: clearRange, with: "")
                    textView.didChangeText()
                }
                return true
            }

            let insertion = "\n" + marker.continuation
            guard textView.shouldChangeText(in: sel, replacementString: insertion) else { return false }
            textView.textStorage?.replaceCharacters(in: sel, with: insertion)
            textView.didChangeText()
            let newLocation = sel.location + (insertion as NSString).length
            textView.setSelectedRange(NSRange(location: newLocation, length: 0))
            return true
        }

        private func listMarker(for line: String) -> (continuation: String, isEmptyItem: Bool)? {
            let nsLine = line as NSString
            let full = NSRange(location: 0, length: nsLine.length)

            if let m = unorderedRegex.firstMatch(in: line, range: full) {
                let indent = nsLine.substring(with: m.range(at: 1))
                let bullet = nsLine.substring(with: m.range(at: 2))
                let hasTask = m.range(at: 3).location != NSNotFound
                let rest = nsLine.substring(with: m.range(at: 4)).trimmingCharacters(in: .whitespaces)
                let continuation = "\(indent)\(bullet) " + (hasTask ? "[ ] " : "")
                return (continuation, rest.isEmpty)
            }
            if let m = orderedRegex.firstMatch(in: line, range: full) {
                let indent = nsLine.substring(with: m.range(at: 1))
                let number = Int(nsLine.substring(with: m.range(at: 2))) ?? 0
                let delimiter = nsLine.substring(with: m.range(at: 3))
                let rest = nsLine.substring(with: m.range(at: 4)).trimmingCharacters(in: .whitespaces)
                return ("\(indent)\(number + 1)\(delimiter) ", rest.isEmpty)
            }
            if let m = quoteRegex.firstMatch(in: line, range: full) {
                let prefix = nsLine.substring(with: m.range(at: 1))
                let rest = nsLine.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespaces)
                return (prefix, rest.isEmpty)
            }
            return nil
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            guard !isUpdating else { return }

            let newText = textView.string
            parent.text = newText

            if parent.syntaxHighlighting {
                debounceWorkItem?.cancel()

                let workItem = DispatchWorkItem { [weak self] in
                    guard let self = self else { return }
                    self.applyHighlighting(to: textView, text: newText)
                }
                debounceWorkItem = workItem
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: workItem)
            }
        }

        private func applyHighlighting(to textView: NSTextView, text: String) {
            isUpdating = true
            defer { isUpdating = false }

            let selectedRanges = textView.selectedRanges
            let attributed = highlighter.highlight(markdown: text, font: parent.font, theme: parent.editorTheme)

            textView.textStorage?.beginEditing()
            textView.textStorage?.setAttributedString(attributed)
            textView.textStorage?.endEditing()

            let nsText = textView.string as NSString
            let length = nsText.length
            let validRanges = selectedRanges.compactMap { rangeValue -> NSValue? in
                let range = rangeValue.rangeValue
                guard range.location <= length else { return nil }
                let adjustedLength = min(range.length, length - range.location)
                return NSValue(range: NSRange(location: range.location, length: adjustedLength))
            }
            if !validRanges.isEmpty {
                textView.selectedRanges = validRanges
            }
        }
    }
}

struct PreviewPane: View {
    @Environment(AppState.self) private var appState
    
    var body: some View {
        MarkdownPreviewView(
            markdown: appState.currentDocument?.content ?? "",
            baseURL: appState.currentDocument?.fileURL?.deletingLastPathComponent(),
            theme: PreviewTheme(rawValue: appState.settings.previewTheme) ?? .github
        )
    }
}

struct MarkdownPreviewView: NSViewRepresentable {
    let markdown: String
    let baseURL: URL?
    let theme: PreviewTheme
    
    private let renderer = MarkdownRenderer()
    
    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.preferences.isTextInteractionEnabled = true
        
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        context.coordinator.webView = webView
        
        let html = renderer.renderToHTML(markdown: markdown, baseURL: baseURL, theme: theme)
        context.coordinator.lastHTML = html
        webView.loadHTMLString(html, baseURL: baseURL)

        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        let html = renderer.renderToHTML(markdown: markdown, baseURL: baseURL, theme: theme)
        // Debounced + scroll-preserving: previously every keystroke reloaded the
        // whole WebView, resetting scroll to the top and re-running Mermaid.
        context.coordinator.scheduleRender(html: html, baseURL: baseURL)
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    class Coordinator: NSObject, WKNavigationDelegate {
        weak var webView: WKWebView?
        var lastHTML: String = ""
        private var pendingScrollY: Double = 0
        private var renderDebounce: DispatchWorkItem?
        private var scrollObserver: NSObjectProtocol?

        override init() {
            super.init()
            scrollObserver = NotificationCenter.default.addObserver(
                forName: .scrollToHeading,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let headingText = notification.object as? String else { return }
                self?.scrollToHeading(headingText)
            }
        }

        deinit {
            if let observer = scrollObserver {
                NotificationCenter.default.removeObserver(observer)
            }
        }

        /// Debounces preview rebuilds and restores the prior scroll offset after
        /// the reload, so typing in split view doesn't jump the preview to the top.
        func scheduleRender(html: String, baseURL: URL?) {
            guard html != lastHTML else { return }
            renderDebounce?.cancel()
            let work = DispatchWorkItem { [weak self] in
                guard let self = self, let webView = self.webView else { return }
                webView.evaluateJavaScript("window.scrollY") { value, _ in
                    self.pendingScrollY = (value as? Double) ?? 0
                    self.lastHTML = html
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

        private func scrollToHeading(_ headingText: String) {
            // Shared slug function with the renderer so the anchor id matches
            // (the old per-side normalizations diverged and broke on non-ASCII
            // headings such as Korean).
            let headingId = markdownHeadingSlug(headingText)

            let js = """
            (function() {
                var el = document.getElementById('\(headingId)');
                if (el) {
                    el.scrollIntoView({ behavior: 'smooth', block: 'start' });
                }
            })();
            """
            webView?.evaluateJavaScript(js, completionHandler: nil)
        }

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
            
            return .allow
        }
    }
}

struct WelcomeView: View {
    @Environment(AppState.self) private var appState
    
    var body: some View {
        VStack(spacing: 32) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)
            
            VStack(spacing: 8) {
                Text("CmdMD")
                    .font(.largeTitle.bold())
                
                Text("Fast Markdown Viewer & Vault Router")
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
            
            VStack(spacing: 12) {
                WelcomeButton(
                    title: "Open File",
                    subtitle: "Open a Markdown file",
                    icon: "doc.badge.plus",
                    shortcut: "⌘O"
                ) {
                    appState.openFile()
                }
                
                WelcomeButton(
                    title: "New Draft",
                    subtitle: "Start writing a new note",
                    icon: "square.and.pencil",
                    shortcut: "⌘N"
                ) {
                    appState.createNewDraft()
                }
                
                WelcomeButton(
                    title: "Open Folder",
                    subtitle: "Browse a folder of Markdown files",
                    icon: "folder.badge.plus",
                    shortcut: "⇧⌘O"
                ) {
                    appState.openFolder()
                }
                
                WelcomeButton(
                    title: "Add Vault",
                    subtitle: "Configure an Obsidian vault",
                    icon: "folder.badge.gearshape",
                    shortcut: nil
                ) {
                    appState.showVaultManager = true
                }
            }
            .frame(maxWidth: 320)
            
            if !appState.recentFiles.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Recent Files")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                    
                    ForEach(appState.recentFiles.prefix(5), id: \.self) { url in
                        Button {
                            appState.openDocument(at: url)
                        } label: {
                            HStack {
                                Image(systemName: "doc.text")
                                    .foregroundStyle(.secondary)
                                Text(url.lastPathComponent)
                                    .lineLimit(1)
                                Spacer()
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: 320)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }
}

struct WelcomeButton: View {
    let title: String
    let subtitle: String
    let icon: String
    let shortcut: String?
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.title2)
                    .frame(width: 32)
                    .foregroundStyle(.blue)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                Spacer()
                
                if let shortcut = shortcut {
                    Text(shortcut)
                        .font(.caption.monospaced())
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}

extension Notification.Name {
    static let openInternalLink = Notification.Name("openInternalLink")
    static let scrollToHeading = Notification.Name("scrollToHeading")
}

#if !SWIFT_PACKAGE
#Preview {
    MainEditorView()
        .environment(AppState())
        .frame(width: 800, height: 600)
}
#endif
