import XCTest
@testable import CmdMD

final class CleanupModelsTests: XCTestCase {
    func testParaBucketMapsFolderToRelativePath() {
        let pf = ParaFolder(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000aa")!,
                            label: "Resources", folder: "30000_Resources", hint: "참고 자료")
        let bucket = CleanupBucket.from(para: pf)
        XCTAssertEqual(bucket.id, pf.id.uuidString)
        XCTAssertEqual(bucket.name, "Resources")
        XCTAssertEqual(bucket.relativePath, "30000_Resources")
        XCTAssertEqual(bucket.hint, "참고 자료")
    }

    func testMoveBatchCodableRoundTrip() throws {
        let batch = MoveBatch(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000000bb")!,
            date: Date(timeIntervalSince1970: 1_700_000_000),
            modeLabel: "하위폴더 정리 — Downloads",
            records: [MoveRecord(from: URL(fileURLWithPath: "/a/x.pdf"),
                                 to: URL(fileURLWithPath: "/a/문서/x.pdf"))],
            createdDirs: [URL(fileURLWithPath: "/a/문서")]
        )
        let data = try JSONEncoder().encode(batch)
        let decoded = try JSONDecoder().decode(MoveBatch.self, from: data)
        XCTAssertEqual(decoded, batch)
    }

    func testSubfolderModeRootAndLabel() {
        let root = URL(fileURLWithPath: "/Users/x/Downloads")
        let mode = CleanupMode.subfolder(root: root)
        XCTAssertEqual(mode.root, root)
        XCTAssertTrue(mode.label.contains("Downloads"))
    }
}
