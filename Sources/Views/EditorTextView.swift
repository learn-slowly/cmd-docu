import SwiftUI
import AppKit

extension Notification.Name {
    static let editorDidScroll = Notification.Name("editorDidScroll")
}

// MARK: - Line Index

/// Caches newline offsets (UTF-16) so line numbers, caret position, and
/// scroll-to-line are O(log n) lookups instead of rescanning the document.
final class LineIndex {
    private(set) var newlinePositions: [Int] = []

    func rebuild(from text: NSString) {
        var positions: [Int] = []
        let length = text.length
        guard length > 0 else {
            newlinePositions = []
            return
        }
        var buffer = [unichar](repeating: 0, count: length)
        text.getCharacters(&buffer, range: NSRange(location: 0, length: length))
        for i in 0..<length where buffer[i] == 0x0A {
            positions.append(i)
        }
        newlinePositions = positions
    }

    var lineCount: Int { newlinePositions.count + 1 }

    /// 1-based line number containing the given UTF-16 location.
    func lineNumber(at location: Int) -> Int {
        var low = 0, high = newlinePositions.count
        while low < high {
            let mid = (low + high) / 2
            if newlinePositions[mid] < location { low = mid + 1 } else { high = mid }
        }
        return low + 1
    }

    /// UTF-16 offset where the given 1-based line starts.
    func startLocation(ofLine line: Int) -> Int {
        guard line > 1 else { return 0 }
        let index = line - 2
        guard index < newlinePositions.count else {
            return newlinePositions.last.map { $0 + 1 } ?? 0
        }
        return newlinePositions[index] + 1
    }

    func lineAndColumn(at location: Int) -> (line: Int, column: Int) {
        let line = lineNumber(at: location)
        return (line, location - startLocation(ofLine: line) + 1)
    }
}

// MARK: - Text View

/// NSTextView with current-line highlighting.
final class CmdMDTextView: NSTextView {
    var highlightCurrentLine = false
    var currentLineColor: NSColor = .clear

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)

        guard highlightCurrentLine,
              selectedRange().length == 0,
              let layoutManager, let textContainer else { return }

        let caret = selectedRange().location
        let ns = string as NSString

        var lineRect: NSRect
        if ns.length == 0 {
            let height = layoutManager.defaultLineHeight(for: font ?? .monospacedSystemFont(ofSize: 14, weight: .regular))
            lineRect = NSRect(x: 0, y: 0, width: bounds.width, height: height)
        } else if caret >= ns.length && ns.character(at: ns.length - 1) == 0x0A {
            // Caret on the trailing empty line after a final newline.
            lineRect = layoutManager.extraLineFragmentRect
        } else {
            let clamped = min(caret, ns.length - 1)
            let lineCharRange = ns.lineRange(for: NSRange(location: clamped, length: 0))
            let glyphRange = layoutManager.glyphRange(forCharacterRange: lineCharRange, actualCharacterRange: nil)
            lineRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
        }

        lineRect.origin.x = 0
        lineRect.origin.y += textContainerInset.height
        lineRect.size.width = bounds.width

        guard rect.intersects(lineRect) else { return }
        currentLineColor.setFill()
        lineRect.fill()
    }
}

// MARK: - Line Number Ruler

/// A real NSRulerView gutter. Unlike the old separate ScrollView of Text views,
/// this stays aligned with wrapped lines, scrolls with the text, and costs
/// nothing for offscreen lines.
final class LineNumberRulerView: NSRulerView {
    private weak var textView: NSTextView?
    private let lineIndex: LineIndex

    var numberColor: NSColor = .secondaryLabelColor { didSet { needsDisplay = true } }
    var gutterColor: NSColor = .clear { didSet { needsDisplay = true } }

