import Foundation

/// `claude auth status`의 JSON 결과(해석 완료).
struct ClaudeAuthStatus: Equatable {
    let loggedIn: Bool
    let email: String?
    let subscriptionType: String?
    let authMethod: String?

    /// 로그인 안 된(또는 상태를 못 읽은) 기본값.
    static let loggedOut = ClaudeAuthStatus(loggedIn: false, email: nil, subscriptionType: nil, authMethod: nil)
}

/// `claude auth status` stdout(JSON) 파싱 전용 순수 헬퍼(테스트 대상).
enum ClaudeAuthParser {
    private struct Raw: Decodable {
        let loggedIn: Bool?
        let email: String?
        let subscriptionType: String?
        let authMethod: String?
    }

    /// stdout에서 첫 `{`~마지막 `}` JSON을 추출·디코드한다. JSON이 없으면 nil.
    static func parse(_ stdout: String) -> ClaudeAuthStatus? {
        guard let start = stdout.firstIndex(of: "{"),
              let end = stdout.lastIndex(of: "}"), start < end else { return nil }
        let json = String(stdout[start...end])
        guard let data = json.data(using: .utf8),
              let raw = try? JSONDecoder().decode(Raw.self, from: data) else { return nil }
        return ClaudeAuthStatus(
            loggedIn: raw.loggedIn ?? false,
            email: raw.email,
            subscriptionType: raw.subscriptionType,
            authMethod: raw.authMethod
        )
    }
}
