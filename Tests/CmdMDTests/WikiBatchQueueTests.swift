import XCTest
@testable import CmdMD

/// 다중 문서 인제스트 큐(순수) — 전이·집계·중단(스펙 2026-07-07-wiki-batch-ingest-design §구성).
final class WikiBatchQueueTests: XCTestCase {

    private func urls(_ names: [String]) -> [URL] {
        names.map { URL(fileURLWithPath: "/tmp/batch/\($0)") }
    }

    func testInitStartsAtFirstFile() {
        let q = WikiBatchQueue(files: urls(["a.pdf", "b.pdf", "c.pdf"]))
        XCTAssertEqual(q.current?.lastPathComponent, "a.pdf")
        XCTAssertFalse(q.isDone)
        XCTAssertEqual(q.progressLabel, "(1/3)")
    }

    func testAdvanceMovesThroughOutcomes() {
        var q = WikiBatchQueue(files: urls(["a.pdf", "b.pdf", "c.pdf"]))
        q.advance(with: .applied(URL(fileURLWithPath: "/wiki/references/a.md")))
        XCTAssertEqual(q.current?.lastPathComponent, "b.pdf")
        XCTAssertEqual(q.progressLabel, "(2/3)")
        q.advance(with: .skipped)
        q.advance(with: .failed("타임아웃"))
        XCTAssertTrue(q.isDone)
        XCTAssertNil(q.current)
        XCTAssertEqual(q.appliedCount, 1)
        XCTAssertEqual(q.skippedCount, 1)
        XCTAssertEqual(q.failedCount, 1)
        XCTAssertEqual(q.unprocessedCount, 0)
    }

    func testAppliedPagesListsDestinationsInOrder() {
        var q = WikiBatchQueue(files: urls(["a.pdf", "b.pdf"]))
        let destA = URL(fileURLWithPath: "/wiki/references/a.md")
        let destB = URL(fileURLWithPath: "/wiki/concepts/b.md")
        q.advance(with: .applied(destA))
        q.advance(with: .applied(destB))
        XCTAssertEqual(q.appliedPages, [destA, destB])
    }

    func testAbortLeavesRemainingUnprocessed() {
        var q = WikiBatchQueue(files: urls(["a.pdf", "b.pdf", "c.pdf", "d.pdf"]))
        q.advance(with: .applied(URL(fileURLWithPath: "/wiki/a.md")))
        q.advance(with: .skipped)
        q.abort()
        XCTAssertTrue(q.isDone)
        XCTAssertNil(q.current)
        XCTAssertEqual(q.appliedCount, 1)
        XCTAssertEqual(q.skippedCount, 1)
        XCTAssertEqual(q.failedCount, 0)
        XCTAssertEqual(q.unprocessedCount, 2, "중단하면 남은 항목은 미처리")
    }

    func testAdvancePastEndIsNoOp() {
        var q = WikiBatchQueue(files: urls(["a.pdf"]))
        q.advance(with: .skipped)
        XCTAssertTrue(q.isDone)
        q.advance(with: .skipped)   // 끝 이후 호출은 무동작(크래시·집계 오염 없음)
        XCTAssertEqual(q.skippedCount, 1)
        XCTAssertEqual(q.unprocessedCount, 0)
    }

    func testEmptyQueueIsImmediatelyDone() {
        let q = WikiBatchQueue(files: [])
        XCTAssertTrue(q.isDone)
        XCTAssertNil(q.current)
        XCTAssertEqual(q.progressLabel, "(0/0)")
    }

    func testProgressLabelClampsAtDone() {
        // 끝난 뒤(currentIndex == count)에는 (n/n) — min 클램프가 없으면 (n+1/n)이 된다.
        var q = WikiBatchQueue(files: urls(["a.pdf", "b.pdf"]))
        q.advance(with: .skipped)
        XCTAssertEqual(q.progressLabel, "(2/2)")
        q.advance(with: .skipped)
        XCTAssertTrue(q.isDone)
        XCTAssertEqual(q.progressLabel, "(2/2)", "done 상태는 (n/n)으로 고정")
    }
}
