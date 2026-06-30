import XCTest
@testable import CmdMD

final class IndexedFoldersSettingsTests: XCTestCase {
    func testDefaultsEmptyWhenAbsent() throws {
        let json = #"{"fontSize":14}"#.data(using: .utf8)!
        let s = try JSONDecoder().decode(AppSettings.self, from: json)
        XCTAssertEqual(s.indexedFolders, [])
    }

    func testRoundTripsIndexedFolders() throws {
        var s = AppSettings()
        s.indexedFolders = ["/Users/x/Docs", "/Users/x/HWP"]
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertEqual(back.indexedFolders, ["/Users/x/Docs", "/Users/x/HWP"])
    }
}
