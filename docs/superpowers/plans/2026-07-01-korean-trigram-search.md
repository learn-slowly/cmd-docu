# 한국어 검색 근본 수정 (FTS5 trigram) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** `SearchIndex`의 FTS5 토크나이저를 trigram으로 바꿔 한국어 부분일치(조사·복합어 양방향)를 지원하고, 2글자 용어는 같은 테이블 `LIKE` 폴백으로 커버한다. Phase 7 키워드검색·Phase 9 RAG 검색이 함께 고쳐진다.

**Architecture:** 순수 빌더 `TrigramQuery`가 용어를 길이로 나눠(≥3글자→trigram `MATCH` 구, ≤2글자→`LIKE` 절) AND/OR SQL 조각을 만든다. `SearchIndex.searchTerms(terms:mode:)`가 이를 실행(MATCH 있으면 BM25 `rank`). 기존 `search(query:)`는 이 위에서 재구성, 구 unicode61 인덱스는 init에서 tokenizer 감지로 자동 재구성하고 AppState가 등록 폴더를 재인덱싱한다.

**Tech Stack:** Swift 5.9+ / SwiftUI, SPM, macOS 14+. 시스템 SQLite3(FTS5 trigram, 기존 `import SQLite3`). 새 패키지 의존성 없음.

## Global Constraints

- 비샌드박스 유지 — `Process` CLI 호출 막히면 안 됨.
- 검색/읽기 전용 — 어떤 파일도 이동·이름변경·삭제하지 않음. 인덱스 재구성은 캐시 DB만.
- 새 패키지 의존성 추가 금지(시스템 SQLite FTS5 trigram은 내장).
- 신규는 별도 파일, 기존은 필요한 만큼만 수정. 코드 주석·커밋 메시지 한국어. '박다/박는다' 류 표현 금지(넣는다/추가한다/좁힌다/회수한다/맡긴다 등).
- Phase 게이트 — 시작·종료 `swift test` 통과(정식 Xcode 필요; CLT는 build만). 현재 307에서 제거(`SearchIndexMatchTests` 2 + `RagQueryExpansion` orMatch 2) + 신규만큼 순증.
- 추정을 사실로 적지 않음 — 이 계획의 SQL 형태는 spike로 실측 확정(아래).
- **영어가 단어→부분일치로 바뀌는 것은 의도된 동작(승인됨).**

**참조 스펙:** `docs/superpowers/specs/2026-07-01-korean-trigram-search-design.md`

**실측 근거(SQLite 3.51.0, 이 앱 링크 libsqlite3):** trigram MATCH는 ≥3글자 부분일치(평가서↔평가서에, 선거↔지방선거), 2글자는 `body LIKE '%…%'`. 한 쿼리에서 `docs MATCH ? AND/OR body LIKE ?` 결합 가능, 순수 MATCH엔 `ORDER BY rank` OK(LIKE 전용엔 rank 없음 → 생략), `snippet(docs,2,…)`는 trigram MATCH에서 정상.

---

## 파일 구조

**생성:**
- `Sources/Services/TrigramQuery.swift` — `SearchMode`, `TrigramQuery.build`(순수).
- 테스트: `TrigramQueryTests`, `SearchIndexMigrationTests`.

**수정:**
- `Sources/Services/SearchIndex.swift` — init(트리그램 토크나이저 + tokenizer 감지 재구성 + `didResetForSchemaChange`), `searchTerms(_:mode:flagFilename:limit:)` 신설, `search(query:)` 재구성, `searchMatch` 제거(Task 3).
- `Sources/Services/RagRetriever.swift` — OR 백스톱을 `searchTerms(.or)`로(Task 3).
- `Sources/Services/RagQueryExpansion.swift` — `orMatch` 제거(Task 3).
- `Sources/App/AppState.swift` — 마이그레이션 후 등록 폴더 재인덱싱 훅(Task 4).
- 테스트: `SearchIndexTests`(trigram 기대값으로 갱신, Task 2), `RagRetrieverTests`(조사 케이스 추가, Task 3), `RagQueryExpansionTests`(orMatch 테스트 제거, Task 3), `SearchIndexMatchTests`(파일 삭제, Task 3).

**단일 실행:** `swift test --filter <ClassName>`. ⚠️ `swift test`는 정식 Xcode 필요.

---

### Task 1: TrigramQuery 빌더 (순수)

