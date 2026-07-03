import XCTest
import WebKit
import PDFKit
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

    // ⌘A는 디스크 재열거가 아니라 라이브러리가 표시 중인 목록(libraryOrderedURLs)만 선택한다.
    func testSelectAllUsesLibraryOrderedURLs() throws {
        let a = try makeFile("a.md")
        let b = try makeFile("b.md")
        appState.libraryOrderedURLs = [a, b]

        appState.selectAllInLibrary()
        XCTAssertEqual(appState.fileSelection, [a, b])
        XCTAssertEqual(appState.selectionAnchor, a, "앵커 = 표시 목록 첫 항목")

        // 디스크에 c를 추가해도(리스트 미갱신) 선택에 안 들어옴 — 화면 목록만이 진실원.
        let c = try makeFile("c.md")
        appState.selectAllInLibrary()
        XCTAssertFalse(appState.fileSelection.contains(c), "화면에 없는 파일은 ⌘A에 안 잡힘")
        XCTAssertEqual(appState.fileSelection, [a, b])
    }

    // 파일 키를 양보해야 할 응답자 판정 — NSText·WKWebView·PDFView(및 그 서브뷰)는 true.
    func testResponderYieldsFileKeys() {
        XCTAssertFalse(AppState.responderYieldsFileKeys(nil), "nil → 양보 안 함")
        XCTAssertFalse(AppState.responderYieldsFileKeys(NSView()), "일반 NSView → 양보 안 함")
        XCTAssertTrue(AppState.responderYieldsFileKeys(NSTextView()), "NSText → 양보")

        let webView = WKWebView()
        XCTAssertTrue(AppState.responderYieldsFileKeys(webView), "WKWebView → 양보")
        // 웹뷰 내부 서브뷰가 firstResponder일 수 있어 조상 체인을 걷는다.
        let inner = NSView()
        webView.addSubview(inner)
        XCTAssertTrue(AppState.responderYieldsFileKeys(inner), "웹뷰 서브뷰 → 조상 체인으로 양보")

        let pdfView = PDFView()
        XCTAssertTrue(AppState.responderYieldsFileKeys(pdfView), "PDFView → 양보")
    }
}
