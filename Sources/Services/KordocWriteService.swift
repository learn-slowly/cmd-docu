import Foundation

enum KordocWriteError: Error {
    case toolNotFound
    case patchFailed(String)
    case timeout
}

/// kordoc patch를 Process로 호출해 편집한 마크다운을 원본 서식에 반영한다.
/// kordoc 자체는 구현하지 않는다(외부 도구). 원본은 변경하지 않고 output에만 쓴다.
actor KordocWriteService {
    private let timeout: TimeInterval = 120

    /// 두 URL이 (심볼릭 링크·상대 요소 정규화 후) 같은 파일을 가리키는가.
    static func isSameFile(_ a: URL, _ b: URL) -> Bool {
        a.standardizedFileURL.resolvingSymlinksInPath().path
            == b.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// 편집 마크다운을 임시 .md로 적고 `kordoc patch <원본> <임시.md> -o <출력>`을 실행한다.
    func patch(original: URL, editedMarkdown: String, output: URL) async throws {
        guard let npx = KordocService.resolveNpxPath() else { throw KordocWriteError.toolNotFound }

        // 원본을 절대 덮어쓰지 않는다 — 출력이 원본과 같은 파일이면 거부한다.
        guard !Self.isSameFile(original, output) else {
            throw KordocWriteError.patchFailed("출력 경로가 원본과 같습니다. 다른 경로를 선택하세요.")
        }

        // kordoc patch는 편집본을 파일로 받는다 — 임시 .md로 적는다.
        let tmpMd = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("md")
        defer { try? FileManager.default.removeItem(at: tmpMd) }
        do {
            try editedMarkdown.write(to: tmpMd, atomically: true, encoding: .utf8)
        } catch {
            throw KordocWriteError.patchFailed("임시 파일을 적지 못했습니다: \(error.localizedDescription)")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: npx)
        process.arguments = ["-y", "kordoc", "patch",
                             original.path(percentEncoded: false),
                             tmpMd.path(percentEncoded: false),
                             "-o", output.path(percentEncoded: false), "--silent"]
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw KordocWriteError.toolNotFound
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            if Date() > deadline {
                process.terminate()
                throw KordocWriteError.timeout
            }
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s
        }

        if process.terminationStatus != 0 {
            let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw KordocWriteError.patchFailed(String(msg.prefix(500)))
        }

        // 성공이라면 출력 파일이 실제로 생겼는지 확인한다.
        guard FileManager.default.fileExists(atPath: output.path(percentEncoded: false)) else {
            throw KordocWriteError.patchFailed("출력 파일이 생성되지 않았습니다.")
        }
    }
}
