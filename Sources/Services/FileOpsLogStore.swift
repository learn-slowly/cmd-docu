import Foundation

/// 파일 작업 종류(작업 로그용).
/// 주의: 새 케이스가 든 로그를 구버전 앱이 읽으면 배열 단위 디코드가 실패해
/// 기록 전체가 빈 것으로 보인다 — 앱은 전진만 하므로 수용(F1b 스펙 §4.2).
enum FileOpKind: String, Codable {
    case trash
    case rename
    case move
    case copy
}

/// 되돌리기 가능한 파일 작업 1건의 기록.
/// - trash: originalURL = 원위치, resultURL = 휴지통 내 실제 위치.
/// - rename: originalURL = 옛 경로, resultURL = 새 경로.
/// - move: originalURL = 옛 경로, resultURL = 새 경로(목적지 폴더 안, uniquify 반영).
/// - copy: originalURL = 원본, resultURL = 사본 — undo는 역이동이 아니라 사본을 휴지통으로.
/// 새 폴더는 기록하지 않는다 — 되돌리기가 삭제라 "영구 삭제 없음" 정책과 충돌.
struct FileOpEntry: Codable, Equatable, Identifiable {
    let id: UUID
    let kind: FileOpKind
    let originalURL: URL
    let resultURL: URL
    /// 배치 작업 묶음 id — F1a 단건은 nil(하위호환: 옛 로그 JSON에 필드 없음).
    let batchId: UUID?
    let date: Date

    init(id: UUID = UUID(), kind: FileOpKind, originalURL: URL, resultURL: URL,
         batchId: UUID? = nil, date: Date = Date()) {
        self.id = id
        self.kind = kind
        self.originalURL = originalURL
        self.resultURL = resultURL
        self.batchId = batchId
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
        appendBatch([entry])
    }

    /// 배치 기록 — 1회 load→save(건별 전체 재기록 회피).
    func appendBatch(_ newEntries: [FileOpEntry]) {
        guard !newEntries.isEmpty else { return }
        var all = load()
        all.append(contentsOf: newEntries)
        save(all)
    }

    /// 되돌리기 1건 — 성공 시 로그에서 제거, 실패 시 보존.
    func undo(_ entry: FileOpEntry) -> Bool {
        guard undoSingle(entry) else { return false }
        save(load().filter { $0.id != entry.id })
        return true
    }

    /// 배치 되돌리기 — 기록 순서(append 순서) 그대로 복원한다.
    /// 주의: MoveExecutor.undo류의 reversed() 선례를 그대로 따르면 이 스토어에서는 오히려
    /// 틀린다 — 폴더 안에 든 항목처럼 한 엔트리의 resultURL이 다른 엔트리의 결과 경로 밑에
    /// 중첩되는 경우, 중첩된(자식) 엔트리는 조상 엔트리보다 로그에 먼저 적힌다(자식이 실제로
    /// 먼저 이동됐으므로). 조상을 먼저 되돌리면 조상 이동의 부수효과로 자식이 함께 원위치
    /// 쪽으로 딸려가 자식 엔트리의 resultURL이 그 순간 사라져(존재하지 않아) 실패한다.
    /// 기록 순서대로(자식 먼저) 처리하면 자식이 아직 조상의 최종 경로에 남아있을 때 먼저
    /// 되돌려지고, 그 다음 빈 조상을 되돌리는 순서가 되어 성공한다. 실측(RED)으로 확인.
    func undoBatch(batchId: UUID) -> (succeeded: [FileOpEntry], failed: [FileOpEntry]) {
        let targets = load().filter { $0.batchId == batchId }
        var succeeded: [FileOpEntry] = []
        var failed: [FileOpEntry] = []
        for entry in targets {
            if undoSingle(entry) { succeeded.append(entry) } else { failed.append(entry) }
        }
        if !succeeded.isEmpty {
            let doneIds = Set(succeeded.map(\.id))
            save(load().filter { !doneIds.contains($0.id) })
        }
        return (succeeded, failed)
    }

    /// 실제 복원 연산(로그 조작 없음).
    /// - copy: 사본을 휴지통으로(영구 삭제 없음 정책) — 원위치 점유 검사 불필요.
    /// - 그 외: resultURL → originalURL 역이동. 결과물이 사라졌거나 원위치가 점유됐으면
    ///   실패(덮어쓰기 금지·uniquify 복원 안 함 — 이 스토어의 기존 정책 유지).
    private func undoSingle(_ entry: FileOpEntry) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: entry.resultURL.path) else { return false }
        if entry.kind == .copy {
            return (try? FileOperations.trash(at: entry.resultURL)) != nil
        }
        guard !fm.fileExists(atPath: entry.originalURL.path) else { return false }
        do {
            try fm.moveItem(at: entry.resultURL, to: entry.originalURL)
        } catch {
            return false
        }
        return true
    }

    private func save(_ entries: [FileOpEntry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: [.atomic])
    }
}
