import XCTest
@testable import CmdMD

@MainActor
final class AppPasteboardActionsTests: XCTestCase {

    private var tempData: URL!
    private var work: URL!
    private var appState: AppState!
    private var pasteboard: NSPasteboard!

    override func setUpWithError() throws {
        tempData = TempDataDirectory.make()
        work = FileManager.default.temporaryDirectory
            .appendingPathComponent("pbact-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        appState = AppState(dataDirectory: tempData)
        pasteboard = NSPasteboard(name: NSPasteboard.Name("f1b-act-\(UUID().uuidString)"))
    }

    override func tearDown() {
        pasteboard.releaseGlobally()
        TempDataDirectory.cleanup(tempData)
        try? FileManager.default.removeItem(at: work)
        tempData = nil; work = nil; appState = nil; pasteboard = nil
        super.tearDown()
    }

    private func makeFile(_ name: String) throws -> URL {
        let url = work.appendingPathComponent(name)
        try Data("본문".utf8).write(to: url)
        return url
    }

    func testCopySelectionWritesToPasteboard() throws {
        let a = try makeFile("a.md")
        appState.handleFileClick(a, modifier: .none, ordered: [a])
        XCTAssertTrue(appState.copySelectionToPasteboard(pasteboard))
        XCTAssertEqual(FilePasteboard.readFileURLs(from: pasteboard).map(\.lastPathComponent), ["a.md"])
    }

    func testCopyWithEmptySelectionReturnsFalse() {
        XCTAssertFalse(appState.copySelectionToPasteboard(pasteboard))
        XCTAssertTrue(FilePasteboard.readFileURLs(from: pasteboard).isEmpty, "빈 선택은 페이스트보드 불변")
    }

    func testPasteCopiesIntoExplicitFolder() async throws {
        let a = try makeFile("a.md")
        let dest = work.appendingPathComponent("대상")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        FilePasteboard.write([a], to: pasteboard)

        appState.pasteFromPasteboard(move: false, into: dest, pasteboard: pasteboard)
        // pasteFromPasteboard는 Task로 배치를 돌린다 — 완료 폴링(기존 async 테스트 관례).
        for _ in 0..<50 where !FileManager.default.fileExists(atPath: dest.appendingPathComponent("a.md").path) {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.appendingPathComponent("a.md").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.path), "복사 — 원본 불변")
    }

    func testPasteMoveMovesIntoFolder() async throws {
        let a = try makeFile("a.md")
        let dest = work.appendingPathComponent("대상")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        FilePasteboard.write([a], to: pasteboard)

        appState.pasteFromPasteboard(move: true, into: dest, pasteboard: pasteboard)
        for _ in 0..<50 where FileManager.default.fileExists(atPath: a.path) {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.path), "이동 — 원본 사라짐")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.appendingPathComponent("a.md").path))
    }

    func testSelectAllInLibrarySelectsDisplayFolderEntries() throws {
        _ = try makeFile("a.md")
        _ = try makeFile("b.md")
        appState.currentFolder = work
        appState.mainMode = .library
        appState.selectAllInLibrary()
        XCTAssertEqual(appState.fileSelection.count, 2)
    }
}
