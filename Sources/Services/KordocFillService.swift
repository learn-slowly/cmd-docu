import Foundation

enum KordocFillError: Error {
    case toolNotFound
    case dryRunFailed(String)
    case fillFailed(String)
    case timeout
    case decodeFailed
}

/// kordoc fill을 Process로 호출해 서식 빈칸을 채운다. kordoc 자체는 구현하지 않는다(외부 도구).
/// fill은 -o를 무시하고 채운 hwpx를 stdout으로 내므로, stdout을 직접 파일로 받아 우리가 저장한다.
/// 원본은 변경하지 않고 새 .hwpx에만 쓴다.
actor KordocFillService {
    private let timeout: TimeInterval = 120

    /// 서식 필드 목록만 조회한다(채우지 않음). stdout JSON을 FillDetection으로 디코드.
    func dryRun(template: URL) async throws -> FillDetection {
        guard let npx = KordocService.resolveNpxPath() else { throw KordocFillError.toolNotFound }

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        FileManager.default.createFile(atPath: tmp.path(percentEncoded: false), contents: nil)
        guard let outHandle = try? FileHandle(forWritingTo: tmp) else {
            throw KordocFillError.dryRunFailed("임시 파일을 열지 못했습니다.")
        }
        // defer 등록 순서: removeItem이 먼저(= 나중에 실행), close가 나중(= 먼저 실행) → 닫은 뒤 삭제.
        defer { try? outHandle.close() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: npx)
        process.arguments = ["-y", "kordoc", "fill", "--dry-run", "--silent",
                             template.path(percentEncoded: false)]
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = outHandle   // dry-run JSON을 임시 파일로 받는다.

        do { try process.run() }
        catch { throw KordocFillError.toolNotFound }

        try await waitOrTimeout(process)

        if process.terminationStatus != 0 {
            let msg = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw KordocFillError.dryRunFailed(String(msg.prefix(500)))
        }
        // stderr는 --silent라 작아 미드레인해도 안전(논-silent로 바꾸면 드레인 필요).
        guard let data = try? Data(contentsOf: tmp),
              let detection = try? JSONDecoder().decode(FillDetection.self, from: data) else {
            throw KordocFillError.decodeFailed
        }
        return detection
    }

    /// values(label→value)를 임시 JSON으로 적고 fill을 실행한다. 채운 hwpx(stdout)를 output에 저장.
    /// 반환: 비치명적 "매칭 실패" 라벨 목록.
    func fill(template: URL, values: [String: String], output: URL) async throws -> [String] {
        guard let npx = KordocService.resolveNpxPath() else { throw KordocFillError.toolNotFound }

        // 원본을 절대 덮어쓰지 않는다.
        guard !KordocWriteService.isSameFile(template, output) else {
            throw KordocFillError.fillFailed("출력 경로가 원본과 같습니다. 다른 경로를 선택하세요.")
        }

        // 채울 값 JSON 임시 파일.
        let tmpJson = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("json")
        defer { try? FileManager.default.removeItem(at: tmpJson) }
        do {
            let data = try JSONEncoder().encode(values)
            try data.write(to: tmpJson)
        } catch {
            throw KordocFillError.fillFailed("값 파일을 적지 못했습니다: \(error.localizedDescription)")
        }

        // 채운 hwpx(stdout)를 받을 임시 출력 파일.
        let tmpOut = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("hwpx")
        defer { try? FileManager.default.removeItem(at: tmpOut) }
        FileManager.default.createFile(atPath: tmpOut.path(percentEncoded: false), contents: nil)
        guard let outHandle = try? FileHandle(forWritingTo: tmpOut) else {
            throw KordocFillError.fillFailed("임시 출력 파일을 열지 못했습니다.")
        }
        // defer 등록 순서: removeItem(tmpOut)이 먼저(= 나중에 실행), close가 나중(= 먼저 실행) → 닫은 뒤 삭제.
        defer { try? outHandle.close() }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: npx)
        process.arguments = ["-y", "kordoc", "fill", template.path(percentEncoded: false),
                             "-j", tmpJson.path(percentEncoded: false), "--silent"]
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = outHandle   // 채운 hwpx 바이너리를 파일로 직접 받는다(파이프 교착 회피).

        do { try process.run() }
        catch { throw KordocFillError.toolNotFound }

        // stderr를 동시에 드레인한다 — fill은 "매칭 실패" 경고를 stderr로 내므로,
        // 종료 후에야 읽으면 버퍼가 차서 kordoc이 막혀 교착될 수 있다.
        let stderrHandle = stderrPipe.fileHandleForReading
        let stderrTask = Task.detached { stderrHandle.readDataToEndOfFile() }

        try await waitOrTimeout(process)

        let stderrText = String(data: await stderrTask.value, encoding: .utf8) ?? ""
        if process.terminationStatus != 0 {
            throw KordocFillError.fillFailed(String(stderrText.prefix(500)))
        }

        // 출력 이동(원본과 같지 않음은 위에서 확인). 기존 파일이 있으면 교체.
        if FileManager.default.fileExists(atPath: output.path(percentEncoded: false)) {
            try? FileManager.default.removeItem(at: output)
        }
        do {
            try FileManager.default.moveItem(at: tmpOut, to: output)
        } catch {
            throw KordocFillError.fillFailed("출력 파일을 저장하지 못했습니다: \(error.localizedDescription)")
        }
        guard FileManager.default.fileExists(atPath: output.path(percentEncoded: false)) else {
            throw KordocFillError.fillFailed("출력 파일이 생성되지 않았습니다.")
        }
        return Self.parseMatchWarnings(stderrText)
    }

    /// stderr에서 "매칭 실패: <라벨>" 라인을 골라 라벨 배열로 반환한다(순수 함수).
    static func parseMatchWarnings(_ stderr: String) -> [String] {
        stderr.split(separator: "\n").compactMap { line -> String? in
            guard let r = line.range(of: "매칭 실패:") else { return nil }
            let label = line[r.upperBound...].trimmingCharacters(in: .whitespaces)
            return label.isEmpty ? nil : label
        }
    }

    /// 종료까지 협조적으로 폴링하다 타임아웃이면 terminate.
    private func waitOrTimeout(_ process: Process) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            if Date() > deadline {
                process.terminate()
                throw KordocFillError.timeout
            }
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s
        }
    }
}
