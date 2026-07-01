import XCTest
@testable import CmdMD

final class AppAskCorpusTests: XCTestCase {
    @MainActor
    func testAskCorpusStateDefaults() {
        let dir = TempDataDirectory.make(); defer { TempDataDirectory.cleanup(dir) }
        let app = AppState(dataDirectory: dir)
        XCTAssertFalse(app.showAskCorpus)
        XCTAssertNil(app.ragAnswer)
        XCTAssertTrue(app.ragSources.isEmpty)
        XCTAssertFalse(app.ragBusy)
    }

    @MainActor
    func testRunRagQueryNoEvidenceOnEmptyIndex() async {
        let dir = TempDataDirectory.make(); defer { TempDataDirectory.cleanup(dir) }
        let app = AppState(dataDirectory: dir)
        app.settings.ragExpandQuery = false            // 오프라인 결정성: 확장 Claude 호출 안 함
        app.ragQuestion = "존재하지 않는 질의 xyzzy"
        await app.runRagQuery()
        XCTAssertFalse(app.ragBusy)
        XCTAssertNil(app.ragAnswer)
        XCTAssertTrue(app.ragSources.isEmpty)
        XCTAssertEqual(app.ragMessage, "자료에서 관련 내용을 찾지 못했습니다.")
    }
}
