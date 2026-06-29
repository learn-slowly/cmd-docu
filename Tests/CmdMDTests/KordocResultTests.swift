import XCTest
@testable import CmdMD

final class KordocResultTests: XCTestCase {
    private let json = """
    {
      "success": true,
      "fileType": "hwp",
      "markdown": "# 제목\\n\\n본문",
      "blocks": [
        {"type":"heading","text":"제목","pageNumber":1,"level":1,"style":{"fontSize":20}},
        {"type":"paragraph","text":"본문","pageNumber":1,"style":{"fontSize":10}}
      ],
      "metadata": {"version":"5.0","pageCount":3},
      "outline": [{"level":1,"text":"제목","pageNumber":1}]
    }
    """.data(using: .utf8)!

    func testDecodesCoreFields() throws {
        let r = try JSONDecoder().decode(KordocResult.self, from: json)
        XCTAssertTrue(r.success)
        XCTAssertEqual(r.fileType, "hwp")
        XCTAssertEqual(r.markdown, "# 제목\n\n본문")
    }

    func testDecodesBlocksAndOutline() throws {
        let r = try JSONDecoder().decode(KordocResult.self, from: json)
        XCTAssertEqual(r.blocks?.count, 2)
        XCTAssertEqual(r.blocks?.first?.type, "heading")
        XCTAssertEqual(r.blocks?.first?.level, 1)
        XCTAssertEqual(r.blocks?[1].pageNumber, 1)
        XCTAssertEqual(r.outline?.first?.text, "제목")
        XCTAssertEqual(r.outline?.first?.level, 1)
    }

    func testMissingOptionalArraysDecodeAsNil() throws {
        let minimal = #"{"success":true,"fileType":"docx","markdown":"hi"}"#.data(using: .utf8)!
        let r = try JSONDecoder().decode(KordocResult.self, from: minimal)
        XCTAssertNil(r.blocks)
        XCTAssertNil(r.outline)
        XCTAssertEqual(r.markdown, "hi")
    }

    func testMalformedJSONThrows() {
        let bad = "not json".data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(KordocResult.self, from: bad))
    }
}
