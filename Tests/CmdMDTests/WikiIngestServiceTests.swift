import XCTest
@testable import CmdMD

/// 병합 제안 생성 — FakeClaude 주입(폴더 정리 전례). 제안 단계는 디스크에 쓰지 않는다.
final class WikiIngestServiceTests: XCTestCase {
    var wikiDir: URL!
    var srcDir: URL!

    override func setUp() {
        super.setUp()
        wikiDir = TempDataDirectory.make()
        srcDir = TempDataDirectory.make()
    }
    override func tearDown() {
        TempDataDirectory.cleanup(wikiDir)
        TempDataDirectory.cleanup(srcDir)
        super.tearDown()
    }

    private func makeSource(_ name: String = "자료.md", body: String = "# 자료\n핵심 내용") -> URL {
        let url = srcDir.appendingPathComponent(name)
        try? body.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// 항상 지정 응답을 돌려주는 가짜. 호출 기록으로 프롬프트 계약을 검증한다.
    private actor FakeClaude: ClaudeAsking {
        let response: String
        var timeoutsBeforeSuccess: Int
        private(set) var calls: [(prompt: String, context: String)] = []
        init(response: String, timeoutsBeforeSuccess: Int = 0) {
            self.response = response
            self.timeoutsBeforeSuccess = timeoutsBeforeSuccess
        }
        func ask(prompt: String, context: String) async throws -> String {
            calls.append((prompt, context))
            if timeoutsBeforeSuccess > 0 {
                timeoutsBeforeSuccess -= 1
                throw ClaudeError.timeout
            }
            return response
        }
        func callCount() -> Int { calls.count }
        func lastContext() -> String? { calls.last?.context }
    }

    func testProposeMergesIntoExistingPage() async throws {
        let page = wikiDir.appendingPathComponent("주제.md")
        try "# 주제\n\n기존 본문".write(to: page, atomically: true, encoding: .utf8)
        let merged = "---\nupdated: 2026-07-06\n---\n# 주제\n\n기존 본문\n\n새 내용"
        let fake = FakeClaude(response: merged)
        let service = WikiIngestService(claude: fake, kordoc: KordocService())

        let p = try await service.propose(source: makeSource(), target: .existing(page),
                                          wikiFolder: wikiDir, rulesSummary: nil,
                                          today: "2026-07-06")
        XCTAssertEqual(p.pageURL, page)
        XCTAssertFalse(p.isNewPage)
        XCTAssertEqual(p.oldBody, "# 주제\n\n기존 본문")
        XCTAssertEqual(p.newBody, merged)
        // 제안 단계 — 페이지는 아직 그대로다.
        XCTAssertEqual(try String(contentsOf: page, encoding: .utf8), "# 주제\n\n기존 본문")
        // 컨텍스트에 기존 본문·소스 본문이 실렸다.
        let ctx = await fake.lastContext()
        XCTAssertTrue(ctx?.contains("기존 본문") == true)
        XCTAssertTrue(ctx?.contains("핵심 내용") == true)
    }

    func testProposeNewPage() async throws {
        let fake = FakeClaude(response: "# 새주제\n\n요약")
        let service = WikiIngestService(claude: fake, kordoc: KordocService())
        let p = try await service.propose(source: makeSource(), target: .new(name: "새주제"),
                                          wikiFolder: wikiDir, rulesSummary: nil,
                                          today: "2026-07-06")
        XCTAssertTrue(p.isNewPage)
        XCTAssertEqual(p.oldBody, "")
        XCTAssertEqual(p.pageURL.lastPathComponent, "새주제.md")
        XCTAssertFalse(FileManager.default.fileExists(atPath: p.pageURL.path))   // 아직 안 만든다
    }

    func testProposeRetriesOnceOnTimeout() async throws {
        let page = wikiDir.appendingPathComponent("p.md")
        try "# p\n본문본문본문".write(to: page, atomically: true, encoding: .utf8)
        let fake = FakeClaude(response: "# p\n본문본문본문\n추가", timeoutsBeforeSuccess: 1)
        let service = WikiIngestService(claude: fake, kordoc: KordocService())
        _ = try await service.propose(source: makeSource(), target: .existing(page),
                                      wikiFolder: wikiDir, rulesSummary: nil,
                                      today: "2026-07-06")
        let count = await fake.callCount()
        XCTAssertEqual(count, 2)
    }

    func testProposeThrowsOnMissingSource() async {
        let fake = FakeClaude(response: "x")
        let service = WikiIngestService(claude: fake, kordoc: KordocService())
        let missing = srcDir.appendingPathComponent("없음.md")
        do {
            _ = try await service.propose(source: missing, target: .new(name: "n"),
                                          wikiFolder: wikiDir, rulesSummary: nil,
                                          today: "2026-07-06")
            XCTFail("에러여야 함")
        } catch let e as WikiIngestError {
            XCTAssertEqual(e, .sourceUnreadable)
        } catch { XCTFail("다른 에러: \(error)") }
    }

    func testProposeThrowsWhenPageTooLarge() async throws {
        let page = wikiDir.appendingPathComponent("큰페이지.md")
        try String(repeating: "가", count: WikiIngestModels.pageBodyLimit + 1)
            .write(to: page, atomically: true, encoding: .utf8)
        let fake = FakeClaude(response: "x")
        let service = WikiIngestService(claude: fake, kordoc: KordocService())
        do {
            _ = try await service.propose(source: makeSource(), target: .existing(page),
                                          wikiFolder: wikiDir, rulesSummary: nil,
                                          today: "2026-07-06")
            XCTFail("에러여야 함")
        } catch let e as WikiIngestError {
            XCTAssertEqual(e, .pageTooLarge)
            let count = await fake.callCount()
            XCTAssertEqual(count, 0)   // Claude 호출 전에 거부(크레딧 절약)
        } catch { XCTFail("다른 에러: \(error)") }
    }

    func testProposeThrowsOnBadResponse() async throws {
        let page = wikiDir.appendingPathComponent("p.md")
        try String(repeating: "본문", count: 200).write(to: page, atomically: true, encoding: .utf8)
        let fake = FakeClaude(response: "짧음")   // 기존 대비 40% 미만 급축소 → 검증 실패
        let service = WikiIngestService(claude: fake, kordoc: KordocService())
        do {
            _ = try await service.propose(source: makeSource(), target: .existing(page),
                                          wikiFolder: wikiDir, rulesSummary: nil,
                                          today: "2026-07-06")
            XCTFail("에러여야 함")
        } catch let e as WikiIngestError {
            XCTAssertEqual(e, .badResponse)
        } catch { XCTFail("다른 에러: \(error)") }
    }

    func testProposeThrowsOnInvalidNewPageName() async {
        let fake = FakeClaude(response: "x")
        let service = WikiIngestService(claude: fake, kordoc: KordocService())
        do {
            _ = try await service.propose(source: makeSource(), target: .new(name: "///"),
                                          wikiFolder: wikiDir, rulesSummary: nil,
                                          today: "2026-07-06")
            XCTFail("에러여야 함")
        } catch let e as WikiIngestError {
            XCTAssertEqual(e, .invalidNewPageName)
        } catch { XCTFail("다른 에러: \(error)") }
    }

    func testProposeAutoParsesSuggestedPath() async throws {
        let merged = "<!-- page: references/신진욱2011.md -->\n# 신진욱2011\n\n요약"
        let fake = FakeClaude(response: merged)
        let service = WikiIngestService(claude: fake, kordoc: KordocService())
        let p = try await service.propose(source: makeSource(), target: .auto,
                                          wikiFolder: wikiDir, rulesSummary: "규칙",
                                          today: "2026-07-06")
        XCTAssertTrue(p.isNewPage)
        XCTAssertEqual(p.pageURL,
                       wikiDir.appendingPathComponent("references/신진욱2011.md"))
        XCTAssertFalse(p.newBody.contains("<!-- page:"))   // 마커는 본문에서 제거
        XCTAssertFalse(FileManager.default.fileExists(atPath: p.pageURL.path))  // 무쓰기
    }

    func testProposeAutoThrowsWithoutMarker() async {
        let fake = FakeClaude(response: "# 마커 없음\n본문")
        let service = WikiIngestService(claude: fake, kordoc: KordocService())
        do {
            _ = try await service.propose(source: makeSource(), target: .auto,
                                          wikiFolder: wikiDir, rulesSummary: "규칙",
                                          today: "2026-07-06")
            XCTFail("에러여야 함")
        } catch let e as WikiIngestError {
            XCTAssertEqual(e, .autoPathInvalid)
        } catch { XCTFail("다른 에러: \(error)") }
    }

    func testProposeAutoThrowsOnEscapePath() async {
        let fake = FakeClaude(response: "<!-- page: ../밖.md -->\n# x\n본문")
        let service = WikiIngestService(claude: fake, kordoc: KordocService())
        do {
            _ = try await service.propose(source: makeSource(), target: .auto,
                                          wikiFolder: wikiDir, rulesSummary: nil,
                                          today: "2026-07-06")
            XCTFail("에러여야 함")
        } catch let e as WikiIngestError {
            XCTAssertEqual(e, .autoPathInvalid)
        } catch { XCTFail("다른 에러: \(error)") }
    }

    func testProposeAutoThrowsWhenPathOccupied() async throws {
        let refDir = wikiDir.appendingPathComponent("references")
        try FileManager.default.createDirectory(at: refDir, withIntermediateDirectories: true)
        try "# 기존".write(to: refDir.appendingPathComponent("신진욱2011.md"),
                          atomically: true, encoding: .utf8)
        let fake = FakeClaude(response: "<!-- page: references/신진욱2011.md -->\n# x\n본문")
        let service = WikiIngestService(claude: fake, kordoc: KordocService())
        do {
            _ = try await service.propose(source: makeSource(), target: .auto,
                                          wikiFolder: wikiDir, rulesSummary: nil,
                                          today: "2026-07-06")
            XCTFail("에러여야 함")
        } catch let e as WikiIngestError {
            XCTAssertEqual(e, .autoPathOccupied("references/신진욱2011.md"))
        } catch { XCTFail("다른 에러: \(error)") }
    }

    func testProposeExistingPassesRulesSummaryToPrompt() async throws {
        let page = wikiDir.appendingPathComponent("주제.md")
        try "# 주제\n\n기존 본문".write(to: page, atomically: true, encoding: .utf8)
        let fake = FakeClaude(response: "# 주제\n\n기존 본문\n\n추가")
        let service = WikiIngestService(claude: fake, kordoc: KordocService())
        _ = try await service.propose(source: makeSource(), target: .existing(page),
                                      wikiFolder: wikiDir, rulesSummary: "반말로 쓴다",
                                      today: "2026-07-06")
        let calls = await fake.calls
        XCTAssertTrue(calls.last?.prompt.contains("반말로 쓴다") == true)
    }

    // MARK: - 호출별 타임아웃(2026-07-07 스모크 발견 — 실물 페이지 병합이 120s 구조 초과)

    /// 타임아웃 변형 호출만 기록하는 가짜 — 기본 ask로 새면 -1이 남는다.
    private actor TimeoutRecordingClaude: ClaudeAsking {
        let response: String
        private(set) var timeouts: [TimeInterval] = []
        init(response: String) { self.response = response }
        func ask(prompt: String, context: String) async throws -> String {
            timeouts.append(-1)
            return response
        }
        func ask(prompt: String, context: String, timeout: TimeInterval) async throws -> String {
            timeouts.append(timeout)
            return response
        }
        func recorded() -> [TimeInterval] { timeouts }
    }

    /// 병합 호출이 기본 120s가 아닌 위키 전용 한도를 호출별로 지정하는지 — 회귀 방지.
    func testProposeUsesWikiTimeoutPerCall() async throws {
        let page = wikiDir.appendingPathComponent("주제.md")
        try "# 주제\n\n기존 본문".write(to: page, atomically: true, encoding: .utf8)
        let fake = TimeoutRecordingClaude(response: "# 주제\n\n기존 본문\n\n추가")
        let service = WikiIngestService(claude: fake, kordoc: KordocService())
        _ = try await service.propose(source: makeSource(), target: .existing(page),
                                      wikiFolder: wikiDir, rulesSummary: nil,
                                      today: "2026-07-07")
        let recorded = await fake.recorded()
        XCTAssertEqual(recorded, [WikiIngestModels.claudeTimeout])
    }

    /// 프로토콜 확장 기본 구현 계약 — timeout 변형이 기존 ask로 위임된다(가짜 소스 호환의 근거).
    func testTimeoutOverloadDefaultDelegatesToBaseAsk() async throws {
        let fake = FakeClaude(response: "위임 응답")
        let claude: any ClaudeAsking = fake
        let out = try await claude.ask(prompt: "p", context: "c", timeout: 999)
        XCTAssertEqual(out, "위임 응답")
        let count = await fake.callCount()
        XCTAssertEqual(count, 1)
    }
}
