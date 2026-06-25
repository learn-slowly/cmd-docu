import Foundation
import SwiftUI
import Yams

// MARK: - Document Model
struct MarkdownDocument: Identifiable, Equatable, Codable {
    let id: UUID
    var title: String
    var content: String
    var fileURL: URL?
    var createdAt: Date
    var modifiedAt: Date
    var frontmatter: Frontmatter?
    var isDraft: Bool
    var sourceDevice: String?
    
    init(
        id: UUID = UUID(),
        title: String = "Untitled",
        content: String = "",
        fileURL: URL? = nil,
        createdAt: Date = Date(),
        modifiedAt: Date = Date(),
        frontmatter: Frontmatter? = nil,
        isDraft: Bool = false,
        sourceDevice: String? = nil
    ) {
        self.id = id
        self.title = title
        self.content = content
        self.fileURL = fileURL
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.frontmatter = frontmatter
        self.isDraft = isDraft
        self.sourceDevice = sourceDevice
    }
    
    // Extract title from content if not set
    var displayTitle: String {
        if !title.isEmpty && title != "Untitled" {
            return title
        }
        // Try to extract first heading
        let lines = content.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("# ") {
                return String(trimmed.dropFirst(2))
            }
        }
        // Use filename if available
        if let url = fileURL {
            return url.deletingPathExtension().lastPathComponent
        }
        return "Untitled"
    }
    
    // Word count
    var wordCount: Int {
        let words = content.components(separatedBy: .whitespacesAndNewlines)
        return words.filter { !$0.isEmpty }.count
    }
    
    // Character count
    var characterCount: Int {
        content.count
    }

    /// The complete on-disk representation: frontmatter block (if any) + body.
    /// `content` is kept body-only after parsing, so this is the single source of
    /// truth for what gets written to disk / exported / sent. We intentionally do
    /// NOT guard on `content.hasPrefix("---")`: a body legitimately starting with a
    /// `---` horizontal rule must not suppress the frontmatter block (that would
    /// silently drop the document's metadata on save).
    var fullText: String {
        guard let frontmatter = frontmatter else { return content }
        let yaml = frontmatter.toYAML()
        guard !yaml.isEmpty else { return content }
        return yaml + "\n\n" + content
    }
}

// MARK: - Frontmatter Value (type-preserving for custom keys)

/// Preserves the original YAML type of a custom frontmatter value so that
/// booleans, numbers, and lists survive a parse -> edit -> serialize round-trip
/// instead of being flattened to strings or dropped (a data-loss bug against
/// Obsidian vaults). UI edits set `.string(...)`; untouched keys keep their type.
enum FrontmatterValue: Equatable, Codable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case list([String])

    /// Human-readable form used by the Properties editor.
    var displayString: String {
        switch self {
        case .string(let s): return s
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        case .bool(let b): return b ? "true" : "false"
        case .list(let arr): return arr.joined(separator: ", ")
        }
    }

    /// Native value handed to Yams so it emits the correct YAML scalar/sequence.
    var yamlValue: Any {
        switch self {
        case .string(let s): return s
        case .int(let i): return i
        case .double(let d): return d
        case .bool(let b): return b
        case .list(let arr): return arr
        }
    }

    /// Build from a value produced by `Yams.load`. Bool is checked before Int
    /// to avoid NSNumber bridging collapsing `true`/`false` into 1/0.
    init(yaml value: Any) {
        switch value {
        case let b as Bool: self = .bool(b)
        case let i as Int: self = .int(i)
        case let d as Double: self = .double(d)
        case let arr as [Any]: self = .list(arr.map { String(describing: $0) })
        case let s as String: self = .string(s)
        default: self = .string(String(describing: value))
        }
    }
}

// MARK: - Frontmatter
struct Frontmatter: Equatable, Codable {
    var title: String?
    var date: Date?
    var tags: [String]
    var aliases: [String]
    var cssclass: String?
    var custom: [String: FrontmatterValue]

    init(
        title: String? = nil,
        date: Date? = nil,
        tags: [String] = [],
        aliases: [String] = [],
        cssclass: String? = nil,
        custom: [String: FrontmatterValue] = [:]
    ) {
        self.title = title
        self.date = date
        self.tags = tags
        self.aliases = aliases
        self.cssclass = cssclass
        self.custom = custom
    }

    /// Generate a `---`-delimited YAML block. Values are emitted through Yams so
    /// quoting/escaping is spec-correct (a stray quote no longer produces invalid
    /// YAML that wipes the whole block on reload). Keys are emitted in a stable
    /// order (known keys first, then custom keys sorted) for clean diffs.
    func toYAML() -> String {
        var entries: [(String, Any)] = []
        if let title = title, !title.isEmpty { entries.append(("title", title)) }
        if let date = date {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withFullDate]
            entries.append(("date", formatter.string(from: date)))
        }
        if !tags.isEmpty { entries.append(("tags", tags)) }
        if !aliases.isEmpty { entries.append(("aliases", aliases)) }
        if let cssclass = cssclass, !cssclass.isEmpty { entries.append(("cssclass", cssclass)) }
        for key in custom.keys.sorted() {
            if let value = custom[key] { entries.append((key, value.yamlValue)) }
        }

        guard !entries.isEmpty else { return "" }

        var body = ""
        for (key, value) in entries {
            if let fragment = try? Yams.dump(object: [key: value]) {
                body += fragment
            }
        }
        let trimmed = body.hasSuffix("\n") ? String(body.dropLast()) : body
        return "---\n\(trimmed)\n---"
    }
}

// MARK: - Draft (for iPhone-Mac sync)
struct Draft: Identifiable, Equatable, Codable {
    let id: UUID
    var title: String
    var body: String
    var createdAt: Date
    var updatedAt: Date
    var sourceDevice: String
    var tags: [String]
    var status: DraftStatus
    var attachments: [DraftAttachment]
    
    init(
        id: UUID = UUID(),
        title: String = "",
        body: String = "",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        sourceDevice: String = Host.current().localizedName ?? "Mac",
        tags: [String] = [],
        status: DraftStatus = .active,
        attachments: [DraftAttachment] = []
    ) {
        self.id = id
        self.title = title
        self.body = body
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.sourceDevice = sourceDevice
        self.tags = tags
        self.status = status
        self.attachments = attachments
    }
    
    var displayTitle: String {
        if !title.isEmpty {
            return title
        }
        let lines = body.components(separatedBy: .newlines)
        if let first = lines.first, !first.isEmpty {
            return String(first.prefix(50))
        }
        return "Untitled Draft"
    }
    
    // Convert to MarkdownDocument
    func toDocument() -> MarkdownDocument {
        MarkdownDocument(
            id: id,
            title: displayTitle,
            content: body,
            createdAt: createdAt,
            modifiedAt: updatedAt,
            isDraft: true,
            sourceDevice: sourceDevice
        )
    }
}

enum DraftStatus: String, Codable, CaseIterable {
    case active = "Active"
    case sent = "Sent"
    case archived = "Archived"
}

struct DraftAttachment: Identifiable, Equatable, Codable {
    let id: UUID
    var filename: String
    var data: Data
    var mimeType: String
    
    init(id: UUID = UUID(), filename: String, data: Data, mimeType: String) {
        self.id = id
        self.filename = filename
        self.data = data
        self.mimeType = mimeType
    }
}

