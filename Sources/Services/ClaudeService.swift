import Foundation

enum ClaudeError: Error {
    case toolNotFound
    case notLoggedIn
    case creditExhausted
    case timeout
    case failed(String)
}

/// Claude 질의 최소 인터페이스 — 소비자(CleanupService 등)가 가짜를 주입해
/// 호출 횟수·분할을 테스트할 수 있게 좁힌다(2026-07-05 배정 청크 회귀 테스트용).
protocol ClaudeAsking: Sendable {
    func ask(prompt: String, context: String) async throws -> String
    /// 호출별 타임아웃 지정 — 출력이 긴 작업(위키 병합=페이지 전문 재생성)이 기본 120s를
    /// 구조적으로 초과해 도입(2026-07-07 실측: 138행 페이지 병합 6연속 타임아웃).
    func ask(prompt: String, context: String, timeout: TimeInterval) async throws -> String
}

extension ClaudeAsking {
    /// 기본 구현: timeout을 무시하고 기존 ask로 위임 — 기존 준수 타입(테스트 가짜)의
    /// 소스 호환 유지. 실제 시간 제한은 ClaudeService의 구체 구현만 갖는다.
    func ask(prompt: String, context: String, timeout: TimeInterval) async throws -> String {
        try await ask(prompt: prompt, context: context)
    }
}

