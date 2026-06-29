import XCTest
@testable import CmdMD

final class AppPatchTests: XCTestCase {
    func testPatchedOutputURLAddsSuffixAndKeepsExtension() {
        let original = URL(fileURLWithPath: "/tmp/cmddocu-test-nonexistent/평가서.hwpx")
        let out = AppState.patchedOutputURL(for: original)
        XCTAssertEqual(out.deletingLastPathComponent().path, "/tmp/cmddocu-test-nonexistent")
        XCTAssertEqual(out.pathExtension, "hwpx")
        XCTAssertEqual(out.lastPathComponent, "평가서 (편집).hwpx")
    }

    func testPatchedOutputURLPreservesHwpExtension() {
        let out = AppState.patchedOutputURL(for: URL(fileURLWithPath: "/tmp/cmddocu-test-nonexistent/문서.hwp"))
        XCTAssertEqual(out.pathExtension, "hwp")
        XCTAssertEqual(out.lastPathComponent, "문서 (편집).hwp")
    }
}
