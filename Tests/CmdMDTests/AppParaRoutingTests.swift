import XCTest
@testable import CmdMD

final class AppParaRoutingTests: XCTestCase {

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

    @MainActor
    func testIsParaRoutingConfiguredFalseWhenUnset() {
        // 임시 디렉터리라 settings.paraVaultId가 미설정 → 미구성으로 판정돼야 한다.
        let app = AppState(dataDirectory: tempDir)
        XCTAssertFalse(app.isParaRoutingConfigured())
    }

    @MainActor
    func testIsParaRoutingConfiguredFalseWithoutFolders() {
        let app = AppState(dataDirectory: tempDir)
        let vault = Vault(name: "V", rootPath: URL(fileURLWithPath: "/tmp/v"))
        app.vaults = [vault]
        app.settings.paraVaultId = vault.id
        app.settings.paraFolders = []
        XCTAssertFalse(app.isParaRoutingConfigured())
    }

    @MainActor
    func testIsParaRoutingConfiguredTrueWhenVaultAndFoldersPresent() {
        let app = AppState(dataDirectory: tempDir)
        let vault = Vault(name: "V", rootPath: URL(fileURLWithPath: "/tmp/v"))
        app.vaults = [vault]
        app.settings.paraVaultId = vault.id
        app.settings.paraFolders = ParaFolder.legoSeed()
        XCTAssertTrue(app.isParaRoutingConfigured())
        XCTAssertEqual(app.paraVault?.id, vault.id)
    }

    @MainActor
    func testIsParaRoutingConfiguredFalseWhenVaultMissing() {
        let app = AppState(dataDirectory: tempDir)
        app.settings.paraVaultId = UUID()      // 등록되지 않은 볼트
        app.settings.paraFolders = ParaFolder.legoSeed()
        XCTAssertFalse(app.isParaRoutingConfigured())
        XCTAssertNil(app.paraVault)
    }

    @MainActor
    func testRequestClaudeRouteUnconfiguredSetsErrorAndReturnsNil() async {
        let app = AppState(dataDirectory: tempDir)
        let result = await app.requestClaudeRoute(noteBody: "본문")
        XCTAssertNil(result)
        XCTAssertNotNil(app.claudeRouteError)
        XCTAssertFalse(app.claudeRouteInProgress)
    }
}