**Files:**
- Create: `Sources/Services/TrigramQuery.swift`
- Test: `Tests/CmdMDTests/TrigramQueryTests.swift`

**Interfaces:**
- Produces:
  - `enum SearchMode { case and, or }`
  - `struct TrigramQuery.Built: Equatable { let whereClause: String; let matchArg: String?; let likeArgs: [String]; let hasMatch: Bool }`
  - `static func TrigramQuery.build(terms: [String], mode: SearchMode) -> Built?`

**규칙:** 각 용어 trim. `count >= 3` → trigram MATCH 구(`"…"`, 내부 `"`→`""`), `1~2` → LIKE(`%…%`, `\ % _` 이스케이프 + `ESCAPE '\'`). 빈 용어 무시, 전부 비면 nil. MATCH 구들은 AND면 공백/OR면 ` OR `로 한 문자열. matchClause(`docs MATCH ?`)와 각 likeClause(`body LIKE ? ESCAPE '\'`)를 mode 커넥터로 결합, 절이 2개 이상이면 각 절을 괄호로 감쌈. `hasMatch = matchArg != nil`.

- [ ] **Step 1: 실패하는 테스트 작성**

`Tests/CmdMDTests/TrigramQueryTests.swift`:
```swift
import XCTest
@testable import CmdMD

final class TrigramQueryTests: XCTestCase {
    func testMatchOnlyForLongTerm() {
        let b = TrigramQuery.build(terms: ["평가서"], mode: .and)
        XCTAssertEqual(b?.whereClause, "docs MATCH ?")
        XCTAssertEqual(b?.matchArg, "\"평가서\"")
        XCTAssertEqual(b?.likeArgs, [])
        XCTAssertEqual(b?.hasMatch, true)
    }

    func testLikeOnlyForShortTerm() {
        let b = TrigramQuery.build(terms: ["선거"], mode: .and)
        XCTAssertEqual(b?.whereClause, "body LIKE ? ESCAPE '\\'")
        XCTAssertNil(b?.matchArg)
        XCTAssertEqual(b?.likeArgs, ["%선거%"])
        XCTAssertEqual(b?.hasMatch, false)
    }

    func testMixedAndCombinesWithParens() {
        let b = TrigramQuery.build(terms: ["평가서", "선거"], mode: .and)
        XCTAssertEqual(b?.whereClause, "(docs MATCH ?) AND (body LIKE ? ESCAPE '\\')")
        XCTAssertEqual(b?.matchArg, "\"평가서\"")
        XCTAssertEqual(b?.likeArgs, ["%선거%"])
        XCTAssertEqual(b?.hasMatch, true)
    }

    func testOrModeJoinsMatchPhrasesWithOR() {
        let b = TrigramQuery.build(terms: ["평가서", "지방선거"], mode: .or)
        XCTAssertEqual(b?.whereClause, "docs MATCH ?")
        XCTAssertEqual(b?.matchArg, "\"평가서\" OR \"지방선거\"")
        XCTAssertEqual(b?.hasMatch, true)
    }

    func testMixedOrConnector() {
        let b = TrigramQuery.build(terms: ["평가서", "선거"], mode: .or)
        XCTAssertEqual(b?.whereClause, "(docs MATCH ?) OR (body LIKE ? ESCAPE '\\')")
    }

    func testEscaping() {
        // MATCH 구의 " 는 "" 로, LIKE의 % _ \ 는 이스케이프.
        let m = TrigramQuery.build(terms: ["평가\"서X"], mode: .and)   // 4글자 → MATCH
        XCTAssertEqual(m?.matchArg, "\"평가\"\"서X\"")
        let l = TrigramQuery.build(terms: ["a%"], mode: .and)          // 2글자 → LIKE
        XCTAssertEqual(l?.likeArgs, ["%a\\%%"])
    }

    func testEmptyReturnsNil() {
        XCTAssertNil(TrigramQuery.build(terms: [], mode: .and))
        XCTAssertNil(TrigramQuery.build(terms: ["", "  "], mode: .and))
    }
}
```

- [ ] **Step 2: 테스트 실패 확인**

Run: `swift test --filter TrigramQueryTests`
Expected: FAIL — "cannot find 'TrigramQuery' in scope".

- [ ] **Step 3: 최소 구현**

