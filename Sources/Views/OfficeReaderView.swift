import SwiftUI

/// 한글·오피스 문서를 kordoc 변환 결과(마크다운)로 표시한다.
/// hwp/hwpx는 편집모드(편집 → kordoc patch로 서식 보존 저장)를 지원한다.
/// 상태: 변환 중 / 완료(읽기 프리뷰 또는 편집) / 실패(안내+재시도).
struct OfficeReaderView: View {
    @Environment(AppState.self) private var appState
    let tabID: UUID
    let fileURL: URL

    var body: some View {
        switch appState.officeStates[tabID] {
        case .loaded(let result):
            let isEditing = appState.officeEditing.contains(tabID)
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Spacer()
                    if isEditing {
                        if appState.officePatchInProgress.contains(tabID) {
                            ProgressView().controlSize(.small)
                        }
                        Button("취소") { appState.cancelOfficeEdit(tabID: tabID) }
                            .disabled(appState.officePatchInProgress.contains(tabID))
                        Button("서식 보존 저장") {
                            appState.requestOfficeSave(tabID: tabID, fileURL: fileURL)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(appState.officePatchInProgress.contains(tabID))
                    } else if DocumentKind.isPatchable(fileURL) {
                        Button {
                            appState.beginOfficeEdit(tabID: tabID)
                        } label: {
                            Label("편집", systemImage: "pencil")
                        }
                    }
                }
                .padding(8)
                Divider()
                if isEditing {
                    OfficeEditorPane(tabID: tabID)
                } else {
                    MarkdownPreviewView(
                        documentID: tabID,
                        markdown: result.markdown,
                        baseURL: fileURL.deletingLastPathComponent(),
                        options: appState.renderOptions(),
                        scrollSyncEnabled: false
                    )
                }
            }
        case .failed(let message):
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                Button("다시 시도") {
                    appState.retryOfficeConversion(tabID: tabID, fileURL: fileURL)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        case .loading, .none:
            VStack(spacing: 12) {
                ProgressView()
                Text("변환 중… (첫 실행은 kordoc 다운로드로 느릴 수 있어요)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// 편집 버퍼(officeEditBuffers[tabID])를 마크다운 에디터로 보여준다. 위키링크 자동완성은 끈다.
private struct OfficeEditorPane: View {
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme
    let tabID: UUID

    private func editorFont() -> NSFont {
        let size = appState.settings.fontSize
        let name = appState.settings.fontName
        if !name.isEmpty, let custom = NSFont(name: name, size: size) { return custom }
        return .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    var body: some View {
        let settings = appState.settings
        let theme = settings.editorTheme.resolved(forDark: colorScheme == .dark)
        MarkdownTextEditor(
            documentID: tabID,
            text: Binding(
                get: { appState.officeEditBuffers[tabID] ?? "" },
                set: { appState.officeEditBuffers[tabID] = $0 }
            ),
            font: editorFont(),
            editorTheme: theme,
            softWrap: settings.softWrap,
            showLineNumbers: settings.showLineNumbers,
            highlightCurrentLine: settings.highlightCurrentLine,
            tabSize: settings.tabSize,
            insertSpacesForTab: settings.insertSpacesInsteadOfTabs,
            enableCompletion: false,
            scrollSyncEnabled: false
        )
    }
}
