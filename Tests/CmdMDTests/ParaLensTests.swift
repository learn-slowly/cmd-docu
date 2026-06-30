import Testing
import Foundation
@testable import CmdMD

// MARK: - ParaLens 단위 테스트

@Suite("ParaLens")
struct ParaLensTests {

    // MARK: classify — 기본 매핑

    @Test("10000_ 접두사 → projects")
    func classifyProjects() {
        let url = URL(fileURLWithPath: "/Vault/10000_Projects/note.md")
        #expect(ParaLens.classify(url) == .projects)
    }

    @Test("20000_ 접두사 → areas")
    func classifyAreas() {
        let url = URL(fileURLWithPath: "/Vault/20000_Areas/health.md")
        #expect(ParaLens.classify(url) == .areas)
    }

    @Test("30000_ 접두사 → resources")
    func classifyResources() {
        let url = URL(fileURLWithPath: "/Vault/30000_Resources/book.md")
        #expect(ParaLens.classify(url) == .resources)
    }

    @Test("40000_ 접두사 → archive")
    func classifyArchive() {
        let url = URL(fileURLWithPath: "/Vault/40000_Archive/old.md")
        #expect(ParaLens.classify(url) == .archive)
    }

    // MARK: classify — 캐스케이드 (최상위 PARA 루트 우선)

    @Test("Projects 하위 깊은 경로도 projects")
    func classifyCascadeProjects() {
        let url = URL(fileURLWithPath: "/Vault/10000_Projects/Living_with_Damage/note.md")
        #expect(ParaLens.classify(url) == .projects)
    }

    @Test("Archive 하위 깊은 경로도 archive")
    func classifyCascadeArchive() {
        let url = URL(fileURLWithPath: "/Vault/40000_Archive/2024/old.pdf")
        #expect(ParaLens.classify(url) == .archive)
    }

    @Test("PARA 루트가 있으면 더 깊은 비매칭과 무관하게 해당 분류")
    func classifyCascadeIgnoresDeepNonMatch() {
        let url = URL(fileURLWithPath: "/Vault/20000_Areas/no_prefix_subfolder/file.md")
        #expect(ParaLens.classify(url) == .areas)
    }

    // MARK: classify — 접두사 없는 경로 → other

    @Test("접두사 없는 일반 폴더 → other")
    func classifyOtherNoPrefix() {
        let url = URL(fileURLWithPath: "/Vault/RandomFolder/file.md")
        #expect(ParaLens.classify(url) == .other)
    }

    @Test("루트 바로 아래 파일도 other")
    func classifyOtherRootFile() {
        let url = URL(fileURLWithPath: "/Vault/note.md")
        #expect(ParaLens.classify(url) == .other)
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
        let items: [FileTreeItem] = [
            FileTreeItem(url: URL(fileURLWithPath: "/Vault/40000_Archive"), isDirectory: true),
            FileTreeItem(url: URL(fileURLWithPath: "/Vault/20000_Areas"), isDirectory: true),
            FileTreeItem(url: URL(fileURLWithPath: "/Vault/10000_Projects"), isDirectory: true),
            FileTreeItem(url: URL(fileURLWithPath: "/Vault/30000_Resources"), isDirectory: true),
        ]
        let sorted = ParaLens.sorted(items)
        #expect(sorted.map(\.name) == [
            "10000_Projects",
            "20000_Areas",
            "30000_Resources",
            "40000_Archive",
        ])
    }

    @Test("archive는 항상 맨 끝, other는 그 앞")
    func sortedArchiveLast() {
        let items: [FileTreeItem] = [
            FileTreeItem(url: URL(fileURLWithPath: "/Vault/40000_Archive"), isDirectory: true),
            FileTreeItem(url: URL(fileURLWithPath: "/Vault/general_notes"), isDirectory: true),
            FileTreeItem(url: URL(fileURLWithPath: "/Vault/10000_Projects"), isDirectory: true),
        ]
        let sorted = ParaLens.sorted(items)
        let names = sorted.map(\.name)
        #expect(names.first == "10000_Projects")
        #expect(names.last == "40000_Archive")
    }

    // MARK: sorted — 같은 분류 내 폴더 먼저, 이름 오름차순

    @Test("같은 분류 내 폴더 먼저, 파일 나중")
    func sortedFoldersBeforeFiles() {
        let items: [FileTreeItem] = [
            FileTreeItem(url: URL(fileURLWithPath: "/Vault/10000_Projects/note.md"), isDirectory: false),
            FileTreeItem(url: URL(fileURLWithPath: "/Vault/10000_Projects/SubProject"), isDirectory: true),
        ]
        let sorted = ParaLens.sorted(items)
        #expect(sorted[0].isDirectory == true)
        #expect(sorted[1].isDirectory == false)
    }

    @Test("같은 분류·같은 종류 내 이름 오름차순")
    func sortedNameAscending() {
        let items: [FileTreeItem] = [
            FileTreeItem(url: URL(fileURLWithPath: "/Vault/10000_Projects/Beta"), isDirectory: true),
            FileTreeItem(url: URL(fileURLWithPath: "/Vault/10000_Projects/Alpha"), isDirectory: true),
        ]
        let sorted = ParaLens.sorted(items)
        #expect(sorted.map(\.name) == ["Alpha", "Beta"])
    }

    // MARK: sorted — 식별자·children 보존

    @Test("정렬 후 id와 children이 보존된다")
    func sortedPreservesIdentityAndChildren() {
        let child = FileTreeItem(url: URL(fileURLWithPath: "/Vault/40000_Archive/child.md"), isDirectory: false)
        let parent = FileTreeItem(url: URL(fileURLWithPath: "/Vault/40000_Archive"), isDirectory: true, children: [child])
        let other = FileTreeItem(url: URL(fileURLWithPath: "/Vault/10000_Projects"), isDirectory: true)

        let sorted = ParaLens.sorted([parent, other])

        // Projects가 앞, Archive가 뒤
        let archiveItem = sorted.last!
        #expect(archiveItem.id == parent.id)
        #expect(archiveItem.children.count == 1)
        #expect(archiveItem.children[0].id == child.id)
    }
}
