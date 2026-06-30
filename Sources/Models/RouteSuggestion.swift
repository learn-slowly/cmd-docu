import Foundation

/// Claude가 고른 PARA 목적지(해석 완료).
struct RouteSuggestion: Equatable {
    let folder: ParaFolder
    let reason: String
}

/// Claude가 답해야 하는 strict JSON 형태.
struct RouteParse: Decodable {
    let id: String
    let reason: String
}

/// PARA 라우팅 프롬프트/컨텍스트/파싱 순수 헬퍼(테스트 대상).
enum RouteHelper {
    /// 목록 중 best를 id로 골라 JSON만 답하게 지시하는 프롬프트.
    static func buildRoutePrompt(destinations: [ParaFolder]) -> String {
        let list = destinations
            .map { "- \($0.id.uuidString) | \($0.label) — \($0.hint)" }
            .joined(separator: "\n")
        return """
        아래는 노트를 분류할 PARA 폴더 후보다. 이어지는 노트 본문을 읽고, 가장 알맞은 폴더 하나를 골라라.
        반드시 아래 목록의 id 중 하나만 고른다.

        \(list)

        답은 다른 텍스트 없이 strict JSON 한 줄로만 한다:
        {"id":"<위 목록의 id>","reason":"<한국어 한 줄 이유>"}
        """
    }

    /// 본문 컨텍스트. maxChars 초과면 앞부분만 남기고 잘렸음을 표시한다.
    static func buildRouteContext(noteBody: String, maxChars: Int = 4000) -> String {
        guard noteBody.count > maxChars else { return noteBody }
        return String(noteBody.prefix(maxChars)) + "\n…(생략)"
    }

    /// stdout에서 첫 {…} JSON을 추출·디코드하고 id를 ParaFolder로 해석한다. 실패 시 nil.
    static func parseRouteSuggestion(_ stdout: String, destinations: [ParaFolder]) -> RouteSuggestion? {
        guard let start = stdout.firstIndex(of: "{"),
              let end = stdout.lastIndex(of: "}"), start < end else { return nil }
        let jsonText = String(stdout[start...end])
        guard let data = jsonText.data(using: .utf8),
              let parsed = try? JSONDecoder().decode(RouteParse.self, from: data),
              let folder = destinations.first(where: { $0.id.uuidString == parsed.id })
        else { return nil }
        return RouteSuggestion(folder: folder, reason: parsed.reason)
    }
}
