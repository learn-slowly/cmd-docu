import SwiftUI

/// 다중 선택 배치 메뉴 — 우클릭 셀이 선택 집합에 포함되고 2개 이상일 때 단건 메뉴를 대체.
/// 라이브러리 셀·트리 행 공용(F1b 스펙 §7).
struct BatchSelectionMenu: View {
    @Environment(AppState.self) private var appState
    /// 우클릭한 셀 — 폴더면 '이 폴더에 붙여넣기'를 살린다(단건 메뉴와 동일 항목).
    let item: FileTreeItem

    var body: some View {
        // 실제 처리 건수(부모+자식 동시 선택 시 조상만) — 라벨과 휴지통 인자가 같은 값을 쓴다.
        let targets = FileSelectionHelper.ancestorsOnly(appState.fileSelection)
        let count = targets.count
        Button {
            _ = appState.copySelectionToPasteboard()
        } label: {
            Label("\(count)개 항목 복사", systemImage: "doc.on.doc")
        }
        Button {
            appState.promptBatchMove(urls: targets)
        } label: {
            Label("\(count)개 항목 폴더로 이동…", systemImage: "folder")
        }
        // 폴더 셀 위에서 우클릭했고 페이스트보드에 파일이 있으면 붙여넣기(단건 메뉴 패리티).
        if item.isDirectory && !FilePasteboard.readFileURLs().isEmpty {
            Button {
                appState.pasteFromPasteboard(move: false, into: item.url)
            } label: {
                Label("이 폴더에 붙여넣기", systemImage: "doc.on.clipboard")
            }
        }
        Button {
            // 폴더는 requestWikiBatchIngest가 걸러낸다(문서 단위 기능) — 라벨은 선택 건수 기준.
            appState.requestWikiBatchIngest(sources: targets)
        } label: {
            Label("\(count)개 항목 위키에 인제스트…", systemImage: "text.badge.plus")
        }
        Divider()
        Button(role: .destructive) {
            appState.batchTrashWithConfirmation(targets)
        } label: {
            Label("\(count)개 항목 휴지통으로 이동", systemImage: "trash")
        }
    }
}
