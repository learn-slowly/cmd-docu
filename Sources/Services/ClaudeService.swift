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

    /// 열린 문서 컨텍스트와 프롬프트를 claude -p로 보내고 stdout 응답을 반환한다.
    func ask(prompt: String, context: String) async throws -> String {
        guard let claudePath = Self.resolveClaudePath() else { throw ClaudeError.toolNotFound }
        let (arguments, stdin) = Self.makeInput(prompt: prompt, context: context)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: claudePath)
        process.arguments = arguments

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        do {
            try process.run()
        } catch {
            throw ClaudeError.toolNotFound
        }

        // 컨텍스트를 stdin으로 주입하고 닫는다.
        if let data = stdin.data(using: .utf8), !data.isEmpty {
            stdinPipe.fileHandleForWriting.write(data)
        }
        stdinPipe.fileHandleForWriting.closeFile()

        // 파이프 버퍼가 차서 교착되지 않게 stdout/stderr를 백그라운드에서 비운다.
        let outHandle = stdoutPipe.fileHandleForReading
        let errHandle = stderrPipe.fileHandleForReading
        async let outData = Task.detached { outHandle.readDataToEndOfFile() }.value
        async let errData = Task.detached { errHandle.readDataToEndOfFile() }.value

        // 타임아웃 감시(협조적 폴링).
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            if Date() > deadline {
                process.terminate()
                throw ClaudeError.timeout
            }
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s
        }

        let out = String(data: await outData, encoding: .utf8) ?? ""
        let err = String(data: await errData, encoding: .utf8) ?? ""

        if process.terminationStatus != 0 {
            throw Self.classify(exitCode: process.terminationStatus, stderr: err)
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// GUI 앱(.app)은 로그인 셸 PATH를 상속하지 않으므로 claude 절대경로를 탐지한다.
    /// 흔한 설치 경로 → 그래도 없으면 로그인 셸의 `which claude`.
    static func resolveClaudePath() -> String? {
        let home = NSHomeDirectory()
        let candidates = [
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(home)/.claude/local/claude",
            "\(home)/.local/bin/claude",
            "/usr/bin/claude",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/bin/zsh")
        probe.arguments = ["-lc", "which claude"]
        let pipe = Pipe()
        probe.standardOutput = pipe
        probe.standardError = FileHandle.nullDevice
        do {
            try probe.run()
            probe.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let out = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !out.isEmpty, FileManager.default.isExecutableFile(atPath: out) {
                return out
            }
        } catch { }
        return nil
    }
}