`Sources/Services/TrigramQuery.swift`:
```swift
import Foundation

/// 검색 용어 결합 방식.
enum SearchMode { case and, or }

/// 용어 목록을 trigram FTS5 검색용 SQL 조각으로 바꾼다(순수).
/// ≥3글자는 trigram MATCH 구(부분일치), ≤2글자는 body LIKE 폴백(trigram MATCH가 3글자 미만 불가).
enum TrigramQuery {
    struct Built: Equatable {
        let whereClause: String     // 예: "(docs MATCH ?) OR (body LIKE ? ESCAPE '\\')"
        let matchArg: String?       // docs MATCH 바인딩(있으면)
        let likeArgs: [String]      // LIKE 바인딩("%term%") — whereClause의 ? 순서(match 다음)
        let hasMatch: Bool          // true면 ORDER BY rank 사용 가능
    }

    static func build(terms: [String], mode: SearchMode) -> Built? {
        var matchPhrases: [String] = []
        var likeArgs: [String] = []
        var likeClauses: [String] = []
        for raw in terms {
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { continue }
            if t.count >= 3 {
                let esc = t.replacingOccurrences(of: "\"", with: "\"\"")
                matchPhrases.append("\"\(esc)\"")
            } else {
                let escLike = t.replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "%", with: "\\%")
                    .replacingOccurrences(of: "_", with: "\\_")
                likeArgs.append("%\(escLike)%")
                likeClauses.append("body LIKE ? ESCAPE '\\'")
            }
        }
        var clauses: [String] = []
        var matchArg: String? = nil
        if !matchPhrases.isEmpty {
            matchArg = (mode == .and)
                ? matchPhrases.joined(separator: " ")
                : matchPhrases.joined(separator: " OR ")
            clauses.append("docs MATCH ?")
        }
        clauses.append(contentsOf: likeClauses)
        guard !clauses.isEmpty else { return nil }
        let connector = (mode == .and) ? " AND " : " OR "
        let whereClause = clauses.count == 1
            ? clauses[0]
            : clauses.map { "(\($0))" }.joined(separator: connector)
        return Built(whereClause: whereClause, matchArg: matchArg, likeArgs: likeArgs, hasMatch: matchArg != nil)
    }
}
```

- [ ] **Step 4: 테스트 통과 확인**

Run: `swift test --filter TrigramQueryTests`
Expected: PASS (7 tests).

- [ ] **Step 5: 커밋**

```bash
git add Sources/Services/TrigramQuery.swift Tests/CmdMDTests/TrigramQueryTests.swift
git commit -m "기능(검색): TrigramQuery 빌더(≥3글자 MATCH구·≤2글자 LIKE·AND/OR) + 테스트"
```

---

### Task 2: SearchIndex — trigram 토크나이저 + 마이그레이션 + searchTerms + search 재구성

**Files:**
- Modify: `Sources/Services/SearchIndex.swift` (init 34–61, search 159–187, `searchMatch`는 이 태스크에선 유지)
- Test: `Tests/CmdMDTests/SearchIndexTests.swift`(갱신), `Tests/CmdMDTests/SearchIndexMigrationTests.swift`(신규)

**Interfaces:**
- Consumes: `TrigramQuery`(Task 1), `SearchMode`, 기존 `IndexHit`.
- Produces:
  - `SearchIndex`의 새 프로퍼티 `private(set) var didResetForSchemaChange: Bool`(actor — 외부는 `await`).
  - `func searchTerms(_ terms: [String], mode: SearchMode, flagFilename: Bool = false, limit: Int = 200) -> [IndexHit]`
  - `search(query:limit:)` 시그니처·반환 불변, 내부만 trigram 기반으로 재구성.

**핵심:** 토크나이저를 바꾸면 기존 `search`(FTSQuery.sanitize의 접두검색)가 trigram에서 깨지므로 **토크나이저 변경 + search 재구성 + searchTerms를 이 한 태스크에서 함께** 랜딩해 테스트를 녹색으로 유지한다.

- [ ] **Step 1: 마이그레이션 실패 테스트 작성**

`Tests/CmdMDTests/SearchIndexMigrationTests.swift`:
```swift
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
```

- [ ] **Step 2: 테스트 실패 확인**

Run: `swift test --filter SearchIndexMigrationTests`
Expected: FAIL — `didResetForSchemaChange`/`searchTerms` 미존재로 컴파일 실패.

- [ ] **Step 3: SearchIndex init 재구성 + 감지**

`Sources/Services/SearchIndex.swift` — `init(dbURL:)`(34–61) 전체를 아래로 교체:
```swift
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
```

