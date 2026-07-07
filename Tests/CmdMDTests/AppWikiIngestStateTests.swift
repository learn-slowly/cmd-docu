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

    private actor RecordingClaude: ClaudeAsking {
        let response: String
        private(set) var prompts: [String] = []
        init(response: String) { self.response = response }
        func ask(prompt: String, context: String) async throws -> String {
            prompts.append(prompt)
            return response
        }
        func lastPrompt() -> String? { prompts.last }
    }

    func testCaptureWikiRulesStoresSummaryAndDate() async throws {
        try "# 규칙\n한국어로 쓴다.".write(
            to: wikiDir.appendingPathComponent("CLAUDE.md"), atomically: true, encoding: .utf8)
        app.wikiRulesService = WikiRulesService(claude: RecordingClaude(response: "- 한국어 전용"))
        let ok = await app.captureWikiRules()
        XCTAssertTrue(ok)
        XCTAssertEqual(app.settings.wikiRulesSummary, "- 한국어 전용")
        XCTAssertNotNil(app.settings.wikiRulesCapturedAt)
        XCTAssertFalse(app.wikiRulesBusy)
    }

    func testCaptureWikiRulesWithoutSourcesSetsMessage() async {
        app.wikiRulesService = WikiRulesService(claude: RecordingClaude(response: "x"))
        let ok = await app.captureWikiRules()   // wikiDir에 규칙 파일 없음
        XCTAssertFalse(ok)
        XCTAssertNotNil(app.wikiRulesMessage)
        XCTAssertNil(app.settings.wikiRulesSummary)
    }

    func testGenerateWikiMergePassesStoredRulesSummary() async {
        app.settings.wikiRulesSummary = "반말로 쓴다"
        let claude = RecordingClaude(response: "# 새주제\n\n요약")
        app.wikiIngestService = WikiIngestService(claude: claude, kordoc: KordocService())
        await app.generateWikiMerge(source: makeSource(), target: .new(name: "새주제"))
        let prompt = await claude.lastPrompt()
        XCTAssertTrue(prompt?.contains("반말로 쓴다") == true)
    }

    func testGenerateWikiMergeAutoWithoutMarkerFallsBackToInbox() async {
        // 마커 없는 응답도 이제 실패하지 않고 _인박스 폴백 제안이 뜬다(2026-07-07 사용자 결정).
        app.settings.wikiRulesSummary = "규칙"
        app.wikiIngestService = WikiIngestService(
            claude: RecordingClaude(response: "# 마커 없음\n본문본문본문 충분히 긴 내용"),
            kordoc: KordocService())
        await app.generateWikiMerge(source: makeSource(), target: .auto)
        XCTAssertNotNil(app.wikiMergeProposal)
        XCTAssertNil(app.wikiIngestError)
        XCTAssertTrue(app.wikiMergeProposal?.pageURL.path.contains("_인박스") == true,
                      "폴백 경로가 _인박스여야: \(app.wikiMergeProposal?.pageURL.path ?? "nil")")
        XCTAssertEqual(app.wikiMergeProposal?.isNewPage, true)
    }

    func testApplyCreatesIntermediateDirectoriesForAutoPage() async {
        let page = wikiDir.appendingPathComponent("references/새논문.md")   // references/ 미존재
        let proposal = WikiMergeProposal(pageURL: page, isNewPage: true,
                                         oldBody: "", newBody: "# 새논문\n요약",
                                         sourceURL: makeSource())
        let dest = await app.applyWikiMerge(proposal)
        XCTAssertNotNil(dest)
        XCTAssertEqual(try? String(contentsOf: dest!, encoding: .utf8), "# 새논문\n요약")
    }

    /// 최종 리뷰 반영(Important 1) — 위키 폴더를 다른 폴더로 재지정하면 옛 위키의 규칙
    /// 요약·일시가 스테일로 남지 않게 비워야 한다(옛 규칙이 새 위키 인제스트를 조종 방지).
    func testSetWikiFolderClearsRulesSummaryWhenFolderChanges() {
        app.settings.wikiRulesSummary = "옛 위키 규칙"
        app.settings.wikiRulesCapturedAt = Date()
        let otherWiki = TempDataDirectory.make()
        defer { TempDataDirectory.cleanup(otherWiki) }
        app.setWikiFolder(otherWiki)
        XCTAssertEqual(app.settings.wikiFolder, otherWiki.resolvingSymlinksInPath().path)
        XCTAssertNil(app.settings.wikiRulesSummary)
        XCTAssertNil(app.settings.wikiRulesCapturedAt)
        XCTAssertNotNil(app.wikiRulesMessage)
    }

    /// 같은 폴더를 재지정(경로 정규화 후 동일)하면 요약·일시가 보존돼야 한다.
    func testSetWikiFolderPreservesRulesSummaryWhenSameFolder() {
        // setUp이 unresolved path를 넣으므로, 먼저 setWikiFolder로 정규화된 값을 맞춰둔다.
        app.setWikiFolder(wikiDir)
        app.settings.wikiRulesSummary = "그대로 유지"
        app.settings.wikiRulesCapturedAt = Date()
        app.setWikiFolder(wikiDir)   // 같은 폴더 재지정 — no-op이어야 함
        XCTAssertEqual(app.settings.wikiRulesSummary, "그대로 유지")
        XCTAssertNotNil(app.settings.wikiRulesCapturedAt)
    }

    func testWikiRulesSettingsDecodeBackwardCompatible() throws {
        let old = "{\"hasCompletedOnboarding\": true}".data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AppSettings.self, from: old)
        XCTAssertNil(decoded.wikiRulesSummary)
        XCTAssertNil(decoded.wikiRulesCapturedAt)
    }

    // MARK: - 트리아지 픽스(2026-07-07): 세대 토큰·자기 인제스트·규칙 없는 자동·재uniquify 안내

    /// 적용(특히 새 페이지 생성)은 트리·라이브러리에 보여야 한다 — 세대 토큰 증가
    /// (F1a createNewFile 공백과 동류였던 트리아지 항목).
    func testApplyWikiMergeBumpsFileOpsGeneration() async {
        let page = wikiDir.appendingPathComponent("새주제.md")
        let proposal = WikiMergeProposal(pageURL: page, isNewPage: true,
                                         oldBody: "", newBody: "# 새주제", sourceURL: makeSource())
        let before = app.fileOpsGeneration
        _ = await app.applyWikiMerge(proposal)
        XCTAssertGreaterThan(app.fileOpsGeneration, before)
    }

    /// 실패한 적용(더티 탭 거부)은 아무것도 안 바꿨으므로 세대 토큰도 불변.
    func testRefusedApplyDoesNotBumpFileOpsGeneration() async throws {
        let page = wikiDir.appendingPathComponent("주제.md")
        try "# 이전".write(to: page, atomically: true, encoding: .utf8)
        let document = MarkdownDocument(content: "편집 중")
        let tab = EditorTab(documentId: document.id, fileURL: page)
        app.tabs = [tab]
        app.documents[document.id] = document
        app.originalContents[document.id] = "저장본"
        let proposal = WikiMergeProposal(pageURL: page, isNewPage: false,
                                         oldBody: "# 이전", newBody: "# 후", sourceURL: makeSource())
        let before = app.fileOpsGeneration
        let dest = await app.applyWikiMerge(proposal)
        XCTAssertNil(dest)
        XCTAssertEqual(app.fileOpsGeneration, before)
    }

    /// 복원도 파일 내용을 바꾼다(새 페이지 복원은 휴지통 이동) — 세대 토큰 증가.
    func testRestoreWikiIngestBumpsFileOpsGeneration() async throws {
        let page = wikiDir.appendingPathComponent("주제.md")
        try "# 이전".write(to: page, atomically: true, encoding: .utf8)
        let proposal = WikiMergeProposal(pageURL: page, isNewPage: false,
                                         oldBody: "# 이전", newBody: "# 후", sourceURL: makeSource())
        _ = await app.applyWikiMerge(proposal)
        let entry = await app.wikiBackupStore.allEntries().first!
        let before = app.fileOpsGeneration
        let ok = await app.restoreWikiIngest(entry)
        XCTAssertTrue(ok)
        XCTAssertGreaterThan(app.fileOpsGeneration, before)
    }

    /// 자기 자신 인제스트 거부 — 위키 페이지를 소스로 골라 같은 페이지에 병합하면
    /// (소스=대상) Claude 호출 전에 막는다(kordoc fill isSameFile 전례).
    func testGenerateRefusesSelfIngest() async throws {
        let page = wikiDir.appendingPathComponent("자기.md")
        try "# 자기\n본문".write(to: page, atomically: true, encoding: .utf8)
        let claude = RecordingClaude(response: "호출되면 안 됨")
        app.wikiIngestService = WikiIngestService(claude: claude, kordoc: KordocService())

        await app.generateWikiMerge(source: page, target: .existing(page))

        XCTAssertNil(app.wikiMergeProposal)
        XCTAssertNotNil(app.wikiIngestError)
        let called = await claude.lastPrompt()
        XCTAssertNil(called, "Claude를 호출하기 전에 거부해야 한다")
    }

    /// 자동(규칙에 따름)은 규칙 요약이 전제 — 요약이 없거나 공백이면 Claude 호출 전에 안내
    /// (시트가 열린 채 다른 창에서 요약을 비운 스테일 .auto 선택 방어의 AppState 층).
    func testGenerateAutoWithoutRulesSetsError() async {
        for empty in [nil, "", "  \n "] as [String?] {
            app.settings.wikiRulesSummary = empty
            app.wikiIngestError = nil
            let claude = RecordingClaude(response: "호출되면 안 됨")
            app.wikiIngestService = WikiIngestService(claude: claude, kordoc: KordocService())

            await app.generateWikiMerge(source: makeSource(), target: .auto)

            XCTAssertNil(app.wikiMergeProposal)
            XCTAssertNotNil(app.wikiIngestError, "요약 '\(empty ?? "nil")'에서 에러여야 함")
            let called = await claude.lastPrompt()
            XCTAssertNil(called)
        }
    }

    /// 시트의 "중단"(또는 닫기)이 진행 중인 병합 생성을 실제로 멈춘다 — busy 해제·
    /// 에러 없음(사용자 중단은 에러가 아니다)·제안 없음. Claude 프로세스 종료 자체는
    /// ClaudeService 폴링 루프의 협조 취소가 담당(실기 검증 몫).
    func testCancelWikiMergeStopsGenerationSilently() async throws {
        app.wikiIngestService = WikiIngestService(claude: SlowClaude(), kordoc: KordocService())
        app.startWikiMerge(source: makeSource(), target: .new(name: "느린병합"))

        var tries = 0
        while !app.wikiIngestBusy && tries < 200 {
            try await Task.sleep(nanoseconds: 10_000_000)
            tries += 1
        }
        XCTAssertTrue(app.wikiIngestBusy, "병합 생성이 시작돼야 함")

        app.cancelWikiMerge()
        tries = 0
        while app.wikiIngestBusy && tries < 200 {
            try await Task.sleep(nanoseconds: 10_000_000)
            tries += 1
        }
        XCTAssertFalse(app.wikiIngestBusy)
        XCTAssertNil(app.wikiIngestError, "사용자 중단은 에러 표시 없이 조용히 끝난다")
        XCTAssertNil(app.wikiMergeProposal)
    }

    /// 중단 없이 완주하면 기존 generateWikiMerge와 동일하게 제안이 선다(시작 API 등가).
    func testStartWikiMergeCompletesLikeGenerate() async throws {
        app.wikiIngestService = WikiIngestService(
            claude: StubClaude(response: "# 새주제\n\n요약"), kordoc: KordocService())
        app.startWikiMerge(source: makeSource(), target: .new(name: "새주제"))
        var tries = 0
        while app.wikiMergeProposal == nil && app.wikiIngestError == nil && tries < 500 {
            try await Task.sleep(nanoseconds: 10_000_000)
            tries += 1
        }
        XCTAssertNotNil(app.wikiMergeProposal)
        XCTAssertNil(app.wikiIngestError)
        XCTAssertFalse(app.wikiIngestBusy)
    }

    /// 느린 가짜 Claude — Task.sleep은 취소 협조적이라 cancel 시 즉시 CancellationError.
    private actor SlowClaude: ClaudeAsking {
        func ask(prompt: String, context: String) async throws -> String {
            try await Task.sleep(nanoseconds: 30_000_000_000)
            return "너무 늦음"
        }
    }

    // MARK: - 다중 문서 인제스트(일괄 처리) 요청 배선

    func testRequestWikiBatchIngestOpensSheetWithCleanState() {
        let a = makeSource(); let b = makeSource()
        app.wikiIngestError = "이전 에러"
        app.requestWikiBatchIngest(sources: [a, b])
        XCTAssertEqual(app.wikiBatchRequest?.files, [a, b])
        XCTAssertNil(app.wikiMergeProposal)
        XCTAssertNil(app.wikiIngestError)
    }

    func testRequestWikiBatchIngestIgnoresEmptyAndFoldersOnly() throws {
        let folder = wikiDir.appendingPathComponent("하위폴더")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        app.toastMessage = nil
        app.requestWikiBatchIngest(sources: [])
        XCTAssertNil(app.wikiBatchRequest)
        XCTAssertNil(app.toastMessage, "빈 입력은 조용히 무동작(토스트 없음)")
        app.requestWikiBatchIngest(sources: [folder])   // 폴더는 걸러져 빈 목록 → 안내 토스트
        XCTAssertNil(app.wikiBatchRequest)
        XCTAssertNotNil(app.toastMessage, "폴더만 준 경우는 안내 토스트")
    }

    func testRequestWikiBatchIngestFiltersFoldersKeepsFiles() throws {
        let folder = wikiDir.appendingPathComponent("하위폴더2")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = makeSource()
        app.requestWikiBatchIngest(sources: [folder, file])
        XCTAssertEqual(app.wikiBatchRequest?.files, [file], "폴더는 제외, 파일만")
    }

    /// 새 페이지 재uniquify(TOCTOU 비켜 가기)가 일어나면 실제 쓴 파일명을 토스트로 알린다 —
    /// diff 승인 화면의 경로와 최종 파일명이 달라지는 걸 조용히 넘기지 않는다.
    func testApplyNewPageReuniquifyAnnouncesActualName() async throws {
        let page = wikiDir.appendingPathComponent("충돌.md")
        let proposal = WikiMergeProposal(pageURL: page, isNewPage: true,
                                         oldBody: "", newBody: "# 충돌\n새 내용",
                                         sourceURL: makeSource())
        try "# 먼저 생긴 파일".write(to: page, atomically: true, encoding: .utf8)
        let dest = await app.applyWikiMerge(proposal)
        XCTAssertNotNil(dest)
        XCTAssertNotEqual(dest, page)
        XCTAssertTrue(app.toastMessage?.contains(dest!.lastPathComponent) == true,
                      "재uniquify된 실제 파일명이 안내에 있어야 함: \(app.toastMessage ?? "nil")")
    }
}
