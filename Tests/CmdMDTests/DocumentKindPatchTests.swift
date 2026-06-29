import XCTest
@testable import CmdMD

final class DocumentKindPatchTests: XCTestCase {
    func testHwpAndHwpxArePatchable() {
        XCTAssertTrue(DocumentKind.isPatchable(URL(fileURLWithPath: "/tmp/문서.hwp")))
        XCTAssertTrue(DocumentKind.isPatchable(URL(fileURLWithPath: "/tmp/문서.hwpx")))
        XCTAssertTrue(DocumentKind.isPatchable(URL(fileURLWithPath: "/tmp/문서.HWPX"))) // 대소문자 무시
    }

    func testOtherKindsAreNotPatchable() {
        for path in ["/tmp/a.docx", "/tmp/a.xlsx", "/tmp/a.pdf", "/tmp/a.md", "/tmp/a.hwpml"] {
            XCTAssertFalse(DocumentKind.isPatchable(URL(fileURLWithPath: path)), "\(path)는 patch 비대상")
        }
    }
}
