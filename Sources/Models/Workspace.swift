import Foundation
import SwiftUI

// MARK: - View Mode

enum ViewMode: String, CaseIterable, Codable {
    case source = "Source"
    case split = "Split"
    case preview = "Preview"
}

// MARK: - Launch Defaults

/// Review-first launch posture: open straight into preview with chrome hidden.
struct AppLaunchDefaults: Equatable {
    var viewMode: ViewMode = .preview
    var sidebarVisible: Bool = false
}

// MARK: - Sidebar

enum SidebarTab: String, CaseIterable, Codable {
    case files = "Files"
    case favorites = "Favorites"
    case drafts = "Drafts"
    case recent = "Recent"

    var icon: String {
        switch self {
        case .files: return "folder"
        case .favorites: return "star"
        case .drafts: return "doc.text"
        case .recent: return "clock"
        }
    }
}

// MARK: - Tabs

struct EditorTab: Identifiable, Equatable, Codable {
    let id: UUID
    var documentId: UUID
    var fileURL: URL?
    var title: String
    var isPinned: Bool
    var isDirty: Bool
    var scrollPosition: CGFloat
    var cursorPosition: Int
    var kind: DocumentKind

    init(
        id: UUID = UUID(),
        documentId: UUID = UUID(),
        fileURL: URL? = nil,
        title: String = "Untitled",
        isPinned: Bool = false,
        isDirty: Bool = false,
        scrollPosition: CGFloat = 0,
        cursorPosition: Int = 0,
        kind: DocumentKind = .markdown
    ) {
        self.id = id
        self.documentId = documentId
        self.fileURL = fileURL
        self.title = title
        self.isPinned = isPinned
        self.isDirty = isDirty
        self.scrollPosition = scrollPosition
        self.cursorPosition = cursorPosition
        self.kind = kind
    }

    var displayTitle: String {
        if let url = fileURL {
            return url.deletingPathExtension().lastPathComponent
        }
        return title.isEmpty ? "Untitled" : title
    }

    // EditorTab은 현재 세션에 직접 직렬화되지 않는다(세션은 URL 목록만 저장).
    // 이 커스텀 디코더는 추후 EditorTab을 직접 저장하게 될 때를 대비한 방어로,
    // `kind` 키가 없으면 .markdown 으로 폴백한다.
    // (커스텀 init(from:)만 제공하면 encode(to:)는 합성된다.)
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        documentId = try c.decode(UUID.self, forKey: .documentId)
        fileURL = try c.decodeIfPresent(URL.self, forKey: .fileURL)
        title = try c.decode(String.self, forKey: .title)
        isPinned = try c.decode(Bool.self, forKey: .isPinned)
        isDirty = try c.decode(Bool.self, forKey: .isDirty)
        scrollPosition = try c.decode(CGFloat.self, forKey: .scrollPosition)
        cursorPosition = try c.decode(Int.self, forKey: .cursorPosition)
        kind = try c.decodeIfPresent(DocumentKind.self, forKey: .kind) ?? .markdown
    }
}

// MARK: - Favorites

struct FavoriteItem: Identifiable, Equatable, Codable {
    let id: UUID
    var url: URL
    var addedAt: Date
    var alias: String?

    init(id: UUID = UUID(), url: URL, addedAt: Date = Date(), alias: String? = nil) {
        self.id = id
        self.url = url
        self.addedAt = addedAt
        self.alias = alias
    }

    var displayName: String {
        alias ?? url.deletingPathExtension().lastPathComponent
    }
}

// MARK: - File Tree

struct FileTreeItem: Identifiable, Hashable {
    let id: UUID
    let url: URL
    let isDirectory: Bool
    var isExpanded: Bool
    var children: [FileTreeItem]

    init(url: URL, isDirectory: Bool = false, isExpanded: Bool = false, children: [FileTreeItem] = []) {
        self.id = UUID()
        self.url = url
        self.isDirectory = isDirectory
        self.isExpanded = isExpanded
        self.children = children
    }

    var name: String {
        url.lastPathComponent
    }

    var icon: String {
        if isDirectory {
            return isExpanded ? "folder.fill" : "folder"
        }
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "md", "markdown": return "doc.text"
        case "txt": return "doc.plaintext"
        case "json": return "curlybraces"
        case "yml", "yaml": return "list.bullet.rectangle"
        default: return "doc"
        }
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: FileTreeItem, rhs: FileTreeItem) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Search

struct SearchResult: Identifiable {
    let id: UUID
    let fileURL: URL
    let lineNumber: Int
    let lineContent: String
    let matchRange: Range<String.Index>

    init(fileURL: URL, lineNumber: Int, lineContent: String, matchRange: Range<String.Index>) {
        self.id = UUID()
        self.fileURL = fileURL
        self.lineNumber = lineNumber
        self.lineContent = lineContent
        self.matchRange = matchRange
    }

    var fileName: String {
        fileURL.lastPathComponent
    }
}

// MARK: - Table of Contents

struct TOCHeading: Identifiable {
    let id: UUID
    let level: Int
    let text: String
    let lineNumber: Int
    /// Deduplicated anchor id matching the preview renderer's heading ids.
    let slug: String

    init(level: Int, text: String, lineNumber: Int, slug: String = "") {
        self.id = UUID()
        self.level = level
        self.text = text
        self.lineNumber = lineNumber
        self.slug = slug.isEmpty ? markdownHeadingSlug(text) : slug
    }
}

// MARK: - Session Restore

/// What gets persisted across launches when "Restore last session" is on.
struct SessionState: Codable, Equatable {
    var openFiles: [URL] = []
    var activeFileIndex: Int?
    var viewMode: ViewMode = .preview
    var currentFolder: URL?
    var sidebarVisible: Bool = false
    var inspectorVisible: Bool = false
}
