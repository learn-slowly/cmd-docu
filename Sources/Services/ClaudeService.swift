import Foundation

enum ClaudeError: Error {
    case toolNotFound
    case notLoggedIn
    case creditExhausted
    case timeout
    case failed(String)
}

/// claude CLI를 Process로 호출해 열린 문서를 질의한다.
/// claude 자체는 구현하지 않는다(외부 도구). 실패는 throw로만 — 크래시 금지.
actor ClaudeService {
    // Task 2의 ask() Process 타임아웃으로 사용한다.
    private let timeout: TimeInterval = 120

    /// claude CLI 종료코드/stderr를 사용자 분기 에러로 분류한다(순수 함수).
    static func classify(exitCode: Int32, stderr: String) -> ClaudeError {
        // exitCode는 Task 2의 Process 호출에서 전달되며, 현재는 stderr 신호로만 분류한다.
        let s = stderr.lowercased()
        if s.contains("not logged in") || s.contains("unauthorized")
            || s.contains("authenticate") || s.contains("login") {
            return .notLoggedIn
        }
        if s.contains("credit") || s.contains("quota")
            || s.contains("usage limit") || s.contains("rate limit") || s.contains("insufficient") {
            return .creditExhausted
        }
        return .failed(String(stderr.prefix(500)))
    }

    /// claude 호출 인자/stdin을 만든다(순수 함수). 프롬프트=`-p` 인자, 컨텍스트=stdin.
    static func makeInput(prompt: String, context: String) -> (arguments: [String], stdin: String) {
        let trimmed = context.trimmingCharacters(in: .whitespacesAndNewlines)
        return (["-p", prompt], trimmed)
    }
}
