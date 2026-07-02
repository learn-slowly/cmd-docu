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

    // MARK: - stream-json 파서 (실측 fixture 기반)

    func testTextDeltaParsesRealStreamEventLine() {
        let line = #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"안"}},"session_id":"s","uuid":"u"}"#
        XCTAssertEqual(ClaudeService.textDelta(fromStreamLine: line), "안")
    }

    func testTextDeltaIgnoresNonDeltaLines() {
        XCTAssertNil(ClaudeService.textDelta(fromStreamLine: #"{"type":"system","subtype":"init"}"#))
        XCTAssertNil(ClaudeService.textDelta(fromStreamLine: #"{"type":"assistant","message":{}}"#))
        XCTAssertNil(ClaudeService.textDelta(fromStreamLine: "not json"))
    }

    func testTextDeltaIgnoresThinkingDelta() {
        // thinking 델타는 delta.type=="thinking_delta"라 text_delta 필터로 배제돼야 한다(실측).
        let line = #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":""}}}"#
        XCTAssertNil(ClaudeService.textDelta(fromStreamLine: line))
    }

    func testFinalResultParsesResultLine() {
        let line = #"{"type":"result","subtype":"success","is_error":false,"result":"안녕"}"#
        let r = ClaudeService.finalResult(fromStreamLine: line)
        XCTAssertEqual(r?.text, "안녕")
        XCTAssertEqual(r?.isError, false)
    }

    func testFinalResultFlagsErrorResult() {
        let line = #"{"type":"result","subtype":"error_during_execution","is_error":true,"result":""}"#
        let r = ClaudeService.finalResult(fromStreamLine: line)
        XCTAssertEqual(r?.isError, true)
    }

    func testFinalResultIgnoresNonResultLine() {
        XCTAssertNil(ClaudeService.finalResult(fromStreamLine: #"{"type":"stream_event"}"#))
    }

    func testMakeStreamArgumentsIncludeStreamFlags() {
        let args = ClaudeService.makeStreamArguments(prompt: "q")
        XCTAssertEqual(Array(args.prefix(2)), ["-p", "q"])
        XCTAssertTrue(args.contains("--output-format"))
        XCTAssertTrue(args.contains("stream-json"))
        XCTAssertTrue(args.contains("--verbose"))
        XCTAssertTrue(args.contains("--include-partial-messages"))
    }
}