    private let numberFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)

    init(textView: NSTextView, lineIndex: LineIndex) {
        self.textView = textView
        self.lineIndex = lineIndex
        super.init(scrollView: textView.enclosingScrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 44
    }

    required init(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func refreshThickness() {
        let digits = max(2, String(lineIndex.lineCount).count)
        let charWidth = ("8" as NSString).size(withAttributes: [.font: numberFont]).width
        let needed = ceil(CGFloat(digits) * charWidth) + 20
        if abs(needed - ruleThickness) > 0.5 {
            ruleThickness = needed
        }
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        gutterColor.setFill()
        bounds.fill()

        guard let textView,
              let layoutManager = textView.layoutManager,
              let container = textView.textContainer else { return }

        let attributes: [NSAttributedString.Key: Any] = [
            .font: numberFont,
            .foregroundColor: numberColor
        ]

        func draw(_ number: Int, atTextViewY y: CGFloat, fragmentHeight: CGFloat) {
            let str = NSAttributedString(string: "\(number)", attributes: attributes)
            let size = str.size()
            let point = convert(NSPoint(x: 0, y: y), from: textView)
            str.draw(at: NSPoint(
                x: ruleThickness - size.width - 10,
                y: point.y + (fragmentHeight - size.height) / 2
            ))
        }

        let content = textView.string as NSString
        let inset = textView.textContainerInset

        if content.length == 0 {
            let height = layoutManager.defaultLineHeight(for: textView.font ?? .monospacedSystemFont(ofSize: 14, weight: .regular))
            draw(1, atTextViewY: inset.height, fragmentHeight: height)
            return
        }

        // Glyph rects live in container coordinates (no inset), the visible
        // rect is in view coordinates — offset before asking for glyphs.
        let visibleRect = textView.visibleRect.offsetBy(dx: -inset.width, dy: -inset.height)
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: container)

        var glyphIndex = glyphRange.location
        while glyphIndex < NSMaxRange(glyphRange) {
            let charIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
            let lineCharRange = content.lineRange(for: NSRange(location: charIndex, length: 0))
            let lineGlyphRange = layoutManager.glyphRange(forCharacterRange: lineCharRange, actualCharacterRange: nil)

            var effectiveRange = NSRange()
            let fragmentRect = layoutManager.lineFragmentRect(
                forGlyphAt: lineGlyphRange.location,
                effectiveRange: &effectiveRange,
                withoutAdditionalLayout: true
            )

            let lineNumber = lineIndex.lineNumber(at: lineCharRange.location)
            draw(lineNumber, atTextViewY: fragmentRect.minY + inset.height, fragmentHeight: fragmentRect.height)

            glyphIndex = max(NSMaxRange(lineGlyphRange), glyphIndex + 1)
        }

        // Trailing empty line (document ends with a newline).
        if layoutManager.extraLineFragmentTextContainer != nil {
            let fragmentRect = layoutManager.extraLineFragmentRect
            draw(lineIndex.lineCount, atTextViewY: fragmentRect.minY + inset.height, fragmentHeight: fragmentRect.height)
        }
    }
}

// MARK: - Editor Representable

struct MarkdownTextEditor: NSViewRepresentable {
    /// Identity of the document being edited. A change means a tab switch, which
    /// resets undo/scroll/selection (vs. an in-place text edit or disk reload).
    let documentID: UUID?
    @Binding var text: String
    let font: NSFont
    let editorTheme: EditorTheme
    let softWrap: Bool
    let showLineNumbers: Bool
    let highlightCurrentLine: Bool
    let tabSize: Int
    let insertSpacesForTab: Bool
    let enableCompletion: Bool
    let scrollSyncEnabled: Bool
    var onImageDrop: ((URL) -> Void)?
    var onSelectionChange: ((Int, Int) -> Void)?
    var onSelectedTextChange: ((String) -> Void)?
    var completionsProvider: ((CompletionContext) -> [CompletionItem])?

