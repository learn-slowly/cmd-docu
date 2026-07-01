import Foundation

/// 검색 용어 결합 방식.
enum SearchMode { case and, or }

/// 용어 목록을 trigram FTS5 검색용 SQL 조각으로 바꾼다(순수).
/// ≥3글자는 trigram MATCH 구(부분일치), ≤2글자는 body·filename LIKE 폴백(MATCH는 3글자 미만 불가).
enum TrigramQuery {
    struct Built: Equatable {
        let whereClause: String
        let matchArg: String?       // docs MATCH 바인딩(있으면 항상 바인딩)
        let likeArgs: [String]      // LIKE 바인딩 — 각 ≤2글자 용어당 2개(body, filename)
        let directMatch: Bool       // true면 ORDER BY rank / snippet 사용 가능(순수 MATCH·AND-혼합). OR-혼합·순수 LIKE는 false.
    }

    /// 용어를 길이로 나눠 trigram 검색용 SQL을 만든다.
    /// ≥3글자→trigram MATCH 구(부분일치), ≤2글자→body·filename LIKE 폴백(MATCH는 3글자 미만 불가).
    /// .or 혼합에서 (docs MATCH ?) OR (…) 는 FTS5 런타임 에러라, MATCH를 rowid IN 서브쿼리로 감싼다.
    static func build(terms: [String], mode: SearchMode) -> Built? {
        var matchPhrases: [String] = []
        var likeClauses: [String] = []
        var likeArgs: [String] = []
        for raw in terms {
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { continue }
            if t.count >= 3 {
                let esc = t.replacingOccurrences(of: "\"", with: "\"\"")
                matchPhrases.append("\"\(esc)\"")
            } else {
                let e = t.replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "%", with: "\\%")
                    .replacingOccurrences(of: "_", with: "\\_")
                likeArgs.append("%\(e)%")   // body
                likeArgs.append("%\(e)%")   // filename
                likeClauses.append("(body LIKE ? ESCAPE '\\' OR filename LIKE ? ESCAPE '\\')")
            }
        }
        let hasMatch = !matchPhrases.isEmpty
        let hasLike = !likeClauses.isEmpty
        guard hasMatch || hasLike else { return nil }
        let matchArg: String? = hasMatch
            ? (mode == .and ? matchPhrases.joined(separator: " ") : matchPhrases.joined(separator: " OR "))
            : nil

        if hasMatch && hasLike {
            if mode == .and {
                // AND-혼합: 직접 MATCH가 top-level AND 제약이라 유효(rank/snippet 가능).
                let clause = (["(docs MATCH ?)"] + likeClauses).joined(separator: " AND ")
                return Built(whereClause: clause, matchArg: matchArg, likeArgs: likeArgs, directMatch: true)
            } else {
                // OR-혼합: (docs MATCH ?) OR (…) 는 FTS5 에러 → MATCH를 rowid IN 서브쿼리로 감싼다(rank/snippet 불가).
                let matchClause = "(rowid IN (SELECT rowid FROM docs WHERE docs MATCH ?))"
                let clause = ([matchClause] + likeClauses).joined(separator: " OR ")
                return Built(whereClause: clause, matchArg: matchArg, likeArgs: likeArgs, directMatch: false)
            }
        } else if hasMatch {
            return Built(whereClause: "docs MATCH ?", matchArg: matchArg, likeArgs: [], directMatch: true)
        } else {
            let connector = (mode == .and) ? " AND " : " OR "
            let clause = likeClauses.count == 1 ? likeClauses[0] : likeClauses.joined(separator: connector)
            return Built(whereClause: clause, matchArg: nil, likeArgs: likeArgs, directMatch: false)
        }
    }
}
