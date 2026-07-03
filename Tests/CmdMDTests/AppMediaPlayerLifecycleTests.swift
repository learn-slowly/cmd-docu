import XCTest
import AVFoundation
@testable import CmdMD

/// 미디어 플레이어 정지 소유권 — 뷰 생명주기(onDisappear)가 창 숨김·탭 전환에서
/// 신뢰 불가함이 실측됐다(2026-07-03, 35초+ 오디오 잔존). AppState가 소유권을 가져와
/// 탭 전환·탭 닫기·창 닫기 시점에 능동적으로 정지시키는지 검증한다.
final class AppMediaPlayerLifecycleTests: XCTestCase {

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

    /// 존재하지 않는 URL이라도 AVPlayer 인스턴스 자체는 생성된다(재생 불필요).
    private func makePlayer() -> AVPlayer {
        AVPlayer(url: URL(fileURLWithPath: "/tmp/존재하지않는파일-\(UUID().uuidString).mp3"))
    }

    @MainActor
    func testRegisteringSameTabPausesPreviousPlayer() {
        let app = AppState(dataDirectory: tempDir)
        let tabID = UUID()
        let first = makePlayer()
        let second = makePlayer()

        app.registerMediaPlayer(first, forTab: tabID)
        app.registerMediaPlayer(second, forTab: tabID)

        XCTAssertEqual(first.timeControlStatus, .paused, "같은 탭에 새 플레이어를 등록하면 이전 플레이어는 정지해야 한다")
        XCTAssertTrue(app.mediaPlayers[tabID] === second, "등록된 플레이어는 최신 것으로 교체돼야 한다")
    }

    @MainActor
    func testCloseTabRemovesAndPausesPlayer() {
        let app = AppState(dataDirectory: tempDir)
        let tab = EditorTab(fileURL: URL(fileURLWithPath: "/tmp/a.mp3"), title: "a", kind: .media)
        app.tabs = [tab]
        app.activeTabId = tab.id
        let player = makePlayer()
        app.registerMediaPlayer(player, forTab: tab.id)

        app.closeTab(tab)

        XCTAssertEqual(player.timeControlStatus, .paused, "탭을 닫으면 그 플레이어는 정지해야 한다")
        XCTAssertNil(app.mediaPlayers[tab.id], "탭을 닫으면 플레이어 등록도 제거돼야 한다")
    }

    @MainActor
    func testActiveTabChangePausesInactivePlayers() {
        let app = AppState(dataDirectory: tempDir)
        let tabA = EditorTab(fileURL: URL(fileURLWithPath: "/tmp/a.mp3"), title: "a", kind: .media)
        let tabB = EditorTab(fileURL: URL(fileURLWithPath: "/tmp/b.mp3"), title: "b", kind: .media)
        app.tabs = [tabA, tabB]
        app.activeTabId = tabA.id
        let playerA = makePlayer()
        let playerB = makePlayer()
        app.registerMediaPlayer(playerA, forTab: tabA.id)
        app.registerMediaPlayer(playerB, forTab: tabB.id)

        // 탭 A를 활성 탭으로 등록한 뒤 탭 B로 전환하면 A가 정지해야 한다(비활성이 됐으므로).
        app.activeTabId = tabB.id

        XCTAssertEqual(playerA.timeControlStatus, .paused, "비활성 탭이 된 플레이어는 정지해야 한다")
    }

    @MainActor
    func testPauseAllMediaPlayersStopsEveryPlayer() {
        let app = AppState(dataDirectory: tempDir)
        let tabA = EditorTab(fileURL: URL(fileURLWithPath: "/tmp/a.mp3"), title: "a", kind: .media)
        let tabB = EditorTab(fileURL: URL(fileURLWithPath: "/tmp/b.mp3"), title: "b", kind: .media)
        app.tabs = [tabA, tabB]
        let playerA = makePlayer()
        let playerB = makePlayer()
        app.registerMediaPlayer(playerA, forTab: tabA.id)
        app.registerMediaPlayer(playerB, forTab: tabB.id)

        app.pauseAllMediaPlayers()

        XCTAssertEqual(playerA.timeControlStatus, .paused, "창 닫기(=숨김) 시 전 플레이어가 정지해야 한다")
        XCTAssertEqual(playerB.timeControlStatus, .paused, "창 닫기(=숨김) 시 전 플레이어가 정지해야 한다")
    }
}
