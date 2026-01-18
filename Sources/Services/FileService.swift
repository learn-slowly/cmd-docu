import Foundation
import Yams

actor FileService {
    
    func loadDocument(from url: URL) async throws -> MarkdownDocument {
        let content = try String(contentsOf: url, encoding: .utf8)
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
        let tempURL = url.appendingPathExtension("tmp")
        try document.content.write(to: tempURL, atomically: true, encoding: .utf8)
        
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try FileManager.default.moveItem(at: tempURL, to: url)
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
        guard content.hasPrefix("---") else {
            return (nil, content)
        }
        
        let lines = content.components(separatedBy: .newlines)
        var frontmatterLines: [String] = []
        var endIndex = 0
        var foundEnd = false
        
        for (index, line) in lines.dropFirst().enumerated() {
            if line == "---" || line == "..." {
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
        
        if let dateString = yaml["date"] as? String {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withFullDate]
            frontmatter.date = formatter.date(from: dateString)
        }
        
        if let tags = yaml["tags"] as? [String] {
            frontmatter.tags = tags
        } else if let tagsString = yaml["tags"] as? String {
            frontmatter.tags = tagsString.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        
        if let aliases = yaml["aliases"] as? [String] {
            frontmatter.aliases = aliases
        }
        
        frontmatter.cssclass = yaml["cssclass"] as? String
        
        let knownKeys = Set(["title", "date", "tags", "aliases", "cssclass"])
        for (key, value) in yaml where !knownKeys.contains(key) {
            if let stringValue = value as? String {
                frontmatter.custom[key] = stringValue
            } else if let intValue = value as? Int {
                frontmatter.custom[key] = String(intValue)
            }
        }
        
        return (frontmatter, body)
    }
}
