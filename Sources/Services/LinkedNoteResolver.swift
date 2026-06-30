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
        // 지원 확장자(md/markdown/txt)가 명시됐을 때만 그대로 쓴다.
        // 그 외에는 — 확장자가 없든, 노트 이름에 점(.)이 들어가 URL이 끝자락을
        // 확장자로 오인하든 — md/markdown/txt 후보를 붙여 찾는다.
        // (예: "1.1.1_미디어_개념과_특징"의 pathExtension은 "1_미디어_개념과_특징"이라
        //  isEmpty 검사로는 .md가 안 붙어 해석에 실패했다.)
        if Self.supportedExtensions.contains(url.pathExtension.lowercased()) {
            return [url]
        }
        return [
            url.appendingPathExtension("md"),
            url.appendingPathExtension("markdown"),
            url.appendingPathExtension("txt")
        ]
    }

    private func findLinkedNote(named target: String) -> URL? {
        // 위키링크 target은 파일 경로가 아니라 노트 "이름"이다. 지원 확장자(md/markdown/txt)가
        // 명시된 경우에만 떼고, 그 외엔 점(.)이 든 이름을 그대로 둔다. NSString.deletingPathExtension을
        // 무조건 쓰면 "1.1.1_미디어_개념과_특징"을 "1.1"로 잘라 매칭에 실패했다.
        let strippedTarget = Self.strippingSupportedExtension(target)
        let targetPath = strippedTarget as NSString
        let targetBasename = targetPath.lastPathComponent
        let targetRelativePath = strippedTarget

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

    /// 지원 확장자(md/markdown/txt)가 명시됐을 때만 떼고, 그 외 점(.)이 든 이름은 그대로 둔다.
    private static func strippingSupportedExtension(_ s: String) -> String {
        let ns = s as NSString
        if supportedExtensions.contains(ns.pathExtension.lowercased()) {
            return ns.deletingPathExtension
        }
        return s
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
