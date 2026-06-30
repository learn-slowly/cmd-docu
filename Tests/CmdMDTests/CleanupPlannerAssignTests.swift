import XCTest
@testable import CmdMD

final class CleanupPlannerAssignTests: XCTestCase {
    private func scheme() -> CleanupScheme {
        [CleanupBucket(id: "문서", name: "문서", hint: "서류", relativePath: "문서"),
         CleanupBucket(id: "이미지", name: "이미지", hint: "사진", relativePath: "이미지")]
    }
    private func metas() -> [FileMeta] {
        [FileMeta(url: URL(fileURLWithPath: "/d/세금.pdf"), name: "세금.pdf", ext: "pdf", size: 1, createdAt: Date(), modifiedAt: Date()),
         FileMeta(url: URL(fileURLWithPath: "/d/사진.png"), name: "사진.png", ext: "png", size: 1, createdAt: Date(), modifiedAt: Date())]
    }

    func testAssignPromptIncludesSchemeIdsAndFiles() {
        let p = CleanupPlanner.buildAssignPrompt(scheme: scheme(), metadata: metas())
        XCTAssertTrue(p.contains("문서"))
        XCTAssertTrue(p.contains("이미지"))
        XCTAssertTrue(p.contains("세금.pdf"))
        XCTAssertTrue(p.contains("\"assignments\""))
    }

    func testParseAssignmentsMatchesByNameAndValidatesId() {
        let out = """
        {"assignments":[
          {"name":"세금.pdf","id":"문서","reason":"서류","confidence":0.9},
          {"name":"사진.png","id":"없는버킷","reason":"?","confidence":0.4},
          {"name":"유령.txt","id":"문서","reason":"x","confidence":1.0}
        ]}
        """
        let a = CleanupPlanner.parseAssignments(out, scheme: scheme(), metadata: metas())
        XCTAssertEqual(a?.count, 2) // 유령.txt는 메타에 없어 버려짐
        XCTAssertEqual(a?.first(where: { $0.fileURL.lastPathComponent == "세금.pdf" })?.bucketId, "문서")
        // 없는 버킷 id는 ""(미분류)로 강등
        XCTAssertEqual(a?.first(where: { $0.fileURL.lastPathComponent == "사진.png" })?.bucketId, "")
    }

    func testParseAssignmentsClampsConfidence() {
        let out = "{\"assignments\":[{\"name\":\"세금.pdf\",\"id\":\"문서\",\"reason\":\"x\",\"confidence\":9.9}]}"
        let a = CleanupPlanner.parseAssignments(out, scheme: scheme(), metadata: metas())
        XCTAssertEqual(a?.first?.confidence, 1.0)
    }

    func testParseAssignmentsNilOnGarbage() {
        XCTAssertNil(CleanupPlanner.parseAssignments("없음", scheme: scheme(), metadata: metas()))
    }

    func testMergeOverridesByURL() {
        let base = [CleanupAssignment(fileURL: URL(fileURLWithPath: "/d/세금.pdf"), bucketId: "", reason: "모호", confidence: 0.2)]
        let over = [CleanupAssignment(fileURL: URL(fileURLWithPath: "/d/세금.pdf"), bucketId: "문서", reason: "본문 확인", confidence: 0.95)]
        let merged = CleanupPlanner.merge(base, with: over)
        XCTAssertEqual(merged.first?.bucketId, "문서")
        XCTAssertEqual(merged.first?.confidence, 0.95)
    }

    func testBuildMovesApprovesOnlyClassified() {
        let assigns = [
            CleanupAssignment(fileURL: URL(fileURLWithPath: "/d/세금.pdf"), bucketId: "문서", reason: "x", confidence: 0.9),
            CleanupAssignment(fileURL: URL(fileURLWithPath: "/d/사진.png"), bucketId: "", reason: "모호", confidence: 0.1),
        ]
        let moves = CleanupPlanner.buildMoves(from: assigns)
        XCTAssertEqual(moves.count, 2)
        XCTAssertEqual(moves.first(where: { $0.source.lastPathComponent == "세금.pdf" })?.approved, true)
        XCTAssertEqual(moves.first(where: { $0.source.lastPathComponent == "사진.png" })?.approved, false)
    }

    func testAmbiguousContextTruncates() {
        let ctx = CleanupPlanner.buildAmbiguousContext([("a.md", String(repeating: "가", count: 5000))], maxCharsEach: 100)
        XCTAssertTrue(ctx.contains("a.md"))
        XCTAssertTrue(ctx.contains("생략"))
        XCTAssertLessThan(ctx.count, 5000)
    }
}
