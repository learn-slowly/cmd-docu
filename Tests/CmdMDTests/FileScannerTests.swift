import XCTest
@testable import CmdMD

final class FileScannerTests: XCTestCase {
    private func makeTempDir() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scan-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testScanReturnsTopLevelFilesOnly() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "a".write(to: dir.appendingPathComponent("note.md"), atomically: true, encoding: .utf8)
        try "b".write(to: dir.appendingPathComponent("pic.png"), atomically: true, encoding: .utf8)
        // 하위폴더와 숨김파일은 제외돼야 한다
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try "c".write(to: dir.appendingPathComponent(".hidden"), atomically: true, encoding: .utf8)

        let metas = FileScanner.scan(dir)
        XCTAssertEqual(metas.map { $0.name }, ["note.md", "pic.png"])
        XCTAssertEqual(metas.first?.ext, "md")
    }

    func testScanMissingFolderReturnsEmpty() {
        let metas = FileScanner.scan(URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)"))
        XCTAssertTrue(metas.isEmpty)
    }
}
