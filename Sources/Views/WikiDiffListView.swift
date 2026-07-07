import SwiftUI

/// 병합 diff 목록 렌더 — 단일(WikiIngestView)·일괄(WikiBatchIngestView) 인제스트 시트 공용.
struct WikiDiffListView: View {
    let lines: [LineDiff.Line]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                    row(line)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 180, maxHeight: 320)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private func row(_ line: LineDiff.Line) -> some View {
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
}