    /// Clamp previously-selected ranges to the current text, measuring in UTF-16
    /// code units (NSRange's unit) rather than grapheme clusters — mixing the two
    /// corrupted selections in documents containing emoji/composed characters.
    static func clampedRanges(_ ranges: [NSValue], to nsString: NSString) -> [NSValue] {
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
        let textView = CmdMDTextView(frame: .zero)
        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false

        textView.autoresizingMask = [.width]
        textView.isVerticallyResizable = true
        textView.minSize = NSSize(width: 0, height: 0)

        context.coordinator.textView = textView
        textView.delegate = context.coordinator
        textView.font = font
        textView.isRichText = true
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isContinuousSpellCheckingEnabled = false
        textView.usesFontPanel = false
        textView.textContainerInset = NSSize(width: 12, height: 12)
        textView.drawsBackground = true

        // Native find/replace bar (⌘F / ⌘⌥F).
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true

        applyWrapMode(to: textView, scrollView: scrollView)
        applyTheme(to: textView, scrollView: scrollView)

        textView.registerForDraggedTypes([.fileURL, .png, .tiff])

        textView.string = text
        context.coordinator.currentDocumentID = documentID
        context.coordinator.lineIndex.rebuild(from: text as NSString)
        context.coordinator.applyHighlightingNow()

        // Line-number gutter.
        let ruler = LineNumberRulerView(textView: textView, lineIndex: context.coordinator.lineIndex)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = showLineNumbers
        context.coordinator.rulerView = ruler
        applyRulerTheme(ruler)
        ruler.refreshThickness()

        // Scroll-sync + ruler redraw on scroll.
        scrollView.contentView.postsBoundsChangedNotifications = true
        context.coordinator.observeScroll(of: scrollView)

        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? CmdMDTextView else { return }
        context.coordinator.parent = self

        applyTheme(to: textView, scrollView: nsView)
        textView.font = font
        applyWrapMode(to: textView, scrollView: nsView)

        nsView.rulersVisible = showLineNumbers
        if let ruler = context.coordinator.rulerView {
            applyRulerTheme(ruler)
        }

        let documentSwitch = context.coordinator.currentDocumentID != documentID
        let externalChange = textView.string != text
        let themeChange = context.coordinator.currentTheme != editorTheme
            || context.coordinator.currentFontPointSize != font.pointSize
            || context.coordinator.currentFontName != font.fontName

        if documentSwitch {
            // Tab switch: reuse this NSTextView (no teardown) but reset its
            // editing state so undo history, scroll, and selection don't bleed
            // across documents.
            context.coordinator.currentDocumentID = documentID
            textView.textStorage?.replaceCharacters(
                in: NSRange(location: 0, length: (textView.string as NSString).length),
                with: text
            )
            context.coordinator.lineIndex.rebuild(from: text as NSString)
            context.coordinator.rulerView?.refreshThickness()
            context.coordinator.applyHighlightingNow()
            textView.undoManager?.removeAllActions()
            textView.setSelectedRange(NSRange(location: 0, length: 0))
            textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
            context.coordinator.resetScrollTracking()
        } else if externalChange {
            // Same document, different text: a disk reload or programmatic update.
            // Preserve the caret/selection.
            let selectedRanges = textView.selectedRanges
            textView.textStorage?.replaceCharacters(
                in: NSRange(location: 0, length: (textView.string as NSString).length),
                with: text
            )
            context.coordinator.lineIndex.rebuild(from: text as NSString)
            context.coordinator.rulerView?.refreshThickness()
            context.coordinator.applyHighlightingNow()

            let validRanges = Self.clampedRanges(selectedRanges, to: textView.string as NSString)
            if !validRanges.isEmpty {
                textView.selectedRanges = validRanges
            }
        } else if themeChange {
            context.coordinator.currentTheme = editorTheme
            context.coordinator.currentFontPointSize = font.pointSize
            context.coordinator.currentFontName = font.fontName
            context.coordinator.applyHighlightingNow()
        }
    }

    static func dismantleNSView(_ nsView: NSScrollView, coordinator: Coordinator) {
        coordinator.tearDown()
    }

    private func applyTheme(to textView: CmdMDTextView, scrollView: NSScrollView) {
        textView.backgroundColor = NSColor(editorTheme.backgroundColor)
        textView.insertionPointColor = NSColor(editorTheme.cursorColor)
        textView.selectedTextAttributes = [
            .backgroundColor: NSColor(editorTheme.selectionColor)
        ]
        textView.highlightCurrentLine = highlightCurrentLine
        textView.currentLineColor = NSColor(editorTheme.currentLineColor).withAlphaComponent(0.35)
        scrollView.backgroundColor = NSColor(editorTheme.backgroundColor)
    }

