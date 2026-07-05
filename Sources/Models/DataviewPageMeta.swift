import Foundation

// MARK: - 데이터 모델

struct DataviewListItemMeta: Codable, Equatable {
    let text: String            // 마커([-*+]·체크박스) 뗀 항목 텍스트
    let headerSubpath: String   // 직전 헤딩 텍스트("" 가능)
    let tags: [String]          // 항목 안 인라인 태그, "#" 포함
    let task: Bool              // 체크박스 항목 여부
    let completed: Bool         // [x]/[X]
}

enum DataviewYAMLValue: Equatable {
    case string(String), number(Double), bool(Bool), array([DataviewYAMLValue])
}

struct DataviewPageMeta: Codable, Equatable {
    let name: String            // 확장자 없는 파일명
    let folder: String          // 루트 상대 폴더 경로("" = 루트)
    let path: String            // 루트 상대 파일 경로(확장자 포함)
    let day: String?            // "yyyy-MM-dd" — 파일명 우선, frontmatter date 폴백
    let mtime: Double           // epoch ms
    let ctime: Double
    let tags: [String]          // frontmatter tags + 본문 인라인 태그, "#" 포함 정규화
    let frontmatter: [String: DataviewYAMLValue]
    let lists: [DataviewListItemMeta]
}

// MARK: - Codable 구현 (DataviewYAMLValue)

extension DataviewYAMLValue: Codable {
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let n = try? c.decode(Double.self) { self = .number(n); return }
        if let a = try? c.decode([DataviewYAMLValue].self) { self = .array(a); return }
        self = .string(try c.decode(String.self))
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b): try c.encode(b)
        case .array(let a): try c.encode(a)
        }
    }
}

// MARK: - 파서 메인

extension DataviewPageMeta {

    private static let dayRegex = try! NSRegularExpression(pattern: #"\d{4}-\d{2}-\d{2}"#)
    private static let tagRegex = try! NSRegularExpression(pattern: #"#[\p{L}\p{N}_/-]+"#)

    /// 파일 1개의 본문에서 Dataview식 페이지 메타를 뽑는다(순수).
    /// - day: 파일명 안 yyyy-MM-dd 우선, 없으면 frontmatter date(스펙 §12 — 옵시디언 대조는 스모크에서).
    /// - lists: 코드펜스 밖 리스트 항목만, 직전 헤딩 텍스트를 subpath로.
    static func parse(content: String, name: String, folder: String, path: String,
                      mtime: Double, ctime: Double) -> DataviewPageMeta {
        var frontmatter: [String: DataviewYAMLValue] = [:]
        var body = content
        if let split = CompanionNote.splitFrontmatter(content) {
            frontmatter = parseYAMLLite(split.yaml)
            body = split.body
        }

        var day = firstMatch(dayRegex, in: name)
        if day == nil, case .string(let d)? = frontmatter["date"] {
            day = firstMatch(dayRegex, in: d)
        }

        var tags = Set<String>()
        if case .array(let arr)? = frontmatter["tags"] {
            for case .string(let t) in arr { tags.insert(t.hasPrefix("#") ? t : "#\(t)") }
        } else if case .string(let t)? = frontmatter["tags"] {
            tags.insert(t.hasPrefix("#") ? t : "#\(t)")
        }

        var lists: [DataviewListItemMeta] = []
        var currentHeader = ""
        var inFence = false
        for rawLine in body.components(separatedBy: "\n") {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") { inFence.toggle(); continue }
            if inFence { continue }
            if trimmed.hasPrefix("#"), let range = trimmed.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
                currentHeader = String(trimmed[range.upperBound...])
                continue
            }
            guard let markerRange = trimmed.range(of: #"^[-*+]\s+"#, options: .regularExpression) else { continue }
            var text = String(trimmed[markerRange.upperBound...])
            var task = false, completed = false
            if let boxRange = text.range(of: #"^\[( |x|X|~|<|>|-)\]\s*"#, options: .regularExpression) {
                task = true
                completed = text.hasPrefix("[x]") || text.hasPrefix("[X]")
                text = String(text[boxRange.upperBound...])
            }
            let itemTags = allMatches(tagRegex, in: text)
            itemTags.forEach { tags.insert($0) }
            lists.append(DataviewListItemMeta(text: text, headerSubpath: currentHeader,
                                              tags: itemTags, task: task, completed: completed))
        }

        return DataviewPageMeta(name: name, folder: folder, path: path, day: day,
                                mtime: mtime, ctime: ctime, tags: tags.sorted(),
                                frontmatter: frontmatter, lists: lists)
    }

    /// YAML 라이트 파서: 최상위 `키: 값` 스칼라(따옴표 벗김)·인라인 배열 [a, b]·
    /// `키:` 다음 `- 항목` 블록 리스트만. 중첩 맵·멀티라인은 문자열로 뭉갠다(실사용 충분).
    private static func parseYAMLLite(_ yaml: String) -> [String: DataviewYAMLValue] {
        var result: [String: DataviewYAMLValue] = [:]
        var pendingListKey: String?
        var pendingList: [DataviewYAMLValue] = []
        func flushList() {
            if let k = pendingListKey { result[k] = .array(pendingList) }
            pendingListKey = nil; pendingList = []
        }
        for line in yaml.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if trimmed.hasPrefix("- "), pendingListKey != nil {
                pendingList.append(scalar(String(trimmed.dropFirst(2))))
                continue
            }
            flushList()
            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
            let raw = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if raw.isEmpty { pendingListKey = key; continue }
            if raw.hasPrefix("["), raw.hasSuffix("]") {
                let inner = raw.dropFirst().dropLast()
                result[key] = .array(inner.split(separator: ",").map { scalar(String($0).trimmingCharacters(in: .whitespaces)) })
            } else {
                result[key] = scalar(raw)
            }
        }
        flushList()
        return result
    }

    private static func scalar(_ raw: String) -> DataviewYAMLValue {
        var s = raw
        if s.count >= 2, (s.hasPrefix("'") && s.hasSuffix("'")) || (s.hasPrefix("\"") && s.hasSuffix("\"")) {
            s = String(s.dropFirst().dropLast())
            return .string(s)   // 따옴표가 있으면 항상 문자열(YAML 시맨틱)
        }
        if s == "true" { return .bool(true) }
        if s == "false" { return .bool(false) }
        if let n = Double(s) { return .number(n) }
        return .string(s)
    }

    private static func firstMatch(_ regex: NSRegularExpression, in s: String) -> String? {
        let ns = s as NSString
        guard let m = regex.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return ns.substring(with: m.range)
    }

    private static func allMatches(_ regex: NSRegularExpression, in s: String) -> [String] {
        let ns = s as NSString
        return regex.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
    }
}
