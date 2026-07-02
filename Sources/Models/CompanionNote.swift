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

    /// 같은 폴더 열거 목록(siblings: 파일명 집합) 기준으로 짝꿍 노트인지 판별.
    /// 대응 미디어가 실재할 때만 true — 고아 노트는 일반 노트로 취급(숨기지 않음).
    /// 렌더·빌드 중 추가 FS 호출을 피하려고 siblings를 인자로 받는다.
    static func isCompanionNote(_ url: URL, siblings: Set<String>) -> Bool {
        guard let media = mediaURL(for: url) else { return false }
        return siblings.contains(media.lastPathComponent)
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

    /// 노트 내용에서 frontmatter의 summary를 읽는다(순수). 없거나 빈 값이면 nil.
    static func summary(fromNoteContent content: String) -> String? {
        guard content.hasPrefix("---\n") else { return nil }
        let afterOpen = content.dropFirst(4)
        guard let close = afterOpen.range(of: "\n---") else { return nil }
        let yamlString = String(afterOpen[..<close.lowerBound])
        guard let yaml = (try? Yams.load(yaml: yamlString)) as? [String: Any],
              let summary = yaml["summary"] as? String,
              !summary.isEmpty else { return nil }
        return summary
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
