import XCTest
@testable import CmdMD

final class FileOperationsTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fileops-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        dir = nil
        super.tearDown()
    }

    private func makeFile(_ name: String, contents: String = "본문") throws -> URL {
        let url = dir.appendingPathComponent(name)
        try contents.data(using: .utf8)!.write(to: url)
        return url
    }

    // MARK: rename

    func testRenameFileSuccess() throws {
        let src = try makeFile("원본.md")
        let result = try FileOperations.rename(at: src, to: "새이름.md")
        XCTAssertEqual(result, dir.appendingPathComponent("새이름.md"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: src.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.path))
    }

    func testRenameFolderSuccess() throws {
        let src = dir.appendingPathComponent("폴더A")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        let result = try FileOperations.rename(at: src, to: "폴더B")
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.path))
        XCTAssertEqual(result.lastPathComponent, "폴더B")
    }

    func testRenameRejectsEmptyOrWhitespaceName() throws {
        let src = try makeFile("a.md")
        XCTAssertThrowsError(try FileOperations.rename(at: src, to: "")) {
            XCTAssertEqual($0 as? FileOperationError, .emptyName)
        }
        XCTAssertThrowsError(try FileOperations.rename(at: src, to: "   ")) {
            XCTAssertEqual($0 as? FileOperationError, .emptyName)
        }
    }

    func testRenameRejectsSlash() throws {
        let src = try makeFile("a.md")
        XCTAssertThrowsError(try FileOperations.rename(at: src, to: "b/c.md")) {
            XCTAssertEqual($0 as? FileOperationError, .invalidName)
        }
    }

    func testRenameRejectsSameName() throws {
        let src = try makeFile("a.md")
        XCTAssertThrowsError(try FileOperations.rename(at: src, to: "a.md")) {
            XCTAssertEqual($0 as? FileOperationError, .sameName)
        }
    }

    func testRenameRejectsExistingTarget() throws {
        let src = try makeFile("a.md")
        _ = try makeFile("b.md")
        XCTAssertThrowsError(try FileOperations.rename(at: src, to: "b.md")) {
            XCTAssertEqual($0 as? FileOperationError, .alreadyExists("b.md"))
        }
        // 실패 시 원본 불변
        XCTAssertTrue(FileManager.default.fileExists(atPath: src.path))
    }

    func testRenameAllowsCaseOnlyChange() throws {
        // APFS 기본(대소문자 무시)에서 fileExists("A.md")가 true라도 대소문자만 다른 rename은 허용.
        let src = try makeFile("a.md")
        let result = try FileOperations.rename(at: src, to: "A.md")
        XCTAssertEqual(result.lastPathComponent, "A.md")
    }

    func testRenameMissingSource() {
        let ghost = dir.appendingPathComponent("없음.md")
        XCTAssertThrowsError(try FileOperations.rename(at: ghost, to: "x.md")) {
            XCTAssertEqual($0 as? FileOperationError, .sourceMissing)
        }
    }

    // MARK: createFolder

    func testCreateFolderDefaultName() throws {
        let created = try FileOperations.createFolder(in: dir)
        XCTAssertEqual(created.lastPathComponent, "새 폴더")
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: created.path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
    }

    func testCreateFolderUniquifiesOnConflict() throws {
        _ = try FileOperations.createFolder(in: dir)
        let second = try FileOperations.createFolder(in: dir)
        XCTAssertEqual(second.lastPathComponent, "새 폴더 (1)")
    }

    // MARK: trash

    func testTrashMovesToTrashAndReturnsLocation() throws {
        let src = try makeFile("버릴것.md")
        let trashed: URL
        do {
            trashed = try FileOperations.trash(at: src)
        } catch {
            throw XCTSkip("휴지통 접근 불가 환경: \(error)")
        }
        defer { try? FileManager.default.removeItem(at: trashed) }   // 테스트 자체 픽스처 정리
        XCTAssertFalse(FileManager.default.fileExists(atPath: src.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: trashed.path))
    }

    func testTrashMissingSource() {
        let ghost = dir.appendingPathComponent("없음.md")
        XCTAssertThrowsError(try FileOperations.trash(at: ghost)) {
            XCTAssertEqual($0 as? FileOperationError, .sourceMissing)
        }
    }
}
