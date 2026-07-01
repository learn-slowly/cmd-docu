import XCTest
@testable import CmdMD

final class RagServiceTests: XCTestCase {
    /// 빈 인덱스 + 확장 OFF → Claude를 호출하지 않고 .noEvidence(오프라인 결정성).
    func testEmptyIndexReturnsNoEvidenceWithoutNetwork() async {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmddocu-rag-\(UUID().uuidString)").appendingPathExtension("sqlite")
        let idx = SearchIndex(dbURL: url)
        let svc = RagService(index: idx, claude: ClaudeService(), kordoc: KordocService())
        let outcome = await svc.ask(question: "존재하지 않는 질의 xyzzy", expandQuery: false)
        if case .noEvidence = outcome { } else { XCTFail("expected .noEvidence, got \(outcome)") }
    }
}
