import XCTest
@testable import CmdMD

final class DocumentKindFillTests: XCTestCase {
    func testHwpAndHwpxAreFillable() {
        XCTAssertTrue(DocumentKind.isFillable(URL(fileURLWithPath: "/tmp/서식.hwp")))
        XCTAssertTrue(DocumentKind.isFillable(URL(fileURLWithPath: "/tmp/서식.hwpx")))
        XCTAssertTrue(DocumentKind.isFillable(URL(fileURLWithPath: "/tmp/서식.HWP"))) // 대소문자 무시
    }

    func testOtherKindsAreNotFillable() {
        for path in ["/tmp/a.docx", "/tmp/a.xlsx", "/tmp/a.pdf", "/tmp/a.md", "/tmp/a.hwpml"] {
            XCTAssertFalse(DocumentKind.isFillable(URL(fileURLWithPath: path)), "\(path)는 fill 비대상")
        }
    }
}
