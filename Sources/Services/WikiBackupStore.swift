import Foundation

/// 위키 인제스트 적용 기록 한 건. backupFile은 wiki-backups/ 안 파일명 — 새 페이지
/// 생성이면 nil(복원 = 휴지통 이동).
struct WikiIngestLogEntry: Codable, Identifiable, Equatable {
    let id: UUID
    let pageURL: URL
    let backupFile: String?
    let sourceName: String
    let date: Date
}

/// 덮어쓰기 직전 본 백업·기록·복원(스펙 §2.4). 앱 데이터 디렉터리에만 쓴다 —
/// 볼트 안엔 잡파일을 만들지 않는다. 복원도 삭제 없음(새 페이지는 휴지통).
actor WikiBackupStore {
    private let backupsDir: URL
    private let logURL: URL
    private var entries: [WikiIngestLogEntry]

    init(directory: URL) {
        backupsDir = directory.appendingPathComponent("wiki-backups")
        logURL = directory.appendingPathComponent("wiki-ingest-log.json")
        try? FileManager.default.createDirectory(at: backupsDir, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: logURL) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let loaded = try? decoder.decode([WikiIngestLogEntry].self, from: data) {
                entries = loaded
            } else {
                entries = []
            }
        } else {
            entries = []
        }
    }

    /// 적용 직전 호출 — oldBody가 있으면 백업 파일로 저장하고 로그에 기록한다.
    func recordApply(pageURL: URL, oldBody: String?, sourceName: String) throws -> WikiIngestLogEntry {
        let now = Date()   // 백업 파일명 stamp와 로그 date가 같은 시각을 가리키도록 한 번만 읽는다.
        var backupFile: String? = nil
        if let oldBody {
            let stamp = Self.timestampFormatter.string(from: now)
            let base = pageURL.deletingPathExtension().lastPathComponent
            let file = backupsDir.appendingPathComponent("\(base)-\(stamp).md").uniquified()
            try oldBody.write(to: file, atomically: true, encoding: .utf8)
            backupFile = file.lastPathComponent
        }
        // Date를 초 단위로 반올림 — JSON 인코딩/디코딩 정밀도 맞춤
        let roundedDate = Date(timeIntervalSinceReferenceDate: now.timeIntervalSinceReferenceDate.rounded())
        let entry = WikiIngestLogEntry(
            id: UUID(), pageURL: pageURL, backupFile: backupFile,
            sourceName: sourceName, date: roundedDate)
        entries.append(entry)
        do {
            try persist()
        } catch {
            // 로그를 못 쓰면 기록 없는 고아 백업이 남는다 — 항목과 백업 파일을 되물리고 실패를 알린다.
            entries.removeLast()
            if let backupFile {
                try? FileManager.default.removeItem(at: backupsDir.appendingPathComponent(backupFile))
            }
            throw error
        }
        return entry
    }

    /// 최신순 기록.
    func allEntries() -> [WikiIngestLogEntry] {
        Array(entries.reversed())
    }

    /// 복원 — 백업이 있으면 현재 본을 다시 백업(왕복 안전) 후 백업본으로 교체,
    /// 새 페이지(backupFile nil)면 생성 파일을 휴지통으로. 로그는 보존.
    func restore(_ entry: WikiIngestLogEntry) throws {
        if let backupFile = entry.backupFile {
            let backup = backupsDir.appendingPathComponent(backupFile)
            let restored = try String(contentsOf: backup, encoding: .utf8)
            let current = try? String(contentsOf: entry.pageURL, encoding: .utf8)
            if let current {
                _ = try recordApply(pageURL: entry.pageURL, oldBody: current,
                                    sourceName: "복원 전 자동 백업")
            }
            try restored.write(to: entry.pageURL, atomically: true, encoding: .utf8)
        } else {
            _ = try FileOperations.trash(at: entry.pageURL)
        }
    }

    private func persist() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(entries)
        try data.write(to: logURL)
    }

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}
