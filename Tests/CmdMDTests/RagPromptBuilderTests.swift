import XCTest
@testable import CmdMD

final class RagPromptBuilderTests: XCTestCase {
    func testPromptEmbedsQuestionAndGroundingRules() {
        let p = RagPromptBuilder.prompt(question: "지방선거 평가 정리해줘")
        XCTAssertTrue(p.contains("지방선거 평가 정리해줘"))   // 질문 포함
        XCTAssertTrue(p.contains("["))                        // [n] 인용 규칙
        XCTAssertTrue(p.contains("자료에 없"))                // grounding(모르면 없다고)
    }
}
