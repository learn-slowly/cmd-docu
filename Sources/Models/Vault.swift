import Foundation
import SwiftUI

struct Vault: Identifiable, Equatable, Codable, Hashable {
    let id: UUID
    var name: String
    var rootPath: URL
    var inboxPath: String
    var templateId: UUID?
    var bookmarkData: Data?
    var createdAt: Date
    var isDefault: Bool
    
    init(
        id: UUID = UUID(),
        name: String,
        rootPath: URL,
        inboxPath: String = "Inbox",
        templateId: UUID? = nil,
        bookmarkData: Data? = nil,
        createdAt: Date = Date(),
        isDefault: Bool = false
    ) {
        self.id = id
        self.name = name
        self.rootPath = rootPath
        self.inboxPath = inboxPath
        self.templateId = templateId
        self.bookmarkData = bookmarkData
        self.createdAt = createdAt
        self.isDefault = isDefault
    }
    
    var inboxURL: URL {
        rootPath.appendingPathComponent(inboxPath)
    }
    
    var displayName: String {
        name.isEmpty ? rootPath.lastPathComponent : name
    }
}

struct VaultTemplate: Identifiable, Equatable, Codable {
    let id: UUID
    var name: String
    var content: String
    var frontmatterTemplate: Frontmatter?
    var filenamePattern: String
    
    init(
        id: UUID = UUID(),
        name: String,
        content: String = "",
        frontmatterTemplate: Frontmatter? = nil,
        filenamePattern: String = "{{title}}"
    ) {
        self.id = id
        self.name = name
        self.content = content
        self.frontmatterTemplate = frontmatterTemplate
        self.filenamePattern = filenamePattern
    }
    
    func generateFilename(title: String, date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let dateStr = formatter.string(from: date)
        
        let timestampFormatter = DateFormatter()
        timestampFormatter.dateFormat = "HHmmss"
        let timestamp = timestampFormatter.string(from: date)
        
        return filenamePattern
            .replacingOccurrences(of: "{{title}}", with: title)
            .replacingOccurrences(of: "{{date}}", with: dateStr)
            .replacingOccurrences(of: "{{timestamp}}", with: timestamp)
    }
}

enum SendAction: String, CaseIterable, Codable {
    case copy = "Copy"
    case move = "Move"
}

enum FileConflictResolution: String, CaseIterable, Codable {
    case rename = "Rename with suffix"
    case timestamp = "Add timestamp"
    case overwrite = "Overwrite"
    case skip = "Skip"
}

struct SendOptions: Equatable {
    var action: SendAction = .copy
    var targetVault: Vault?
    var targetFolder: String = "Inbox"
    var conflictResolution: FileConflictResolution = .rename
    var injectFrontmatter: Bool = true
    var applyTemplate: Bool = false
    var templateId: UUID?
    var addSourceLink: Bool = false
    var openAfterSend: Bool = false
}

struct RoutingRule: Identifiable, Equatable, Codable {
    let id: UUID
    var name: String
    var isEnabled: Bool
    var conditions: [RoutingCondition]
    var targetVaultId: UUID
    var targetFolder: String
    var action: SendAction
    var injectFrontmatter: Bool
    var priority: Int
    
    init(
        id: UUID = UUID(),
        name: String,
        isEnabled: Bool = true,
        conditions: [RoutingCondition] = [],
        targetVaultId: UUID,
        targetFolder: String = "Inbox",
        action: SendAction = .move,
        injectFrontmatter: Bool = true,
        priority: Int = 0
    ) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.conditions = conditions
        self.targetVaultId = targetVaultId
        self.targetFolder = targetFolder
        self.action = action
        self.injectFrontmatter = injectFrontmatter
        self.priority = priority
    }
}

struct RoutingCondition: Identifiable, Equatable, Codable {
    let id: UUID
    var type: ConditionType
    var value: String
    var matchType: MatchType
    
    init(
        id: UUID = UUID(),
        type: ConditionType,
        value: String,
        matchType: MatchType = .contains
    ) {
        self.id = id
        self.type = type
        self.value = value
        self.matchType = matchType
    }
    
    enum ConditionType: String, CaseIterable, Codable {
        case tag = "Tag"
        case frontmatterKey = "Frontmatter Key"
        case filenamePrefix = "Filename Prefix"
        case filenameSuffix = "Filename Suffix"
        case sourceDevice = "Source Device"
        case content = "Content"
    }
    
    enum MatchType: String, CaseIterable, Codable {
        case equals = "Equals"
        case contains = "Contains"
        case startsWith = "Starts With"
        case endsWith = "Ends With"
        case regex = "Regex"
    }
    
    func matches(document: MarkdownDocument) -> Bool {
        let targetValue: String
        switch type {
        case .tag:
            let tags = document.frontmatter?.tags ?? []
            return tags.contains { matchValue($0) }
        case .frontmatterKey:
            let parts = value.split(separator: ":", maxSplits: 1)
            guard parts.count == 2 else { return false }
            let key = String(parts[0])
            let expectedValue = String(parts[1])
            if let customValue = document.frontmatter?.custom[key] {
                return matchValue(customValue, against: expectedValue)
            }
            return false
        case .filenamePrefix:
            targetValue = document.fileURL?.lastPathComponent ?? document.title
            return targetValue.hasPrefix(value)
        case .filenameSuffix:
            targetValue = document.fileURL?.deletingPathExtension().lastPathComponent ?? document.title
            return targetValue.hasSuffix(value)
        case .sourceDevice:
            return matchValue(document.sourceDevice ?? "")
        case .content:
            return matchValue(document.content)
        }
    }
    
    private func matchValue(_ target: String, against expected: String? = nil) -> Bool {
        let compareValue = expected ?? value
        switch matchType {
        case .equals:
            return target.lowercased() == compareValue.lowercased()
        case .contains:
            return target.lowercased().contains(compareValue.lowercased())
        case .startsWith:
            return target.lowercased().hasPrefix(compareValue.lowercased())
        case .endsWith:
            return target.lowercased().hasSuffix(compareValue.lowercased())
        case .regex:
            guard let regex = try? NSRegularExpression(pattern: compareValue, options: .caseInsensitive) else {
                return false
            }
            let range = NSRange(target.startIndex..., in: target)
            return regex.firstMatch(in: target, range: range) != nil
        }
    }
}
