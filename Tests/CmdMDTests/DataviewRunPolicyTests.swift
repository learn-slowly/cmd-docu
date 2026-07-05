import XCTest
@testable import CmdMD

final class DataviewRunPolicyTests: XCTestCase {
    func testInsideVaultOrIndexedFolderIsAuto() {
        XCTAssertTrue(DataviewRunPolicy.isAutoRun(notePath: "/v/notebox/Calendar/a.md",
                                                  vaultPaths: ["/v/notebox"], indexedFolders: []))
        XCTAssertTrue(DataviewRunPolicy.isAutoRun(notePath: "/idx/f/a.md",
                                                  vaultPaths: [], indexedFolders: ["/idx/f"]))
        XCTAssertFalse(DataviewRunPolicy.isAutoRun(notePath: "/Users/x/Downloads/a.md",
                                                   vaultPaths: ["/v/notebox"], indexedFolders: ["/idx/f"]))
    }

    func testSlashBoundaryNoSiblingPrefixMatch() {
        XCTAssertFalse(DataviewRunPolicy.isAutoRun(notePath: "/v/notebox2/a.md",
                                                   vaultPaths: ["/v/notebox"], indexedFolders: []))
    }

    func testRootPathPicksLongestMatch() {
        XCTAssertEqual(DataviewRunPolicy.rootPath(for: "/v/notebox/Calendar/a.md",
                                                  vaultPaths: ["/v/notebox"],
                                                  indexedFolders: ["/v/notebox/Calendar"]),
                       "/v/notebox/Calendar")
        XCTAssertNil(DataviewRunPolicy.rootPath(for: "/elsewhere/a.md",
                                                vaultPaths: ["/v/notebox"], indexedFolders: []))
    }
}
