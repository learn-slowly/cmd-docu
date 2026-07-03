import SwiftUI

/// 다중 선택 배치 메뉴 — 우클릭 셀이 선택 집합에 포함되고 2개 이상일 때 단건 메뉴를 대체.
/// 라이브러리 셀·트리 행 공용(F1b 스펙 §7).
struct BatchSelectionMenu: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let count = appState.fileSelection.count
        Button {
            _ = appState.copySelectionToPasteboard()
        } label: {
            Label("\(count)개 항목 복사", systemImage: "doc.on.doc")
        }
        Button {
            appState.promptBatchMove()
        } label: {
            Label("\(count)개 항목 폴더로 이동…", systemImage: "folder")
        }
        Divider()
        Button(role: .destructive) {
            appState.batchTrashWithConfirmation(Array(appState.fileSelection))
        } label: {
            Label("\(count)개 항목 휴지통으로 이동", systemImage: "trash")
        }
    }
}
