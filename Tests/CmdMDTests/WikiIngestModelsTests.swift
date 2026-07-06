import XCTest
@testable import CmdMD

/// 위키 인제스트 순수 헬퍼 — 대상 URL·프롬프트 계약·응답 검증·크기 한도(스펙 §2.1).
final class WikiIngestModelsTests: XCTestCase {
    var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = TempDataDirectory.make()
    }
    override func tearDown() {
        TempDataDirectory.cleanup(tempDir)
        super.tearDown()
    }

    // MARK: - newPageURL

    func testNewPageURLSanitizesAndAppendsMd() {
        let url = WikiIngestModels.newPageURL(name: "미디어/이론: 개요", wikiFolder: tempDir)
        XCTAssertEqual(url?.lastPathComponent, "미디어-이론- 개요.md")
        XCTAssertEqual(url?.deletingLastPathComponent().path, tempDir.path)
    }

    func testNewPageURLRejectsEmptyAfterSanitize() {
        XCTAssertNil(WikiIngestModels.newPageURL(name: "///", wikiFolder: tempDir))
        XCTAssertNil(WikiIngestModels.newPageURL(name: "  ", wikiFolder: tempDir))
    }

    func testNewPageURLUniquifiesOnCollision() throws {
        let taken = tempDir.appendingPathComponent("주제.md")
        try "x".write(to: taken, atomically: true, encoding: .utf8)
        let url = WikiIngestModels.newPageURL(name: "주제", wikiFolder: tempDir)
        XCTAssertEqual(url?.lastPathComponent, "주제 (1).md")
    }

    func testNewPageURLBlocksPathEscape() {
        // sanitize가 구분자·".."을 제거하므로 결과는 항상 wikiFolder 직속이어야 한다.
        let url = WikiIngestModels.newPageURL(name: "../밖", wikiFolder: tempDir)
        XCTAssertEqual(url?.deletingLastPathComponent().standardizedFileURL.path,
                       tempDir.standardizedFileURL.path)
    }

    // MARK: - truncatedExcerpt

    func testExcerptUnderLimitPassesThrough() {
        let r = WikiIngestModels.truncatedExcerpt("짧은 본문")
        XCTAssertEqual(r.text, "짧은 본문")
        XCTAssertFalse(r.truncated)
    }

    func testExcerptCoversFullAcademicPaper() {
        // 실사례 회귀(2026-07-06 신진욱2011): 36쪽 논문 추출 텍스트 48,273자가 12k 한도에
        // 잘려 페이지가 "앞부분 발췌 기반"으로만 생성됐다. 단일 문서 전체 이해가 목적이므로
        // 한도는 학술 논문 한 편(수십 쪽)을 덮어야 한다.
        let paper = String(repeating: "가", count: 48_273)
        let r = WikiIngestModels.truncatedExcerpt(paper)
        XCTAssertFalse(r.truncated)
        XCTAssertEqual(r.text.count, 48_273)
    }

    func testExcerptOverLimitTruncates() {
        let long = String(repeating: "가", count: WikiIngestModels.sourceExcerptLimit + 100)
        let r = WikiIngestModels.truncatedExcerpt(long)
        XCTAssertEqual(r.text.count, WikiIngestModels.sourceExcerptLimit)
        XCTAssertTrue(r.truncated)
    }

    // MARK: - mergePrompt

    func testMergePromptContainsSchemaRules() {
        let (prompt, context) = WikiIngestModels.mergePrompt(
            pageTitle: "미디어 이론", pageBody: "# 미디어 이론\n\n기존 내용.",
            sourceName: "논문.pdf", sourceExcerpt: "새 자료 본문",
            excerptTruncated: false, isNewPage: false, today: "2026-07-06")
        XCTAssertTrue(prompt.contains("마크다운 전문만"))
        XCTAssertTrue(prompt.contains("sources"))
        XCTAssertTrue(prompt.contains("논문.pdf (2026-07-06)"))
        XCTAssertTrue(prompt.contains("유실"))
        XCTAssertTrue(prompt.contains("한국어"))
        XCTAssertFalse(prompt.contains("발췌본"))          // truncated=false면 발췌 고지 없음
        XCTAssertTrue(context.contains("[위키 페이지: 미디어 이론]"))
        XCTAssertTrue(context.contains("기존 내용."))
        XCTAssertTrue(context.contains("[새 자료: 논문.pdf]"))
        XCTAssertTrue(context.contains("새 자료 본문"))
    }

    func testMergePromptNewPageAndTruncatedNotices() {
        let (prompt, context) = WikiIngestModels.mergePrompt(
            pageTitle: "새주제", pageBody: "",
            sourceName: "자료.pdf", sourceExcerpt: "발췌",
            excerptTruncated: true, isNewPage: true, today: "2026-07-06")
        XCTAssertTrue(prompt.contains("새 페이지"))
        XCTAssertTrue(prompt.contains("# 새주제"))
        XCTAssertTrue(prompt.contains("발췌본"))
        XCTAssertTrue(context.contains("(새 페이지 — 본문 없음)"))
    }

    // MARK: - extractMarkdown

    func testExtractStripsWholeCodeFence() {
        let out = "```markdown\n---\nupdated: 2026-07-06\n---\n# 제목\n본문\n```"
        XCTAssertEqual(WikiIngestModels.extractMarkdown(from: out, oldBodyLength: 0),
                       "---\nupdated: 2026-07-06\n---\n# 제목\n본문")
    }

    func testExtractDropsPreambleBeforeFrontmatter() {
        let out = "네, 갱신된 페이지입니다.\n---\nupdated: x\n---\n# 제목\n본문"
        XCTAssertEqual(WikiIngestModels.extractMarkdown(from: out, oldBodyLength: 0),
                       "---\nupdated: x\n---\n# 제목\n본문")
    }

    func testExtractDropsPreambleBeforeHeading() {
        let out = "설명 한 줄\n# 제목\n본문"
        XCTAssertEqual(WikiIngestModels.extractMarkdown(from: out, oldBodyLength: 0), "# 제목\n본문")
    }

    func testExtractPassesCleanBodyThrough() {
        let body = "---\na: b\n---\n# 제목\n본문"
        XCTAssertEqual(WikiIngestModels.extractMarkdown(from: body, oldBodyLength: 0), body)
    }

    func testExtractRejectsEmpty() {
        XCTAssertNil(WikiIngestModels.extractMarkdown(from: "   \n  ", oldBodyLength: 0))
    }

    func testExtractRejectsSevereShrinkOnExistingPage() {
        // 기존 1000자 페이지가 100자로 축소 — 유실 방어(스펙 §2.1: 40% 미만 거부)
        let small = "# 짧음\n" + String(repeating: "a", count: 90)
        XCTAssertNil(WikiIngestModels.extractMarkdown(from: small, oldBodyLength: 1000))
        // 새 페이지(기존 0자)엔 미적용
        XCTAssertNotNil(WikiIngestModels.extractMarkdown(from: small, oldBodyLength: 0))
    }
}
