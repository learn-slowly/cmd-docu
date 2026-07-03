import SwiftUI

/// 파일 작업 기록 시트 — 아직 되돌릴 수 있는 휴지통/이름변경 목록 + 행별 되돌리기.
/// 되돌리기 성공 시 목록에서 사라지고(스토어가 제거), 실패 시 행에 사유 캡션.
struct FileOpsHistoryView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var entries: [FileOpEntry] = []
    @State private var failedIds: Set<UUID> = []
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
                ForEach(entries.reversed()) { entry in
                    row(entry)
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
    private func row(_ entry: FileOpEntry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: entry.kind == .trash ? "trash" : "pencil")
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

    private func rowTitle(_ entry: FileOpEntry) -> String {
        switch entry.kind {
        case .trash:
            return "휴지통: \(entry.originalURL.lastPathComponent)"
        case .rename:
            return "이름 변경: \(entry.originalURL.lastPathComponent) → \(entry.resultURL.lastPathComponent)"
        case .move:
            return "이동: \(entry.originalURL.lastPathComponent) → \(entry.resultURL.lastPathComponent)"
        case .copy:
            return "복사: \(entry.originalURL.lastPathComponent) → \(entry.resultURL.lastPathComponent)"
        }
    }
}
