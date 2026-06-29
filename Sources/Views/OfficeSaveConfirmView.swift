import SwiftUI
import AppKit

/// 서식 보존 저장 전 출력 경로를 제안·확인한다. 원본은 건드리지 않고 새 파일로 저장한다.
struct OfficeSaveConfirmView: View {
    @Environment(AppState.self) private var appState
    let request: OfficeSaveRequest
    @State private var output: URL

    init(request: OfficeSaveRequest) {
        self.request = request
        _output = State(initialValue: request.output)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("서식 보존 저장")
                .font(.headline)
            Text("원본은 그대로 두고 새 파일로 저장합니다.")
                .font(.callout)
                .foregroundStyle(.secondary)

            GroupBox {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(output.lastPathComponent)
                            .font(.callout.weight(.medium))
                        Text(output.deletingLastPathComponent().path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    Button("위치 변경…") { chooseLocation() }
                }
                .padding(4)
            }

            HStack {
                Spacer()
                Button("취소") { appState.officeSaveConfirm = nil }
                Button("저장") {
                    appState.confirmOfficeSave(tabID: request.tabID,
                                               fileURL: request.fileURL,
                                               output: output)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func chooseLocation() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = output.lastPathComponent
        panel.directoryURL = output.deletingLastPathComponent()
        if panel.runModal() == .OK, let url = panel.url {
            output = url
        }
    }
}
