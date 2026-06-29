import SwiftUI
import AppKit

/// 전용 Claude 사이드 패널. 프롬프트 입력 + 응답/로딩/에러 표시.
/// 응답 저장(노트 삽입·볼트)은 후속 Phase — 이번엔 세션 표시 + 복사만.
struct ClaudePanelView: View {
    @Environment(AppState.self) private var appState
    @FocusState private var promptFocused: Bool

    var body: some View {
        @Bindable var state = appState

        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .foregroundStyle(Color.cmdsAccent)
                Text("Claude")
                    .font(.headline)
                Spacer()
                Button {
                    appState.claudePanelVisible = false
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .help("Close Claude panel")
            }
            .padding(10)

            Divider()

            ScrollView {
                Group {
                    if appState.claudeBusy {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("Claude에게 묻는 중…").foregroundStyle(.secondary)
                        }
                    } else if let err = appState.claudeError {
                        Text(err)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                    } else if let resp = appState.claudeResponse {
                        Text(resp)
                            .textSelection(.enabled)
                    } else {
                        Text("열린 문서에 대해 Claude에게 물어보세요. 마크다운에서 선택영역이 있으면 그 부분만 전송됩니다.")
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }

            if let resp = appState.claudeResponse, !appState.claudeBusy {
                HStack {
                    Spacer()
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(resp, forType: .string)
                    } label: {
                        Label("복사", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
            }

            Divider()

            VStack(spacing: 8) {
                TextEditor(text: $state.claudePrompt)
                    .font(.body)
                    .frame(height: 72)
                    .focused($promptFocused)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.gray.opacity(0.25), lineWidth: 1)
                    )
                HStack {
                    Spacer()
                    Button("질문 (⌘↩)") {
                        appState.askClaude()
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.cmdsAccent)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(appState.claudeBusy
                        || appState.claudePrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(10)
        }
        .frame(maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear { promptFocused = true }
    }
}
