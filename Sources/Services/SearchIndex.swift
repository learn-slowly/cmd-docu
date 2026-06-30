import Foundation
import SQLite3

/// 검색 결과 1건(파일 단위).
struct IndexHit: Equatable {
    let path: String
    let snippet: String
    let isFilenameMatch: Bool
}

/// 사용자 입력을 안전한 FTS5 MATCH 문자열로 바꾼다(구문 깨짐 방지).
enum FTSQuery {
    /// 공백으로 용어를 나누고 각 용어를 "..."로 감싸며 내부 따옴표를 ""로 이스케이프한다.
    /// 마지막 용어에는 접두 검색 *를 붙인다. 빈 입력이면 nil.
    static func sanitize(_ raw: String) -> String? {
        let terms = raw.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).map(String.init)
        guard !terms.isEmpty else { return nil }
        var parts: [String] = []
        for (i, term) in terms.enumerated() {
            let escaped = term.replacingOccurrences(of: "\"", with: "\"\"")
            let quoted = "\"\(escaped)\""
            parts.append(i == terms.count - 1 ? quoted + "*" : quoted)
        }
        return parts.joined(separator: " ")
    }
}

/// SQLite FTS5 영속 인덱스. kordoc/FSEvents와 달리 in-process라 단위테스트 대상.
/// 인덱싱은 읽기 전용 — 원본 파일을 건드리지 않는다.
actor SearchIndex {
    private var db: OpaquePointer?
    private let dbURL: URL

    init(dbURL: URL) {
        self.dbURL = dbURL
        // init은 actor 격리 전이므로 open()을 직접 인라인.
        var dbPtr: OpaquePointer? = nil
        if sqlite3_open(dbURL.path, &dbPtr) != SQLITE_OK {
            // 열기 실패 → SQLite는 에러 시에도 핸들을 반환하므로 먼저 닫고 DB 재생성 시도.
            sqlite3_close(dbPtr)
            dbPtr = nil
            try? FileManager.default.removeItem(at: dbURL)
            sqlite3_open(dbURL.path, &dbPtr)
        }
        db = dbPtr
        let schema = """
        CREATE TABLE IF NOT EXISTS files(
          path TEXT PRIMARY KEY, mtime REAL NOT NULL, ext TEXT, indexedAt REAL
        );
        CREATE VIRTUAL TABLE IF NOT EXISTS docs USING fts5(
          path UNINDEXED, filename, body, tokenize = 'unicode61'
        );
        """
        if sqlite3_exec(db, schema, nil, nil, nil) != SQLITE_OK {
            // 스키마 깨짐 → DB 재생성 후 1회 재시도.
            sqlite3_close(db); db = nil
            try? FileManager.default.removeItem(at: dbURL)
            sqlite3_open(dbURL.path, &db)
            sqlite3_exec(db, schema, nil, nil, nil)
        }
    }

    deinit { sqlite3_close(db) }

    // SQLite 텍스트 바인딩은 SQLITE_TRANSIENT가 필요(스코프 종료 후 복사 보장).
    private let TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private func exec(_ sql: String) {
        sqlite3_exec(db, sql, nil, nil, nil)
    }

    func needsIndex(path: String, mtime: Double) -> Bool {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT mtime FROM files WHERE path = ?;", -1, &stmt, nil) == SQLITE_OK else { return true }
        sqlite3_bind_text(stmt, 1, path, -1, TRANSIENT)
        if sqlite3_step(stmt) == SQLITE_ROW {
            return sqlite3_column_double(stmt, 0) != mtime
        }
        return true
    }

    func upsert(path: String, filename: String, body: String, mtime: Double, ext: String) {
        exec("BEGIN;")
        var del: OpaquePointer?
        if sqlite3_prepare_v2(db, "DELETE FROM docs WHERE path = ?;", -1, &del, nil) == SQLITE_OK {
            sqlite3_bind_text(del, 1, path, -1, TRANSIENT)
            sqlite3_step(del)
        }
        sqlite3_finalize(del)

        var ins: OpaquePointer?
        if sqlite3_prepare_v2(db, "INSERT INTO docs(path, filename, body) VALUES(?, ?, ?);", -1, &ins, nil) == SQLITE_OK {
            sqlite3_bind_text(ins, 1, path, -1, TRANSIENT)
            sqlite3_bind_text(ins, 2, filename, -1, TRANSIENT)
            sqlite3_bind_text(ins, 3, body, -1, TRANSIENT)
            sqlite3_step(ins)
        }
        sqlite3_finalize(ins)

        var meta: OpaquePointer?
        if sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO files(path, mtime, ext, indexedAt) VALUES(?, ?, ?, ?);", -1, &meta, nil) == SQLITE_OK {
            sqlite3_bind_text(meta, 1, path, -1, TRANSIENT)
            sqlite3_bind_double(meta, 2, mtime)
            sqlite3_bind_text(meta, 3, ext, -1, TRANSIENT)
            sqlite3_bind_double(meta, 4, Date().timeIntervalSince1970)
            sqlite3_step(meta)
        }
        sqlite3_finalize(meta)
        exec("COMMIT;")
    }

    func remove(path: String) {
        for sql in ["DELETE FROM docs WHERE path = ?;", "DELETE FROM files WHERE path = ?;"] {
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                sqlite3_bind_text(stmt, 1, path, -1, TRANSIENT)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }
    }

    /// 폴더 하위(접두 일치) 항목을 모두 제거하고 제거 수를 반환한다.
    func removeUnder(folder: String) -> Int {
        let prefix = folder.hasSuffix("/") ? folder : folder + "/"
        let before = count()
        for table in ["docs", "files"] {
            var stmt: OpaquePointer?
            let sql = "DELETE FROM \(table) WHERE path LIKE ? ESCAPE '\\';"
            if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
                let like = prefix.replacingOccurrences(of: "%", with: "\\%")
                    .replacingOccurrences(of: "_", with: "\\_") + "%"
                sqlite3_bind_text(stmt, 1, like, -1, TRANSIENT)
                sqlite3_step(stmt)
            }
            sqlite3_finalize(stmt)
        }
        return before - count()
    }

    func indexedPaths(under folder: String) -> [String] {
        let prefix = folder.hasSuffix("/") ? folder : folder + "/"
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        var out: [String] = []
        let like = prefix.replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_") + "%"
        if sqlite3_prepare_v2(db, "SELECT path FROM files WHERE path LIKE ? ESCAPE '\\';", -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_text(stmt, 1, like, -1, TRANSIENT)
            while sqlite3_step(stmt) == SQLITE_ROW {
                // path가 nil이면 해당 행 건너뜀(안전 읽기).
                if let c = sqlite3_column_text(stmt, 0) { out.append(String(cString: c)) }
            }
        }
        return out
    }

    func search(query: String, limit: Int = 200) -> [IndexHit] {
        guard let match = FTSQuery.sanitize(query) else { return [] }
        // 첫 번째 원문 용어 추출(INSTR 파일명 매칭용 — filename MATCH ?는 SELECT에서 FTS5 미지원).
        let firstTerm = query.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
                             .first.map(String.init) ?? query
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        // body 스니펫(컬럼 인덱스 2). 파일명 매칭 여부는 INSTR로 판정(FTS5 가상테이블 특성상
        // filename MATCH ?를 SELECT 절에 쓰면 prepare 실패 → INSTR 대안 사용).
        let sql = """
        SELECT path, snippet(docs, 2, '[', ']', '…', 10),
               (INSTR(lower(filename), lower(?)) > 0) AS fnameHit
        FROM docs WHERE docs MATCH ? ORDER BY rank LIMIT ?;
        """
        var out: [IndexHit] = []
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        sqlite3_bind_text(stmt, 1, firstTerm, -1, TRANSIENT)
        sqlite3_bind_text(stmt, 2, match, -1, TRANSIENT)
        sqlite3_bind_int(stmt, 3, Int32(limit))
        while sqlite3_step(stmt) == SQLITE_ROW {
            // path가 nil이면 해당 행 건너뜀(안전 읽기).
            guard let pathC = sqlite3_column_text(stmt, 0) else { continue }
            let path = String(cString: pathC)
            let snippet = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            let isFilenameMatch = sqlite3_column_int(stmt, 2) != 0
            out.append(IndexHit(path: path, snippet: snippet, isFilenameMatch: isFilenameMatch))
        }
        return out
    }

    func clear() {
        exec("DELETE FROM docs;")
        exec("DELETE FROM files;")
    }

    func count() -> Int {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM files;", -1, &stmt, nil) == SQLITE_OK else { return 0 }
        return sqlite3_step(stmt) == SQLITE_ROW ? Int(sqlite3_column_int(stmt, 0)) : 0
    }
}
