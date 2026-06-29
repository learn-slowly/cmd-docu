import Foundation

enum KordocError: Error {
    case toolNotFound
    case conversionFailed(String)
    case timeout
    case decodeFailed
}

/// kordoc CLI를 Process로 호출해 한글·오피스 문서를 KordocResult로 변환한다.
/// kordoc 자체는 구현하지 않는다(외부 도구). 실패는 throw로만 — 크래시 금지.
actor KordocService {
    private let timeout: TimeInterval = 120

    func convert(fileURL: URL) async throws -> KordocResult {
        guard let npx = Self.resolveNpxPath() else { throw KordocError.toolNotFound }

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: npx)
        process.arguments = ["-y", "kordoc", fileURL.path,
                             "--format", "json", "-o", tmp.path, "--silent"]
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = FileHandle.nullDevice   // -o로 출력, stdout 불필요

        do {
            try process.run()
        } catch {
            throw KordocError.toolNotFound
        }

        // 타임아웃 감시(협조적 폴링; --silent라 stderr 버퍼 넘침 위험 낮음).
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            if Date() > deadline {
                process.terminate()
                throw KordocError.timeout
            }
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s
        }

        if process.terminationStatus != 0 {
            let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw KordocError.conversionFailed(String(msg.prefix(500)))
        }

        guard let data = try? Data(contentsOf: tmp) else {
            throw KordocError.conversionFailed("출력 파일이 생성되지 않았습니다.")
        }
        guard let result = try? JSONDecoder().decode(KordocResult.self, from: data) else {
            throw KordocError.decodeFailed
        }
        return result
    }

    /// GUI 앱(.app)은 로그인 셸 PATH를 상속하지 않으므로 npx 절대경로를 탐지한다.
    /// 흔한 설치 경로 → 그래도 없으면 로그인 셸의 `which npx`.
    static func resolveNpxPath() -> String? {
        let candidates = ["/opt/homebrew/bin/npx", "/usr/local/bin/npx", "/usr/bin/npx"]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/bin/zsh")
        probe.arguments = ["-lc", "which npx"]
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
