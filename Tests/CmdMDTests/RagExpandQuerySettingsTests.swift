import XCTest
@testable import CmdMD

final class RagExpandQuerySettingsTests: XCTestCase {
    func testDefaultsTrueWhenAbsent() throws {
        let json = #"{"fontSize":14}"#.data(using: .utf8)!
        let s = try JSONDecoder().decode(AppSettings.self, from: json)
        XCTAssertTrue(s.ragExpandQuery)
    }

    func testRoundTripsFalse() throws {
        var s = AppSettings()
        s.ragExpandQuery = false
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertFalse(back.ragExpandQuery)
    }
}
