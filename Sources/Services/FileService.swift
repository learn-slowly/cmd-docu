import Foundation
import Yams

actor FileService {
    
    func loadDocument(from url: URL) async throws -> MarkdownDocument {
        let content = try Self.readString(from: url)
        let (frontmatter, body) = parseFrontmatter(from: content)
        
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let createdAt = attributes[.creationDate] as? Date ?? Date()
        let modifiedAt = attributes[.modificationDate] as? Date ?? Date()
        
        return MarkdownDocument(
            title: frontmatter?.title ?? url.deletingPathExtension().lastPathComponent,
            content: body,
            fileURL: url,
            createdAt: createdAt,
            modifiedAt: modifiedAt,
            frontmatter: frontmatter
        )
    }
    
    func saveDocument(_ document: MarkdownDocument, to url: URL) async throws {
        // `write(atomically:)` already writes to a hidden temp and performs an
        // atomic exchange, preserving the original on failure — no manual
        // remove-then-move (which loses the file if the move fails). Writes
        // `fullText` so the frontmatter block is never stripped on save.
        try document.fullText.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Reads a text file, tolerating non-UTF-8 encodings (UTF-16, Latin-1, …)
    /// instead of throwing, so real-world vault files still open.
    private static func readString(from url: URL) throws -> String {
        var usedEncoding: String.Encoding = .utf8
        if let s = try? String(contentsOf: url, usedEncoding: &usedEncoding) {
            return s
        }
        if let s = try? String(contentsOf: url, encoding: .utf8) {
            return s
        }
        for encoding in [String.Encoding.utf16, .isoLatin1, .windowsCP1252] {
            if let s = try? String(contentsOf: url, encoding: encoding) {
                return s
            }
        }
        // Surface the original UTF-8 error if everything failed.
        return try String(contentsOf: url, encoding: .utf8)
    }
    
    func watchFile(at url: URL, onChange: @escaping (URL) -> Void) -> DispatchSourceFileSystemObject? {
        let fileDescriptor = open(url.path, O_EVTONLY)
        guard fileDescriptor >= 0 else { return nil }
        
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fileDescriptor,
            eventMask: [.write, .rename, .delete],
            queue: .main
        )
        
        source.setEventHandler {
            onChange(url)
        }
        
        source.setCancelHandler {
            close(fileDescriptor)
        }
        
        source.resume()
        return source
    }
    
    private func parseFrontmatter(from content: String) -> (Frontmatter?, String) {
        // Tolerate a leading UTF-8 BOM so Windows/other-editor files still detect
        // their frontmatter block.
        var content = content
        if content.hasPrefix("\u{FEFF}") {
            content.removeFirst()
        }

        guard content.hasPrefix("---") else {
            return (nil, content)
        }

        let lines = content.components(separatedBy: .newlines)
        var frontmatterLines: [String] = []
        var endIndex = 0
        var foundEnd = false

        for (index, line) in lines.dropFirst().enumerated() {
            // Trim so a closing fence with trailing whitespace ("--- ") still matches.
            if line.trimmingCharacters(in: .whitespaces) == "---" || line.trimmingCharacters(in: .whitespaces) == "..." {
                endIndex = index + 2
                foundEnd = true
                break
            }
            frontmatterLines.append(line)
        }

        guard foundEnd else {
            return (nil, content)
        }

        let yamlString = frontmatterLines.joined(separator: "\n")
        let body = lines.dropFirst(endIndex).joined(separator: "\n")

        guard let yaml = try? Yams.load(yaml: yamlString) as? [String: Any] else {
            return (nil, body)
        }

        var frontmatter = Frontmatter()
        frontmatter.title = yaml["title"] as? String

        // Yams resolves bare dates (e.g. `2024-01-01`) to Date and full
        // timestamps too, so handle both Date and String forms.
        if let date = yaml["date"] as? Date {
            frontmatter.date = date
        } else if let dateString = yaml["date"] as? String {
            frontmatter.date = Self.parseDate(dateString)
        }

        if let tags = yaml["tags"] as? [String] {
            frontmatter.tags = tags
        } else if let tagsString = yaml["tags"] as? String {
            frontmatter.tags = tagsString.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        }

        if let aliases = yaml["aliases"] as? [String] {
            frontmatter.aliases = aliases
        } else if let alias = yaml["aliases"] as? String {
            frontmatter.aliases = [alias]
        }

        frontmatter.cssclass = yaml["cssclass"] as? String

        // Preserve ALL unknown keys with their original YAML type instead of
        // dropping bools/doubles/lists.
        let knownKeys: Set<String> = ["title", "date", "tags", "aliases", "cssclass"]
        for (key, value) in yaml where !knownKeys.contains(key) {
            frontmatter.custom[key] = FrontmatterValue(yaml: value)
        }

        return (frontmatter, body)
    }

    /// Parses a frontmatter date string, accepting both a bare date and a full
    /// ISO-8601 timestamp.
    private static func parseDate(_ string: String) -> Date? {
        let fullDate = ISO8601DateFormatter()
        fullDate.formatOptions = [.withFullDate]
        if let date = fullDate.date(from: string) { return date }

        let dateTime = ISO8601DateFormatter()
        dateTime.formatOptions = [.withInternetDateTime]
        if let date = dateTime.date(from: string) { return date }

        return nil
    }
}
