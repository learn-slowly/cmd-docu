import Testing
import Foundation
@testable import CmdMD

// MARK: - ParaLens 단위 테스트

@Suite("ParaLens")
struct ParaLensTests {

    // MARK: classify — 기본 매핑 (root = 볼트 루트)

    @Test("10000_ 접두사 → projects")
    func classifyProjects() {
        let root = URL(fileURLWithPath: "/Vault")
        let url  = URL(fileURLWithPath: "/Vault/10000_Projects/note.md")
        #expect(ParaLens.classify(url, under: root) == .projects)
    }

    @Test("20000_ 접두사 → areas")
    func classifyAreas() {
        let root = URL(fileURLWithPath: "/Vault")
        let url  = URL(fileURLWithPath: "/Vault/20000_Areas/health.md")
        #expect(ParaLens.classify(url, under: root) == .areas)
    }

    @Test("30000_ 접두사 → resources")
    func classifyResources() {
        let root = URL(fileURLWithPath: "/Vault")
        let url  = URL(fileURLWithPath: "/Vault/30000_Resources/book.md")
        #expect(ParaLens.classify(url, under: root) == .resources)
    }

    @Test("40000_ 접두사 → archive")
    func classifyArchive() {
        let root = URL(fileURLWithPath: "/Vault")
        let url  = URL(fileURLWithPath: "/Vault/40000_Archive/old.md")
        #expect(ParaLens.classify(url, under: root) == .archive)
    }

    // MARK: classify — 캐스케이드 (최상위 PARA 루트 우선)

    @Test("Projects 하위 깊은 경로도 projects")
    func classifyCascadeProjects() {
        let root = URL(fileURLWithPath: "/Vault")
        let url  = URL(fileURLWithPath: "/Vault/10000_Projects/Living_with_Damage/note.md")
        #expect(ParaLens.classify(url, under: root) == .projects)
    }

    @Test("Archive 하위 깊은 경로도 archive")
    func classifyCascadeArchive() {
        let root = URL(fileURLWithPath: "/Vault")
        let url  = URL(fileURLWithPath: "/Vault/40000_Archive/2024/old.pdf")
        #expect(ParaLens.classify(url, under: root) == .archive)
    }

    @Test("PARA 루트가 있으면 더 깊은 비매칭과 무관하게 해당 분류")
    func classifyCascadeIgnoresDeepNonMatch() {
        let root = URL(fileURLWithPath: "/Vault")
        let url  = URL(fileURLWithPath: "/Vault/20000_Areas/no_prefix_subfolder/file.md")
        #expect(ParaLens.classify(url, under: root) == .areas)
    }

    // MARK: classify — 접두사 없는 경로 → other

    @Test("접두사 없는 일반 폴더 → other")
    func classifyOtherNoPrefix() {
        let root = URL(fileURLWithPath: "/Vault")
        let url  = URL(fileURLWithPath: "/Vault/RandomFolder/file.md")
        #expect(ParaLens.classify(url, under: root) == .other)
    }

    @Test("루트 바로 아래 파일도 other")
    func classifyOtherRootFile() {
        let root = URL(fileURLWithPath: "/Vault")
        let url  = URL(fileURLWithPath: "/Vault/note.md")
        #expect(ParaLens.classify(url, under: root) == .other)
    }

    // MARK: sortRank — archive 맨 끝

    @Test("sortRank: projects 0, areas 1, resources 2, other 3, archive 4")
    func sortRankOrder() {
        #expect(ParaCategory.projects.sortRank == 0)
        #expect(ParaCategory.areas.sortRank == 1)
        #expect(ParaCategory.resources.sortRank == 2)
        #expect(ParaCategory.other.sortRank == 3)
        #expect(ParaCategory.archive.sortRank == 4)
    }

    // MARK: sorted — 루트 4개 PARA 순서

