import Foundation

/// 정리 배치 로그를 JSON 파일로 영속한다(undo용). 삭제 없음 — 로그만 관리.
actor MoveLogStore {
    private let fileURL: URL

    init(directory: URL) {
        self.fileURL = directory.appendingPathComponent("cleanup-moves.json")
    }

    func load() -> [MoveBatch] {
        guard let data = try? Data(contentsOf: fileURL),
              let batches = try? JSONDecoder().decode([MoveBatch].self, from: data) else { return [] }
        return batches
    }

    func append(_ batch: MoveBatch) {
        var all = load()
        all.append(batch)
        save(all)
    }

    func remove(id: UUID) {
        save(load().filter { $0.id != id })
    }

    private func save(_ batches: [MoveBatch]) {
        guard let data = try? JSONEncoder().encode(batches) else { return }
        try? data.write(to: fileURL, options: [.atomic])
    }
}
