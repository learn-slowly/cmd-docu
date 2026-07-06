import XCTest
@testable import CmdMD

/// 외부 열기 직렬 큐(스펙 §2.2·§2.3) — 도착 순 FIFO·항상 새 탭·마지막 처리 파일이 활성.
@MainActor
final class AppExternalOpenQueueTests: XCTestCase {
    var tempData: URL!
    var workDir: URL!
    var app: AppState!

    override func setUp() {
        super.setUp()
        tempData = TempDataDirectory.make()
        workDir = TempDataDirectory.make()
        app = AppState(dataDirectory: tempData)
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

    func testSequentialEnqueueOpensInOrderAndActivatesLast() async {
        let a = makeNote("a.md"), b = makeNote("b.md"), c = makeNote("c.md")
        app.enqueueExternalOpen([a])
        app.enqueueExternalOpen([b])
        app.enqueueExternalOpen([c])
        await app.externalOpenChain?.value
        XCTAssertEqual(app.tabs.compactMap(\.fileURL), [a, b, c])
        XCTAssertEqual(app.activeTabId, app.tabs.last?.id)
    }

    func testBatchEnqueueActivatesLastOfBatch() async {
        let a = makeNote("a.md"), b = makeNote("b.md")
        app.enqueueExternalOpen([a, b])
        await app.externalOpenChain?.value
        XCTAssertEqual(app.tabs.compactMap(\.fileURL), [a, b])
        XCTAssertEqual(app.activeTab?.fileURL, b)
    }

    func testReopeningSameURLReusesExistingTab() async {
        let a = makeNote("a.md"), b = makeNote("b.md")
        app.enqueueExternalOpen([a, b])
        await app.externalOpenChain?.value
        let originalTabId = app.tabs.first?.id

        app.enqueueExternalOpen([a])   // 같은 URL 재열기 — 새 탭이 아니라 기존 탭 활성
        await app.externalOpenChain?.value
        XCTAssertEqual(app.tabs.count, 2)
        XCTAssertEqual(app.activeTabId, originalTabId)
    }

    func testEnqueueSwitchesToReaderMode() async {
        let a = makeNote("a.md")
        app.mainMode = .library
        app.enqueueExternalOpen([a])
        await app.externalOpenChain?.value
        XCTAssertEqual(app.mainMode, .reader)
    }

    func testEmptyEnqueueIsNoop() async {
        app.enqueueExternalOpen([])
        XCTAssertNil(app.externalOpenChain)
        XCTAssertTrue(app.tabs.isEmpty)
    }

    // MARK: - 스모크 픽스 1(배치 열기 유실) — routeOpenedURLs

    func testRouteOpenedURLsBatchOpensAllFilesInOrder() async {
        let a = makeNote("r1.md"), b = makeNote("r2.md"), c = makeNote("r3.md")
        AppState.routeOpenedURLs([a, b, c], to: app)
        await app.externalOpenChain?.value
        XCTAssertEqual(app.tabs.compactMap(\.fileURL), [a, b, c])
        XCTAssertEqual(app.activeTab?.fileURL, c)
    }

    func testRouteOpenedURLsSkipsNonFileAndNilAppState() async {
        AppState.routeOpenedURLs([URL(string: "https://example.com")!], to: app)
        XCTAssertNil(app.externalOpenChain)
        XCTAssertTrue(app.tabs.isEmpty)
        AppState.routeOpenedURLs([makeNote("x.md")], to: nil)   // crash 없이 무시
    }
}
