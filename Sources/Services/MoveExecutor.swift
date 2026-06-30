import Foundation

struct MoveOutcome {
    let batch: MoveBatch
    let moved: Int
    let failed: [URL]
}

/// 승인된 move만 실행하고 배치 로그를 남긴다. 삭제 없음.
/// undo는 역방향 이동 + 우리가 생성한 빈 폴더만 제거.
actor MoveExecutor {
    private let store: MoveLogStore

    init(store: MoveLogStore) {
        self.store = store
    }

    func apply(plan: CleanupPlan, mode: CleanupMode) async -> MoveOutcome {
        let fm = FileManager.default
        let root = mode.root
        var records: [MoveRecord] = []
        var createdDirs: [URL] = []
        var failed: [URL] = []

        let approved = plan.moves.filter { $0.approved && !$0.bucketId.isEmpty }
        for move in approved {
            guard let bucket = plan.scheme.first(where: { $0.id == move.bucketId }),
                  let destDir = CleanupPlanner.destinationDir(root: root, bucket: bucket) else {
                failed.append(move.source); continue
            }
            if !fm.fileExists(atPath: destDir.path) {
                do {
                    try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
                    createdDirs.append(destDir)
                } catch { failed.append(move.source); continue }
            }
            let dest = destDir.appendingPathComponent(move.source.lastPathComponent).uniquified()
            do {
                try fm.moveItem(at: move.source, to: dest)
                records.append(MoveRecord(from: move.source, to: dest))
            } catch { failed.append(move.source) }
        }

        let batch = MoveBatch(id: UUID(), date: Date(), modeLabel: mode.label,
                              records: records, createdDirs: createdDirs)
        if !records.isEmpty { await store.append(batch) }
        return MoveOutcome(batch: batch, moved: records.count, failed: failed)
    }

    func undo(_ batch: MoveBatch) async -> (restored: Int, failed: Int) {
        let fm = FileManager.default
        var restored = 0, failed = 0

        for record in batch.records.reversed() {
            guard fm.fileExists(atPath: record.to.path) else { failed += 1; continue }
            // 원위치가 다시 점유됐으면 덮어쓰지 않고 uniquify.
            let target = record.from.uniquified()
            do { try fm.moveItem(at: record.to, to: target); restored += 1 }
            catch { failed += 1 }
        }

        // 우리가 만든 폴더 중 비어 있는 것만 제거(깊은 경로부터).
        for dir in batch.createdDirs.sorted(by: { $0.path.count > $1.path.count }) {
            if let contents = try? fm.contentsOfDirectory(atPath: dir.path), contents.isEmpty {
                try? fm.removeItem(at: dir)
            }
        }

        await store.remove(id: batch.id)
        return (restored, failed)
    }
}
