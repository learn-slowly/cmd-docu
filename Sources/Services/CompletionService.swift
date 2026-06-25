import Foundation

// MARK: - Completion Types

struct CompletionItem: Identifiable, Equatable {
    let id = UUID()
    /// Raw value inserted into the document (note title or tag name).
    let text: String
    let displayText: String
    let detail: String?
    let type: CompletionContext.Kind
}

struct CompletionContext: Equatable {
    enum Kind {
        case wikiLink
        case tag
    }

    let type: Kind
    let query: String
    /// UTF-16 range in the document from the trigger ("[[" or "#") through the
    /// caret. Replaced wholesale when a completion is accepted.
    let range: NSRange

    /// The full text to insert when `item` is accepted.
    func replacement(for item: CompletionItem) -> String {
        switch type {
        case .wikiLink: return "[[\(item.text)]]"
        case .tag: return "#\(item.text) "
        }
    }
}

// MARK: - Completion Engine

/// Stateless completion logic. All offsets are UTF-16 (NSRange's unit) — the
/// previous implementation mixed grapheme-cluster counts with NSRange, which
/// corrupted replacements in documents containing emoji or Korean text.
enum CompletionService {
    static let maxResults = 12

    /// Detects whether the caret sits inside an unclosed "[[…" or "#…" run on
    /// the current line.
    static func detectContext(in text: NSString, cursorLocation: Int) -> CompletionContext? {
        guard cursorLocation > 0, cursorLocation <= text.length else { return nil }

        let lineRange = text.lineRange(for: NSRange(location: min(cursorLocation, max(0, text.length - 1)), length: 0))
        let lineStart = lineRange.location
        guard cursorLocation >= lineStart else { return nil }
        let searchRange = NSRange(location: lineStart, length: cursorLocation - lineStart)

        // Wiki link: last "[[" before the caret with no closing "]]" after it.
        let wikiOpen = text.range(of: "[[", options: .backwards, range: searchRange)
        if wikiOpen.location != NSNotFound {
            let queryStart = wikiOpen.location + 2
            let queryRange = NSRange(location: queryStart, length: cursorLocation - queryStart)
            let query = text.substring(with: queryRange)
            if !query.contains("]]") {
                return CompletionContext(
                    type: .wikiLink,
                    query: query,
                    range: NSRange(location: wikiOpen.location, length: cursorLocation - wikiOpen.location)
                )
            }
        }

        // Tag: "#" preceded by start-of-line/whitespace, no whitespace after it.
        let hash = text.range(of: "#", options: .backwards, range: searchRange)
        if hash.location != NSNotFound {
            let validStart: Bool
            if hash.location == lineStart {
                validStart = true
            } else {
                let before = text.character(at: hash.location - 1)
                validStart = before == 0x20 || before == 0x09 // space or tab
            }

            if validStart {
                let queryStart = hash.location + 1
                let query = text.substring(with: NSRange(location: queryStart, length: cursorLocation - queryStart))
                if !query.contains(" ") && !query.contains("\t") && !query.contains("#") {
                    return CompletionContext(
                        type: .tag,
                        query: query,
                        range: NSRange(location: hash.location, length: cursorLocation - hash.location)
                    )
                }
            }
        }

        return nil
    }

    static func completions(for context: CompletionContext, notes: [VaultNote], tags: Set<String>) -> [CompletionItem] {
        switch context.type {
        case .wikiLink:
            return wikiLinkCompletions(query: context.query, notes: notes)
        case .tag:
            return tagCompletions(query: context.query, tags: tags)
        }
    }

    private static func wikiLinkCompletions(query: String, notes: [VaultNote]) -> [CompletionItem] {
        let lowered = query.lowercased()

        let matches: [VaultNote]
        if lowered.isEmpty {
            // Bare "[[" shows the most recently modified notes.
            matches = Array(notes.prefix(maxResults))
        } else {
            matches = notes.filter {
                $0.title.lowercased().contains(lowered) || $0.path.lowercased().contains(lowered)
            }
        }

        return matches
            .sorted { lhs, rhs in
                let lhsPrefix = lhs.title.lowercased().hasPrefix(lowered)
                let rhsPrefix = rhs.title.lowercased().hasPrefix(lowered)
                if lhsPrefix != rhsPrefix { return lhsPrefix }
                return lhs.modifiedAt > rhs.modifiedAt
            }
            .prefix(maxResults)
            .map { CompletionItem(text: $0.title, displayText: $0.title, detail: $0.path, type: .wikiLink) }
    }

    private static func tagCompletions(query: String, tags: Set<String>) -> [CompletionItem] {
        let lowered = query.lowercased()

        return tags
            .filter { lowered.isEmpty || $0.lowercased().contains(lowered) }
            .sorted { lhs, rhs in
                let lhsPrefix = lhs.lowercased().hasPrefix(lowered)
                let rhsPrefix = rhs.lowercased().hasPrefix(lowered)
                if lhsPrefix != rhsPrefix { return lhsPrefix }
                return lhs < rhs
            }
            .prefix(maxResults)
            .map { CompletionItem(text: $0, displayText: "#\($0)", detail: nil, type: .tag) }
    }
}