- [ ] **Step 4: searchTerms 추가 + search 재구성**

`Sources/Services/SearchIndex.swift` — 기존 `search(query:limit:)`(159–187) 전체를 아래로 교체(같은 위치):
```swift
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
        let snippetExpr = built.hasMatch ? "snippet(docs, 2, '[', ']', '…', 10)" : "''"
        let fnameExpr = flagFilename ? "(INSTR(lower(filename), lower(?)) > 0)" : "0"
        let orderBy = built.hasMatch ? "ORDER BY rank " : ""
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
```
그리고 이제 완전 미사용이 된 `FTSQuery` enum(`Sources/Services/SearchIndex.swift` 11–26행, `sanitize`)을 **삭제**한다(`search`가 더 이상 안 쓰고 다른 소비자 없음 — grep으로 잔존 참조 0 확인). `searchMatch`는 Task 3까지 유지(RagRetriever가 아직 사용).

- [ ] **Step 5: SearchIndexTests를 trigram 기대값으로 갱신**

`Tests/CmdMDTests/SearchIndexTests.swift` — 아래 두 테스트를 교체(나머지 upsert/remove/needsIndex/indexedPaths 테스트는 그대로 통과):

기존 `testSanitizeQuotesTermsAndPrefixesLast`·`testSanitizeEscapesEmbeddedQuotes`(FTSQuery 검증)는 **삭제**(FTSQuery는 더 이상 검색 경로 아님). 기존 `testUpsertThenSearchFindsBodyHitWithSnippet`를 아래로 교체:
```swift
    func testSearchFindsBodyHitWithSnippet() async {
        let idx = SearchIndex(dbURL: tempDBURL())
        await idx.upsert(path: "/d/a.hwp", filename: "a.hwp",
                         body: "정의당 평가서 선거 분석 보고", mtime: 1, ext: "hwp")
        // ≥3글자 → MATCH + 스니펫.
        let hits = await idx.search(query: "평가서")
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.path, "/d/a.hwp")
        XCTAssertTrue(hits.first?.snippet.contains("평가서") ?? false)
        XCTAssertFalse(hits.first?.isFilenameMatch ?? true)
    }

    func testSearchMatchesKoreanParticleAndCompound() async {
        let idx = SearchIndex(dbURL: tempDBURL())
        await idx.upsert(path: "/d/p.md", filename: "p.md", body: "정의당 평가서에 대한 총평", mtime: 1, ext: "md")
        await idx.upsert(path: "/d/c.md", filename: "c.md", body: "지방선거 결과 분석", mtime: 1, ext: "md")
        // 조사: "평가서" → "평가서에" 매치.
        let h1 = await idx.search(query: "평가서")
        XCTAssertEqual(h1.first?.path, "/d/p.md")
        // 복합어(2글자 LIKE): "선거" → "지방선거" 매치.
        let h2 = await idx.search(query: "선거")
        XCTAssertEqual(h2.first?.path, "/d/c.md")
    }
```
그리고 기존 `testFilenameMatchFlagged`는 유지하되 쿼리를 3글자 이상으로(파일명 `budget.md`, 본문 "내용 없음", 쿼리 `budget`) — 이미 `budget`(6글자)이라 그대로 통과.

- [ ] **Step 6: 전체 SearchIndex 테스트 통과 확인**

Run: `swift test --filter SearchIndexTests`
Expected: PASS (갱신된 케이스 포함).

Run: `swift test --filter SearchIndexMigrationTests`
Expected: PASS (2 tests).

Run: `swift test --filter SearchIndexMatchTests`
Expected: PASS (searchMatch 아직 존재, 용어 ≥3글자라 trigram에서 동작).

- [ ] **Step 7: 커밋**

```bash
git add Sources/Services/SearchIndex.swift Tests/CmdMDTests/SearchIndexTests.swift Tests/CmdMDTests/SearchIndexMigrationTests.swift
git commit -m "기능(검색): SearchIndex trigram 토크나이저+마이그레이션 감지+searchTerms, search 재구성(조사·복합어 부분일치)"
```

---

### Task 3: RagRetriever·RagQueryExpansion 전환 + searchMatch/orMatch 제거

