import SwiftUI

/// 한글·오피스 문서를 kordoc 변환 결과(마크다운)로 읽기전용 표시.
/// 상태: 변환 중 / 완료(기존 마크다운 프리뷰) / 실패(안내+재시도).
struct OfficeReaderView: View {
    @Environment(AppState.self) private var appState
    let tabID: UUID
    let fileURL: URL

    var body: some View {
        switch appState.officeStates[tabID] {
        case .loaded(let result):
            MarkdownPreviewView(
                documentID: tabID,
                markdown: result.markdown,
                baseURL: fileURL.deletingLastPathComponent(),
                options: appState.renderOptions(),
                scrollSyncEnabled: false
            )
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
