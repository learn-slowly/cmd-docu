import SwiftUI

/// 파일 작업 기록 시트 — 아직 되돌릴 수 있는 휴지통/이름변경/이동/복사 목록(배치는 한 행) + 행별 되돌리기.
/// 되돌리기 성공 시 목록에서 사라지고(스토어가 제거), 실패 시 행에 사유 캡션.
struct FileOpsHistoryView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var entries: [FileOpEntry] = []
    @State private var failedIds: Set<UUID> = []
    @State private var failedBatchIds: Set<UUID> = []
    @State private var isLoading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("파일 작업 기록").font(.headline)
            content
            HStack {
                Spacer()
                Button("닫기") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480, height: 360)
        .task { await reload() }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        } else if entries.isEmpty {
            Text("되돌릴 수 있는 작업이 없습니다.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        } else {
            List {
                // 최근 작업이 위로
                ForEach(FileOpsHistoryGrouping.rows(entries).reversed()) { row in
                    switch row {
                    case .single(let entry): singleRow(entry)
                    case .batch(let id, let members): batchRow(id: id, members: members)
                    }
                }
            }
            .listStyle(.plain)
        }
    }

    private func reload() async {
        entries = await appState.fileOpsLogStore.load()
        isLoading = false
    }

    @ViewBuilder
    private func singleRow(_ entry: FileOpEntry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: kindIcon(entry.kind))
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(rowTitle(entry)).lineLimit(1)
                Text(entry.date.formatted(.dateTime.month().day().hour().minute()))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if failedIds.contains(entry.id) {
                    Text("되돌리지 못했습니다 — 원위치가 사용 중이거나 항목이 사라졌습니다.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            Spacer()
            Button("되돌리기") {
                Task { @MainActor in
                    if await appState.undoFileOp(entry) {
                        failedIds.remove(entry.id)
                        await reload()
                    } else {
                        failedIds.insert(entry.id)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func batchRow(id: UUID, members: [FileOpEntry]) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "square.stack")
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(kindLabel(members.first?.kind ?? .move)) \(members.count)건")
                    .lineLimit(1)
                Text(members.first?.date.formatted(.dateTime.month().day().hour().minute()) ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if failedBatchIds.contains(id) {
                    Text("일부를 되돌리지 못했습니다 — 남은 항목으로 다시 시도할 수 있습니다.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            Spacer()
            Button("모두 되돌리기") {
                Task { @MainActor in
                    if await appState.undoFileOpBatch(batchId: id) {
                        failedBatchIds.remove(id)
                    } else {
                        failedBatchIds.insert(id)
                    }
                    await reload()
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func rowTitle(_ entry: FileOpEntry) -> String {
        switch entry.kind {
        case .trash:
            return "휴지통: \(entry.originalURL.lastPathComponent)"
        case .rename:
            return "이름 변경: \(entry.originalURL.lastPathComponent) → \(entry.resultURL.lastPathComponent)"
        case .move:
            return "이동: \(entry.originalURL.lastPathComponent) → \(entry.resultURL.deletingLastPathComponent().lastPathComponent)/"
        case .copy:
            return "복사: \(entry.originalURL.lastPathComponent)"
        }
    }

    private func kindIcon(_ kind: FileOpKind) -> String {
        switch kind {
        case .trash: return "trash"
        case .rename: return "pencil"
        case .move: return "folder"
        case .copy: return "doc.on.doc"
        }
    }

    private func kindLabel(_ kind: FileOpKind) -> String {
        switch kind {
        case .trash: return "휴지통"
        case .rename: return "이름 변경"
        case .move: return "이동"
        case .copy: return "복사"
        }
    }
}

/// 기록 행 그룹핑 — batchId가 같은 엔트리를 첫 등장 위치에서 한 행으로 묶는다(순수).
enum FileOpsHistoryGrouping {
    enum Row: Identifiable {
        case single(FileOpEntry)
        case batch(id: UUID, entries: [FileOpEntry])

        var id: UUID {
            switch self {
            case .single(let entry): return entry.id
            case .batch(let id, _): return id
            }
        }
    }

    static func rows(_ entries: [FileOpEntry]) -> [Row] {
        var rows: [Row] = []
        var seenBatches = Set<UUID>()
        for entry in entries {
            guard let batchId = entry.batchId else {
                rows.append(.single(entry)); continue
            }
            guard !seenBatches.contains(batchId) else { continue }
            seenBatches.insert(batchId)
            rows.append(.batch(id: batchId, entries: entries.filter { $0.batchId == batchId }))
        }
        return rows
    }
}