**Files:**
- Modify: `Sources/Services/RagRetriever.swift` (topFiles 8–18)
- Modify: `Sources/Services/RagQueryExpansion.swift` (orMatch 35–44 제거)
- Modify: `Sources/Services/SearchIndex.swift` (searchMatch 189–209 제거)
- Delete: `Tests/CmdMDTests/SearchIndexMatchTests.swift`
- Modify: `Tests/CmdMDTests/RagQueryExpansionTests.swift` (orMatch 테스트 2개 제거)
- Modify: `Tests/CmdMDTests/RagRetrieverTests.swift` (조사 케이스 추가)

**Interfaces:**
- Consumes: `SearchIndex.searchTerms(_:mode:)`(Task 2), `SearchIndex.search(query:)`, `RagRetriever.tokens(_:)`.
- Produces: `RagRetriever.topFiles`가 `searchMatch`/`orMatch` 대신 `searchTerms(.or)` 사용. `searchMatch`·`orMatch` 삭제.

- [ ] **Step 1: RagRetrieverTests에 조사 회귀 케이스 추가(실패 확인용은 아님 — 리팩터 후에도 통과해야)**

`Tests/CmdMDTests/RagRetrieverTests.swift`에 추가:
```swift
    func testTopFilesMatchesKoreanParticleSubstring() async {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmddocu-ret3-\(UUID().uuidString)").appendingPathExtension("sqlite")
        let idx = SearchIndex(dbURL: url)
        // 문서엔 조사 붙은 "평가서에". 질의는 bare "평가서"(3글자) → 부분일치로 회수.
        await idx.upsert(path: "/d/p.md", filename: "p.md", body: "정의당 평가서에 총평", mtime: 1, ext: "md")
        let paths = await RagRetriever(index: idx).topFiles(question: "평가서", expandedTerms: [])
        XCTAssertTrue(paths.contains("/d/p.md"))
    }
```

- [ ] **Step 2: 이 상태로 빌드 실패/불일치 확인**

Run: `swift test --filter RagRetrieverTests`
Expected: 현재 코드로는 PASS(아직 리팩터 전이지만 trigram search가 Task 2에서 들어와 "평가서"→"평가서에" 이미 매치). — 이 케이스는 리팩터 후에도 통과하는 **회귀 가드**다. (RED이 아니라 가드 테스트임을 리포트에 명시.)

- [ ] **Step 3: RagRetriever 전환**

`Sources/Services/RagRetriever.swift` — `topFiles`(8–18)를 교체:
```swift
    /// 원질문 히트(우선) + 원질문토큰·확장어 OR 히트(신규 경로만)를 합쳐 파일 경로 top-N.
    func topFiles(question: String, expandedTerms: [String], limit: Int = 8) async -> [String] {
        let primary = await index.search(query: question)
        // 원질문 토큰 + 확장 용어를 OR로 재검색해, 문장 전체 AND(primary)로는 놓치는
        // 문서를 회수한다(대화형 질문·확장 OFF에서도 recall 유지). trigram이라 조사·복합어 부분일치.
        let secondary = await index.searchTerms(Self.tokens(question) + expandedTerms, mode: .or)
        return Self.mergePaths(primary: primary, secondary: secondary, limit: limit)
    }
```

- [ ] **Step 4: orMatch 제거**

`Sources/Services/RagQueryExpansion.swift` — `orMatch(_:)`(35–44)와 그 앞 doc 주석을 삭제(파일 끝 `}` 전까지). `prompt()`·`parse(_:)`만 남긴다.

`Tests/CmdMDTests/RagQueryExpansionTests.swift` — `testOrMatchQuotesAndEscapes`·`testOrMatchEmptyIsNil` 두 메서드 삭제(나머지 parse/prompt 테스트 유지).

- [ ] **Step 5: searchMatch 제거**

`Sources/Services/SearchIndex.swift` — `searchMatch(_:limit:)`(189–209)와 그 앞 doc 주석을 삭제.

`Tests/CmdMDTests/SearchIndexMatchTests.swift` — 파일 삭제:
```bash
git rm Tests/CmdMDTests/SearchIndexMatchTests.swift
```

- [ ] **Step 6: 통과 확인**

Run: `swift test --filter RagRetrieverTests`
Expected: PASS (mergePaths 3 + topFiles 병합 + 무확장회수 + 조사 케이스).

Run: `swift test --filter RagQueryExpansionTests`
Expected: PASS (parse/prompt만).

Run: `swift test`
Expected: 전체 통과(제거분 반영, 신규 포함). 빌드에 `searchMatch`/`orMatch` 참조 잔존 없음.

- [ ] **Step 7: 커밋**

