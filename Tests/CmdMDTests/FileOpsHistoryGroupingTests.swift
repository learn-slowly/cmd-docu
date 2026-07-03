import XCTest
@testable import CmdMD

final class FileOpsHistoryGroupingTests: XCTestCase {

    private func entry(_ kind: FileOpKind, _ name: String, batchId: UUID? = nil) -> FileOpEntry {
        FileOpEntry(kind: kind,
                    originalURL: URL(fileURLWithPath: "/tmp/\(name)"),
                    resultURL: URL(fileURLWithPath: "/tmp/dest/\(name)"),
                    batchId: batchId)
    }

    func testSinglesStaySingle() {
        let a = entry(.rename, "a.md")
        let rows = FileOpsHistoryGrouping.rows([a])
        guard case .single(let e) = rows[0] else { return XCTFail() }
        XCTAssertEqual(e.id, a.id)
    }

    func testBatchEntriesCollapseToOneRowAtFirstPosition() {
        let batchId = UUID()
        let single = entry(.trash, "s.md")
        let b1 = entry(.move, "1.md", batchId: batchId)
        let b2 = entry(.move, "2.md", batchId: batchId)
        let rows = FileOpsHistoryGrouping.rows([b1, single, b2])
        XCTAssertEqual(rows.count, 2)
        guard case .batch(let id, let members) = rows[0] else { return XCTFail("배치가 첫 위치") }
        XCTAssertEqual(id, batchId)
        XCTAssertEqual(members.map(\.id), [b1.id, b2.id])
        guard case .single = rows[1] else { return XCTFail() }
    }

    func testDifferentBatchesStaySeparate() {
        let b1 = entry(.move, "1.md", batchId: UUID())
        let b2 = entry(.copy, "2.md", batchId: UUID())
        XCTAssertEqual(FileOpsHistoryGrouping.rows([b1, b2]).count, 2)
    }
}
