import XCTest
@testable import CmdMD

final class AppParaRoutingTests: XCTestCase {
    @MainActor
    func testIsParaRoutingConfiguredFalseWhenUnset() {
        let app = AppState()
        XCTAssertFalse(app.isParaRoutingConfigured())
    }

    @MainActor
    func testIsParaRoutingConfiguredFalseWithoutFolders() {
        let app = AppState()
        let vault = Vault(name: "V", rootPath: URL(fileURLWithPath: "/tmp/v"))
        app.vaults = [vault]
        app.settings.paraVaultId = vault.id
        app.settings.paraFolders = []
        XCTAssertFalse(app.isParaRoutingConfigured())
    }

    @MainActor
    func testIsParaRoutingConfiguredTrueWhenVaultAndFoldersPresent() {
        let app = AppState()
        let vault = Vault(name: "V", rootPath: URL(fileURLWithPath: "/tmp/v"))
        app.vaults = [vault]
        app.settings.paraVaultId = vault.id
        app.settings.paraFolders = ParaFolder.legoSeed()
        XCTAssertTrue(app.isParaRoutingConfigured())
        XCTAssertEqual(app.paraVault?.id, vault.id)
    }

    @MainActor
    func testIsParaRoutingConfiguredFalseWhenVaultMissing() {
        let app = AppState()
        app.settings.paraVaultId = UUID()      // 등록되지 않은 볼트
        app.settings.paraFolders = ParaFolder.legoSeed()
        XCTAssertFalse(app.isParaRoutingConfigured())
        XCTAssertNil(app.paraVault)
    }

    @MainActor
    func testRequestClaudeRouteUnconfiguredSetsErrorAndReturnsNil() async {
        let app = AppState()
        let result = await app.requestClaudeRoute(noteBody: "본문")
        XCTAssertNil(result)
        XCTAssertNotNil(app.claudeRouteError)
        XCTAssertFalse(app.claudeRouteInProgress)
    }
}
