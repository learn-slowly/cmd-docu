import XCTest
@testable import CmdMD

final class ClaudeAuthParserTests: XCTestCase {
    func testParseLoggedInStatus() {
        let out = """
        {
          "loggedIn": true,
          "authMethod": "claude.ai",
          "apiProvider": "firstParty",
          "email": "user@example.com",
          "subscriptionType": "max"
        }
        """
        let s = ClaudeAuthParser.parse(out)
        XCTAssertEqual(s?.loggedIn, true)
        XCTAssertEqual(s?.email, "user@example.com")
        XCTAssertEqual(s?.subscriptionType, "max")
        XCTAssertEqual(s?.authMethod, "claude.ai")
    }

    func testParseLoggedOutStatus() {
        let s = ClaudeAuthParser.parse(#"{"loggedIn": false}"#)
        XCTAssertEqual(s?.loggedIn, false)
        XCTAssertNil(s?.email)
    }

    func testParseToleratesSurroundingText() {
        let out = "잡음\n{\"loggedIn\":true,\"email\":\"a@b.com\"}\n끝"
        XCTAssertEqual(ClaudeAuthParser.parse(out)?.email, "a@b.com")
    }

    func testParseReturnsNilWhenNoJSON() {
        XCTAssertNil(ClaudeAuthParser.parse("not logged in\n"))
        XCTAssertNil(ClaudeAuthParser.parse(""))
    }
}
