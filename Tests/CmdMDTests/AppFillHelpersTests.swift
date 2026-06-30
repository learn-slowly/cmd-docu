import XCTest
@testable import CmdMD

final class AppFillHelpersTests: XCTestCase {
    func testFilledOutputURLForcesHwpxAndAddsSuffix() {
        let out = AppState.filledOutputURL(for: URL(fileURLWithPath: "/tmp/cmddocu-test-nonexistent/신청서.hwpx"))
        XCTAssertEqual(out.deletingLastPathComponent().path, "/tmp/cmddocu-test-nonexistent")
        XCTAssertEqual(out.pathExtension, "hwpx")
        XCTAssertEqual(out.lastPathComponent, "신청서 (채움).hwpx")
    }

    func testFilledOutputURLConvertsHwpToHwpx() {
        let out = AppState.filledOutputURL(for: URL(fileURLWithPath: "/tmp/cmddocu-test-nonexistent/서식.hwp"))
        XCTAssertEqual(out.pathExtension, "hwpx")
        XCTAssertEqual(out.lastPathComponent, "서식 (채움).hwpx")
    }

    func testFillValuesToSendIncludesOnlyChangedNonEmpty() {
        let fields = [
            FillField(label: "성명", value: "", row: 0, col: 1),   // 빈칸 → 입력
            FillField(label: "전화", value: "010", row: 1, col: 1), // 변경 안 함
            FillField(label: "주소", value: "옛값", row: 2, col: 1), // 변경
            FillField(label: "비고", value: "x", row: 3, col: 1),   // 비움(전송 안 함)
        ]
        let edited = [
            "0-1-성명": "홍길동",
            "1-1-전화": "010",
            "2-1-주소": "새값",
            "3-1-비고": "",
        ]
        let out = AppState.fillValuesToSend(fields: fields, edited: edited)
        XCTAssertEqual(out, ["성명": "홍길동", "주소": "새값"])
    }

    func testFillValuesToSendDuplicateLabelsLastWins() {
        let fields = [
            FillField(label: "값", value: "", row: 0, col: 0),
            FillField(label: "값", value: "", row: 0, col: 1),
        ]
        let edited = ["0-0-값": "첫째", "0-1-값": "둘째"]
        let out = AppState.fillValuesToSend(fields: fields, edited: edited)
        XCTAssertEqual(out, ["값": "둘째"])
    }
}