    private func applyRulerTheme(_ ruler: LineNumberRulerView) {
        ruler.numberColor = NSColor(editorTheme.lineNumberColor)
        ruler.gutterColor = NSColor(editorTheme.backgroundColor)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    // MARK: Coordinator

    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownTextEditor
        var currentTheme: EditorTheme
        var currentDocumentID: UUID?
        var currentFontPointSize: CGFloat = 0
        var currentFontName: String = ""
        weak var textView: CmdMDTextView?
        weak var rulerView: LineNumberRulerView?
        let lineIndex = LineIndex()

        private let highlighter = SyntaxHighlighter()
        private var highlightDebounce: DispatchWorkItem?
        private var observers: [NSObjectProtocol] = []
        private let completionPopup = CompletionWindowController()
        private var activeCompletionContext: CompletionContext?
        private var lastSentScrollFraction: Double = -1

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
            observers.append(center.addObserver(forName: .insertClaudeResponse, object: nil, queue: .main) { [weak self] note in
                guard let text = note.object as? String else { return }
                self?.insertPlainText(text)
            })
            observers.append(center.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { [weak self] note in
                guard let self, let window = self.textView?.window, (note.object as? NSWindow) === window else { return }
                self.completionPopup.dismiss()
            })
        }

        deinit {
            tearDown()
        }

        func tearDown() {
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers = []
            completionPopup.dismiss()
            highlightDebounce?.cancel()
        }