    @Test("루트 PARA 폴더 4개가 Projects→Areas→Resources→Archive 순")
    func sortedParaRootOrder() {
        let root = URL(fileURLWithPath: "/Vault")
        let items: [FileTreeItem] = [
            FileTreeItem(url: URL(fileURLWithPath: "/Vault/40000_Archive"), isDirectory: true),
            FileTreeItem(url: URL(fileURLWithPath: "/Vault/20000_Areas"), isDirectory: true),
            FileTreeItem(url: URL(fileURLWithPath: "/Vault/10000_Projects"), isDirectory: true),
            FileTreeItem(url: URL(fileURLWithPath: "/Vault/30000_Resources"), isDirectory: true),
        ]
        let sorted = ParaLens.sorted(items, under: root)
        #expect(sorted.map(\.name) == [
            "10000_Projects",
            "20000_Areas",
            "30000_Resources",
            "40000_Archive",
        ])
    }

    @Test("archive는 항상 맨 끝, other는 그 앞")
    func sortedArchiveLast() {
        let root = URL(fileURLWithPath: "/Vault")
        let items: [FileTreeItem] = [
            FileTreeItem(url: URL(fileURLWithPath: "/Vault/40000_Archive"), isDirectory: true),
            FileTreeItem(url: URL(fileURLWithPath: "/Vault/general_notes"), isDirectory: true),
            FileTreeItem(url: URL(fileURLWithPath: "/Vault/10000_Projects"), isDirectory: true),
        ]
        let sorted = ParaLens.sorted(items, under: root)
        let names = sorted.map(\.name)
        #expect(names.first == "10000_Projects")
        #expect(names.last == "40000_Archive")
    }

    // MARK: sorted — 같은 분류 내 폴더 먼저, 이름 오름차순

    @Test("같은 분류 내 폴더 먼저, 파일 나중")
    func sortedFoldersBeforeFiles() {
        let root = URL(fileURLWithPath: "/Vault")
        let items: [FileTreeItem] = [
            FileTreeItem(url: URL(fileURLWithPath: "/Vault/10000_Projects/note.md"), isDirectory: false),
            FileTreeItem(url: URL(fileURLWithPath: "/Vault/10000_Projects/SubProject"), isDirectory: true),
        ]
        let sorted = ParaLens.sorted(items, under: root)
        #expect(sorted[0].isDirectory == true)
        #expect(sorted[1].isDirectory == false)
    }

    @Test("같은 분류·같은 종류 내 이름 오름차순")
    func sortedNameAscending() {
        let root = URL(fileURLWithPath: "/Vault")
        let items: [FileTreeItem] = [
            FileTreeItem(url: URL(fileURLWithPath: "/Vault/10000_Projects/Beta"), isDirectory: true),
            FileTreeItem(url: URL(fileURLWithPath: "/Vault/10000_Projects/Alpha"), isDirectory: true),
        ]
        let sorted = ParaLens.sorted(items, under: root)
        #expect(sorted.map(\.name) == ["Alpha", "Beta"])
    }

    // MARK: sorted — 식별자·children 보존

    @Test("정렬 후 id와 children이 보존된다")
    func sortedPreservesIdentityAndChildren() {
        let root   = URL(fileURLWithPath: "/Vault")
        let child  = FileTreeItem(url: URL(fileURLWithPath: "/Vault/40000_Archive/child.md"), isDirectory: false)
        let parent = FileTreeItem(url: URL(fileURLWithPath: "/Vault/40000_Archive"), isDirectory: true, children: [child])
        let other  = FileTreeItem(url: URL(fileURLWithPath: "/Vault/10000_Projects"), isDirectory: true)

        let sorted = ParaLens.sorted([parent, other], under: root)

        // Projects가 앞, Archive가 뒤
        let archiveItem = sorted.last!
        #expect(archiveItem.id == parent.id)
        #expect(archiveItem.children.count == 1)
        #expect(archiveItem.children[0].id == child.id)
    }

    // MARK: 회귀 테스트 — 볼트 조상의 PARA 접두사로 오분류 방지

    @Test("볼트가 PARA 접두사 조상 아래 있어도 볼트 내부 Projects는 projects")
    func classifyNoAncestorLeak() {
        // 수정 전: classify 전체 경로 스캔 → 조상 40000_Archive 때문에 archive 오분류
        // 수정 후: root 기준 스캔 → 볼트 이름(MyNotes)부터 시작해 10000_Projects 매칭
        let root = URL(fileURLWithPath: "/Users/me/40000_Archive/MyNotes")
        let url  = URL(fileURLWithPath: "/Users/me/40000_Archive/MyNotes/10000_Projects/note.md")
        #expect(ParaLens.classify(url, under: root) == .projects)
    }

    @Test("볼트 내부 Archive 폴더는 archive(볼트 내부 PARA는 정상 작동)")
    func classifyInternalArchiveKept() {
        let root = URL(fileURLWithPath: "/Users/me/40000_Archive/MyNotes")
        let url  = URL(fileURLWithPath: "/Users/me/40000_Archive/MyNotes/40000_Archive/x.md")
        #expect(ParaLens.classify(url, under: root) == .archive)
    }

    @Test("root nil이면 전체 경로 스캔 — 조상 PARA도 매칭(기존 동작)")
    func classifyNilRootFullScan() {
        // root nil → 처음부터 스캔 → 조상 40000_Archive 매칭 → archive
        let url = URL(fileURLWithPath: "/Users/me/40000_Archive/MyNotes/note.md")
        #expect(ParaLens.classify(url, under: nil) == .archive)
    }
}
