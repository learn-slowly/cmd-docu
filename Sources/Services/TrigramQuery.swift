import Foundation

/// 검색 용어 결합 방식.
enum SearchMode { case and, or }

/// 용어 목록을 trigram FTS5 검색용 SQL 조각으로 바꾼다(순수).
/// ≥3글자는 trigram MATCH 구(부분일치), ≤2글자는 body LIKE 폴백(trigram MATCH가 3글자 미만 불가).
enum TrigramQuery {
    struct Built: Equatable {
        let whereClause: String     // 예: "(docs MATCH ?) OR (body LIKE ? ESCAPE '\\')"
        let matchArg: String?       // docs MATCH 바인딩(있으면)
        let likeArgs: [String]      // LIKE 바인딩("%term%") — whereClause의 ? 순서(match 다음)
        let hasMatch: Bool          // true면 ORDER BY rank 사용 가능
    }

    static func build(terms: [String], mode: SearchMode) -> Built? {
        var matchPhrases: [String] = []
        var likeArgs: [String] = []
        var likeClauses: [String] = []
        for raw in terms {
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { continue }
            if t.count >= 3 {
                let esc = t.replacingOccurrences(of: "\"", with: "\"\"")
                matchPhrases.append("\"\(esc)\"")
            } else {
                let escLike = t.replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "%", with: "\\%")
                    .replacingOccurrences(of: "_", with: "\\_")
                likeArgs.append("%\(escLike)%")
                likeClauses.append("body LIKE ? ESCAPE '\\'")
            }
        }
        var clauses: [String] = []
        var matchArg: String? = nil
        if !matchPhrases.isEmpty {
            matchArg = (mode == .and)
                ? matchPhrases.joined(separator: " ")
                : matchPhrases.joined(separator: " OR ")
            clauses.append("docs MATCH ?")
        }
        clauses.append(contentsOf: likeClauses)
        guard !clauses.isEmpty else { return nil }
        let connector = (mode == .and) ? " AND " : " OR "
        let whereClause = clauses.count == 1
            ? clauses[0]
            : clauses.map { "(\($0))" }.joined(separator: connector)
        return Built(whereClause: whereClause, matchArg: matchArg, likeArgs: likeArgs, hasMatch: matchArg != nil)
    }
}
