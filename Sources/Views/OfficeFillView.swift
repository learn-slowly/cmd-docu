import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// 양식 채우기 시트. dry-run으로 감지한 서식 필드를 보여주고 값을 입력받아 새 .hwpx로 저장한다.
/// 원본은 건드리지 않는다(제안→확인→실행).
struct OfficeFillView: View {
    @Environment(AppState.self) private var appState
    let request: OfficeFillRequest
    @State private var values: [String: String]   // 키 = FillField.id
    @State private var output: URL

    init(request: OfficeFillRequest) {
        self.request = request
        // 감지된 현재값으로 프리필.
        var seed: [String: String] = [:]
        for field in request.detection.fields { seed[field.id] = field.value }
        _values = State(initialValue: seed)
        _output = State(initialValue: request.output)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("양식 채우기")
                .font(.headline)
            VStack(alignment: .leading, spacing: 2) {
                Text("원본은 그대로 두고 새 .hwpx로 저장합니다.")
                if let c = request.detection.confidence {
                    Text("감지 확신도 \(Int((c * 100).rounded()))%")
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            if request.detection.fields.isEmpty {
                Text("감지된 서식 필드가 없습니다.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(request.detection.fields) { field in
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Text(field.label.isEmpty ? "(빈 라벨)" : field.label)
                                    .font(.callout)
                                    .frame(width: 160, alignment: .leading)
                                    .lineLimit(2)
                                TextField("값", text: Binding(
                                    get: { values[field.id] ?? "" },
                                    set: { values[field.id] = $0 }
                                ))
                                .textFieldStyle(.roundedBorder)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: 420)
            }

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
                Button("취소") { appState.officeFillSession = nil }
                Button("채우기") {
                    let toSend = AppState.fillValuesToSend(fields: request.detection.fields, edited: values)
                    appState.confirmOfficeFill(tabID: request.tabID, fileURL: request.fileURL,
                                               values: toSend, output: output)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func chooseLocation() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = output.lastPathComponent
        panel.directoryURL = output.deletingLastPathComponent()
        if let type = UTType(filenameExtension: "hwpx") {
            panel.allowedContentTypes = [type]
        }
        if panel.runModal() == .OK, let url = panel.url {
            // 원본 자체를 고르면 옆 새 경로로 바꿔 원본 보호.
            output = KordocWriteService.isSameFile(url, request.fileURL) ? url.uniquified() : url
        }
    }
}
