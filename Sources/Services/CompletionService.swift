import Foundation
import AppKit

struct CompletionItem: Identifiable, Equatable {
    let id = UUID()
    let text: String
    let displayText: String
    let detail: String?
    let type: CompletionType
    
    enum CompletionType {
        case wikiLink
        case tag
        case template
    }
}

class CompletionService {
    private var vaultNotes: [String: [VaultNote]] = [:]
    private var allTags: Set<String> = []
    
    func updateIndex(vaultId: UUID, notes: [VaultNote]) {
        vaultNotes[vaultId.uuidString] = notes
    }
    
    func addTags(_ tags: [String]) {
        allTags.formUnion(tags)
    }
    
    func completionsForWikiLink(query: String) -> [CompletionItem] {
        let lowercasedQuery = query.lowercased()
        var matches: [CompletionItem] = []
        
        for (_, notes) in vaultNotes {
            for note in notes {
                let matchesTitle = note.title.lowercased().contains(lowercasedQuery)
                let matchesPath = note.path.lowercased().contains(lowercasedQuery)
                
                if matchesTitle || matchesPath {
                    let item = CompletionItem(
                        text: note.title,
                        displayText: note.title,
                        detail: note.path,
                        type: .wikiLink
                    )
                    matches.append(item)
                }
            }
        }
        
        return matches
            .sorted { lhs, rhs in
                let lhsExact = lhs.displayText.lowercased().hasPrefix(lowercasedQuery)
                let rhsExact = rhs.displayText.lowercased().hasPrefix(lowercasedQuery)
                if lhsExact != rhsExact { return lhsExact }
                return lhs.displayText < rhs.displayText
            }
            .prefix(20)
            .map { $0 }
    }
    
    func completionsForTag(query: String) -> [CompletionItem] {
        let lowercasedQuery = query.lowercased()
        
        return allTags
            .filter { $0.lowercased().contains(lowercasedQuery) }
            .sorted { lhs, rhs in
                let lhsExact = lhs.lowercased().hasPrefix(lowercasedQuery)
                let rhsExact = rhs.lowercased().hasPrefix(lowercasedQuery)
                if lhsExact != rhsExact { return lhsExact }
                return lhs < rhs
            }
            .prefix(15)
            .map { tag in
                CompletionItem(
                    text: tag,
                    displayText: "#\(tag)",
                    detail: nil,
                    type: .tag
                )
            }
    }
    
    func detectCompletionContext(in text: String, at cursorPosition: Int) -> CompletionContext? {
        guard cursorPosition > 0 && cursorPosition <= text.count else { return nil }
        
        let textBeforeCursor = String(text.prefix(cursorPosition))
        
        if let wikiLinkMatch = detectWikiLinkContext(in: textBeforeCursor) {
            return wikiLinkMatch
        }
        
        if let tagMatch = detectTagContext(in: textBeforeCursor) {
            return tagMatch
        }
        
        return nil
    }
    
    private func detectWikiLinkContext(in text: String) -> CompletionContext? {
        guard let openBrackets = text.range(of: "[[", options: .backwards) else { return nil }
        
        let afterBrackets = String(text[openBrackets.upperBound...])
        
        guard !afterBrackets.contains("]]") else { return nil }
        guard !afterBrackets.contains("\n") else { return nil }
        
        let query = afterBrackets.trimmingCharacters(in: .whitespaces)
        let startIndex = text.distance(from: text.startIndex, to: openBrackets.lowerBound)
        
        return CompletionContext(
            type: .wikiLink,
            query: query,
            range: NSRange(location: startIndex, length: text.count - startIndex)
        )
    }
    
    private func detectTagContext(in text: String) -> CompletionContext? {
        guard let hashIndex = text.range(of: "#", options: .backwards) else { return nil }
        
        let charBeforeHash = hashIndex.lowerBound > text.startIndex
            ? text[text.index(before: hashIndex.lowerBound)]
            : " "
        
        let isValidTagStart = charBeforeHash == " " || charBeforeHash == "\n" || hashIndex.lowerBound == text.startIndex
        guard isValidTagStart else { return nil }
        
        let afterHash = String(text[hashIndex.upperBound...])
        
        guard !afterHash.contains(" ") else { return nil }
        guard !afterHash.contains("\n") else { return nil }
        
        let query = afterHash
        let startIndex = text.distance(from: text.startIndex, to: hashIndex.lowerBound)
        
        return CompletionContext(
            type: .tag,
            query: query,
            range: NSRange(location: startIndex, length: text.count - startIndex)
        )
    }
}

struct CompletionContext {
    let type: CompletionType
    let query: String
    let range: NSRange
    
    enum CompletionType {
        case wikiLink
        case tag
    }
}
