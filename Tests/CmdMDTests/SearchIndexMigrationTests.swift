import XCTest
import SQLite3
@testable import CmdMD

final class SearchIndexMigrationTests: XCTestCase {
    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("cmddocu-mig-\(UUID().uuidString)").appendingPathExtension("sqlite")
    }

    /// 구 unicode61 스키마 DB를 만들어두면 SearchIndex init이 감지해 trigram으로 재구성한다.
    func testMigratesOldUnicode61Schema() async {
        let url = tempURL()
        // 구 스키마를 직접 만들고 행 1개 삽입.
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        sqlite3_exec(db, """
        CREATE TABLE files(path TEXT PRIMARY KEY, mtime REAL NOT NULL, ext TEXT, indexedAt REAL);
        CREATE VIRTUAL TABLE docs USING fts5(path UNINDEXED, filename, body, tokenize='unicode61');
        INSERT INTO docs(path, filename, body) VALUES('/old.md','old.md','옛 데이터');
        INSERT INTO files(path, mtime, ext, indexedAt) VALUES('/old.md', 1, 'md', 1);
        """, nil, nil, nil)
        sqlite3_close(db)

        let idx = SearchIndex(dbURL: url)
        let reset = await idx.didResetForSchemaChange
        XCTAssertTrue(reset)                     // 구 스키마 감지 → 재구성
        let count = await idx.count()
        XCTAssertEqual(count, 0)                  // 구 데이터 비워짐(재인덱싱 대상)
        // trigram 활성 확인: 복합어 2글자 부분일치.
        await idx.upsert(path: "/n.md", filename: "n.md", body: "지방선거 결과", mtime: 1, ext: "md")
        let hits = await idx.searchTerms(["선거"], mode: .and)
        XCTAssertEqual(hits.first?.path, "/n.md")
    }

    /// 새 DB(구 스키마 없음)는 재구성 플래그가 서지 않는다.
    func testFreshDbDoesNotResetFlag() async {
        let idx = SearchIndex(dbURL: tempURL())
        let reset = await idx.didResetForSchemaChange
        XCTAssertFalse(reset)
    }
}
