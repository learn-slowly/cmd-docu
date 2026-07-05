import XCTest
@testable import CmdMD

/// 트리 평탄화(FileTreeFlattener) — 트리 컨텍스트 메뉴 오귀속 수정(2026-07-05)의 순수 코어.
/// 자식을 부모 List 행 안 VStack으로 렌더하면 macOS가 우클릭을 행 단위로 해석해
/// 최상위 폴더 메뉴가 자식 행을 가로채던 결함의 구조적 수정: 보이는 노드 전부를
/// 각자의 List 행(item, depth)으로 편다.
final class FileTreeFlattenerTests: XCTestCase {

    private let root = URL(fileURLWithPath: "/tmp/flat-root")

    private func file(_ path: String) -> FileTreeItem {
        FileTreeItem(url: root.appendingPathComponent(path), isDirectory: false)
    }

    private func dir(_ path: String, children: [FileTreeItem] = []) -> FileTreeItem {
        FileTreeItem(url: root.appendingPathComponent(path), isDirectory: true, children: children)
    }

    private func names(_ rows: [FileTreeRow]) -> [String] { rows.map { $0.item.name } }

    /// 접힌 상태: 최상위만, 폴더 먼저 + 이름순(기본 정렬 위임 확인).
    func testCollapsedEmitsTopLevelOnly() {
        let tree = [file("b.md"), dir("폴더", children: [file("폴더/안쪽.md")]), file("a.md")]
        let rows = FileTreeFlattener.flatten(items: tree, expanded: [], root: root,
                                             parent: root, sortFor: { _ in .default })
        XCTAssertEqual(names(rows), ["폴더", "a.md", "b.md"], "폴더 먼저 + 이름순, 자식 미방출")
        XCTAssertEqual(rows.map(\.depth), [0, 0, 0])
    }

    /// 펼친 폴더: 자식이 부모 바로 다음, depth+1, 다음 형제보다 앞.
    func testExpandedInsertsChildrenAfterParent() {
        let folder = dir("폴더", children: [file("폴더/안쪽.md")])
        let tree = [folder, file("z.md")]
        let rows = FileTreeFlattener.flatten(items: tree, expanded: [folder.url], root: root,
                                             parent: root, sortFor: { _ in .default })
        XCTAssertEqual(names(rows), ["폴더", "안쪽.md", "z.md"])
        XCTAssertEqual(rows.map(\.depth), [0, 1, 0])
    }

    /// 중첩 펼침: depth가 단계마다 +1.
    func testNestedExpansionDepths() {
        let inner = dir("바깥/안", children: [file("바깥/안/깊은.md")])
        let outer = dir("바깥", children: [inner])
        let rows = FileTreeFlattener.flatten(items: [outer], expanded: [outer.url, inner.url],
                                             root: root, parent: root, sortFor: { _ in .default })
        XCTAssertEqual(names(rows), ["바깥", "안", "깊은.md"])
        XCTAssertEqual(rows.map(\.depth), [0, 1, 2])
    }

    /// 접힌 부모의 자식은 expanded 집합에 있어도 방출 안 됨(고아 펼침 상태 무해).
    func testExpandedChildUnderCollapsedParentIsHidden() {
        let inner = dir("바깥/안", children: [file("바깥/안/깊은.md")])
        let outer = dir("바깥", children: [inner])
        let rows = FileTreeFlattener.flatten(items: [outer], expanded: [inner.url],
                                             root: root, parent: root, sortFor: { _ in .default })
        XCTAssertEqual(names(rows), ["바깥"])
    }

    /// 폴더별 정렬 주입: 루트는 기본, 특정 폴더 자식만 이름 내림차순.
    func testPerFolderSortInjection() {
        let folder = dir("폴더", children: [file("폴더/a.md"), file("폴더/b.md")])
        let rows = FileTreeFlattener.flatten(
            items: [folder], expanded: [folder.url], root: root, parent: root,
            sortFor: { parent in
                parent == folder.url ? LibrarySort(key: .name, ascending: false) : .default
            })
        XCTAssertEqual(names(rows), ["폴더", "b.md", "a.md"], "자식 레벨만 내림차순")
    }

    /// 행 identity는 URL(재빌드마다 UUID 재발급돼도 @State 보존 — F2 결정 유지).
    func testRowIdentityIsURL() {
        let a = file("a.md")
        let rows = FileTreeFlattener.flatten(items: [a], expanded: [], root: root,
                                             parent: root, sortFor: { _ in .default })
        XCTAssertEqual(rows.first?.id, a.url)
    }

    // MARK: PARA root 스레딩 고정(리뷰 지적 — 뮤테이션 킬 테스트)

    /// flatten이 root를 nil로 흘리면 죽는 테스트 — 루트 경로의 "조상"에 PARA 접두사를 두면
    /// nil(전체 경로 스캔)일 때 모든 항목이 조상 분류로 오염돼 archive가 맨 끝으로 못 간다.
    func testRootThreadingKillsNilMutation() {
        let paraRoot = URL(fileURLWithPath: "/tmp/10000_Ancestor/testroot")
        let items = [
            FileTreeItem(url: paraRoot.appendingPathComponent("40000_Archive"), isDirectory: true),
            FileTreeItem(url: paraRoot.appendingPathComponent("가나다"), isDirectory: true),
        ]
        let rows = FileTreeFlattener.flatten(items: items, expanded: [], root: paraRoot,
                                             parent: paraRoot, sortFor: { _ in .default })
        // 올바른 root 기준: 40000_Archive=archive → 맨 끝. (root=nil이면 둘 다 조상
        // 10000_ 접두사로 projects가 돼 이름순 [40000_Archive, 가나다]로 뒤집힌다.)
        XCTAssertEqual(names(rows), ["가나다", "40000_Archive"])
    }

    /// flatten 재귀가 root 대신 각 레벨의 parent를 root로 흘리면 죽는 테스트 —
    /// PARA 폴더(10000_) 아래 일반 폴더(plain)의 자식은 "루트 기준"으론 projects지만,
    /// root=plain으로 잘못 흘리면 40000_X가 archive로 재분류돼 맨 끝으로 밀린다.
    func testRootThreadingKillsPerLevelParentMutation() {
        let top = dir("10000_Top", children: [])
        let plain = FileTreeItem(url: top.url.appendingPathComponent("plain"), isDirectory: true,
                                 children: [
                                     FileTreeItem(url: top.url.appendingPathComponent("plain/40000_X"),
                                                  isDirectory: true),
                                     FileTreeItem(url: top.url.appendingPathComponent("plain/B"),
                                                  isDirectory: true),
                                 ])
        let topExpanded = FileTreeItem(url: top.url, isDirectory: true, children: [plain])
        let rows = FileTreeFlattener.flatten(items: [topExpanded],
                                             expanded: [topExpanded.url, plain.url],
                                             root: root, parent: root, sortFor: { _ in .default })
        // 올바른 root 기준: 40000_X도 첫 매치가 10000_Top이라 projects → 이름순 40000_X, B.
        // (root=parent(plain)이면 40000_X=archive → [B, 40000_X]로 뒤집힌다.)
        XCTAssertEqual(names(rows), ["10000_Top", "plain", "40000_X", "B"])
        XCTAssertEqual(rows.map(\.depth), [0, 1, 2, 2])
    }
}