/// claude CLI를 Process로 호출해 열린 문서를 질의한다.
/// claude 자체는 구현하지 않는다(외부 도구). 실패는 throw로만 — 크래시 금지.
actor ClaudeService: ClaudeAsking {
    // ask()/askStream()의 기본 Process 타임아웃. 출력이 긴 호출은 ask(…timeout:)으로 상향.
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
        try await ask(prompt: prompt, context: context, timeout: timeout)
    }

    /// ask의 호출별 타임아웃 변형 — 위키 병합처럼 출력이 페이지 전문이라 오래 걸리는
    /// 호출이 기본 120s 대신 자기 한도를 지정한다. 그 외 동작은 ask와 동일.
    func ask(prompt: String, context: String, timeout: TimeInterval) async throws -> String {
        guard let claudePath = Self.resolveClaudePath() else { throw ClaudeError.toolNotFound }
        let (arguments, stdin) = Self.makeInput(prompt: prompt, context: context)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: claudePath)
        process.arguments = arguments
        process.environment = SubprocessEnvironment.environment(forTool: claudePath)

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

        // 파이프 버퍼가 차서 교착되지 않게 stdout/stderr 드레인을 먼저 시작한다.
        let outHandle = stdoutPipe.fileHandleForReading
        let errHandle = stderrPipe.fileHandleForReading
        async let outData = Task.detached { outHandle.readDataToEndOfFile() }.value
        async let errData = Task.detached { errHandle.readDataToEndOfFile() }.value

        // 컨텍스트를 stdin으로 주입하고 닫는다. write가 블록돼도 위 드레인이
        // 동시에 돌도록 별도 스레드에서 처리해 교착을 막는다.
        let stdinHandle = stdinPipe.fileHandleForWriting
        let stdinData = stdin.data(using: .utf8) ?? Data()
        Task.detached {
            // claude가 stdin을 읽기 전에 종료하면 broken pipe가 날 수 있다.
            // 던지는 API를 써서 NSException 대신 Swift 에러로 받아 무시한다.
            if !stdinData.isEmpty { try? stdinHandle.write(contentsOf: stdinData) }
            try? stdinHandle.close()
        }

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

    // MARK: - 스트리밍 (askStream)

    /// stream-json 스트리밍용 인자(순수 함수). 프롬프트=`-p` 인자, 컨텍스트=stdin(ask와 동일).
    /// `--verbose`는 stream-json에 필수(줄단위 이벤트를 내보내려면 필요).
    static func makeStreamArguments(prompt: String) -> [String] {
        ["-p", prompt,
         "--output-format", "stream-json",
         "--verbose",
         "--include-partial-messages"]
    }

    /// stream-json 한 줄에서 텍스트 델타를 뽑는다(순수 함수).
    /// `stream_event`/`content_block_delta`/`text_delta`만 통과 — thinking_delta·system·assistant 등은 nil.
    static func textDelta(fromStreamLine line: String) -> String? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["type"] as? String == "stream_event",
              let event = obj["event"] as? [String: Any],
              event["type"] as? String == "content_block_delta",
              let delta = event["delta"] as? [String: Any],
              delta["type"] as? String == "text_delta" else { return nil }
        return delta["text"] as? String
    }

    /// stream-json 최종 결과 줄을 뽑는다(순수 함수). `type=="result"`만 통과.
    /// 델타 미지원 구버전 폴백용 텍스트와 에러 여부를 반환한다.
    static func finalResult(fromStreamLine line: String) -> (text: String, isError: Bool)? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              obj["type"] as? String == "result" else { return nil }
        let isError = (obj["is_error"] as? Bool) ?? (obj["subtype"] as? String != "success")
        return (obj["result"] as? String ?? "", isError)
    }

    /// ask와 동일한 골격(경로 탐지→Process 3파이프→stdin detached write→120s 협조 타임아웃) 위에
    /// stdout을 줄 단위로 증분 파싱해 text_delta를 yield한다. 기존 `ask`는 그대로 둔다(RAG·라우팅 의존).
    func askStream(prompt: String, context: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            // process는 work·onTermination 양쪽에서 참조(소비자 취소 시 즉시 terminate).
            let process = Process()
            let work = Task.detached { [timeout] in
                guard let claudePath = Self.resolveClaudePath() else {
                    continuation.finish(throwing: ClaudeError.toolNotFound)
                    return
                }
                process.executableURL = URL(fileURLWithPath: claudePath)
                process.arguments = Self.makeStreamArguments(prompt: prompt)
                process.environment = SubprocessEnvironment.environment(forTool: claudePath)

                let stdinPipe = Pipe()
                let stdoutPipe = Pipe()
                let stderrPipe = Pipe()
                process.standardInput = stdinPipe
                process.standardOutput = stdoutPipe
                process.standardError = stderrPipe

                do {
                    try process.run()
                } catch {
                    continuation.finish(throwing: ClaudeError.toolNotFound)
                    return
                }

                let outHandle = stdoutPipe.fileHandleForReading
                let errHandle = stderrPipe.fileHandleForReading

                // stderr 일괄 드레인을 stdout 증분 읽기와 **동시에** 시작(파이프 교착 방지).
                let errTask = Task.detached { errHandle.readDataToEndOfFile() }

                // 컨텍스트를 stdin으로 주입(별도 스레드 — write가 블록돼도 stdout 드레인이 계속 돌게).
                let stdinHandle = stdinPipe.fileHandleForWriting
                let trimmed = context.trimmingCharacters(in: .whitespacesAndNewlines)
                let stdinData = trimmed.data(using: .utf8) ?? Data()
                Task.detached {
                    if !stdinData.isEmpty { try? stdinHandle.write(contentsOf: stdinData) }
                    try? stdinHandle.close()
                }

                // 데드라인 감시(별도 폴링 — 증분 읽기가 블록돼도 초과 시 terminate).
                let timedOut = AtomicFlag()
                let timeoutTask = Task.detached { [timeout] in
                    let deadline = Date().addingTimeInterval(timeout)
                    while process.isRunning {
                        if Date() > deadline {
                            timedOut.set()
                            process.terminate()
                            return
                        }
                        try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s
                    }
                }

                var emitted = false
                var sawErrorResult = false
                do {
                    for try await line in outHandle.bytes.lines {
                        if Task.isCancelled { process.terminate(); break }
                        if let t = Self.textDelta(fromStreamLine: line) {
                            emitted = true
                            continuation.yield(t)
                        } else if let r = Self.finalResult(fromStreamLine: line) {
                            if r.isError {
                                sawErrorResult = true
                            } else if !emitted, !r.text.isEmpty {
                                // 델타 미지원 구버전 폴백 — result 텍스트를 한 번에 yield.
                                emitted = true
                                continuation.yield(r.text)
                            }
                        }
                    }
                } catch {
                    // stdout 증분 읽기 실패(취소 포함) — 아래 종료 분류로 넘어간다.
                }

                process.waitUntilExit()
                timeoutTask.cancel()
                let err = String(data: await errTask.value, encoding: .utf8) ?? ""

                if timedOut.value {
                    continuation.finish(throwing: ClaudeError.timeout)
                } else if process.terminationStatus != 0 || sawErrorResult {
                    continuation.finish(throwing: Self.classify(exitCode: process.terminationStatus, stderr: err))
                } else {
                    continuation.finish()
                }
            }
            continuation.onTermination = { _ in
                work.cancel()
                if process.isRunning { process.terminate() }
            }
        }
    }

    // MARK: - 인증 (claude auth)

    /// `claude auth status` 결과. CLI를 못 찾으면 nil(미설치), 찾았으나 미로그인이면 loggedOut.
    func authStatus() async -> ClaudeAuthStatus? {
        guard let path = Self.resolveClaudePath() else { return nil }
        guard let result = await Self.runCapturing(path: path, arguments: ["auth", "status"], timeout: 20)
        else { return ClaudeAuthStatus.loggedOut }
        return ClaudeAuthParser.parse(result.out) ?? .loggedOut
    }

    /// `claude auth login --claudeai` 실행 — 브라우저 로그인 페이지가 열린다.
    /// 완료까지 대기(긴 타임아웃). 실패 시 분류된 에러를 던진다.
    func login() async throws {
        guard let path = Self.resolveClaudePath() else { throw ClaudeError.toolNotFound }
        guard let result = await Self.runCapturing(path: path, arguments: ["auth", "login", "--claudeai"], timeout: 300)
        else { throw ClaudeError.toolNotFound }
        if result.code != 0 {
            throw Self.classify(exitCode: result.code, stderr: result.err.isEmpty ? result.out : result.err)
        }
    }

    /// `claude auth logout`.
    func logout() async throws {
        guard let path = Self.resolveClaudePath() else { throw ClaudeError.toolNotFound }
        _ = await Self.runCapturing(path: path, arguments: ["auth", "logout"], timeout: 30)
    }

    /// stdin 없이 인자만으로 claude를 실행해 (stdout, stderr, 종료코드)를 돌려준다.
    /// 실행 자체가 불가하면 nil. 파이프 교착 방지를 위해 드레인을 먼저 시작한다.
    private static func runCapturing(path: String, arguments: [String], timeout: TimeInterval) async -> (out: String, err: String, code: Int32)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        process.environment = SubprocessEnvironment.environment(forTool: path)
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice

        do { try process.run() } catch { return nil }

        let outHandle = outPipe.fileHandleForReading
        let errHandle = errPipe.fileHandleForReading
        async let outData = Task.detached { outHandle.readDataToEndOfFile() }.value
        async let errData = Task.detached { errHandle.readDataToEndOfFile() }.value

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            if Date() > deadline { process.terminate(); break }
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s
        }

        let out = String(data: await outData, encoding: .utf8) ?? ""
        let err = String(data: await errData, encoding: .utf8) ?? ""
        return (out, err, process.terminationStatus)
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

/// askStream 타임아웃 여부를 여러 Task 사이에서 스레드 안전하게 공유하는 작은 박스.
private final class AtomicFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false
    var value: Bool { lock.lock(); defer { lock.unlock() }; return _value }
    func set() { lock.lock(); _value = true; lock.unlock() }
}
