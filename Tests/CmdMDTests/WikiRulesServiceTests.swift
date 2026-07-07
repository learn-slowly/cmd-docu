import XCTest
@testable import CmdMD

/// 위키 규칙 파악(스펙 §2.1) — 규칙 소스 수집·추출 프롬프트·요약 검증. FakeClaude 주입.
final class WikiRulesServiceTests: XCTestCase {
    var wikiDir: URL!

    override func setUp() {
        super.setUp()
        wikiDir = TempDataDirectory.make()
    }
    override func tearDown() {
        TempDataDirectory.cleanup(wikiDir)
        super.tearDown()
    }

    private actor FakeClaude: ClaudeAsking {
        let response: String
        private(set) var calls: [(prompt: String, context: String)] = []
        init(response: String) { self.response = response }
        func ask(prompt: String, context: String) async throws -> String {
            calls.append((prompt, context))
            return response
        }
        func lastPrompt() -> String? { calls.last?.prompt }
        func lastContext() -> String? { calls.last?.context }
    }

    private func seedRules(claudeMd: String? = "# 규칙\n한국어로 쓴다.",
                           templates: [String: String] = [:]) {
        if let claudeMd {
            try? claudeMd.write(to: wikiDir.appendingPathComponent("CLAUDE.md"),
                                atomically: true, encoding: .utf8)
        }
        if !templates.isEmpty {
            let dir = wikiDir.appendingPathComponent("templates")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for (name, body) in templates {
                try? body.write(to: dir.appendingPathComponent(name),
                                atomically: true, encoding: .utf8)
            }
        }
    }

    func testCollectGathersClaudeMdAndTemplatesInOrder() {
        seedRules(claudeMd: "루트 규칙",
                  templates: ["b_concept.md": "개념 템플릿", "a_paper.md": "논문 템플릿"])
        let src = WikiRulesService.collectRuleSources(wikiFolder: wikiDir)
        XCTAssertNotNil(src)
        let s = src!
        XCTAssertTrue(s.contains("루트 규칙"))
        // 템플릿은 이름순(a_paper 먼저), 파일별 헤더 포함.
        let aPos = s.range(of: "a_paper.md")!.lowerBound
        let bPos = s.range(of: "b_concept.md")!.lowerBound
        XCTAssertLessThan(aPos, bPos)
        XCTAssertTrue(s.contains("## 파일:"))
    }

    func testCollectReturnsNilWithoutAnySources() {
        XCTAssertNil(WikiRulesService.collectRuleSources(wikiFolder: wikiDir))
    }

    func testCaptureRulesReturnsSummary() async throws {
        seedRules()
        let fake = FakeClaude(response: "- 모든 문서는 한국어.\n- references/에 저자연도.md로.")
        let service = WikiRulesService(claude: fake)
        let summary = try await service.captureRules(wikiFolder: wikiDir)
        XCTAssertTrue(summary.contains("한국어"))
        // 추출 프롬프트 계약 — 문서 생성 규칙만·워크플로우 제외 지시가 실려 있다.
        let prompt = await fake.lastPrompt()
        XCTAssertTrue(prompt?.contains("명명") == true)
        XCTAssertTrue(prompt?.contains("frontmatter") == true)
        XCTAssertTrue(prompt?.contains("워크플로우") == true)
        let ctx = await fake.lastContext()
        XCTAssertTrue(ctx?.contains("한국어로 쓴다") == true)
    }

    func testCaptureRulesThrowsWithoutSources() async {
        let service = WikiRulesService(claude: FakeClaude(response: "x"))
        do {
            _ = try await service.captureRules(wikiFolder: wikiDir)
            XCTFail("에러여야 함")
        } catch let e as WikiRulesError {
            XCTAssertEqual(e, .noRuleSources)
        } catch { XCTFail("다른 에러: \(error)") }
    }

    func testCaptureRulesRejectsEmptyResponse() async {
        seedRules()
        let service = WikiRulesService(claude: FakeClaude(response: "   \n "))
        do {
            _ = try await service.captureRules(wikiFolder: wikiDir)
            XCTFail("에러여야 함")
        } catch let e as WikiRulesError {
            XCTAssertEqual(e, .badResponse)
        } catch { XCTFail("다른 에러: \(error)") }
    }

    func testCaptureRulesTruncatesLongSummary() async throws {
        seedRules()
        let long = String(repeating: "규", count: WikiRulesService.summaryLimit + 500)
        let service = WikiRulesService(claude: FakeClaude(response: long))
        let summary = try await service.captureRules(wikiFolder: wikiDir)
        XCTAssertEqual(summary.count, WikiRulesService.summaryLimit)
    }

    func testCollectTruncatesOversizedInput() {
        seedRules(claudeMd: String(repeating: "가", count: WikiRulesService.sourceInputLimit + 1000))
        let src = WikiRulesService.collectRuleSources(wikiFolder: wikiDir)
        XCTAssertNotNil(src)
        XCTAssertLessThanOrEqual(src!.count, WikiRulesService.sourceInputLimit)
    }

    /// 규칙 파악도 위키 전용 타임아웃을 호출별로 지정하는지(입력 40k) — 2026-07-07 수정 회귀 방지.
    func testCaptureUsesWikiTimeoutPerCall() async throws {
        seedRules()
        let fake = TimeoutRecordingClaude(response: "요약 규칙")
        let service = WikiRulesService(claude: fake)
        _ = try await service.captureRules(wikiFolder: wikiDir)
        let recorded = await fake.recorded()
        XCTAssertEqual(recorded, [WikiIngestModels.claudeTimeout])
    }

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
}
