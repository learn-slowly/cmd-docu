import Foundation

/// FTS5 인덱스에서 근거 후보 파일 경로를 추린다. 원질문 + (확장) OR 질의를 합친다.
struct RagRetriever {
    let index: SearchIndex

    /// 원질문 히트(우선) + 확장 OR 히트(신규 경로만)를 합쳐 파일 경로 top-N.
    func topFiles(question: String, expandedTerms: [String], limit: Int = 8) async -> [String] {
        let primary = await index.search(query: question)
        var secondary: [IndexHit] = []
        if let orMatch = RagQueryExpansion.orMatch(expandedTerms) {
            secondary = await index.searchMatch(orMatch)
        }
        return Self.mergePaths(primary: primary, secondary: secondary, limit: limit)
    }

    /// primary 순서를 유지하며 중복 제거, 이어서 secondary의 새 경로만 붙이고 limit로 자른다(순수).
    static func mergePaths(primary: [IndexHit], secondary: [IndexHit], limit: Int) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for hit in primary + secondary {
            guard !seen.contains(hit.path) else { continue }
            seen.insert(hit.path)
            out.append(hit.path)
            if out.count >= limit { break }
        }
        return out
    }
}