```bash
git add Sources/Services/RagRetriever.swift Sources/Services/RagQueryExpansion.swift Sources/Services/SearchIndex.swift Tests/CmdMDTests/RagRetrieverTests.swift Tests/CmdMDTests/RagQueryExpansionTests.swift
git rm Tests/CmdMDTests/SearchIndexMatchTests.swift
git commit -m "정리(RAG): 검색을 searchTerms(.or)로 전환, raw-MATCH searchMatch·orMatch 제거 + 조사 회귀테스트"
```

---

### Task 4: AppState — 마이그레이션 후 등록 폴더 재인덱싱

**Files:**
- Modify: `Sources/App/AppState.swift` (init 621행 `loadUserData()` 이후, 메서드는 `reindexFolder` 인근)

**Interfaces:**
- Consumes: `SearchIndex.didResetForSchemaChange`(Task 2, `await`), 기존 `reindexFolder(_:)`, `settings.indexedFolders`.
- Produces: 스키마 재구성이 있었으면 등록 폴더를 1회 자동 재인덱싱.

UI/실제 마이그레이션 재인덱싱은 수동 검증. 이 태스크의 관문은 **빌드 통과 + 전체 `swift test` 회귀 없음**.

- [ ] **Step 1: init에 훅 추가**

`Sources/App/AppState.swift` — `init(dataDirectory:)` 안 `loadUserData()`(약 621행) **다음 줄**에 추가:
```swift
        // 검색 인덱스 스키마가 바뀌어 재구성됐으면 등록 폴더를 자동 재인덱싱(1회).
        Task { @MainActor in await self.reindexAfterSchemaMigration() }
```

- [ ] **Step 2: 메서드 추가**

`Sources/App/AppState.swift` — `reindexFolder(_:)`(약 1084행) **앞**에 추가:
```swift
    /// 인덱스 DB가 스키마 변경으로 재구성됐으면 등록된 모든 폴더를 재인덱싱한다.
    @MainActor
    private func reindexAfterSchemaMigration() async {
        guard await searchIndex.didResetForSchemaChange else { return }
        for folder in settings.indexedFolders {
            reindexFolder(folder)
        }
    }
```

- [ ] **Step 3: 빌드 + 전체 테스트**

Run: `swift build`
Expected: 성공.

Run: `swift test`
Expected: 전체 통과(신규 포함, 회귀 0).

- [ ] **Step 4: 수동 스모크(문서화)**

앱 실행 후(불가 환경이면 리포트에 절차만):
1. 기존 등록 폴더가 있는 사용자는 앱 첫 실행 시 인덱스가 재구성되고 자동 재인덱싱(진행률 표시)되는지.
2. "내용 검색 (인덱스)"에서 조사 붙은 단어("평가서")로 검색 → 조사/복합어 포함 문서가 나오는지.
3. "자료에 묻기 (RAG)"에서 조사 붙은 질문이 근거를 회수하는지.

- [ ] **Step 5: 커밋**

```bash
git add Sources/App/AppState.swift
git commit -m "기능(검색): 스키마 마이그레이션 시 등록 폴더 자동 재인덱싱(AppState 훅)"
```

---

## 마무리 (플랜 종료 후)

- [ ] `swift test` 전체 재확인. CLAUDE.md 현재 상태에 한국어 trigram 검색 수정 기록 갱신.
- [ ] main 머지·origin 푸시·옵시디언 데일리 로그.

## Self-Review (작성자 점검)

**Spec 커버리지:** §2.1 스키마/마이그레이션→T2, §2.2 TrigramQuery→T1, §2.3 searchTerms/search/searchMatch제거→T2·T3, §2.4 RagRetriever/orMatch제거→T3, §2.5 AppState 재인덱싱→T4, §4 테스트 전부 매핑.

**플레이스홀더:** 없음 — 전 코드/테스트 실코드. SQL 형태는 spike 실측 확정.

**타입 일관성:** `SearchMode`(.and/.or)·`TrigramQuery.Built{whereClause,matchArg,likeArgs,hasMatch}`·`searchTerms(_:mode:flagFilename:limit:)`·`didResetForSchemaChange`가 T1→T2→T3에서 동일 시그니처로 소비. `searchMatch`/`orMatch`는 T3에서 제거되고 그 유일 소비자(RagRetriever)가 같은 태스크에서 전환되어 참조 잔존 없음. 바인딩 순서(fname→match→like→limit)가 SQL ? 순서와 일치.
