import XCTest
@testable import CmdMD

/// 위키 백업 저장소 — 덮어쓰기 직전 본 백업·기록·복원(스펙 §2.4). 볼트 밖(앱 데이터
/// 디렉터리)에만 쓴다.
final class WikiBackupStoreTests: XCTestCase {
    var dataDir: URL!
    var wikiDir: URL!

    override func setUp() {
        super.setUp()
        dataDir = TempDataDirectory.make()
        wikiDir = TempDataDirectory.make()
    }
    override func tearDown() {
        TempDataDirectory.cleanup(dataDir)
        TempDataDirectory.cleanup(wikiDir)
        super.tearDown()
    }

    func testRecordApplySavesBackupAndLog() async throws {
        let store = WikiBackupStore(directory: dataDir)
        let page = wikiDir.appendingPathComponent("주제.md")
        let entry = try await store.recordApply(pageURL: page, oldBody: "# 이전 본문", sourceName: "논문.pdf")

        XCTAssertNotNil(entry.backupFile)
        let backup = dataDir.appendingPathComponent("wiki-backups")
            .appendingPathComponent(entry.backupFile!)
        XCTAssertEqual(try String(contentsOf: backup, encoding: .utf8), "# 이전 본문")

        let entries = await store.allEntries()
        XCTAssertEqual(entries, [entry])
        // 로그 영속 — 새 인스턴스로 다시 읽힌다.
        let reloaded = WikiBackupStore(directory: dataDir)
        let persisted = await reloaded.allEntries()
        XCTAssertEqual(persisted, [entry])
    }

    func testRecordApplyNewPageHasNoBackupFile() async throws {
        let store = WikiBackupStore(directory: dataDir)
        let page = wikiDir.appendingPathComponent("새주제.md")
        let entry = try await store.recordApply(pageURL: page, oldBody: nil, sourceName: "논문.pdf")
        XCTAssertNil(entry.backupFile)
    }

    func testRestoreExistingPageRoundTrip() async throws {
        let store = WikiBackupStore(directory: dataDir)
        let page = wikiDir.appendingPathComponent("주제.md")
        try "# 이전".write(to: page, atomically: true, encoding: .utf8)

        let entry = try await store.recordApply(pageURL: page, oldBody: "# 이전", sourceName: "s.pdf")
        try "# 병합 후".write(to: page, atomically: true, encoding: .utf8)   // 적용 시뮬레이션

        try await store.restore(entry)
        XCTAssertEqual(try String(contentsOf: page, encoding: .utf8), "# 이전")
        // 왕복 안전 — 복원 직전의 "# 병합 후" 본도 자동 백업으로 기록된다.
        let entries = await store.allEntries()
        XCTAssertEqual(entries.count, 2)
    }

    func testRestoreNewPageTrashesFile() async throws {
        let store = WikiBackupStore(directory: dataDir)
        let page = wikiDir.appendingPathComponent("새주제.md")
        let entry = try await store.recordApply(pageURL: page, oldBody: nil, sourceName: "s.pdf")
        try "# 새 페이지".write(to: page, atomically: true, encoding: .utf8)  // 적용 시뮬레이션

        try await store.restore(entry)
        XCTAssertFalse(FileManager.default.fileExists(atPath: page.path))   // 휴지통 이동(삭제 아님)
    }

    func testAllEntriesNewestFirst() async throws {
        let store = WikiBackupStore(directory: dataDir)
        let p1 = wikiDir.appendingPathComponent("a.md")
        let p2 = wikiDir.appendingPathComponent("b.md")
        let e1 = try await store.recordApply(pageURL: p1, oldBody: "1", sourceName: "s1")
        let e2 = try await store.recordApply(pageURL: p2, oldBody: "2", sourceName: "s2")
        let entries = await store.allEntries()
        XCTAssertEqual(entries.map(\.id), [e2.id, e1.id])
    }

    func testRecordApplyThrowsWhenLogUnwritable() async throws {
        let store = WikiBackupStore(directory: dataDir)
        // 로그 파일 자리를 디렉터리로 점유해 쓰기를 결정적으로 실패시킨다.
        try FileManager.default.createDirectory(
            at: dataDir.appendingPathComponent("wiki-ingest-log.json"),
            withIntermediateDirectories: true)
        do {
            _ = try await store.recordApply(pageURL: wikiDir.appendingPathComponent("p.md"),
                                            oldBody: "x", sourceName: "s")
            XCTFail("에러여야 함")
        } catch { }
        let entries = await store.allEntries()
        XCTAssertTrue(entries.isEmpty)   // 실패한 기록은 로그에 남지 않는다
        let backups = try FileManager.default.contentsOfDirectory(
            atPath: dataDir.appendingPathComponent("wiki-backups").path)
        XCTAssertTrue(backups.isEmpty)   // 고아 백업도 남지 않는다
    }
}
