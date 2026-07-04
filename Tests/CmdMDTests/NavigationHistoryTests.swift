import XCTest
@testable import CmdMD

/// F3: NavigationHistory 순수 모델 테스트 — FS 접근 없음(존재 검사는 클로저 주입).
final class NavigationHistoryTests: XCTestCase {

    private func loc(_ display: String, root: String = "/root") -> FolderLocation {
        FolderLocation(root: URL(fileURLWithPath: root), display: URL(fileURLWithPath: display))
    }
    private let alwaysValid: (FolderLocation) -> Bool = { _ in true }

    // MARK: - seed: 첫 record는 current만 채우고 스택 불변

    func testFirstRecordSeedsWithoutPush() {
        var h = NavigationHistory()
        h.record(loc("/root"))
        XCTAssertFalse(h.canGoBack, "첫 기록(seed)은 뒤로 갈 곳을 만들지 않는다")
        XCTAssertEqual(h.current, loc("/root"))
    }

    // MARK: - record: 이동 시 push + forward 클리어, 연속 중복 무시

    func testRecordPushesAndClearsForward() {
        var h = NavigationHistory()
        h.record(loc("/root"))
        h.record(loc("/root/a"))
        h.record(loc("/root/b"))
        XCTAssertNotNil(h.goBack(isValid: alwaysValid))
        XCTAssertTrue(h.canGoForward)
        h.record(loc("/root/c"))
        XCTAssertFalse(h.canGoForward, "새 이동은 forwardStack을 버린다(브라우저 규약)")
    }

    func testConsecutiveDuplicateIsIgnored() {
        var h = NavigationHistory()
        h.record(loc("/root"))
        h.record(loc("/root/a"))
        h.record(loc("/root/a"))   // didSet 재발화 등 — standardized 동등이면 무시
        XCTAssertEqual(h.backStack.count, 1, "연속 중복은 병합돼야 한다")
    }

    // MARK: - goBack/goForward 왕복

    func testBackForwardRoundTrip() {
        var h = NavigationHistory()
        h.record(loc("/root"))
        h.record(loc("/root/a"))
        XCTAssertEqual(h.goBack(isValid: alwaysValid), loc("/root"))
        XCTAssertEqual(h.current, loc("/root"))
        XCTAssertEqual(h.goForward(isValid: alwaysValid), loc("/root/a"))
        XCTAssertEqual(h.current, loc("/root/a"))
        XCTAssertFalse(h.canGoForward)
    }

    func testGoBackOnEmptyReturnsNil() {
        var h = NavigationHistory()
        XCTAssertNil(h.goBack(isValid: alwaysValid))
        h.record(loc("/root"))
        XCTAssertNil(h.goBack(isValid: alwaysValid), "seed만 있으면 뒤로 갈 곳이 없다")
    }

    // MARK: - skip-pop: 죽은 항목은 건너뛰며 계속 pop

    func testGoBackSkipsInvalidEntries() {
        var h = NavigationHistory()
        h.record(loc("/root"))
        h.record(loc("/root/dead"))
        h.record(loc("/root/b"))
        let result = h.goBack { !$0.display.path.contains("dead") }
        XCTAssertEqual(result, loc("/root"), "죽은 항목(dead)은 건너뛰고 그 아래 항목으로")
    }

    func testGoBackAllInvalidReturnsNil() {
        var h = NavigationHistory()
        h.record(loc("/root"))
        h.record(loc("/root/a"))
        XCTAssertNil(h.goBack { _ in false })
        XCTAssertFalse(h.canGoBack, "전부 무효면 스택이 비워지고 nil")
    }

    // MARK: - prune

    func testPruneRemovesInvalidFromBothStacksAndKeepsCurrent() {
        var h = NavigationHistory()
        h.record(loc("/root"))
        h.record(loc("/root/deadA"))
        h.record(loc("/root/mid"))
        h.record(loc("/root/deadB"))
        h.record(loc("/root/b"))
        // back=[root, deadA, mid, deadB], current=b
        _ = h.goBack(isValid: alwaysValid)   // deadB→current, forward=[b]
        _ = h.goBack(isValid: alwaysValid)   // mid→current, forward=[b, deadB]
        // 이제 back=[root, deadA], forward=[b, deadB] — 양쪽 스택에 dead가 실존
        h.prune { !$0.display.path.contains("dead") }
        XCTAssertEqual(h.backStack, [loc("/root")], "backStack의 dead 항목이 제거돼야 한다")
        XCTAssertEqual(h.forwardStack, [loc("/root/b")], "forwardStack의 dead 항목이 제거돼야 한다")
        XCTAssertEqual(h.current, loc("/root/mid"), "prune은 current를 건드리지 않는다")
    }

    // MARK: - cap: backStack 상한 100

    func testBackStackCapped() {
        var h = NavigationHistory()
        for i in 0...150 { h.record(loc("/root/\(i)")) }
        XCTAssertEqual(h.backStack.count, NavigationHistory.capacity,
                       "backStack은 상한(\(NavigationHistory.capacity))을 넘지 않는다")
        XCTAssertEqual(h.backStack.last, loc("/root/149"), "최신 항목이 보존돼야 한다")
    }
}
