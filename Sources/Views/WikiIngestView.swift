import SwiftUI

/// LLM-Wiki 단일 문서 인제스트 시트(스펙 §2.5) — 대상 선택 → 병합 생성 → diff 승인 → 적용.
struct WikiIngestView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    let request: WikiIngestRequest

    @State private var pages: [URL] = []
    @State private var selection: String = ""          // 선택된 기존 페이지 path 또는 NEW
    @State private var newPageName: String = ""
    @State private var entries: [WikiIngestLogEntry] = []
    @State private var appliedURL: URL? = nil
    @State private var diffLines: [LineDiff.Line] = []

    private static let newMarker = "__NEW__"

    private var wikiFolderURL: URL? {
        appState.settings.wikiFolder.map { URL(fileURLWithPath: $0) }
    }

    private var target: WikiIngestTarget? {
        if selection == Self.newMarker {
            let name = newPageName.trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? nil : .new(name: name)
        }
        return selection.isEmpty ? nil : .existing(URL(fileURLWithPath: selection))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("위키에 인제스트").font(.headline)
            Label(request.url.lastPathComponent, systemImage: "doc")
                .foregroundStyle(.secondary)

            if wikiFolderURL == nil {
                unsetFolderNotice
            } else {
                targetPicker
                generateSection
                if let proposal = appState.wikiMergeProposal, proposal.sourceURL == request.url {
                    diffSection(proposal)
                }
            }

            if let error = appState.wikiIngestError {
                Text(error).foregroundStyle(.red).font(.callout)
            }

            historySection
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button(appliedURL != nil ? "닫기" : "취소") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(minWidth: 640, minHeight: 520)
        .task { reload() }
        .onChange(of: appState.wikiMergeProposal) { _, proposal in
            diffLines = proposal.map { LineDiff.diff(old: $0.oldBody, new: $0.newBody) } ?? []
        }
    }

    // MARK: - 구획

    private var unsetFolderNotice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("위키 폴더가 설정되지 않았습니다.").foregroundStyle(.secondary)
            Button("위키 폴더 지정…") {
                if let url = Self.pickFolder() {
                    appState.settings.wikiFolder = url.path
                    appState.saveUserData()
                    reload()
                }
            }
        }
    }

    private var targetPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("대상 페이지", selection: $selection) {
                Text("선택…").tag("")
                ForEach(pages, id: \.path) { page in
                    Text(page.deletingPathExtension().lastPathComponent).tag(page.path)
                }
                Divider()
                Text("새 페이지…").tag(Self.newMarker)
            }
            if selection == Self.newMarker {
                TextField("새 페이지 이름", text: $newPageName)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    private var generateSection: some View {
        HStack(spacing: 10) {
            Button("병합 생성") {
                guard let target else { return }
                Task { await appState.generateWikiMerge(source: request.url, target: target) }
            }
            .disabled(target == nil || appState.wikiIngestBusy)
            if appState.wikiIngestBusy {
                ProgressView().controlSize(.small)
                Text("Claude가 병합 중…").foregroundStyle(.secondary).font(.callout)
            }
        }
    }

    @ViewBuilder
    private func diffSection(_ proposal: WikiMergeProposal) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(proposal.isNewPage
                 ? "새 페이지: \(proposal.pageURL.lastPathComponent)"
                 : "변경 미리보기: \(proposal.pageURL.lastPathComponent)")
                .font(.subheadline).bold()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(diffLines.enumerated()), id: \.offset) { _, line in
                        diffRow(line)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 180, maxHeight: 320)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))

            HStack {
                Button("적용") {
                    Task {
                        if let dest = await appState.applyWikiMerge(proposal) {
                            appliedURL = dest
                            appState.wikiMergeProposal = nil
                            reload()
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(appState.wikiIngestBusy)
                if let appliedURL {
                    Button("페이지 열기") {
                        appState.openDocument(at: appliedURL, inNewTab: true)
                        dismiss()
                    }
                }
            }
        }
    }

    private func diffRow(_ line: LineDiff.Line) -> some View {
        Text(line.text.isEmpty ? " " : line.text)
            .font(.system(.caption, design: .monospaced))
            .strikethrough(line.kind == .removed)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 6)
            .background(
                line.kind == .added ? Color.green.opacity(0.18)
                : line.kind == .removed ? Color.red.opacity(0.15)
                : Color.clear)
    }

    private var historySection: some View {
        DisclosureGroup("인제스트 기록") {
            if entries.isEmpty {
                Text("기록 없음").foregroundStyle(.secondary).font(.callout)
            } else {
                ForEach(entries) { entry in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(entry.pageURL.lastPathComponent).font(.callout)
                            Text("\(entry.sourceName) · \(entry.date.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("되돌리기") {
                            Task {
                                if await appState.restoreWikiIngest(entry) { reload() }
                            }
                        }
                        .font(.caption)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .font(.callout)
    }

    // MARK: - 헬퍼

    /// 위키 폴더 최상위 .md 목록(이름순)과 기록을 다시 읽는다.
    private func reload() {
        if let folder = wikiFolderURL {
            let items = (try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles])) ?? []
            pages = items.filter { $0.pathExtension.lowercased() == "md" }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        } else {
            pages = []
        }
        Task {
            entries = await appState.wikiBackupStore.allEntries()
        }
    }

    private static func pickFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }
}
