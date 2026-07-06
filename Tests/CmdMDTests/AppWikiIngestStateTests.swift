import XCTest
@testable import CmdMD

/// 위키 인제스트 AppState 배선 — 시트 상태·제안 생성(busy 가드)·적용(백업→쓰기)·복원.
@MainActor
final class AppWikiIngestStateTests: XCTestCase {
    var tempData: URL!
    var wikiDir: URL!
    var app: AppState!

    override func setUp() {
        super.setUp()
        tempData = TempDataDirectory.make()
        wikiDir = TempDataDirectory.make()
        app = AppState(dataDirectory: tempData)
        app.settings.wikiFolder = wikiDir.path
    }
    override func tearDown() {
        TempDataDirectory.cleanup(tempData)
        TempDataDirectory.cleanup(wikiDir)
        super.tearDown()
    }

    private actor StubClaude: ClaudeAsking {
        let response: String
        init(response: String) { self.response = response }
        func ask(prompt: String, context: String) async throws -> String { response }
    }

    private func makeSource(_ body: String = "# 자료\n내용") -> URL {
        let url = wikiDir.appendingPathComponent("src-\(UUID().uuidString).md")
        try? body.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testRequestOpensSheetWithCleanState() {
        let src = makeSource()
        app.wikiIngestError = "이전 에러"
        app.requestWikiIngest(source: src)
        XCTAssertEqual(app.wikiIngestRequest?.url, src)
        XCTAssertNil(app.wikiMergeProposal)
        XCTAssertNil(app.wikiIngestError)
        XCTAssertFalse(app.wikiIngestBusy)
    }

    func testGenerateProducesProposal() async {
        app.wikiIngestService = WikiIngestService(
            claude: StubClaude(response: "# 새주제\n\n요약"), kordoc: KordocService())
        await app.generateWikiMerge(source: makeSource(), target: .new(name: "새주제"))
        XCTAssertNotNil(app.wikiMergeProposal)
        XCTAssertNil(app.wikiIngestError)
        XCTAssertFalse(app.wikiIngestBusy)
    }

    func testGenerateMapsErrorToKoreanMessage() async {
        app.wikiIngestService = WikiIngestService(
            claude: StubClaude(response: "x"), kordoc: KordocService())
        let missing = wikiDir.appendingPathComponent("없음.pdf")
        await app.generateWikiMerge(source: missing, target: .new(name: "n"))
        XCTAssertNil(app.wikiMergeProposal)
        XCTAssertNotNil(app.wikiIngestError)
    }

    func testGenerateWithoutWikiFolderSetsError() async {
        app.settings.wikiFolder = nil
        await app.generateWikiMerge(source: makeSource(), target: .new(name: "n"))
        XCTAssertNotNil(app.wikiIngestError)
    }

    func testApplyWritesPageAndLogsBackup() async throws {
        let page = wikiDir.appendingPathComponent("주제.md")
        try "# 이전".write(to: page, atomically: true, encoding: .utf8)
        let proposal = WikiMergeProposal(pageURL: page, isNewPage: false,
                                         oldBody: "# 이전", newBody: "# 병합 후",
                                         sourceURL: makeSource())
        // 제안 생성 후 적용 사이에 페이지가 편집됐다고 가정 — 백업은 "적용 시점 디스크 본"이어야 한다.
        try "# 이전(중간 편집)".write(to: page, atomically: true, encoding: .utf8)
        let dest = await app.applyWikiMerge(proposal)
        XCTAssertEqual(dest, page)
        XCTAssertEqual(try String(contentsOf: page, encoding: .utf8), "# 병합 후")
        let entries = await app.wikiBackupStore.allEntries()
        XCTAssertEqual(entries.count, 1)
        guard let backupFile = entries.first?.backupFile else {
            return XCTFail("백업 파일이 기록되지 않았습니다")
        }
        let backupURL = tempData.appendingPathComponent("wiki-backups").appendingPathComponent(backupFile)
        XCTAssertEqual(try String(contentsOf: backupURL, encoding: .utf8), "# 이전(중간 편집)")
    }

    func testApplyNewPageCreatesFile() async {
        let page = wikiDir.appendingPathComponent("새주제.md")
        let proposal = WikiMergeProposal(pageURL: page, isNewPage: true,
                                         oldBody: "", newBody: "# 새주제\n요약",
                                         sourceURL: makeSource())
        let dest = await app.applyWikiMerge(proposal)
        XCTAssertNotNil(dest)
        XCTAssertEqual(try? String(contentsOf: dest!, encoding: .utf8), "# 새주제\n요약")
    }

    /// 코디네이터 해결 사항 1: 제안 생성과 적용 사이(TOCTOU)에 같은 이름 파일이 새로
    /// 생겼으면, 새 페이지 적용은 그 파일을 덮어쓰지 않고 재uniquify해 비켜 간다.
    func testApplyNewPageAvoidsOverwritingFileCreatedMeanwhile() async throws {
        let page = wikiDir.appendingPathComponent("충돌.md")
        let proposal = WikiMergeProposal(pageURL: page, isNewPage: true,
                                         oldBody: "", newBody: "# 충돌\n새 내용",
                                         sourceURL: makeSource())
        // 제안 생성과 적용 사이에 같은 이름 파일이 생긴 상황.
        try "# 먼저 생긴 파일".write(to: page, atomically: true, encoding: .utf8)
        let dest = await app.applyWikiMerge(proposal)
        XCTAssertNotNil(dest)
        XCTAssertNotEqual(dest, page)   // 비켜 감
        XCTAssertEqual(try String(contentsOf: page, encoding: .utf8), "# 먼저 생긴 파일")   // 불변
        XCTAssertEqual(try String(contentsOf: dest!, encoding: .utf8), "# 충돌\n새 내용")
    }

    func testRestoreRoundTripThroughAppState() async throws {
        let page = wikiDir.appendingPathComponent("주제.md")
        try "# 이전".write(to: page, atomically: true, encoding: .utf8)
        let proposal = WikiMergeProposal(pageURL: page, isNewPage: false,
                                         oldBody: "# 이전", newBody: "# 병합 후",
                                         sourceURL: makeSource())
        _ = await app.applyWikiMerge(proposal)
        let entry = await app.wikiBackupStore.allEntries().first!
        let ok = await app.restoreWikiIngest(entry)
        XCTAssertTrue(ok)
        XCTAssertEqual(try String(contentsOf: page, encoding: .utf8), "# 이전")
    }

    /// 대상 페이지가 열린 탭에서 저장 안 된 편집 상태면 적용을 거부한다 — 그러지 않으면
    /// 디스크는 병합본으로 덮이는데 더티 버퍼는 그대로라, 이후 사용자의 ⌘S가 병합 결과를
    /// 조용히 되덮는다(F1a rename flush와 동류).
    func testApplyRefusesWhenTargetPageIsDirtyTab() async throws {
        let page = wikiDir.appendingPathComponent("주제.md")
        try "# 이전".write(to: page, atomically: true, encoding: .utf8)
        let document = MarkdownDocument(content: "편집 중인 본문")
        let tab = EditorTab(documentId: document.id, fileURL: page)
        app.tabs = [tab]
        app.documents[document.id] = document
        app.originalContents[document.id] = "저장된 본문"   // content와 달라 더티 판정

        let proposal = WikiMergeProposal(pageURL: page, isNewPage: false,
                                         oldBody: "# 이전", newBody: "# 병합 후",
                                         sourceURL: makeSource())
        let dest = await app.applyWikiMerge(proposal)
        XCTAssertNil(dest)
        XCTAssertNotNil(app.wikiIngestError)
        XCTAssertEqual(try String(contentsOf: page, encoding: .utf8), "# 이전")   // 디스크 불변
    }

    /// 같은 이유로, 기존 페이지가 대상인 병합 제안 생성도 거부한다 — Claude 호출 자체를 막는다.
    func testGenerateRefusesWhenExistingTargetIsDirtyTab() async {
        let page = wikiDir.appendingPathComponent("주제.md")
        try? "# 이전".write(to: page, atomically: true, encoding: .utf8)
        let document = MarkdownDocument(content: "편집 중인 본문")
        let tab = EditorTab(documentId: document.id, fileURL: page)
        app.tabs = [tab]
        app.documents[document.id] = document
        app.originalContents[document.id] = "저장된 본문"

        app.wikiIngestService = WikiIngestService(
            claude: StubClaude(response: "호출되면 안 됨"), kordoc: KordocService())
        await app.generateWikiMerge(source: makeSource(), target: .existing(page))
        XCTAssertNil(app.wikiMergeProposal)
        XCTAssertNotNil(app.wikiIngestError)
    }

    func testWikiFolderSettingDecodeBackwardCompatible() throws {
        // 구버전 settings.json(wikiFolder 키 없음)이 그대로 디코드된다.
        let old = "{\"hasCompletedOnboarding\": true}".data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AppSettings.self, from: old)
        XCTAssertNil(decoded.wikiFolder)
    }
}
