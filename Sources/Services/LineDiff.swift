import Foundation

/// LCS 기반 줄 diff — 위키 병합 diff 미리보기용. 페이지 한도 24k자(수백 줄) 규모라
/// O(n·m) DP로 충분하다(스펙 §2.2).
enum LineDiff {
    enum Kind: Equatable { case same, added, removed }
    struct Line: Equatable {
        let kind: Kind
        let text: String
    }

    static func diff(old: String, new: String) -> [Line] {
        let a = old.isEmpty ? [] : old.components(separatedBy: "\n")
        let b = new.isEmpty ? [] : new.components(separatedBy: "\n")

        var dp = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        if !a.isEmpty && !b.isEmpty {
            for i in stride(from: a.count - 1, through: 0, by: -1) {
                for j in stride(from: b.count - 1, through: 0, by: -1) {
                    dp[i][j] = a[i] == b[j] ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
                }
            }
        }

        var out: [Line] = []
        var i = 0, j = 0
        while i < a.count && j < b.count {
            if a[i] == b[j] {
                out.append(Line(kind: .same, text: a[i])); i += 1; j += 1
            } else if dp[i + 1][j] >= dp[i][j + 1] {
                out.append(Line(kind: .removed, text: a[i])); i += 1
            } else {
                out.append(Line(kind: .added, text: b[j])); j += 1
            }
        }
        while i < a.count { out.append(Line(kind: .removed, text: a[i])); i += 1 }
        while j < b.count { out.append(Line(kind: .added, text: b[j])); j += 1 }
        return out
    }
}
