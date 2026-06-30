import XCTest
@testable import CmdMD

final class ParaFolderTests: XCTestCase {
    func testLegoSeedHasSixFoldersWithExpectedPaths() {
        let seed = ParaFolder.legoSeed()
        XCTAssertEqual(seed.count, 6)
        let folders = seed.map(\.folder)
        XCTAssertEqual(folders, [
            "10000_Projects/Living_with_Damage",
            "10000_Projects/Build_and_Deploy",
            "10000_Projects/Left_Forward",
            "20000_Areas",
            "30000_Resources",
            "40000_Archive",
        ])
        XCTAssertTrue(seed.allSatisfy { !$0.label.isEmpty && !$0.hint.isEmpty })
    }

    func testParaFolderRoundTripsCodable() throws {
        let f = ParaFolder(label: "L", folder: "P/Q", hint: "H")
        let data = try JSONEncoder().encode(f)
        let back = try JSONDecoder().decode(ParaFolder.self, from: data)
        XCTAssertEqual(f, back)
    }

    func testAppSettingsDefaultsParaFieldsWhenAbsent() throws {
        // 구버전 settings.json(신규 키 없음)도 기본값으로 디코드돼야 한다(하위호환).
        let json = #"{"fontSize":14}"#.data(using: .utf8)!
        let s = try JSONDecoder().decode(AppSettings.self, from: json)
        XCTAssertNil(s.paraVaultId)
        XCTAssertTrue(s.paraFolders.isEmpty)
        XCTAssertFalse(s.claudeRoutingEnabled)
    }
}
