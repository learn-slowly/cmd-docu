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

    func testIsSameFileTrueIgnoringCase() {
        // macOS 기본 파일시스템은 대소문자를 가리지 않으므로 확장자 대소문자만 다른 경로도 같은 파일로 친다.
        XCTAssertTrue(KordocWriteService.isSameFile(
            URL(fileURLWithPath: "/tmp/a/문서.hwpx"),
            URL(fileURLWithPath: "/tmp/a/문서.HWPX")))
    }
}
