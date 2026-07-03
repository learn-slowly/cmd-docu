import XCTest
import Foundation
@testable import CmdMD

final class LibraryListingTests: XCTestCase {

    // MARK: - 테스트용 임시 디렉터리 관리

    private var tmpDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tmpDir = try FileManager.default.url(
            for: .itemReplacementDirectory,
            in: .userDomainMask,
            appropriateFor: FileManager.default.temporaryDirectory,
            create: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmpDir)
        try super.tearDownWithError()
    }

    // MARK: - 직속 자식만 반환

    func testEntriesReturnsDirectChildren() throws {
        // 파일 하나, 폴더 하나 생성
        let file = tmpDir.appendingPathComponent("note.md")
        let folder = tmpDir.appendingPathComponent("SubFolder")
        try "내용".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)

        // 폴더 안의 파일은 결과에 포함되면 안 된다
        let nested = folder.appendingPathComponent("nested.md")
        try "중첩".write(to: nested, atomically: true, encoding: .utf8)

        let result = LibraryListing.entries(of: tmpDir)
        let names = result.map(\.name).sorted()
        XCTAssertEqual(names, ["SubFolder", "note.md"],
                       "직속 자식(파일+폴더)만 반환해야 한다")
    }

    // MARK: - 숨김 파일 제외

    func testEntriesExcludesHiddenFiles() throws {
        let visible = tmpDir.appendingPathComponent("visible.md")
        let hidden = tmpDir.appendingPathComponent(".hidden.md")
        try "v".write(to: visible, atomically: true, encoding: .utf8)
        try "h".write(to: hidden, atomically: true, encoding: .utf8)

        let result = LibraryListing.entries(of: tmpDir)
        XCTAssertFalse(result.contains(where: { $0.name.hasPrefix(".") }),
                       "숨김 파일(.으로 시작)은 제외해야 한다")
        XCTAssertTrue(result.contains(where: { $0.name == "visible.md" }))
    }

    // MARK: - isDirectory 플래그

    func testEntriesMarksFolderAsDirectory() throws {
        let folder = tmpDir.appendingPathComponent("MyFolder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)

        let result = LibraryListing.entries(of: tmpDir)
        guard let item = result.first(where: { $0.name == "MyFolder" }) else {
            return XCTFail("MyFolder가 결과에 없음")
        }
        XCTAssertTrue(item.isDirectory, "폴더 항목의 isDirectory는 true여야 한다")
    }

    func testEntriesMarksFileAsNotDirectory() throws {
        let file = tmpDir.appendingPathComponent("note.md")
        try "내용".write(to: file, atomically: true, encoding: .utf8)

        let result = LibraryListing.entries(of: tmpDir)
        guard let item = result.first(where: { $0.name == "note.md" }) else {
            return XCTFail("note.md가 결과에 없음")
        }
        XCTAssertFalse(item.isDirectory, "파일 항목의 isDirectory는 false여야 한다")
    }

    // MARK: - 빈 폴더

    func testEntriesReturnsEmptyArrayForEmptyFolder() throws {
        let result = LibraryListing.entries(of: tmpDir)
        XCTAssertTrue(result.isEmpty, "빈 폴더는 빈 배열을 반환해야 한다")
    }

    // MARK: - 존재하지 않는 폴더

    func testEntriesReturnsEmptyArrayForNonexistentFolder() {
        let nonexistent = URL(fileURLWithPath: "/tmp/librarylistingtest_nonexistent_\(UUID().uuidString)")
        let result = LibraryListing.entries(of: nonexistent)
        XCTAssertTrue(result.isEmpty, "존재하지 않는 폴더는 빈 배열을 반환해야 한다(크래시 없음)")
    }

    // MARK: - 지원 파일 필터링

    func testEntriesIncludesSupportedFileTypes() throws {
        let extensions = ["md", "txt", "png", "jpg", "pdf", "hwpx", "docx"]
        for ext in extensions {
            let file = tmpDir.appendingPathComponent("test.\(ext)")
            try "".write(to: file, atomically: true, encoding: .utf8)
        }
        let result = LibraryListing.entries(of: tmpDir)
        let names = result.map(\.name)
        for ext in extensions {
            XCTAssertTrue(names.contains("test.\(ext)"), ".\(ext) 파일이 포함돼야 한다")
        }
    }

    func testEntriesExcludesUnsupportedFileTypes() throws {
        let file = tmpDir.appendingPathComponent("archive.zip")
        try "".write(to: file, atomically: true, encoding: .utf8)

        let result = LibraryListing.entries(of: tmpDir)
        XCTAssertFalse(result.contains(where: { $0.name == "archive.zip" }),
                       "지원하지 않는 확장자(.zip)는 제외해야 한다")
    }

    // MARK: - ParaLens.sorted와 결합

    func testEntriesWithParaSortPutsArchiveLast() throws {
        // 폴더 구조: 10000_Projects, 40000_Archive, 일반폴더
        for name in ["40000_Archive", "10000_Projects", "General"] {
            let folder = tmpDir.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        }

        let entries = LibraryListing.entries(of: tmpDir)
        let sorted = ParaLens.sorted(entries, under: tmpDir)
        XCTAssertEqual(sorted.last?.name, "40000_Archive",
                       "ParaLens.sorted 적용 시 archive가 맨 끝이어야 한다")
        XCTAssertEqual(sorted.first?.name, "10000_Projects",
                       "ParaLens.sorted 적용 시 projects가 맨 앞이어야 한다")
    }

    // MARK: - 리스트 열 메타(크기·수정일)

    func testEntriesFillFileMetadata() throws {
        // 파일: fileSize·modifiedAt 채움 / 폴더: fileSize nil·modifiedAt 채움 (리스트 열용, 스펙 §7.3)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("listing-meta-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try Data(repeating: 0, count: 42).write(to: dir.appendingPathComponent("파일.md"))
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("폴더"), withIntermediateDirectories: true)

        let entries = LibraryListing.entries(of: dir)
        let file = try XCTUnwrap(entries.first(where: { !$0.isDirectory }))
        let folder = try XCTUnwrap(entries.first(where: { $0.isDirectory }))

        XCTAssertEqual(file.fileSize, 42)
        XCTAssertNotNil(file.modifiedAt)
        XCTAssertNil(folder.fileSize)
        XCTAssertNotNil(folder.modifiedAt)
    }

    func testTreeScanLeavesMetadataNil() {
        // 사이드바 트리 경로(buildFileTree)는 메타를 읽지 않는다 — 비용 불변 확인.
        let item = FileTreeItem(url: URL(fileURLWithPath: "/tmp/x.md"))
        XCTAssertNil(item.fileSize)
        XCTAssertNil(item.modifiedAt)
    }
}
