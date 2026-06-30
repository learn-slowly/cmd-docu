import SwiftUI
import AppKit

/// 전용 내용 검색 시트: 등록 폴더 관리 + FTS5 키워드 검색(파일+스니펫).
struct IndexSearchView: View {
    @Environment(AppState.self) private var appState
    @State private var query: String = ""
    @State private var debounce: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("내용 검색")
                    .font(.headline)
                Spacer()
                Button("닫기") { appState.showIndexSearch = false }
                    .buttonStyle(.borderless)
            }
            .padding()
            .background(.bar)

            Form {
                Section("등록 폴더") {
                    if appState.settings.indexedFolders.isEmpty {
                        Text("폴더를 추가해 인덱싱하세요.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(appState.settings.indexedFolders, id: \.self) { folder in
                        HStack {
                            Text((folder as NSString).lastPathComponent)
                            Text(folder).font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button("재인덱싱") { appState.reindexFolder(folder) }
                                .controlSize(.small)
                            Button(role: .destructive) { appState.unregisterIndexFolder(folder) } label: {
                                Image(systemName: "minus.circle")
                            }
                            .controlSize(.small)
                        }
                    }
                    HStack {
                        Button("폴더 추가…") { addFolder() }
                        if appState.indexInProgress, let p = appState.indexProgress {
                            ProgressView(value: p.total == 0 ? 0 : Double(p.done) / Double(p.total))
                            Text("\(p.done)/\(p.total)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

                Section("검색") {
                    TextField("키워드", text: $query)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: query) { _, q in
                            appState.indexSearchText = q
                            debounce?.cancel()
                            debounce = Task {
                                try? await Task.sleep(nanoseconds: 200_000_000)
                                if Task.isCancelled { return }
                                await appState.runIndexSearch(query: q)
                            }
                        }

                    if appState.indexSearchResults.isEmpty && !query.isEmpty {
                        Text("결과 없음").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(appState.indexSearchResults, id: \.path) { hit in
                        Button { appState.openIndexHit(hit) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Image(systemName: "doc.text")
                                    Text((hit.path as NSString).lastPathComponent)
                                        .font(.callout.weight(.medium))
                                    if hit.isFilenameMatch {
                                        Text("파일명").font(.caption2)
                                            .padding(.horizontal, 4).background(.quaternary).clipShape(Capsule())
                                    }
                                }
                                if !hit.snippet.isEmpty {
                                    Text(hit.snippet).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                                Text((hit.path as NSString).deletingLastPathComponent)
                                    .font(.caption2).foregroundStyle(.tertiary)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 560, height: 600)
        .tint(.cmdsAccent)
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            appState.registerIndexFolder(url)
        }
    }
}
