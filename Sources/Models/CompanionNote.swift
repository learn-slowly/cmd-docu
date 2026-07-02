import Foundation
import Yams

/// 미디어 파일의 짝꿍 노트(파일명.ext.md) 규칙 — 단일 판별원.
/// 경로 계산·판별·초기 내용 생성은 순수. 파일시스템 접근은 loadSummary뿐.
enum CompanionNote {

    /// 미디어 URL → 짝꿍 노트 URL. 예: a.mp3 → a.mp3.md
    static func noteURL(for mediaURL: URL) -> URL {
        mediaURL.appendingPathExtension("md")
    }

    /// 노트 URL → 대응 미디어 URL. `.md`를 벗긴 결과가 미디어 확장자일 때만.
    /// 예: a.mp3.md → a.mp3 / 일반노트.md → nil
    static func mediaURL(for noteURL: URL) -> URL? {
        guard noteURL.pathExtension.lowercased() == "md" else { return nil }
        let stripped = noteURL.deletingPathExtension()
        guard DocumentKind.mediaExtensions.contains(stripped.pathExtension.lowercased()) else { return nil }
        return stripped
    }

    /// 같은 폴더 파일명들 → 소문자 키 집합. macOS 기본 볼륨(APFS)이 대소문자를
    /// 구분하지 않는 것과 정렬되도록, siblings 매칭은 이 키 집합 위에서 한다.
    static func siblingKeys<S: Sequence>(_ names: S) -> Set<String> where S.Element == String {
        Set(names.map { $0.lowercased() })
    }

    /// 같은 폴더 열거 목록(siblingKeys: siblingKeys(_:)의 산출물) 기준으로 짝꿍 노트인지 판별.
    /// 대응 미디어가 실재할 때만 true — 고아 노트는 일반 노트로 취급(숨기지 않음).
    /// 렌더·빌드 중 추가 FS 호출을 피하려고 siblingKeys를 인자로 받는다.
    static func isCompanionNote(_ url: URL, siblingKeys: Set<String>) -> Bool {
        guard let media = mediaURL(for: url) else { return false }
        return siblingKeys.contains(media.lastPathComponent.lowercased())
    }

    /// 미디어 파일에 짝꿍 노트가 있는가(배지 표시용). siblingKeys는 siblingKeys(_:)의 산출물.
    static func hasCompanionNote(for url: URL, siblingKeys: Set<String>) -> Bool {
        guard DocumentKind(from: url) == .media else { return false }
        return siblingKeys.contains(noteURL(for: url).lastPathComponent.lowercased())
    }

    /// 노트 초기 내용 — frontmatter 자동 채움(§스펙 3.2) + 제목 본문.
    static func initialContent(mediaFileName: String, metadata: MediaMetadata, today: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        let created = formatter.string(from: metadata.createdAt ?? today)
        let duration = MediaMetadataService.formatDuration(metadata.durationSeconds)
        let title = metadata.embeddedTitle ?? (mediaFileName as NSString).deletingPathExtension
        return """
        ---
        media: \(yamlQuoted(mediaFileName))
        duration: \(yamlQuoted(duration))
        format: \(yamlQuoted(metadata.format))
        created: \(created)
        summary: ""
        tags: []
        ---

        # \(title)

        """
    }

    /// YAML 더블쿼트 스칼라 — 역슬래시·따옴표 이스케이프.
    static func yamlQuoted(_ value: String) -> String {
        "\"" + value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// frontmatter 블록을 yaml·body로 분리한다(공용 — FileService.parseFrontmatter와 규칙 정렬).
    /// 여는 펜스는 첫 줄 트림이 "---"일 때만 인정. 닫는 펜스는 "---" 또는 "..." 둘 다
    /// 허용하고 뒤 공백을 관용한다. 닫는 펜스를 못 찾으면 nil(깨진 frontmatter는 원문 취급).
    static func splitFrontmatter(_ content: String) -> (yaml: String, body: String)? {
        var text = content
        if text.hasPrefix("\u{FEFF}") { text.removeFirst() }   // BOM 관용(FileService와 정렬)
        let lines = text.components(separatedBy: "\n")
        guard let first = lines.first, first.trimmingCharacters(in: .whitespaces) == "---" else { return nil }
        for (i, line) in lines.enumerated().dropFirst() {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t == "---" || t == "..." {   // 닫는펜스 두 표기 모두(FileService.parseFrontmatter와 동일 규칙)
                let yaml = lines[1..<i].joined(separator: "\n")
                var body = lines[(i + 1)...].joined(separator: "\n")
                while body.hasPrefix("\n") { body.removeFirst() }
                return (yaml, body)
            }
        }
        return nil
    }

    /// 노트 내용에서 frontmatter의 summary를 읽는다(순수). 없거나 빈 값이면 nil.
    static func summary(fromNoteContent content: String) -> String? {
        guard let (yamlString, _) = splitFrontmatter(content) else { return nil }
        guard let yaml = (try? Yams.load(yaml: yamlString)) as? [String: Any],
              let summary = yaml["summary"] as? String,
              !summary.isEmpty else { return nil }
        return summary
    }

    /// 노트 내용에서 frontmatter 블록을 뗀 본문을 돌려준다(미리보기용 — 편집 모드는 원문 그대로).
    /// 블록 판정 규칙은 splitFrontmatter(_:)와 동일. 닫는 펜스를 못 찾으면 원문 그대로.
    static func bodyStrippingFrontmatter(_ content: String) -> String {
        guard let (_, body) = splitFrontmatter(content) else { return content }
        return body
    }

    /// 짝꿍 노트 파일에서 summary를 비동기로 읽는다(라이브러리 리스트 셀 lazy 표시용).
    static func loadSummary(noteURL: URL) async -> String? {
        let task = Task.detached(priority: .utility) { () -> String? in
            guard let content = try? String(contentsOf: noteURL, encoding: .utf8) else { return nil }
            return summary(fromNoteContent: content)
        }
        return await task.value
    }
}
