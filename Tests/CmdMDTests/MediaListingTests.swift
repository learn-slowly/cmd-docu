import XCTest
@testable import CmdMD

/// 목록(사이드바 트리·라이브러리) — 미디어 표시·짝꿍 노트 숨김·배지 플래그.
final class MediaListingTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("media-listing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // fixture: 노트 있는 미디어 / 노트 없는 미디어 / 고아 노트 / 일반 노트
        for name in ["a.mp3", "a.mp3.md", "b.mp4", "c.mov.md", "일반.md"] {
            FileManager.default.createFile(
                atPath: dir.appendingPathComponent(name).path,
                contents: Data("x".utf8))
        }
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        dir = nil
        super.tearDown()
    }

    func testMediaIsListableInFileTree() {
        XCTAssertTrue(AppState.isListableInFileTree(URL(fileURLWithPath: "/tmp/a.mp3")))
        XCTAssertTrue(AppState.isListableInFileTree(URL(fileURLWithPath: "/tmp/a.MOV")))
        XCTAssertFalse(AppState.isListableInFileTree(URL(fileURLWithPath: "/tmp/a.exe")))
    }

    func testBuildFileTreeHidesCompanionNoteAndFlagsMedia() {
        let items = AppState.buildFileTree(at: dir, expanded: [])
        let names = items.map(\.name)
        XCTAssertTrue(names.contains("a.mp3"))
        XCTAssertFalse(names.contains("a.mp3.md"), "짝꿍 노트는 숨긴다")
        XCTAssertTrue(names.contains("b.mp4"))
        XCTAssertTrue(names.contains("c.mov.md"), "고아 노트는 일반 노트로 표시")
        XCTAssertTrue(names.contains("일반.md"))

        let a = items.first { $0.name == "a.mp3" }
        let b = items.first { $0.name == "b.mp4" }
        XCTAssertEqual(a?.hasCompanionNote, true, "노트 있는 미디어는 배지 플래그 true")
        XCTAssertEqual(b?.hasCompanionNote, false)
    }

    func testLibraryListingMatchesTreeBehavior() {
        let items = LibraryListing.entries(of: dir)
        let names = items.map(\.name)
        XCTAssertTrue(names.contains("a.mp3"))
        XCTAssertFalse(names.contains("a.mp3.md"))
        XCTAssertEqual(items.first { $0.name == "a.mp3" }?.hasCompanionNote, true)
        XCTAssertEqual(items.first { $0.name == "b.mp4" }?.hasCompanionNote, false)
    }

    func testMediaIcons() {
        XCTAssertEqual(FileTreeItem(url: URL(fileURLWithPath: "/tmp/a.mp3")).icon, "music.note")
        XCTAssertEqual(FileTreeItem(url: URL(fileURLWithPath: "/tmp/a.mp4")).icon, "film")
    }
}
