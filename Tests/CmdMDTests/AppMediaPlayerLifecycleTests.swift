import XCTest
import AVFoundation
@testable import CmdMD

/// 미디어 플레이어 정지 소유권 — 뷰 생명주기(onDisappear)가 창 숨김·탭 전환에서
/// 신뢰 불가함이 실측됐다(2026-07-03, 35초+ 오디오 잔존). AppState가 소유권을 가져와
/// 탭 전환·탭 닫기·창 닫기 시점에 능동적으로 정지시키는지 검증한다.
///
/// v2: 창 2개가 같은 탭을 보여주면 뷰마다 AVPlayer를 따로 만들어 등록하는데,
/// 레지스트리는 탭당 1개(마지막 등록)만 유지해 밀려난 플레이어가 재생되면
/// pauseAll/pauseInactive가 못 잡는다(고아, 실측). 그래서 뷰는 직접 만들지 않고
/// `mediaPlayer(forTab:url:)`로 탭당 단일 인스턴스를 획득해야 한다.
///
/// v3: pause 검증은 vacuous 방지를 위해 먼저 play()로 rate != 0 전제를 만든 뒤
/// 우리 정지 경로 실행 후 rate == 0을 확인한다 — pause 로직을 no-op으로 바꾸면
/// 반드시 실패하는 형태. play()/pause()는 rate를 동기 설정하므로 headless에서도
/// 결정적임을 프로세스 밖 프로브로 실측(존재하지 않는 URL 10/10 반복 안정:
/// play→1.0, pause→0.0).
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
    private func makeURL(_ name: String = UUID().uuidString) -> URL {
        URL(fileURLWithPath: "/tmp/존재하지않는파일-\(name).mp3")
    }

    /// 재생 중 상태 전제를 만든다 — 이 전제가 깨지면 pause 검증이 공허해지므로 즉시 실패.
    private func startPlaying(_ player: AVPlayer, _ label: String,
                              file: StaticString = #filePath, line: UInt = #line) {
        player.play()
        XCTAssertNotEqual(player.rate, 0, "\(label): play() 후 rate != 0 전제가 성립해야 한다",
                          file: file, line: line)
    }

    // MARK: - v2 획득 API: 탭당 단일 공유 플레이어

    @MainActor
    func testSameTabSameURLReturnsSameInstance() {
        let app = AppState(dataDirectory: tempDir)
        let tabID = UUID()
        let url = makeURL()

        // 창 2개가 같은 탭을 보여주는 상황 시뮬레이션 — 두 뷰가 각자 획득해도 인스턴스는 하나.
        let first = app.mediaPlayer(forTab: tabID, url: url)
        let second = app.mediaPlayer(forTab: tabID, url: url)

        XCTAssertTrue(first === second, "같은 탭·같은 url이면 동일 인스턴스여야 한다(고아 플레이어 불가)")
        XCTAssertTrue(app.mediaPlayers[tabID] === first, "레지스트리에도 그 인스턴스가 있어야 한다")
    }

    @MainActor
    func testURLChangeReplacesAndPausesPreviousPlayer() {
        let app = AppState(dataDirectory: tempDir)
        let tabID = UUID()

        let old = app.mediaPlayer(forTab: tabID, url: makeURL("a"))
        startPlaying(old, "이전 플레이어")

        let new = app.mediaPlayer(forTab: tabID, url: makeURL("b"))

        XCTAssertFalse(old === new, "url이 바뀌면 새 플레이어로 교체돼야 한다")
        XCTAssertEqual(old.rate, 0, "교체로 밀려나는 이전 플레이어는 정지해야 한다")
        XCTAssertTrue(app.mediaPlayers[tabID] === new, "레지스트리는 최신 플레이어를 가져야 한다")
    }

    // MARK: - 정지 훅: 탭 닫기·탭 전환·창 닫기

    @MainActor
    func testCloseTabRemovesAndPausesPlayer() {
        let app = AppState(dataDirectory: tempDir)
        let tab = EditorTab(fileURL: URL(fileURLWithPath: "/tmp/a.mp3"), title: "a", kind: .media)
        app.tabs = [tab]
        app.activeTabId = tab.id
        let player = app.mediaPlayer(forTab: tab.id, url: makeURL())
        startPlaying(player, "닫을 탭의 플레이어")

        app.closeTab(tab)

        XCTAssertEqual(player.rate, 0, "탭을 닫으면 그 플레이어는 정지해야 한다")
        XCTAssertNil(app.mediaPlayers[tab.id], "탭을 닫으면 플레이어 등록도 제거돼야 한다")
    }

    @MainActor
    func testActiveTabChangePausesInactivePlayers() {
        let app = AppState(dataDirectory: tempDir)
        let tabA = EditorTab(fileURL: URL(fileURLWithPath: "/tmp/a.mp3"), title: "a", kind: .media)
        let tabB = EditorTab(fileURL: URL(fileURLWithPath: "/tmp/b.mp3"), title: "b", kind: .media)
        app.tabs = [tabA, tabB]
        app.activeTabId = tabA.id
        let playerA = app.mediaPlayer(forTab: tabA.id, url: makeURL("a"))
        _ = app.mediaPlayer(forTab: tabB.id, url: makeURL("b"))
        startPlaying(playerA, "활성 탭 A의 플레이어")

        // 탭 A가 재생 중일 때 탭 B로 전환하면 A가 정지해야 한다(비활성이 됐으므로).
        app.activeTabId = tabB.id

        XCTAssertEqual(playerA.rate, 0, "비활성 탭이 된 플레이어는 정지해야 한다")
    }

    @MainActor
    func testPauseAllMediaPlayersStopsEveryPlayer() {
        let app = AppState(dataDirectory: tempDir)
        let tabA = EditorTab(fileURL: URL(fileURLWithPath: "/tmp/a.mp3"), title: "a", kind: .media)
        let tabB = EditorTab(fileURL: URL(fileURLWithPath: "/tmp/b.mp3"), title: "b", kind: .media)
        app.tabs = [tabA, tabB]
        let playerA = app.mediaPlayer(forTab: tabA.id, url: makeURL("a"))
        let playerB = app.mediaPlayer(forTab: tabB.id, url: makeURL("b"))
        startPlaying(playerA, "탭 A 플레이어")
        startPlaying(playerB, "탭 B 플레이어")

        app.pauseAllMediaPlayers()

        XCTAssertEqual(playerA.rate, 0, "창 닫기(=숨김) 시 전 플레이어가 정지해야 한다")
        XCTAssertEqual(playerB.rate, 0, "창 닫기(=숨김) 시 전 플레이어가 정지해야 한다")
    }
}
