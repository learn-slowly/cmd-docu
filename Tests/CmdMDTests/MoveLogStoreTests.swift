import XCTest
@testable import CmdMD

final class MoveLogStoreTests: XCTestCase {
    private func tempDir() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("log-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private func batch(_ label: String) -> MoveBatch {
        MoveBatch(id: UUID(), date: Date(timeIntervalSince1970: 1), modeLabel: label,
                  records: [MoveRecord(from: URL(fileURLWithPath: "/a/x"), to: URL(fileURLWithPath: "/a/d/x"))],
                  createdDirs: [URL(fileURLWithPath: "/a/d")])
    }

    func testAppendThenLoadRoundTrip() async {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = MoveLogStore(directory: dir)
        let b = batch("배치1")
        await store.append(b)
        let loaded = await store.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first, b)
    }

    func testRemoveById() async {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = MoveLogStore(directory: dir)
        let b1 = batch("b1"); let b2 = batch("b2")
        await store.append(b1); await store.append(b2)
        await store.remove(id: b1.id)
        let loaded = await store.load()
        XCTAssertEqual(loaded.map { $0.id }, [b2.id])
    }

    func testLoadEmptyWhenNoFile() async {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = MoveLogStore(directory: dir)
        let loaded = await store.load()
        XCTAssertTrue(loaded.isEmpty)
    }
}
