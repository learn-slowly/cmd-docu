import XCTest
@testable import CmdMD

final class FillFieldTests: XCTestCase {
    private let json = """
    {
      "fields": [
        {"label":"성명","value":"","row":0,"col":1},
        {"label":"전화","value":"010","row":1,"col":1}
      ],
      "confidence": 1.0
    }
    """.data(using: .utf8)!

    func testDecodesFieldsAndConfidence() throws {
        let d = try JSONDecoder().decode(FillDetection.self, from: json)
        XCTAssertEqual(d.fields.count, 2)
        XCTAssertEqual(d.fields.first?.label, "성명")
        XCTAssertEqual(d.fields.first?.value, "")
        XCTAssertEqual(d.fields[1].row, 1)
        XCTAssertEqual(d.fields[1].col, 1)
        XCTAssertEqual(d.confidence, 1.0)
    }

    func testIdDisambiguatesDuplicateLabels() throws {
        let d = try JSONDecoder().decode(FillDetection.self, from: json)
        XCTAssertNotEqual(d.fields[0].id, d.fields[1].id)
    }

    func testMissingConfidenceDecodesAsNil() throws {
        let minimal = #"{"fields":[]}"#.data(using: .utf8)!
        let d = try JSONDecoder().decode(FillDetection.self, from: minimal)
        XCTAssertTrue(d.fields.isEmpty)
        XCTAssertNil(d.confidence)
    }
}