        func observeScroll(of scrollView: NSScrollView) {
            observers.append(NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self] _ in
                self?.handleScrollChanged()
            })
        }

        private func handleScrollChanged() {
            rulerView?.needsDisplay = true
            postScrollFraction()
        }

        /// Resets scroll-sync state after a document switch so the new document's
        /// scroll position re-syncs cleanly instead of inheriting the prior fraction.
        func resetScrollTracking() {
            lastSentScrollFraction = -1
        }

        private func postScrollFraction() {
            guard parent.scrollSyncEnabled,
                  let textView,
                  let scrollView = textView.enclosingScrollView else { return }
            let clip = scrollView.contentView
            let maxOffset = max(1, textView.frame.height - clip.bounds.height)
            let fraction = min(1, max(0, clip.bounds.origin.y / maxOffset))
            guard abs(fraction - lastSentScrollFraction) > 0.001 else { return }
            lastSentScrollFraction = fraction
            NotificationCenter.default.post(name: .editorDidScroll, object: fraction)
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
            let length = (textView.string as NSString).length
            let location = min(lineIndex.startLocation(ofLine: lineNumber), length)
            let range = NSRange(location: location, length: 0)
            textView.scrollRangeToVisible(range)
            textView.setSelectedRange(range)
            textView.window?.makeFirstResponder(textView)
        }

        // MARK: Markdown formatting

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

        /// Claude 응답 등 외부에서 만든 텍스트를 커서 위치에 그대로 삽입한다.
        /// Claude 패널의 버튼에서 오는 요청이라 포맷 단축키(wrapSelection 등)와 달리
        /// 에디터가 포커스를 갖고 있지 않아도 삽입해야 한다(isActiveEditor 가드 없음).
        private func insertPlainText(_ text: String) {
            guard let textView else { return }
            let sel = textView.selectedRange()
            guard textView.shouldChangeText(in: sel, replacementString: text) else { return }
            textView.textStorage?.replaceCharacters(in: sel, with: text)
            textView.didChangeText()
            let endLocation = sel.location + (text as NSString).length
            textView.setSelectedRange(NSRange(location: endLocation, length: 0))
        }

        // MARK: Key commands

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if completionPopup.isVisible {
                switch commandSelector {
                case #selector(NSResponder.moveDown(_:)):
                    completionPopup.moveSelectionDown()
                    return true
                case #selector(NSResponder.moveUp(_:)):
                    completionPopup.moveSelectionUp()
                    return true
                case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)):
                    completionPopup.confirmSelection()
                    return true
                case #selector(NSResponder.cancelOperation(_:)):
                    completionPopup.dismiss()
                    activeCompletionContext = nil
                    return true
                default:
                    break
                }
            }

            if commandSelector == #selector(NSResponder.insertTab(_:)), parent.insertSpacesForTab {
                let spaces = String(repeating: " ", count: max(1, parent.tabSize))
                textView.insertText(spaces, replacementRange: textView.selectedRange())
                return true
            }

            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                return handleNewline(in: textView)
            }
            return false
        }

        // MARK: Smart list continuation

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

        // MARK: Text change

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }

            let newText = textView.string
            parent.text = newText

            lineIndex.rebuild(from: newText as NSString)
            rulerView?.refreshThickness()
            rulerView?.needsDisplay = true

            reportSelection(of: textView)
            updateCompletion(in: textView)
            scheduleHighlighting(for: textView)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            reportSelection(of: textView)
            // Repaint for the current-line highlight.
            textView.needsDisplay = true

            if completionPopup.isVisible {
                let sel = textView.selectedRange()
                let context = sel.length == 0
                    ? CompletionService.detectContext(in: textView.string as NSString, cursorLocation: sel.location)
                    : nil
                if context == nil || context?.range.location != activeCompletionContext?.range.location {
                    completionPopup.dismiss()
                    activeCompletionContext = nil
                }
            }
        }

        private func reportSelection(of textView: NSTextView) {
            let range = textView.selectedRange()
            if let onSelectedTextChange = parent.onSelectedTextChange {
                let selected = range.length > 0
                    ? (textView.string as NSString).substring(with: range)
                    : ""
                onSelectedTextChange(selected)
            }
            guard let onSelectionChange = parent.onSelectionChange else { return }
            let (line, column) = lineIndex.lineAndColumn(at: range.location)
            onSelectionChange(line, column)
        }

        // MARK: Highlighting

        func applyHighlightingNow() {
            guard let textView, let storage = textView.textStorage else { return }
            highlighter.applyHighlights(to: storage, font: parent.font, theme: parent.editorTheme)
        }

        private func scheduleHighlighting(for textView: NSTextView) {
            highlightDebounce?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                self?.applyHighlightingNow()
            }
            highlightDebounce = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: workItem)
        }

        // MARK: Completion

        private func updateCompletion(in textView: NSTextView) {
            guard parent.enableCompletion, let provider = parent.completionsProvider else {
                completionPopup.dismiss()
                return
            }

            let sel = textView.selectedRange()
            guard sel.length == 0,
                  let context = CompletionService.detectContext(in: textView.string as NSString, cursorLocation: sel.location) else {
                completionPopup.dismiss()
                activeCompletionContext = nil
                return
            }

            let items = provider(context)
            guard !items.isEmpty else {
                completionPopup.dismiss()
                activeCompletionContext = nil
                return
            }

            activeCompletionContext = context
            let caretRect = textView.firstRect(forCharacterRange: NSRange(location: sel.location, length: 0), actualRange: nil)
            completionPopup.show(
                items: items,
                at: NSPoint(x: caretRect.minX, y: caretRect.minY - 4),
                in: textView.window
            ) { [weak self] item in
                self?.acceptCompletion(item)
            }
        }

        private func acceptCompletion(_ item: CompletionItem) {
            guard let textView, let context = activeCompletionContext else { return }
            activeCompletionContext = nil

            let replacement = context.replacement(for: item)
            let length = (textView.string as NSString).length
            guard context.range.location + context.range.length <= length,
                  textView.shouldChangeText(in: context.range, replacementString: replacement) else { return }

            textView.textStorage?.replaceCharacters(in: context.range, with: replacement)
            textView.didChangeText()
            textView.setSelectedRange(NSRange(location: context.range.location + (replacement as NSString).length, length: 0))
        }
    }
}
