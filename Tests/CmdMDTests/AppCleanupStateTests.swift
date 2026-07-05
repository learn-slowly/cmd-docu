import XCTest
@testable import CmdMD

@MainActor
final class AppCleanupStateTests: XCTestCase {

    // 빈 임시 데이터 디렉터리를 주입해 디스크 상태에 의존하지 않게 한다(회귀 방지).
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = TempDataDirectory.make()
    }

    override func tearDown() {
        TempDataDirectory.cleanup(tempDir)
        tempDir = nil
        super.tearDown()
    }

    func testCleanupDefaults() {
        let state = AppState(dataDirectory: tempDir)
        XCTAssertFalse(state.showFolderCleanup)
        XCTAssertNil(state.cleanupPlan)
        XCTAssertTrue(state.cleanupScheme.isEmpty)
        XCTAssertFalse(state.cleanupBusy)
        XCTAssertNil(state.cleanupError)
    }

    func testStartCleanupSetsSubfolderModeAndShows() {
        let state = AppState(dataDirectory: tempDir)
        let folder = URL(fileURLWithPath: "/Users/x/Downloads")
        state.startCleanup(folder: folder)
        XCTAssertTrue(state.showFolderCleanup)
        if case .subfolder(let root)? = state.cleanupMode {
            XCTAssertEqual(root, folder)
        } else { XCTFail("subfolder 모드여야 함") }
    }

    // MARK: busy 중 리셋/재진입 가드 — 진행 중 세션 위로 상태를 초기화하면
    // 완료 시점 plan 대입이 새 세션을 덮어쓴다(적대적 리뷰 확증 Important, 2026-07-05).

    func testResetCleanupIgnoredWhileBusy() {
        let state = AppState(dataDirectory: tempDir)
        state.startCleanup(folder: URL(fileURLWithPath: "/tmp/a"))
        state.cleanupScheme = [CleanupBucket(id: "docs", name: "docs", hint: "", relativePath: "docs")]
        state.cleanupBusy = true
        state.resetCleanup()
        XCTAssertNotNil(state.cleanupMode, "busy 중 리셋은 무시돼야 한다")
        XCTAssertFalse(state.cleanupScheme.isEmpty)

        state.cleanupBusy = false
        state.resetCleanup()
        XCTAssertNil(state.cleanupMode, "busy 해제 후엔 정상 리셋")
        XCTAssertTrue(state.cleanupScheme.isEmpty)
    }

    func testStartCleanupIgnoredWhileBusyButShowsSheet() {
        let state = AppState(dataDirectory: tempDir)
        let a = URL(fileURLWithPath: "/tmp/a")
        state.startCleanup(folder: a)
        state.cleanupBusy = true
        state.showFolderCleanup = false

        state.startCleanup(folder: URL(fileURLWithPath: "/tmp/b"))
        XCTAssertEqual(state.cleanupMode?.root, a, "busy 중 다른 폴더 재시작은 무시")
        XCTAssertTrue(state.showFolderCleanup, "시트는 다시 보여준다(진행 중 세션 표시)")
    }

    // MARK: 배정 중 스킴 편집 TOCTOU — plan은 배정 시작 시점 스킴을 봐야 한다.

    /// ask() 도중 주어진 뮤테이션을 실행하는 가짜 Claude — "배정(수 분) 도중 사용자가
    /// 스킴을 편집"하는 상황을 재현한다.
    private actor MutatingClaude: ClaudeAsking {
        let response: String
        let mutate: @Sendable () async -> Void
        init(response: String, mutate: @escaping @Sendable () async -> Void) {
            self.response = response
            self.mutate = mutate
        }
        func ask(prompt: String, context: String) async throws -> String {
            await mutate()
            return response
        }
    }

    /// 회귀(2026-07-05): assignCleanupPlan이 스킴을 배정 시작·완료 두 시점에 읽어,
    /// 배정 도중 버킷을 삭제하면 plan.scheme에서 빠진 버킷의 move가 적용 시
    /// MoveExecutor 가드에서 조용히 실패로 떨어졌다. plan은 시작 시점 스냅샷을 봐야 한다.
    func testAssignPlanUsesSchemeSnapshotFromStart() async throws {
        // 실제 파일 2개(FileScanner가 스캔할 대상).
        let work = tempDir.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try "a".write(to: work.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
        try "b".write(to: work.appendingPathComponent("b.md"), atomically: true, encoding: .utf8)

        let state = AppState(dataDirectory: tempDir)
        state.startCleanup(folder: work)
        state.cleanupScheme = [
            CleanupBucket(id: "docs", name: "docs", hint: "문서", relativePath: "docs"),
            CleanupBucket(id: "imgs", name: "imgs", hint: "이미지", relativePath: "imgs"),
        ]

        // 배정 응답은 두 버킷 모두 사용(confidence 높여 2차 재배정 우회).
        // ask() 도중 사용자가 imgs 버킷을 삭제한다.
        let fake = MutatingClaude(
            response: """
            {"assignments":[{"i":0,"id":"docs","reason":"t","confidence":0.9},
                            {"i":1,"id":"imgs","reason":"t","confidence":0.9}]}
            """,
            mutate: {
                await MainActor.run { state.cleanupScheme.removeAll { $0.id == "imgs" } }
            }
        )
        state.cleanupService = CleanupService(claude: fake, kordoc: KordocService())

        await state.assignCleanupPlan()

        let plan = try XCTUnwrap(state.cleanupPlan)
        XCTAssertEqual(plan.moves.count, 2)
        XCTAssertTrue(plan.scheme.contains { $0.id == "imgs" },
                      "plan.scheme은 배정 시작 시점 스냅샷 — 도중 삭제된 버킷도 있어야 imgs 배정이 적용에서 실패하지 않는다")
    }

    /// 방어선: 배정 도중 세션(cleanupMode)이 바뀌었으면 완료 결과를 폐기한다 —
    /// 스테일 plan이 새 세션 위로 부활해 옛 폴더 파일을 실제로 이동시키는 것 방지.
    func testAssignDiscardsResultWhenSessionChangedMidFlight() async throws {
        let work = tempDir.appendingPathComponent("work2", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        try "a".write(to: work.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)

        let state = AppState(dataDirectory: tempDir)
        state.startCleanup(folder: work)
        state.cleanupScheme = [
            CleanupBucket(id: "docs", name: "docs", hint: "문서", relativePath: "docs"),
        ]

        // ask() 도중 세션이 교체된다(진입점 busy 가드를 우회하는 미래 경로 가정).
        let fake = MutatingClaude(
            response: #"{"assignments":[{"i":0,"id":"docs","reason":"t","confidence":0.9}]}"#,
            mutate: {
                await MainActor.run { state.cleanupMode = nil }
            }
        )
        state.cleanupService = CleanupService(claude: fake, kordoc: KordocService())

        await state.assignCleanupPlan()

        XCTAssertNil(state.cleanupPlan, "세션이 바뀌었으면 스테일 배정 결과를 반영하지 않는다")
    }
}
