import XCTest
@testable import CmdMD

final class ClaudeServiceTests: XCTestCase {
    func testClassifyDetectsNotLoggedIn() {
        let e = ClaudeService.classify(exitCode: 1, stderr: "Error: Not logged in. Run `claude` to authenticate.")
        guard case .notLoggedIn = e else { return XCTFail("기대: notLoggedIn, 실제: \(e)") }
    }

    func testClassifyDetectsCreditExhausted() {
        let e = ClaudeService.classify(exitCode: 1, stderr: "You have exceeded your usage limit / credit balance.")
        guard case .creditExhausted = e else { return XCTFail("기대: creditExhausted, 실제: \(e)") }
    }

    func testClassifyFallsBackToFailedWithStderrPrefix() {
        let e = ClaudeService.classify(exitCode: 2, stderr: "boom: something unexpected broke")
        guard case .failed(let msg) = e else { return XCTFail("기대: failed, 실제: \(e)") }
        XCTAssertTrue(msg.contains("boom"))
    }

    func testMakeInputPassesPromptAsArgAndContextAsStdin() {
        let (args, stdin) = ClaudeService.makeInput(prompt: "이 문서 요약해줘", context: "  # 제목\n본문  ")
        XCTAssertEqual(args, ["-p", "이 문서 요약해줘"])
        XCTAssertEqual(stdin, "# 제목\n본문")   // 앞뒤 공백 트림
    }

    func testMakeInputEmptyContextYieldsEmptyStdin() {
        let (args, stdin) = ClaudeService.makeInput(prompt: "안녕", context: "   ")
        XCTAssertEqual(args, ["-p", "안녕"])
        XCTAssertEqual(stdin, "")
    }
}
