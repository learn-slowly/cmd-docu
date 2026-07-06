import SwiftUI

/// LLM-Wiki 단일 문서 인제스트 시트(스펙 §2.5) — 대상 선택 → 병합 생성 → diff 승인 → 적용.
struct WikiIngestView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    let request: WikiIngestRequest

    @State private var pages: [String] = []     // 위키 루트 기준 상대경로(기존 [URL]에서 교체)
    @State private var selection: String = ""          // 선택된 기존 페이지 path 또는 NEW
    @State private var newPageName: String = ""
    @State private var entries: [WikiIngestLogEntry] = []
    @State private var appliedURL: URL? = nil
    @State private var applying = false                // 적용 이중 클릭(중복 기록) 방지
    @State private var diffLines: [LineDiff.Line] = []

    private static let newMarker = "__NEW__"
    private static let autoMarker = "__AUTO__"

    private var wikiFolderURL: URL? {
        appState.settings.wikiFolder.map { URL(fileURLWithPath: $0) }
    }

    private var target: WikiIngestTarget? {
        if selection == Self.autoMarker { return .auto }
        if selection == Self.newMarker {
            let name = newPageName.trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? nil : .new(name: name)
        }
        guard !selection.isEmpty, let root = wikiFolderURL else { return nil }
        return .existing(root.appendingPathComponent(selection))
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

            // 적용 성공 시 wikiMergeProposal이 nil이 되어 diffSection이 사라지므로,
            // "페이지 열기"는 diff 밖에서 appliedURL만으로 게이트한다.
            if let appliedURL {
                HStack(spacing: 8) {
                    Label("적용 완료", systemImage: "checkmark.circle")
                        .foregroundStyle(.green)
                    Button("페이지 열기") {
                        appState.openDocument(at: appliedURL, inNewTab: true)
                        dismiss()
                    }
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
                    appState.setWikiFolder(url)
                    reload()
                }
            }
        }
    }

    private var targetPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("대상 페이지", selection: $selection) {
                Text("선택…").tag("")
                if appState.settings.wikiRulesSummary?
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                    Text("자동(규칙에 따름)").tag(Self.autoMarker)
                }
                Divider()
                ForEach(pages, id: \.self) { rel in
                    Text(rel.hasSuffix(".md") ? String(rel.dropLast(3)) : rel).tag(rel)
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
                appliedURL = nil   // 이전 병합의 "적용 완료" 배너가 새 병합 시트에 잔존하지 않도록.
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
                 ? "새 페이지: \(relativeDisplayPath(proposal.pageURL))"
                 : "변경 미리보기: \(relativeDisplayPath(proposal.pageURL))")
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
                    // 이중 클릭 재진입 가드 — applyWikiMerge 중복 실행이면 기록이 2건 남는다.
                    guard !applying else { return }
                    applying = true
                    Task {
                        if let dest = await appState.applyWikiMerge(proposal) {
                            appliedURL = dest
                            appState.wikiMergeProposal = nil
                            reload()
                        }
                        applying = false
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(appState.wikiIngestBusy || applying)
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

    /// 위키 루트 기준 상대경로 표시(자동 제안 경로 확인용 — 스펙 §2.6). 루트 밖이면 파일명만.
    private func relativeDisplayPath(_ url: URL) -> String {
        guard let root = wikiFolderURL else { return url.lastPathComponent }
        let rootPath = root.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        return path.hasPrefix(rootPath) ? String(path.dropFirst(rootPath.count)) : url.lastPathComponent
    }

    /// 위키 폴더 하위 전체 .md 목록(재귀·상대경로·이름순)과 기록을 다시 읽는다.
    private func reload() {
        if let folder = wikiFolderURL {
            pages = WikiPageLister.relativePages(under: folder)
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
