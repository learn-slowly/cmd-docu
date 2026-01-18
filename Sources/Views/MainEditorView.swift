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
                    DocumentEditorView(document: document)
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
                        font: .monospacedSystemFont(ofSize: appState.settings.fontSize, weight: .regular),
                        syntaxHighlighting: true,
                        editorTheme: theme,
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
                    font: .monospacedSystemFont(ofSize: appState.settings.fontSize, weight: .regular),
                    syntaxHighlighting: true,
                    editorTheme: theme,
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
    var onImageDrop: ((URL) -> Void)?
    
    private let highlighter = SyntaxHighlighter()
    
    init(text: Binding<String>, font: NSFont, syntaxHighlighting: Bool = true, editorTheme: EditorTheme = .oneDark, onImageDrop: ((URL) -> Void)? = nil) {
        self._text = text
        self.font = font
        self.syntaxHighlighting = syntaxHighlighting
        self.editorTheme = editorTheme
        self.onImageDrop = onImageDrop
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
            
            let validRanges = selectedRanges.compactMap { rangeValue -> NSValue? in
                let range = rangeValue.rangeValue
                if range.location <= text.count {
                    let adjustedLength = min(range.length, text.count - range.location)
                    return NSValue(range: NSRange(location: range.location, length: adjustedLength))
                }
                return nil
            }
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
        private var scrollObserver: NSObjectProtocol?
        weak var textView: NSTextView?
        
        init(_ parent: MarkdownTextEditor) {
            self.parent = parent
            self.currentTheme = parent.editorTheme
            super.init()
            
            scrollObserver = NotificationCenter.default.addObserver(
                forName: .scrollToLine,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard let lineNumber = notification.object as? Int else { return }
                self?.scrollToLine(lineNumber)
            }
        }
        
        deinit {
            if let observer = scrollObserver {
                NotificationCenter.default.removeObserver(observer)
            }
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
                characterIndex += line.count + 1
            }
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
            
            let validRanges = selectedRanges.compactMap { rangeValue -> NSValue? in
                let range = rangeValue.rangeValue
                if range.location <= text.count {
                    let adjustedLength = min(range.length, text.count - range.location)
                    return NSValue(range: NSRange(location: range.location, length: adjustedLength))
                }
                return nil
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
        webView.loadHTMLString(html, baseURL: baseURL)
        
        return webView
    }
    
    func updateNSView(_ webView: WKWebView, context: Context) {
        let html = renderer.renderToHTML(markdown: markdown, baseURL: baseURL, theme: theme)
        webView.loadHTMLString(html, baseURL: baseURL)
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    class Coordinator: NSObject, WKNavigationDelegate {
        weak var webView: WKWebView?
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
        
        private func scrollToHeading(_ headingText: String) {
            let headingId = headingText
                .lowercased()
                .replacingOccurrences(of: " ", with: "-")
                .components(separatedBy: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-")).inverted)
                .joined()
            
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

#Preview {
    MainEditorView()
        .environment(AppState())
        .frame(width: 800, height: 600)
}
