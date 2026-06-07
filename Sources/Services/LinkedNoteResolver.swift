import Foundation

struct LinkedNoteResolver {
    private static let supportedExtensions: Set<String> = ["md", "markdown", "txt"]

    private let roots: [URL]
    private let fileManager: FileManager

    init(roots: [URL], fileManager: FileManager = .default) {
        self.roots = Self.uniqueStandardizedRoots(roots)
        self.fileManager = fileManager
    }

    func resolve(_ rawTarget: String) -> URL? {
        guard let target = Self.normalizedTarget(rawTarget) else { return nil }
        return resolve(normalizedTarget: target)
    }

    func resolve(normalizedTarget target: String) -> URL? {
        if let directURL = resolveDirectCandidate(named: target) {
            return directURL
        }

        return findLinkedNote(named: target)
    }

    func resolveDirectCandidate(named target: String) -> URL? {
        directCandidateURLs(for: target)
            .first { fileManager.fileExists(atPath: $0.path) }
    }

    static func normalizedTarget(_ rawTarget: String) -> String? {
        let decoded: String
        if rawTarget.contains("%") {
            guard let percentDecoded = rawTarget.removingPercentEncoding else { return nil }
            decoded = percentDecoded
        } else {
            decoded = rawTarget
        }

        let withoutFragment = decoded.split(separator: "#", maxSplits: 1)
            .first
            .map(String.init) ?? decoded
        let withoutBlock = withoutFragment.split(separator: "^", maxSplits: 1)
            .first
            .map(String.init) ?? withoutFragment
        let trimmed = withoutBlock.trimmingCharacters(in: .whitespacesAndNewlines)

        return trimmed.isEmpty ? nil : trimmed
    }

    private func directCandidateURLs(for target: String) -> [URL] {
        if target.hasPrefix("/") {
            return fileNameVariants(for: URL(fileURLWithPath: target)).map(\.standardizedFileURL)
        }

        return roots.flatMap { root in
            fileNameVariants(for: root.appendingPathComponent(target))
                .map(\.standardizedFileURL)
        }
    }

    private func fileNameVariants(for url: URL) -> [URL] {
        guard url.pathExtension.isEmpty else { return [url] }
        return [
            url.appendingPathExtension("md"),
            url.appendingPathExtension("markdown"),
            url.appendingPathExtension("txt")
        ]
    }

    private func findLinkedNote(named target: String) -> URL? {
        let targetPath = target as NSString
        let targetBasename = (targetPath.lastPathComponent as NSString).deletingPathExtension
        let targetRelativePath = targetPath.deletingPathExtension

        for root in roots {
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }

            for case let fileURL as URL in enumerator {
                guard Self.supportedExtensions.contains(fileURL.pathExtension.lowercased()) else { continue }

                let basename = fileURL.deletingPathExtension().lastPathComponent
                if basename.localizedCaseInsensitiveCompare(targetBasename) == .orderedSame {
                    return fileURL.standardizedFileURL
                }

                let relative = relativePath(for: fileURL, from: root)
                if relative.localizedCaseInsensitiveCompare(targetRelativePath) == .orderedSame {
                    return fileURL.standardizedFileURL
                }
            }
        }

        return nil
    }

    private func relativePath(for fileURL: URL, from root: URL) -> String {
        let filePath = fileURL.deletingPathExtension().standardizedFileURL.path
        let rootPath = root.standardizedFileURL.path
        let rootPrefix = rootPath + "/"

        guard filePath.hasPrefix(rootPrefix) else {
            return fileURL.deletingPathExtension().lastPathComponent
        }

        return String(filePath.dropFirst(rootPrefix.count))
    }

    private static func uniqueStandardizedRoots(_ roots: [URL]) -> [URL] {
        var seen: Set<String> = []
        return roots.compactMap { root in
            let standardized = root.standardizedFileURL
            guard seen.insert(standardized.path).inserted else { return nil }
            return standardized
        }
    }
}
