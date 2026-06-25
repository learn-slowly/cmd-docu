import Foundation

/// Builds the wiki-link completion index by scanning note roots for Markdown
/// files. Only file names are read — never contents — so even large vaults
/// index quickly. Runs off the main thread (see AppState.rebuildNoteIndex).
enum NoteIndexService {
    static let supportedExtensions: Set<String> = ["md", "markdown", "txt"]

    static func buildIndex(roots: [URL], limit: Int = 8000) -> [VaultNote] {
        var notes: [VaultNote] = []
        var seenPaths: Set<String> = []

        for root in roots {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            for case let fileURL as URL in enumerator {
                guard supportedExtensions.contains(fileURL.pathExtension.lowercased()) else { continue }
                let standardized = fileURL.standardizedFileURL
                guard seenPaths.insert(standardized.path).inserted else { continue }

                let modified = (try? standardized.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast

                notes.append(VaultNote(
                    path: relativePath(of: standardized, in: root),
                    title: standardized.deletingPathExtension().lastPathComponent,
                    modifiedAt: modified,
                    url: standardized
                ))

                if notes.count >= limit {
                    return sorted(notes)
                }
            }
        }

        return sorted(notes)
    }

    /// Recently-modified notes first so completions surface what the user is
    /// actually working with.
    private static func sorted(_ notes: [VaultNote]) -> [VaultNote] {
        notes.sorted { $0.modifiedAt > $1.modifiedAt }
    }

    private static func relativePath(of fileURL: URL, in root: URL) -> String {
        let rootPrefix = root.standardizedFileURL.path + "/"
        guard fileURL.path.hasPrefix(rootPrefix) else { return fileURL.lastPathComponent }
        return String(fileURL.path.dropFirst(rootPrefix.count))
    }
}
