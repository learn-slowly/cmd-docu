import XCTest
@testable import CmdMD

final class KordocWriteServiceTests: XCTestCase {
    func testIsSameFileTrueForIdenticalPath() {
        XCTAssertTrue(KordocWriteService.isSameFile(
            URL(fileURLWithPath: "/tmp/a/문서.hwpx"),
            URL(fileURLWithPath: "/tmp/a/문서.hwpx")))
    }

    func testIsSameFileTrueForUnstandardizedPath() {
        XCTAssertTrue(KordocWriteService.isSameFile(
            URL(fileURLWithPath: "/tmp/a/문서.hwpx"),
            URL(fileURLWithPath: "/tmp/a/../a/문서.hwpx")))
    }

    func testIsSameFileFalseForDifferentNames() {
        XCTAssertFalse(KordocWriteService.isSameFile(
            URL(fileURLWithPath: "/tmp/a/문서.hwpx"),
            URL(fileURLWithPath: "/tmp/a/문서 (편집).hwpx")))
    }
}
