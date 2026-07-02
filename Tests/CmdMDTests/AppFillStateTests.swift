import XCTest
@testable import CmdMD

final class AppFillStateTests: XCTestCase {
    func testKordocFillErrorMessages() {
        XCTAssertTrue(AppState.kordocFillErrorMessage(KordocFillError.toolNotFound).contains("kordoc"))
        XCTAssertTrue(AppState.kordocFillErrorMessage(KordocFillError.timeout).contains("중단"))
        XCTAssertTrue(AppState.kordocFillErrorMessage(KordocFillError.fillFailed("boom")).contains("boom"))
        XCTAssertTrue(AppState.kordocFillErrorMessage(KordocFillError.dryRunFailed("nope")).contains("nope"))
        XCTAssertTrue(AppState.kordocFillErrorMessage(KordocFillError.decodeFailed).contains("서식 필드 정보를"))
    }

    @MainActor
    func testBeginOfficeFillIgnoresNonFillable() {
        let dir = TempDataDirectory.make(); defer { TempDataDirectory.cleanup(dir) }
        let app = AppState(dataDirectory: dir)
        let tabID = UUID()
        app.beginOfficeFill(tabID: tabID, fileURL: URL(fileURLWithPath: "/tmp/a.docx"))
        XCTAssertNil(app.officeFillSession)
        XCTAssertFalse(app.officeFillInProgress.contains(tabID))
    }

    @MainActor
    func testOfficeFillRequestHoldsDetection() {
        let detection = FillDetection(fields: [], confidence: nil)  // 메모버와이즈 init
        let req = OfficeFillRequest(tabID: UUID(),
                                    fileURL: URL(fileURLWithPath: "/tmp/서식.hwpx"),
                                    detection: detection,
                                    output: URL(fileURLWithPath: "/tmp/서식 (채움).hwpx"))
        XCTAssertEqual(req.output.lastPathComponent, "서식 (채움).hwpx")
        XCTAssertTrue(req.detection.fields.isEmpty)
    }
}
