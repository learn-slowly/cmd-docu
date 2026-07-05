import XCTest
@testable import CmdMD

/// 배치 세션 복원(스펙 §2.4) — 로드만 일괄, 활성 탭은 끝에 정확히 1회.
/// 복원 Task는 외부 열기 큐 선두에 시드돼, 복원 중 도착한 외부 열기가 마지막=활성이 된다.
@MainActor
final class AppSessionBatchRestoreTests: XCTestCase {
    var tempData: URL!
    var workDir: URL!

    override func setUp() {
        super.setUp()
        tempData = TempDataDirectory.make()
        workDir = TempDataDirectory.make()
    }

    override func tearDown() {
        TempDataDirectory.cleanup(tempData)
        TempDataDirectory.cleanup(workDir)
        super.tearDown()
    }

    private func makeNote(_ name: String) -> URL {
        let url = workDir.appendingPathComponent(name)
        try? "# \(name)\n".write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// 실제 앱과 동일한 session.json을 시드(JSONEncoder 기본 — URL은 plain string 인코딩).
    private func seedSession(openFiles: [URL], activeIndex: Int?) throws {
        let session = SessionState(
            openFiles: openFiles,
            activeFileIndex: activeIndex,
            viewMode: .source,
            currentFolder: nil,
            sidebarVisible: true,
            inspectorVisible: false
        )
        let data = try JSONEncoder().encode(session)
        try data.write(to: tempData.appendingPathComponent("session.json"))
    }

    func testBatchRestoreOpensAllTabsAndActivatesSavedIndexOnce() async throws {
        let a = makeNote("a.md"), b = makeNote("b.md"), c = makeNote("c.md")
        try seedSession(openFiles: [a, b, c], activeIndex: 1)

        let app = AppState(dataDirectory: tempData)
        await app.externalOpenChain?.value

        XCTAssertEqual(app.tabs.compactMap(\.fileURL), [a, b, c])
        XCTAssertEqual(app.activeTab?.fileURL, b)
        // 배치 복원의 핵심 — 중간 활성화 없이 끝에 정확히 1회만 지정(스펙 §3-1).
        XCTAssertEqual(app.activeTabIdChangeCount, 1)
    }

    func testExternalOpenDuringRestoreEndsUpLastAndActive() async throws {
        let a = makeNote("a.md"), b = makeNote("b.md")
        let external = makeNote("external.md")
        try seedSession(openFiles: [a, b], activeIndex: 0)

        let app = AppState(dataDirectory: tempData)
        // 복원 체인이 도는 도중 외부 열기 도착(Finder 더블클릭 시뮬레이션) — 체인 직렬화로
        // 복원 완료 뒤에 처리돼 마지막 탭·활성이 된다(스펙 §2.4).
        app.enqueueExternalOpen([external])
        await app.externalOpenChain?.value

        XCTAssertEqual(app.tabs.compactMap(\.fileURL), [a, b, external])
        XCTAssertEqual(app.activeTab?.fileURL, external)
    }

    func testRestoreDeduplicatesRepeatedURLs() async throws {
        let a = makeNote("a.md"), b = makeNote("b.md")
        try seedSession(openFiles: [a, b, a], activeIndex: nil)

        let app = AppState(dataDirectory: tempData)
        await app.externalOpenChain?.value

        XCTAssertEqual(app.tabs.compactMap(\.fileURL), [a, b])
    }

    func testRestoreSkipsMissingFilesAndResolvesActiveByURL() async throws {
        let a = makeNote("a.md"), b = makeNote("b.md")
        let missing = workDir.appendingPathComponent("ghost.md")   // 만들지 않음
        // activeIndex 2 = b (missing이 필터돼도 URL로 해석해야 맞음 — 구 코드의 인덱스 시프트 수정)
        try seedSession(openFiles: [a, missing, b], activeIndex: 2)

        let app = AppState(dataDirectory: tempData)
        await app.externalOpenChain?.value

        XCTAssertEqual(app.tabs.compactMap(\.fileURL), [a, b])
        XCTAssertEqual(app.activeTab?.fileURL, b)
    }

    func testNoSessionFileMeansNoChainAndNoTabs() async {
        let app = AppState(dataDirectory: tempData)
        XCTAssertNil(app.externalOpenChain)
        XCTAssertTrue(app.tabs.isEmpty)
    }
}
