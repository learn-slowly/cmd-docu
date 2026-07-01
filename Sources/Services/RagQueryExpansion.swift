import Foundation

/// 질문을 FTS 확장 검색어로 넓히기 위한 Claude 프롬프트/응답 파서(순수).
/// 임베딩 없는 RAG(B안)에서 동의어 recall을 메우는 값싼 레버.
enum RagQueryExpansion {
    /// Claude에게 확장 검색어를 JSON 배열로만 요청하는 프롬프트.
    static func prompt() -> String {
        """
        아래 사용자의 질문을 문서 검색에 쓸 한국어 검색어로 확장하라.
        동의어·유의어·바꿔 부르는 표현을 포함해 최대 6개를 고르되, 질문의 핵심 명사를 유지하라.
        다른 텍스트 없이 JSON 문자열 배열로만 답하라. 예: ["지방선거","총평","평가서"]
        """
    }

    /// stdout에서 첫 '['~마지막 ']'를 잘라 [String]으로 디코드한다.
    /// 앞뒤에 설명이 섞여도 배열만 추출. 실패하면 [](확장 없이 진행).
    static func parse(_ stdout: String) -> [String] {
        guard let open = stdout.firstIndex(of: "["),
              let close = stdout.lastIndex(of: "]"),
              open < close else { return [] }
        let json = String(stdout[open...close])
        guard let data = json.data(using: .utf8),
              let raw = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        var seen = Set<String>()
        var out: [String] = []
        for term in raw {
            let t = term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, !seen.contains(t.lowercased()) else { continue }
            seen.insert(t.lowercased())
            out.append(t)
        }
        return out
    }

}
