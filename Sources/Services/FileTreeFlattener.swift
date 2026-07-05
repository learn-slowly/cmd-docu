import Foundation

// MARK: - FileTreeRow

/// 사이드바 트리의 "보이는 행" 하나 — 평탄화 결과(item + 들여쓰기 깊이).
/// identity는 URL: FileTreeItem.id(UUID)는 트리 재빌드마다 재발급돼 행 @State를
/// 파괴하므로 쓰지 않는다(F2에서 확정한 결정).
struct FileTreeRow: Identifiable {
    let item: FileTreeItem
    let depth: Int
    var id: URL { item.url }
}

// MARK: - FileTreeFlattener

/// 트리 평탄화(순수) — 트리 컨텍스트 메뉴 오귀속 수정(2026-07-05).
/// 자식들을 부모 List 행 안 VStack으로 렌더하면 macOS List가 우클릭을 행 단위로
/// 해석해 최상위 폴더의 contextMenu가 모든 자식 행을 가로챈다(실기 실증 — 자식
/// 이름변경·배치 메뉴 도달 불가, 최상위 폴더 휴지통 오발사 위험). 보이는 노드
/// 전부를 각자의 List 행으로 만들면 행마다 자기 메뉴가 정확히 붙는다.
/// 정렬은 기존 렌더 경로와 동일하게 레벨마다 LibrarySorting에 위임한다
/// (루트 레벨 parent=현재 폴더, 자식 레벨 parent=그 폴더 — 폴더별 정렬 기억 유지).
enum FileTreeFlattener {
    /// items(한 레벨)를 정렬한 뒤, 펼쳐진 폴더의 자식을 깊이 우선으로 이어붙인다.
    /// - Parameters:
    ///   - expanded: 펼쳐진 폴더 집합(AppState.expandedFolders).
    ///   - root: PARA 분류 기준 루트(현재 폴더) — LibrarySorting에 그대로 전달.
    ///   - parent: 이 레벨의 부모 폴더(정렬 조회 키). 루트 레벨은 root와 동일.
    ///   - sortFor: 폴더별 정렬 조회(AppState.sortForFolder 주입 — 순수성 유지).
    static func flatten(items: [FileTreeItem],
                        expanded: Set<URL>,
                        root: URL?,
                        depth: Int = 0,
                        parent: URL?,
                        sortFor: (URL?) -> LibrarySort) -> [FileTreeRow] {
        var rows: [FileTreeRow] = []
        for item in LibrarySorting.sorted(items, by: sortFor(parent), under: root) {
            rows.append(FileTreeRow(item: item, depth: depth))
            if item.isDirectory, expanded.contains(item.url) {
                rows.append(contentsOf: flatten(items: item.children, expanded: expanded,
                                                root: root, depth: depth + 1,
                                                parent: item.url, sortFor: sortFor))
            }
        }
        return rows
    }
}
