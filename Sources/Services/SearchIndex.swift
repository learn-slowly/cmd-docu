import Foundation
import SQLite3

/// 검색 결과 1건(파일 단위).
struct IndexHit: Equatable {
    let path: String
    let snippet: String
    let isFilenameMatch: Bool
}

/// SQLite FTS5 영속 인덱스. kordoc/FSEvents와 달리 in-process라 단위테스트 대상.
/// 인덱싱은 읽기 전용 — 원본 파일을 건드리지 않는다.
actor SearchIndex {
    private var db: OpaquePointer?
    private let dbURL: URL

    /// init 중 구 스키마를 감지해 재구성했는지(= 등록 폴더 재인덱싱 필요) 표시.
    private(set) var didResetForSchemaChange = false

    init(dbURL: URL) {
        self.dbURL = dbURL
        var dbPtr: OpaquePointer? = nil
        if sqlite3_open(dbURL.path, &dbPtr) != SQLITE_OK {
            sqlite3_close(dbPtr)
            dbPtr = nil
            try? FileManager.default.removeItem(at: dbURL)
            sqlite3_open(dbURL.path, &dbPtr)
        }
        db = dbPtr
        // 기존 docs가 trigram이 아니면(구 unicode61) 재구성 대상 — 비우고 아래에서 trigram으로 재생성.
        if Self.docsTokenizerIsTrigram(db) == false {
            sqlite3_exec(db, "DROP TABLE IF EXISTS docs; DROP TABLE IF EXISTS files;", nil, nil, nil)
            didResetForSchemaChange = true
        }
        let schema = """
        CREATE TABLE IF NOT EXISTS files(
          path TEXT PRIMARY KEY, mtime REAL NOT NULL, ext TEXT, indexedAt REAL
        );
        CREATE VIRTUAL TABLE IF NOT EXISTS docs USING fts5(
          path UNINDEXED, filename, body, tokenize = 'trigram'
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

    /// docs 테이블의 정의를 sqlite_master에서 읽어 trigram 여부를 판정.
    /// 반환: nil(테이블 없음=새 DB) / false(구 tokenizer) / true(이미 trigram).
    private static func docsTokenizerIsTrigram(_ db: OpaquePointer?) -> Bool? {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, "SELECT sql FROM sqlite_master WHERE type='table' AND name='docs';", -1, &stmt, nil) == SQLITE_OK else { return nil }
        guard sqlite3_step(stmt) == SQLITE_ROW, let c = sqlite3_column_text(stmt, 0) else { return nil }
        return String(cString: c).lowercased().contains("trigram")
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
        let terms = query.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).map(String.init)
        return searchTerms(terms, mode: .and, flagFilename: true, limit: limit)
    }

    /// 용어 목록을 trigram MATCH(≥3글자)+LIKE(≤2글자)로 검색한다.
    /// flagFilename이면 첫 용어로 파일명 부분일치(INSTR)를 IndexHit.isFilenameMatch에 표시.
    func searchTerms(_ terms: [String], mode: SearchMode, flagFilename: Bool = false, limit: Int = 200) -> [IndexHit] {
        guard let built = TrigramQuery.build(terms: terms, mode: mode) else { return [] }
        let firstTerm = terms.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                             .first(where: { !$0.isEmpty }) ?? ""
        let snippetExpr = built.directMatch ? "snippet(docs, 2, '[', ']', '…', 10)" : "''"
        let fnameExpr = flagFilename ? "(INSTR(lower(filename), lower(?)) > 0)" : "0"
        let orderBy = built.directMatch ? "ORDER BY rank " : ""
        let sql = "SELECT path, \(snippetExpr), \(fnameExpr) FROM docs WHERE \(built.whereClause) \(orderBy)LIMIT ?;"

        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        // 바인딩 순서 = SQL 텍스트의 ? 등장 순서: [flagFilename 첫용어] → matchArg → likeArgs → limit.
        var i: Int32 = 1
        if flagFilename { sqlite3_bind_text(stmt, i, firstTerm, -1, TRANSIENT); i += 1 }
        if let m = built.matchArg { sqlite3_bind_text(stmt, i, m, -1, TRANSIENT); i += 1 }
        for like in built.likeArgs { sqlite3_bind_text(stmt, i, like, -1, TRANSIENT); i += 1 }
        sqlite3_bind_int(stmt, i, Int32(limit))

        var out: [IndexHit] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
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
