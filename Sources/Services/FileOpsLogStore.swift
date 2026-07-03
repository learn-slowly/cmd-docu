import Foundation

/// 파일 작업 종류(작업 로그용).
enum FileOpKind: String, Codable {
    case trash
    case rename
}

/// 되돌리기 가능한 파일 작업 1건의 기록.
/// - trash: originalURL = 원위치, resultURL = 휴지통 내 실제 위치.
/// - rename: originalURL = 옛 경로, resultURL = 새 경로.
/// 새 폴더는 기록하지 않는다 — 되돌리기가 삭제라 "영구 삭제 없음" 정책과 충돌.
struct FileOpEntry: Codable, Equatable, Identifiable {
    let id: UUID
    let kind: FileOpKind
    let originalURL: URL
    let resultURL: URL
    let date: Date

    init(id: UUID = UUID(), kind: FileOpKind, originalURL: URL, resultURL: URL, date: Date = Date()) {
        self.id = id
        self.kind = kind
        self.originalURL = originalURL
        self.resultURL = resultURL
        self.date = date
    }
}

/// 파일 작업 로그를 JSON으로 영속하고 되돌리기를 수행한다(MoveLogStore 패턴).
/// 목록 = 아직 되돌릴 수 있는 작업 — 성공한 undo는 로그에서 제거, 실패는 보존.
actor FileOpsLogStore {
    private let fileURL: URL

    init(directory: URL) {
        self.fileURL = directory.appendingPathComponent("fileops-log.json")
    }

    func load() -> [FileOpEntry] {
        guard let data = try? Data(contentsOf: fileURL),
              let entries = try? JSONDecoder().decode([FileOpEntry].self, from: data) else { return [] }
        return entries
    }

    func append(_ entry: FileOpEntry) {
        var all = load()
        all.append(entry)
        save(all)
    }

    /// 되돌리기 — resultURL을 originalURL로 역이동(휴지통 꺼내기와 rename 역방향이 같은 연산).
    /// 결과물이 사라졌거나 원위치가 점유됐으면 실패(false)하고 로그를 보존한다(덮어쓰기 금지).
    func undo(_ entry: FileOpEntry) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: entry.resultURL.path) else { return false }
        guard !fm.fileExists(atPath: entry.originalURL.path) else { return false }
        do {
            try fm.moveItem(at: entry.resultURL, to: entry.originalURL)
        } catch {
            return false
        }
        save(load().filter { $0.id != entry.id })
        return true
    }

    private func save(_ entries: [FileOpEntry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: [.atomic])
    }
}
