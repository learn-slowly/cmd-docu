import XCTest
@testable import CmdMD

final class KordocFillServiceTests: XCTestCase {
    func testParseMatchWarningsExtractsLabels() {
        let stderr = """
        [kordoc] 신청서.hwpx 파싱 중...
        [kordoc] 2개 필드 채움
        ⚠️ 매칭 실패: 후보자명
        ⚠️ 매칭 실패: 생년월일
        """
        XCTAssertEqual(KordocFillService.parseMatchWarnings(stderr), ["후보자명", "생년월일"])
    }

    func testParseMatchWarningsEmptyWhenNoFailures() {
        XCTAssertTrue(KordocFillService.parseMatchWarnings("[kordoc] 3개 필드 채움").isEmpty)
    }
}
