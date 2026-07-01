import SwiftUI

/// 등록 인덱스 폴더를 근거로 질문하고 Claude 답변 + 출처 점프를 보여주는 시트.
struct AskCorpusView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("자료에 묻기").font(.headline)
                Spacer()
                Toggle("질의 확장", isOn: $state.settings.ragExpandQuery)
                    .toggleStyle(.switch).controlSize(.small)
                    .onChange(of: state.settings.ragExpandQuery) { _, _ in appState.saveUserData() }
                Button("닫기") { state.showAskCorpus = false }
            }
            Text("등록한 인덱스 폴더의 근거가 Claude로 전송됩니다.")
                .font(.caption).foregroundStyle(.secondary)

            TextField("질문을 입력하세요 (⌘↩)", text: $state.ragQuestion, axis: .vertical)
                .lineLimit(2...5)
                .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                Button("질문 (⌘↩)") { Task { await appState.runRagQuery() } }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(appState.ragBusy
                        || appState.ragQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            Divider()
            content
            Spacer()
        }
        .padding(16)
        .frame(width: 560, height: 600)
    }

    @ViewBuilder private var content: some View {
        if appState.ragBusy {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("자료에서 찾아 Claude에게 묻는 중…").foregroundStyle(.secondary)
            }
        } else if let msg = appState.ragMessage {
            Text(msg).foregroundStyle(.secondary)
        } else if let answer = appState.ragAnswer {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(answer).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if !appState.ragSources.isEmpty {
                        Text("근거").font(.subheadline).bold()
                        ForEach(appState.ragSources) { src in
                            Button { appState.openRagSource(src) } label: {
                                HStack(alignment: .top, spacing: 8) {
                                    Text("[\(src.index)]").font(.caption).monospaced()
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(URL(fileURLWithPath: src.path).lastPathComponent
                                             + locationLabel(src.location))
                                            .font(.caption).bold()
                                        Text(src.snippet).font(.caption)
                                            .foregroundStyle(.secondary).lineLimit(2)
                                    }
                                    Spacer()
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        } else {
            Text("등록한 폴더(인덱스)를 근거로 질문하면 출처와 함께 답합니다.\n인덱스 폴더가 없으면 '내용 검색'에서 먼저 폴더를 등록하세요.")
                .foregroundStyle(.secondary).font(.callout)
        }
    }

    private func locationLabel(_ loc: RagLocation) -> String {
        switch loc {
        case .line(let n): return " (줄 \(n))"
        case .page(let p): return " (p.\(p))"
        case .unknown: return ""
        }
    }
}
