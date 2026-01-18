import Foundation
import AppKit

actor VaultService {
    private let dataDirectory: URL
    private var bookmarks: [UUID: Data] = [:]
    private var accessedURLs: [UUID: URL] = [:]
    
    init(dataDirectory: URL) {
        self.dataDirectory = dataDirectory
        
        let bookmarksURL = dataDirectory.appendingPathComponent("vault-bookmarks.json")
        if let data = try? Data(contentsOf: bookmarksURL),
           let dict = try? JSONDecoder().decode([String: Data].self, from: data) {
            for (key, value) in dict {
                if let uuid = UUID(uuidString: key) {
                    bookmarks[uuid] = value
                }
            }
        }
    }
    
    func registerVault(name: String, at url: URL, inboxPath: String = "Inbox") async throws -> Vault {
        guard url.startAccessingSecurityScopedResource() else {
            throw VaultError.accessDenied
        }
        
        let bookmarkData = try url.bookmarkData(
            options: [.withSecurityScope],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        
        let vault = Vault(
            name: name,
            rootPath: url,
            inboxPath: inboxPath,
            bookmarkData: bookmarkData
        )
        
        bookmarks[vault.id] = bookmarkData
        accessedURLs[vault.id] = url
        saveBookmarks()
        
        return vault
    }
    
    func selectVaultFolder() async -> URL? {
        await MainActor.run {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.allowsMultipleSelection = false
            panel.message = "Select your Obsidian vault folder"
            panel.prompt = "Select Vault"
            
            return panel.runModal() == .OK ? panel.url : nil
        }
    }
    
    func restoreVaultAccess(for vault: Vault) throws -> URL {
        guard let bookmarkData = vault.bookmarkData ?? bookmarks[vault.id] else {
            throw VaultError.bookmarkNotFound
        }
        
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: bookmarkData,
            options: [.withSecurityScope, .withoutUI],
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        
        guard url.startAccessingSecurityScopedResource() else {
            throw VaultError.accessDenied
        }
        
        if isStale {
            let newBookmarkData = try url.bookmarkData(
                options: [.withSecurityScope],
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            bookmarks[vault.id] = newBookmarkData
            saveBookmarks()
        }
        
        accessedURLs[vault.id] = url
        return url
    }
    
    func releaseVaultAccess(for vault: Vault) {
        if let url = accessedURLs[vault.id] {
            url.stopAccessingSecurityScopedResource()
            accessedURLs.removeValue(forKey: vault.id)
        }
    }
    
    func indexVault(_ vault: Vault) async throws -> VaultIndex {
        let url = try restoreVaultAccess(for: vault)
        defer { releaseVaultAccess(for: vault) }
        
        var notes: [VaultNote] = []
        let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.nameKey, .isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )
        
        while let fileURL = enumerator?.nextObject() as? URL {
            guard fileURL.pathExtension.lowercased() == "md" else { continue }
            
            let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path)
            let modifiedAt = attributes?[.modificationDate] as? Date ?? Date()
            
            let relativePath = fileURL.path.replacingOccurrences(of: url.path + "/", with: "")
            let title = fileURL.deletingPathExtension().lastPathComponent
            
            notes.append(VaultNote(
                path: relativePath,
                title: title,
                modifiedAt: modifiedAt
            ))
        }
        
        return VaultIndex(vaultId: vault.id, notes: notes, indexedAt: Date())
    }
    
    func listFolders(in vault: Vault) async throws -> [String] {
        let url = try restoreVaultAccess(for: vault)
        defer { releaseVaultAccess(for: vault) }
        
        var folders: [String] = []
        let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )
        
        while let fileURL = enumerator?.nextObject() as? URL {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: fileURL.path, isDirectory: &isDirectory),
               isDirectory.boolValue {
                let relativePath = fileURL.path.replacingOccurrences(of: url.path + "/", with: "")
                if !relativePath.hasPrefix(".obsidian") {
                    folders.append(relativePath)
                }
            }
        }
        
        return folders.sorted()
    }
    

    
    private func saveBookmarks() {
        let bookmarksURL = dataDirectory.appendingPathComponent("vault-bookmarks.json")
        var dict: [String: Data] = [:]
        for (key, value) in bookmarks {
            dict[key.uuidString] = value
        }
        
        if let data = try? JSONEncoder().encode(dict) {
            try? data.write(to: bookmarksURL)
        }
    }
}

struct VaultIndex: Codable {
    let vaultId: UUID
    var notes: [VaultNote]
    let indexedAt: Date
}

struct VaultNote: Codable, Identifiable {
    var id: String { path }
    let path: String
    let title: String
    let modifiedAt: Date
}

enum VaultError: LocalizedError {
    case accessDenied
    case bookmarkNotFound
    case folderNotFound
    case indexingFailed
    
    var errorDescription: String? {
        switch self {
        case .accessDenied:
            return "Cannot access vault folder. Please grant permission."
        case .bookmarkNotFound:
            return "Vault bookmark not found. Please re-register the vault."
        case .folderNotFound:
            return "Vault folder not found."
        case .indexingFailed:
            return "Failed to index vault contents."
        }
    }
}
