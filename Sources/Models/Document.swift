import Foundation
import SwiftUI

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
}

// MARK: - Frontmatter
struct Frontmatter: Equatable, Codable {
    var title: String?
    var date: Date?
    var tags: [String]
    var aliases: [String]
    var cssclass: String?
    var custom: [String: String]
    
    init(
        title: String? = nil,
        date: Date? = nil,
        tags: [String] = [],
        aliases: [String] = [],
        cssclass: String? = nil,
        custom: [String: String] = [:]
    ) {
        self.title = title
        self.date = date
        self.tags = tags
        self.aliases = aliases
        self.cssclass = cssclass
        self.custom = custom
    }
    
    // Generate YAML string
    func toYAML() -> String {
        var lines: [String] = ["---"]
        
        if let title = title {
            lines.append("title: \"\(title)\"")
        }
        
        if let date = date {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withFullDate]
            lines.append("date: \(formatter.string(from: date))")
        }
        
        if !tags.isEmpty {
            lines.append("tags:")
            for tag in tags {
                lines.append("  - \(tag)")
            }
        }
        
        if !aliases.isEmpty {
            lines.append("aliases:")
            for alias in aliases {
                lines.append("  - \"\(alias)\"")
            }
        }
        
        if let cssclass = cssclass {
            lines.append("cssclass: \(cssclass)")
        }
        
        for (key, value) in custom.sorted(by: { $0.key < $1.key }) {
            lines.append("\(key): \"\(value)\"")
        }
        
        lines.append("---")
        return lines.joined(separator: "\n")
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

// MARK: - Recent File
struct RecentFile: Identifiable, Equatable, Codable {
    var id: URL { url }
    let url: URL
    let accessedAt: Date
    let title: String
}
