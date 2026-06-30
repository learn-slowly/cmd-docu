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
                // 아직 존재하지 않는 중간 경로까지 모두 기록해야 undo에서 고아 폴더가 남지 않는다.
                let newlyCreated = Self.missingAncestors(from: destDir, downTo: root, fm: fm)
                do {
                    try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
                    createdDirs.append(contentsOf: newlyCreated)
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

        // 부분 실패 시 로그를 유지한다 — 복원되지 않은 파일의 복구 경로를 보존하기 위해.
        if failed == 0 {
            await store.remove(id: batch.id)
        }
        return (restored, failed)
    }

    /// destDir부터 root 직하까지, 아직 존재하지 않는 디렉터리들을 모은다(우리가 만든 것만 undo에서 제거).
    private static func missingAncestors(from destDir: URL, downTo root: URL, fm: FileManager) -> [URL] {
        var result: [URL] = []
        var current = destDir.standardizedFileURL
        let rootPath = root.standardizedFileURL.path
        while current.path != rootPath && current.path.hasPrefix(rootPath + "/") {
            if !fm.fileExists(atPath: current.path) {
                result.append(current)
            }
            current = current.deletingLastPathComponent()
        }
        return result
    }
}
