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

    private func makeFolder(_ relative: String) throws -> URL {
        let url = dir.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
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

    // MARK: move (F1b)

    func testMoveIntoFolder() throws {
        let src = try makeFile("a.md")
        let dest = try makeFolder("대상")
        let moved = try FileOperations.move(at: src, to: dest)
        XCTAssertEqual(moved, dest.appendingPathComponent("a.md"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: src.path))
    }

    func testMoveConflictUniquifies() throws {
        let src = try makeFile("a.md")
        let dest = try makeFolder("대상")
        try Data("점유".utf8).write(to: dest.appendingPathComponent("a.md"))
        let moved = try FileOperations.move(at: src, to: dest)
        XCTAssertEqual(moved.lastPathComponent, "a (1).md")
    }

    func testMoveToSameParentThrows() throws {
        // 제자리 이동을 허용하면 uniquify가 "a (1).md" 복제 개명으로 둔갑 — 반드시 에러.
        let src = try makeFile("a.md")
        XCTAssertThrowsError(try FileOperations.move(at: src, to: src.deletingLastPathComponent())) { error in
            guard case FileOperationError.invalidDestination = error else {
                return XCTFail("invalidDestination이어야 함: \(error)")
            }
        }
    }

    func testMoveFolderIntoItselfOrDescendantThrows() throws {
        let folder = try makeFolder("상위")
        let child = try makeFolder("상위/하위")
        XCTAssertThrowsError(try FileOperations.move(at: folder, to: folder))
        XCTAssertThrowsError(try FileOperations.move(at: folder, to: child))
        // '/' 경계 — 형제 "상위2"는 하위가 아니다.
        let sibling = try makeFolder("상위2")
        XCTAssertNoThrow(try FileOperations.move(at: folder, to: sibling))
    }

    func testMoveMissingSourceThrows() throws {
        let dest = try makeFolder("대상")
        let ghost = dir.appendingPathComponent("없음.md")
        XCTAssertThrowsError(try FileOperations.move(at: ghost, to: dest)) { error in
            XCTAssertEqual(error as? FileOperationError, .sourceMissing)
        }
    }

    // MARK: copy (F1b)

    func testCopyIntoFolder() throws {
        let src = try makeFile("a.md")
        let dest = try makeFolder("대상")
        let copied = try FileOperations.copy(at: src, to: dest)
        XCTAssertEqual(copied, dest.appendingPathComponent("a.md"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: src.path), "원본 불변")
        XCTAssertTrue(FileManager.default.fileExists(atPath: copied.path))
    }

    func testCopyToSameParentMakesUniquifiedDuplicate() throws {
        // 같은 폴더 복사 = 사본 시맨틱("a (1).md") — move와 달리 허용.
        let src = try makeFile("a.md")
        let copied = try FileOperations.copy(at: src, to: src.deletingLastPathComponent())
        XCTAssertEqual(copied.lastPathComponent, "a (1).md")
    }

    func testCopyFolderIntoOwnDescendantThrows() throws {
        let folder = try makeFolder("상위")
        let child = try makeFolder("상위/하위")
        XCTAssertThrowsError(try FileOperations.copy(at: folder, to: child))
    }
}
