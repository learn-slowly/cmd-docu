import XCTest
@testable import CmdMD

final class CleanupPlannerSchemeTests: XCTestCase {
    private func metas() -> [FileMeta] {
        [
            FileMeta(url: URL(fileURLWithPath: "/d/세금신고.pdf"), name: "세금신고.pdf", ext: "pdf",
                     size: 100, createdAt: Date(), modifiedAt: Date()),
            FileMeta(url: URL(fileURLWithPath: "/d/사진.png"), name: "사진.png", ext: "png",
                     size: 200, createdAt: Date(), modifiedAt: Date()),
        ]
    }

    func testSchemePromptListsFilesAndAsksJSON() {
        let p = CleanupPlanner.buildSchemePrompt(metadata: metas())
        XCTAssertTrue(p.contains("세금신고.pdf"))
        XCTAssertTrue(p.contains("사진.png"))
        XCTAssertTrue(p.lowercased().contains("json"))
        XCTAssertTrue(p.contains("\"buckets\""))
    }

    func testParseSchemeExtractsBuckets() {
        let out = "여기 결과:\n{\"buckets\":[{\"name\":\"문서\",\"hint\":\"PDF·서류\"},{\"name\":\"이미지\",\"hint\":\"사진\"}]}\n끝"
        let scheme = CleanupPlanner.parseScheme(out)
        XCTAssertEqual(scheme?.count, 2)
        XCTAssertEqual(scheme?.first?.name, "문서")
        XCTAssertEqual(scheme?.first?.id, "문서")
        XCTAssertEqual(scheme?.first?.relativePath, "문서")
        XCTAssertEqual(scheme?.first?.hint, "PDF·서류")
    }

    func testParseSchemeSanitizesAndDedupes() {
        let out = "{\"buckets\":[{\"name\":\"../탈출\",\"hint\":\"x\"},{\"name\":\"a/b\",\"hint\":\"y\"},{\"name\":\"a-b\",\"hint\":\"z\"}]}"
        let scheme = CleanupPlanner.parseScheme(out)
        // "a/b" → "a-b" 가 되어 "a-b"와 중복 → 하나만 남는다. "../탈출" → ".." 제거.
        XCTAssertNotNil(scheme)
        XCTAssertFalse(scheme!.contains { $0.id.contains("/") || $0.id.contains("..") })
        XCTAssertEqual(scheme!.filter { $0.id == "a-b" }.count, 1)
    }

    func testParseSchemeReturnsNilOnGarbage() {
        XCTAssertNil(CleanupPlanner.parseScheme("그냥 텍스트 아무것도 없음"))
        XCTAssertNil(CleanupPlanner.parseScheme("{\"buckets\":[]}"))
    }
}
