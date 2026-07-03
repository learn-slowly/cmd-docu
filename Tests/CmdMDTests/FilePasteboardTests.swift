import XCTest
@testable import CmdMD

final class FilePasteboardTests: XCTestCase {

    private var pasteboard: NSPasteboard!
    private var work: URL!

    override func setUpWithError() throws {
        // 시스템 general 페이스트보드를 오염시키지 않도록 고유 이름 인스턴스 사용.
        pasteboard = NSPasteboard(name: NSPasteboard.Name("f1b-test-\(UUID().uuidString)"))
        work = FileManager.default.temporaryDirectory
            .appendingPathComponent("pb-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    }

    override func tearDown() {
        pasteboard.releaseGlobally()
        try? FileManager.default.removeItem(at: work)
        super.tearDown()
    }

    func testWriteThenReadRoundTrip() throws {
        let a = work.appendingPathComponent("a.md")
        let b = work.appendingPathComponent("b.md")
        try Data("a".utf8).write(to: a)
        try Data("b".utf8).write(to: b)

        FilePasteboard.write([a, b], to: pasteboard)
        let read = FilePasteboard.readFileURLs(from: pasteboard)
        XCTAssertEqual(Set(read.map(\.standardizedFileURL.path)),
                       [a.standardizedFileURL.path, b.standardizedFileURL.path])
    }

    func testReadFiltersMissingFiles() throws {
        let a = work.appendingPathComponent("a.md")
        try Data("a".utf8).write(to: a)
        let ghost = work.appendingPathComponent("없음.md")
        FilePasteboard.write([a, ghost], to: pasteboard)
        let read = FilePasteboard.readFileURLs(from: pasteboard)
        XCTAssertEqual(read.map(\.lastPathComponent), ["a.md"], "실재하지 않는 파일은 걸러냄")
    }

    func testReadFromEmptyPasteboardIsEmpty() {
        XCTAssertTrue(FilePasteboard.readFileURLs(from: pasteboard).isEmpty)
    }

    func testWriteReplacesPreviousContents() throws {
        let a = work.appendingPathComponent("a.md")
        let b = work.appendingPathComponent("b.md")
        try Data("a".utf8).write(to: a)
        try Data("b".utf8).write(to: b)
        FilePasteboard.write([a], to: pasteboard)
        FilePasteboard.write([b], to: pasteboard)
        XCTAssertEqual(FilePasteboard.readFileURLs(from: pasteboard).map(\.lastPathComponent), ["b.md"])
    }
}
