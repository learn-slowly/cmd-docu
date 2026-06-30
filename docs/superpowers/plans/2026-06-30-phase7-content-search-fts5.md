# Phase 7 — 내용 검색(FTS5 영속 인덱스 + 파일 감시) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 등록한 폴더의 본문을 SQLite FTS5에 영속 인덱싱해, 파일명이 아니라 본문으로 키워드 검색(HWP·PDF·오피스·텍스트)하고 결과(파일+스니펫)를 클릭해 열며, FSEvents 파일 감시로 자동 증분 재인덱싱한다.

**Architecture:** macOS 내장만 사용(새 패키지 의존성 없음). 신규 서비스 4개(`SearchIndex` FTS5 래퍼, `ContentExtractor` 본문 추출, `SearchIndexer` 폴더 인덱싱, `FolderWatcher` FSEvents) + `AppSettings.indexedFolders` + `AppState` 배선 + 전용 `IndexSearchView` 시트. 기존 `KordocService.markdown`(office)·PDFKit(pdf)·`loadAndActivateDocument`(열기)·`isListableInFileTree` 재사용.

**Tech Stack:** Swift 5.9+ / SwiftUI / SPM, macOS 14+, `import SQLite3`(FTS5, 시스템 내장), CoreServices `FSEvents`, PDFKit, XCTest.

## Global Constraints

- 비샌드박스 유지. macOS 내장만 사용 — `Package.swift`에 새 의존성 추가 금지(`import SQLite3`·`import CoreServices`는 SDK 제공, 검증됨).
- 인덱싱은 **읽기 전용** — 원본 파일을 절대 변경·이동·삭제하지 않는다. 인덱스/등록 해제는 DB만 건드린다.
- kordoc 미설치/실패 시 그 파일만 본문 없이 처리하고 전체 인덱싱은 계속(크래시 금지).
- 코드 주석·커밋 메시지는 한국어. '박다/박는다/박았다' 류 표현 금지(대안: 넣는다/적는다/채운다/추가한다/적재한다 등).
- 신규 기능은 별도 파일로 분리. 설정 영속은 `appState.saveUserData()`(settings.json 포함).
- Process(kordoc)·시스템 콜백(FSEvents)·UI는 단위테스트하지 않는다. SQLite는 in-process라 단위테스트한다(임시 DB). 기존 154개 테스트가 깨지지 않아야 한다.
- 커밋 메시지 말미에 다음 두 줄을 넣는다:
  `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`
  `Claude-Session: https://claude.ai/code/session_01S2QuZUALidkTNRswXFL6xM`

### 검증된 사실(코드 확인 완료)
- `import SQLite3`는 SPM 패키지 빌드·링크 OK(Package.swift 변경 불필요). FTS5 가상테이블·`snippet()`·한글 매칭 동작(SQLite 3.51.0).
- FSEvents Swift 브리징(`FSEventStreamCreate`+`Unmanaged` info+`kFSEventStreamCreateFlagFileEvents`) 컴파일·동작 OK.

### 기존 자산 앵커(`Sources/App/AppState.swift`)
- `private let kordocService = KordocService()` (line ~110).
- AppSupport 경로 패턴(line ~546): `FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("CmdMD")`.
- `private func loadAndActivateDocument(at url: URL, inNewTab: Bool) async` (line ~701).
- `static func isListableInFileTree(_ url: URL) -> Bool` (line ~949).
- `AppSettings`(`Sources/Models/Settings.swift`)는 커스텀 `init(from:)`(line ~39~)에서 `c.decodeIfPresent(...) ?? d.field` 패턴 사용. 신규 필드는 저장 프로퍼티 + 그 디코드 라인 1줄 추가(예: paraFolders line ~149). CodingKeys·encode는 합성됨.
- 커맨드 팔레트 `Command(...)` 엔트리(`Sources/Views/CommandPaletteView.swift` line ~221+, 예 `appState.showOmnisearch = true` line ~258).
- `AppShortcut`(`Sources/Models/Shortcuts.swift` line ~70, `case askClaude` 등) + `defaultBinding`.

---

### Task 1: SearchIndex (SQLite FTS5 래퍼) + FTSQuery 새니타이즈

**Files:**
- Create: `Sources/Services/SearchIndex.swift`
- Test: `Tests/CmdMDTests/SearchIndexTests.swift`

**Interfaces:**
- Produces:
  - `struct IndexHit: Equatable { let path: String; let snippet: String; let isFilenameMatch: Bool }`
  - `enum FTSQuery { static func sanitize(_ raw: String) -> String? }`
  - `actor SearchIndex` with: `init(dbURL: URL)`, `func upsert(path: String, filename: String, body: String, mtime: Double, ext: String)`, `func needsIndex(path: String, mtime: Double) -> Bool`, `func remove(path: String)`, `func removeUnder(folder: String) -> Int`, `func search(query: String, limit: Int = 200) -> [IndexHit]`, `func indexedPaths(under folder: String) -> [String]`, `func clear()`, `func count() -> Int`

- [ ] **Step 1: 실패하는 테스트 작성**

`Tests/CmdMDTests/SearchIndexTests.swift`:
```swift
import XCTest
@testable import CmdMD

final class SearchIndexTests: XCTestCase {
    private func tempDBURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("cmddocu-idx-\(UUID().uuidString)")
            .appendingPathExtension("sqlite")
    }

    func testSanitizeQuotesTermsAndPrefixesLast() {
        XCTAssertEqual(FTSQuery.sanitize("선거 분석"), "\"선거\" \"분석\"*")
        XCTAssertEqual(FTSQuery.sanitize("hello"), "\"hello\"*")
        XCTAssertNil(FTSQuery.sanitize("   "))
    }

    func testSanitizeEscapesEmbeddedQuotes() {
        // FTS5에서 따옴표는 ""로 이스케이프해야 구문 깨짐을 막는다.
        XCTAssertEqual(FTSQuery.sanitize("a\"b"), "\"a\"\"b\"*")
    }

    func testUpsertThenSearchFindsBodyHitWithSnippet() async {
        let idx = SearchIndex(dbURL: tempDBURL())
        await idx.upsert(path: "/d/a.hwp", filename: "a.hwp",
                         body: "정의당 평가서 선거 분석 보고", mtime: 1, ext: "hwp")
        let hits = await idx.search(query: "선거")
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.path, "/d/a.hwp")
        XCTAssertTrue(hits.first?.snippet.contains("선거") ?? false)
        XCTAssertFalse(hits.first?.isFilenameMatch ?? true)
    }

    func testFilenameMatchFlagged() async {
        let idx = SearchIndex(dbURL: tempDBURL())
        await idx.upsert(path: "/d/budget.md", filename: "budget.md",
                         body: "내용 없음", mtime: 1, ext: "md")
        let hits = await idx.search(query: "budget")
        XCTAssertEqual(hits.first?.path, "/d/budget.md")
        XCTAssertTrue(hits.first?.isFilenameMatch ?? false)
    }

    func testNeedsIndexTracksMtime() async {
        let idx = SearchIndex(dbURL: tempDBURL())
        XCTAssertTrue(await idx.needsIndex(path: "/d/a.md", mtime: 10))   // 미인덱스
        await idx.upsert(path: "/d/a.md", filename: "a.md", body: "x", mtime: 10, ext: "md")
        XCTAssertFalse(await idx.needsIndex(path: "/d/a.md", mtime: 10))  // 동일 mtime
        XCTAssertTrue(await idx.needsIndex(path: "/d/a.md", mtime: 20))   // 변경됨
    }

    func testRemoveAndRemoveUnder() async {
        let idx = SearchIndex(dbURL: tempDBURL())
        await idx.upsert(path: "/d/x.md", filename: "x.md", body: "사과", mtime: 1, ext: "md")
        await idx.upsert(path: "/d/sub/y.md", filename: "y.md", body: "사과", mtime: 1, ext: "md")
        await idx.upsert(path: "/other/z.md", filename: "z.md", body: "사과", mtime: 1, ext: "md")
        XCTAssertEqual(await idx.count(), 3)
        await idx.remove(path: "/d/x.md")
        XCTAssertEqual(await idx.count(), 2)
        let removed = await idx.removeUnder(folder: "/d")
        XCTAssertEqual(removed, 1)                 // /d/sub/y.md
        XCTAssertEqual(await idx.count(), 1)        // /other/z.md 만 남음
        XCTAssertEqual(await idx.search(query: "사과").first?.path, "/other/z.md")
    }

    func testIndexedPathsUnder() async {
        let idx = SearchIndex(dbURL: tempDBURL())
        await idx.upsert(path: "/d/a.md", filename: "a.md", body: "x", mtime: 1, ext: "md")
        await idx.upsert(path: "/d/b.md", filename: "b.md", body: "x", mtime: 1, ext: "md")
        await idx.upsert(path: "/e/c.md", filename: "c.md", body: "x", mtime: 1, ext: "md")
        let under = await idx.indexedPaths(under: "/d").sorted()
        XCTAssertEqual(under, ["/d/a.md", "/d/b.md"])
    }
}
```

- [ ] **Step 2: 테스트 실패 확인**

Run: `swift test --filter SearchIndexTests`
Expected: 컴파일 실패("cannot find 'SearchIndex'").

- [ ] **Step 3: 구현**

`Sources/Services/SearchIndex.swift`:
```swift
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
        open()
    }

    private func open() {
        if sqlite3_open(dbURL.path, &db) != SQLITE_OK {
            // 열기 실패 → DB 재생성 시도.
            try? FileManager.default.removeItem(at: dbURL)
            sqlite3_open(dbURL.path, &db)
        }
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
                out.append(String(cString: sqlite3_column_text(stmt, 0)))
            }
        }
        return out
    }

    func search(query: String, limit: Int = 200) -> [IndexHit] {
        guard let match = FTSQuery.sanitize(query) else { return [] }
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        // body 스니펫(컬럼 인덱스 2). filename 매칭 여부는 filename:<term> 별도 판정.
        let sql = """
        SELECT path, snippet(docs, 2, '[', ']', '…', 10),
               (filename MATCH ?) AS fnameHit
        FROM docs WHERE docs MATCH ? ORDER BY rank LIMIT ?;
        """
        var out: [IndexHit] = []
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        sqlite3_bind_text(stmt, 1, match, -1, TRANSIENT)
        sqlite3_bind_text(stmt, 2, match, -1, TRANSIENT)
        sqlite3_bind_int(stmt, 3, Int32(limit))
        while sqlite3_step(stmt) == SQLITE_ROW {
            let path = String(cString: sqlite3_column_text(stmt, 0))
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
```

> 주의: `filename MATCH ?`는 `docs MATCH ?`와 함께 쓰면 같은 행에서 filename 컬럼 매칭 여부를 준다. 만약 `filename MATCH`가 별도 가상테이블 제약으로 동작하지 않으면, 대안으로 `INSTR(lower(filename), lower(첫 용어)) > 0`로 판정한다 — 그러나 1차 구현은 위 형태로 두고 테스트(`testFilenameMatchFlagged`)로 검증한다. 테스트가 실패하면 그 때 INSTR 방식으로 바꾼다.

- [ ] **Step 4: 테스트 통과 확인**

Run: `swift test --filter SearchIndexTests`
Expected: PASS (7 tests). 만약 `testFilenameMatchFlagged`만 실패하면 위 주석대로 `fnameHit`를 `(INSTR(lower(filename), lower(?)) > 0)`로 바꾸고(바인딩은 첫 용어 원문) 재실행해 통과시킨다.

- [ ] **Step 5: 빌드 확인(SQLite 링크)**

Run: `swift build`
Expected: 빌드 성공(`import SQLite3` 링크 OK).

- [ ] **Step 6: 커밋**

```bash
git add Sources/Services/SearchIndex.swift Tests/CmdMDTests/SearchIndexTests.swift
git commit -m "기능(검색): SearchIndex(FTS5 영속 인덱스)·FTSQuery 새니타이즈 추가

import SQLite3로 upsert/search/snippet/needsIndex/remove/removeUnder. 인덱싱 읽기전용.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01S2QuZUALidkTNRswXFL6xM"
```

---

### Task 2: ContentExtractor (본문 추출)

**Files:**
- Create: `Sources/Services/ContentExtractor.swift`
- Test: `Tests/CmdMDTests/ContentExtractorTests.swift`

**Interfaces:**
- Consumes: `KordocService`(기존), `DocumentKind`(기존)
- Produces:
  - `enum ContentExtractor { static func localBody(for url: URL) -> String?; static func body(for url: URL, kordoc: KordocService) async -> String? }`

- [ ] **Step 1: 실패하는 테스트 작성**

`Tests/CmdMDTests/ContentExtractorTests.swift`:
```swift
import XCTest
import PDFKit
@testable import CmdMD

final class ContentExtractorTests: XCTestCase {
    private func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("cmddocu-ext-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func testLocalBodyReadsTextFile() throws {
        let dir = tempDir()
        let url = dir.appendingPathComponent("note.md")
        try "제목\n본문 내용".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(ContentExtractor.localBody(for: url), "제목\n본문 내용")
    }

    func testLocalBodyTxtAndMarkdown() throws {
        let dir = tempDir()
        let txt = dir.appendingPathComponent("a.txt")
        try "hello".write(to: txt, atomically: true, encoding: .utf8)
        XCTAssertEqual(ContentExtractor.localBody(for: txt), "hello")
    }

    func testLocalBodyExtractsPDFText() throws {
        let dir = tempDir()
        let url = dir.appendingPathComponent("doc.pdf")
        // PDFKit로 텍스트 한 줄짜리 PDF를 만든다.
        let pdf = PDFDocument()
        let page = PDFPage(image: NSImage(size: NSSize(width: 10, height: 10)))!
        pdf.insert(page, at: 0)
        pdf.write(to: url)
        // 빈 이미지 페이지는 텍스트가 없을 수 있으므로, 텍스트가 nil이 아님만 보장하지 말고
        // localBody가 크래시 없이 String? 반환함을 확인한다(빈/실내용 모두 허용).
        _ = ContentExtractor.localBody(for: url)   // 크래시 없음
        XCTAssertEqual(ContentExtractor.localBody(for: dir.appendingPathComponent("none.pdf")), nil) // 없는 파일
    }

    func testLocalBodyUnsupportedReturnsNil() throws {
        let dir = tempDir()
        let img = dir.appendingPathComponent("p.png")
        try Data([0x89, 0x50]).write(to: img)
        XCTAssertNil(ContentExtractor.localBody(for: img))   // 이미지: 본문 없음
    }
}
```

- [ ] **Step 2: 테스트 실패 확인**

Run: `swift test --filter ContentExtractorTests`
Expected: 컴파일 실패("cannot find 'ContentExtractor'").

- [ ] **Step 3: 구현**

`Sources/Services/ContentExtractor.swift`:
```swift
import Foundation
import PDFKit

/// 파일 URL → 인덱싱 본문. 없으면 nil(파일명만 인덱싱).
/// office는 kordoc(Process) 비동기 추출, 그 외(text/pdf)는 동기 로컬 추출.
enum ContentExtractor {
    private static let textExtensions: Set<String> = ["md", "markdown", "txt"]

    /// kordoc 없이 즉시 추출 가능한 종류(text/pdf)만. 미지원/없는 파일은 nil.
    static func localBody(for url: URL) -> String? {
        let ext = url.pathExtension.lowercased()
        if textExtensions.contains(ext) {
            return try? String(contentsOf: url, encoding: .utf8)
        }
        if DocumentKind.pdfExtensions.contains(ext) {
            guard let pdf = PDFDocument(url: url) else { return nil }
            var parts: [String] = []
            for i in 0..<pdf.pageCount {
                if let s = pdf.page(at: i)?.string { parts.append(s) }
            }
            return parts.isEmpty ? nil : parts.joined(separator: "\n")
        }
        return nil
    }

    /// 종류별 본문. office면 kordoc 분기, 그 외는 localBody.
    static func body(for url: URL, kordoc: KordocService) async -> String? {
        let ext = url.pathExtension.lowercased()
        if DocumentKind.officeExtensions.contains(ext) {
            return try? await kordoc.markdown(for: url)
        }
        return localBody(for: url)
    }
}
```

- [ ] **Step 4: 테스트 통과 확인**

Run: `swift test --filter ContentExtractorTests`
Expected: PASS (4 tests).

- [ ] **Step 5: 커밋**

```bash
git add Sources/Services/ContentExtractor.swift Tests/CmdMDTests/ContentExtractorTests.swift
git commit -m "기능(검색): ContentExtractor(text/pdf 로컬·office는 kordoc) 추가

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01S2QuZUALidkTNRswXFL6xM"
```

---

### Task 3: SearchIndexer (폴더 인덱싱 오케스트레이션)

**Files:**
- Create: `Sources/Services/SearchIndexer.swift`
- Test: `Tests/CmdMDTests/SearchIndexerTests.swift`

**Interfaces:**
- Consumes: `SearchIndex`(Task 1), `ContentExtractor`(Task 2), `KordocService`(기존), `AppState.isListableInFileTree`(기존 static)
- Produces:
  - `actor SearchIndexer` with `init(index: SearchIndex, kordoc: KordocService)`, `func indexFolder(_ folder: URL, progress: ((Int, Int) -> Void)?) async`, `func reindex(path: String) async`

- [ ] **Step 1: 실패하는 테스트 작성**

`Tests/CmdMDTests/SearchIndexerTests.swift`:
```swift
import XCTest
@testable import CmdMD

final class SearchIndexerTests: XCTestCase {
    private func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("cmddocu-idxr-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    private func tempDBURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("cmddocu-idxr-\(UUID().uuidString).sqlite")
    }

    func testIndexFolderIndexesTextFilesAndSearches() async throws {
        let dir = tempDir()
        try "사과 바나나".write(to: dir.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
        try "포도 수박".write(to: dir.appendingPathComponent("b.txt"), atomically: true, encoding: .utf8)
        let index = SearchIndex(dbURL: tempDBURL())
        let indexer = SearchIndexer(index: index, kordoc: KordocService())
        await indexer.indexFolder(dir, progress: nil)
        XCTAssertEqual(await index.count(), 2)
        XCTAssertEqual(await index.search(query: "바나나").first?.path,
                       dir.appendingPathComponent("a.md").path)
    }

    func testIndexFolderRemovesDeletedFiles() async throws {
        let dir = tempDir()
        let a = dir.appendingPathComponent("a.md")
        try "사과".write(to: a, atomically: true, encoding: .utf8)
        let index = SearchIndex(dbURL: tempDBURL())
        let indexer = SearchIndexer(index: index, kordoc: KordocService())
        await indexer.indexFolder(dir, progress: nil)
        XCTAssertEqual(await index.count(), 1)
        try FileManager.default.removeItem(at: a)        // 파일 삭제
        await indexer.indexFolder(dir, progress: nil)    // 재인덱싱 → 사라진 파일 제거
        XCTAssertEqual(await index.count(), 0)
    }

    func testReindexSingleFileAndDeletion() async throws {
        let dir = tempDir()
        let a = dir.appendingPathComponent("a.md")
        try "사과".write(to: a, atomically: true, encoding: .utf8)
        let index = SearchIndex(dbURL: tempDBURL())
        let indexer = SearchIndexer(index: index, kordoc: KordocService())
        await indexer.reindex(path: a.path)
        XCTAssertEqual(await index.count(), 1)
        try FileManager.default.removeItem(at: a)
        await indexer.reindex(path: a.path)              // 삭제된 파일 → remove
        XCTAssertEqual(await index.count(), 0)
    }
}
```

- [ ] **Step 2: 테스트 실패 확인**

Run: `swift test --filter SearchIndexerTests`
Expected: 컴파일 실패("cannot find 'SearchIndexer'").

- [ ] **Step 3: 구현**

`Sources/Services/SearchIndexer.swift`:
```swift
import Foundation

/// 폴더를 워킹하며 변경분만 (재)인덱싱하고 사라진 파일을 인덱스에서 제거한다.
/// 인덱싱은 읽기 전용 — 원본 파일을 건드리지 않는다.
actor SearchIndexer {
    private let index: SearchIndex
    private let kordoc: KordocService

    init(index: SearchIndex, kordoc: KordocService) {
        self.index = index
        self.kordoc = kordoc
    }

    func indexFolder(_ folder: URL, progress: ((Int, Int) -> Void)?) async {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: folder,
                                     includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                                     options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return }
        let urls = en.allObjects.compactMap { $0 as? URL }.filter { AppState.isListableInFileTree($0) }
        let total = urls.count
        var done = 0
        var seen = Set<String>()
        for url in urls {
            seen.insert(url.path)
            let mtime = ((try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? Date()).timeIntervalSince1970
            if await index.needsIndex(path: url.path, mtime: mtime) {
                let body = await ContentExtractor.body(for: url, kordoc: kordoc) ?? ""
                await index.upsert(path: url.path, filename: url.lastPathComponent,
                                   body: body, mtime: mtime, ext: url.pathExtension.lowercased())
            }
            done += 1
            progress?(done, total)
        }
        // 인덱스에는 있으나 디스크에서 사라진 파일 제거.
        for indexed in await index.indexedPaths(under: folder.path) where !seen.contains(indexed) {
            await index.remove(path: indexed)
        }
    }

    /// 단일 경로 (재)인덱싱. 파일이 없으면 인덱스에서 제거.
    func reindex(path: String) async {
        let url = URL(fileURLWithPath: path)
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue,
              AppState.isListableInFileTree(url) else {
            await index.remove(path: path)
            return
        }
        let mtime = ((try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? Date()).timeIntervalSince1970
        guard await index.needsIndex(path: path, mtime: mtime) else { return }
        let body = await ContentExtractor.body(for: url, kordoc: kordoc) ?? ""
        await index.upsert(path: path, filename: url.lastPathComponent,
                           body: body, mtime: mtime, ext: url.pathExtension.lowercased())
    }
}
```

- [ ] **Step 4: 테스트 통과 확인**

Run: `swift test --filter SearchIndexerTests`
Expected: PASS (3 tests).

- [ ] **Step 5: 커밋**

```bash
git add Sources/Services/SearchIndexer.swift Tests/CmdMDTests/SearchIndexerTests.swift
git commit -m "기능(검색): SearchIndexer(폴더 워킹·mtime 스킵·삭제 제거) 추가

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01S2QuZUALidkTNRswXFL6xM"
```

---

### Task 4: FolderWatcher (FSEvents 파일 감시)

**Files:**
- Create: `Sources/Services/FolderWatcher.swift`
- Test: 없음(FSEvents 시스템 콜백; `swift build` + 회귀만)

**Interfaces:**
- Produces:
  - `final class FolderWatcher { var onChangedPaths: (([String]) -> Void)?; func start(folders: [String]); func stop() }`

- [ ] **Step 1: 구현**

`Sources/Services/FolderWatcher.swift`:
```swift
import Foundation
import CoreServices

/// FSEvents로 등록 폴더들을 감시한다. 변경 경로 배치를 onChangedPaths로 전달.
/// 0.5s 디바운스, 파일 단위 이벤트. 시스템 콜백이라 단위테스트 제외(수동 검증).
final class FolderWatcher {
    var onChangedPaths: (([String]) -> Void)?

    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "work.cmdspace.cmddocu.folderwatcher")

    func start(folders: [String]) {
        stop()
        guard !folders.isEmpty else { return }
        let info = Unmanaged.passUnretained(self).toOpaque()
        var ctx = FSEventStreamContext(version: 0, info: info, retain: nil, release: nil, copyDescription: nil)
        let cb: FSEventStreamCallback = { _, clientInfo, numEvents, eventPaths, _, _ in
            guard let clientInfo else { return }
            let watcher = Unmanaged<FolderWatcher>.fromOpaque(clientInfo).takeUnretainedValue()
            let paths = Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue() as! [String]
            watcher.onChangedPaths?(Array(paths.prefix(numEvents)))
        }
        let created = FSEventStreamCreate(
            kCFAllocatorDefault, cb, &ctx, folders as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.5,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer))
        guard let created else { return }
        stream = created
        FSEventStreamSetDispatchQueue(created, queue)
        FSEventStreamStart(created)
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit { stop() }
}
```

- [ ] **Step 2: 빌드 확인**

Run: `swift build`
Expected: 빌드 성공.
Run: `swift test`
Expected: 기존 + Task1-3 신규 모두 PASS(FolderWatcher는 단위테스트 없음).

- [ ] **Step 3: 커밋**

```bash
git add Sources/Services/FolderWatcher.swift
git commit -m "기능(검색): FolderWatcher(FSEvents 파일 감시) 추가

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01S2QuZUALidkTNRswXFL6xM"
```

---

### Task 5: AppSettings.indexedFolders 영속

**Files:**
- Modify: `Sources/Models/Settings.swift` (`struct AppSettings`: 저장 프로퍼티 + `init(from:)` 디코드 라인)
- Test: `Tests/CmdMDTests/IndexedFoldersSettingsTests.swift`

**Interfaces:**
- Produces: `AppSettings.indexedFolders: [String]`

- [ ] **Step 1: 실패하는 테스트 작성**

`Tests/CmdMDTests/IndexedFoldersSettingsTests.swift`:
```swift
import XCTest
@testable import CmdMD

final class IndexedFoldersSettingsTests: XCTestCase {
    func testDefaultsEmptyWhenAbsent() throws {
        let json = #"{"fontSize":14}"#.data(using: .utf8)!
        let s = try JSONDecoder().decode(AppSettings.self, from: json)
        XCTAssertEqual(s.indexedFolders, [])
    }

    func testRoundTripsIndexedFolders() throws {
        var s = AppSettings()
        s.indexedFolders = ["/Users/x/Docs", "/Users/x/HWP"]
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertEqual(back.indexedFolders, ["/Users/x/Docs", "/Users/x/HWP"])
    }
}
```

- [ ] **Step 2: 테스트 실패 확인**

Run: `swift test --filter IndexedFoldersSettingsTests`
Expected: 컴파일 실패("value of type 'AppSettings' has no member 'indexedFolders'").

- [ ] **Step 3: 구현**

`Sources/Models/Settings.swift`의 `struct AppSettings`에 저장 프로퍼티 추가(다른 영속 필드 근처, 예 `paraFolders` 선언 옆):
```swift
    var indexedFolders: [String] = []   // 내용 검색 인덱스 등록 폴더(절대 경로)
```
그리고 커스텀 `init(from:)`의 다른 `decodeIfPresent` 라인들과 같은 곳(예 `paraFolders =` 디코드 라인 ~149 근처)에 추가:
```swift
        indexedFolders = try c.decodeIfPresent([String].self, forKey: .indexedFolders) ?? d.indexedFolders
```
(CodingKeys·encode는 합성되므로 별도 수정 불필요. `d`는 같은 init 안의 기본 인스턴스.)

- [ ] **Step 4: 테스트 통과 확인**

Run: `swift test --filter IndexedFoldersSettingsTests`
Expected: PASS (2 tests).

- [ ] **Step 5: 커밋**

```bash
git add Sources/Models/Settings.swift Tests/CmdMDTests/IndexedFoldersSettingsTests.swift
git commit -m "기능(검색): AppSettings.indexedFolders(등록 폴더 영속) 추가

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01S2QuZUALidkTNRswXFL6xM"
```

---

### Task 6: AppState 배선 (인스턴스·상태·등록/검색/감시)

**Files:**
- Modify: `Sources/App/AppState.swift`
- Test: `Tests/CmdMDTests/AppIndexSearchTests.swift`

**Interfaces:**
- Consumes: `SearchIndex`/`SearchIndexer`(Task 1·3), `FolderWatcher`(Task 4), `ContentExtractor`(Task 2), `IndexHit`(Task 1), `AppSettings.indexedFolders`(Task 5), 기존 `kordocService`/`loadAndActivateDocument`/AppSupport 경로
- Produces:
  - `var AppState.showIndexSearch: Bool`, `var indexSearchText: String`, `var indexSearchResults: [IndexHit]`, `var indexInProgress: Bool`, `var indexProgress: (done: Int, total: Int)?`
  - `static func AppState.normalizedIndexFolders(_ existing: [String], adding: String) -> [String]` (순수: 중복·중첩 정규화)
  - `func AppState.registerIndexFolder(_ url: URL)`, `func unregisterIndexFolder(_ path: String)`, `func reindexFolder(_ path: String)`, `func runIndexSearch(query: String) async`, `func openIndexHit(_ hit: IndexHit)`, `func startFolderWatching()`

- [ ] **Step 1: 실패하는 테스트 작성(순수 정규화 + 상태)**

`Tests/CmdMDTests/AppIndexSearchTests.swift`:
```swift
import XCTest
@testable import CmdMD

final class AppIndexSearchTests: XCTestCase {
    func testNormalizedDropsDuplicate() {
        let out = AppState.normalizedIndexFolders(["/a", "/b"], adding: "/a")
        XCTAssertEqual(out, ["/a", "/b"])
    }

    func testNormalizedDropsChildOfExisting() {
        // 이미 /a가 등록돼 있으면 그 하위 /a/sub는 추가하지 않는다(중복 인덱싱 방지).
        let out = AppState.normalizedIndexFolders(["/a"], adding: "/a/sub")
        XCTAssertEqual(out, ["/a"])
    }

    func testNormalizedReplacesParentWhenAddingAncestor() {
        // 새로 추가하는 /a가 기존 /a/sub의 상위면, 하위를 흡수해 /a만 남긴다.
        let out = AppState.normalizedIndexFolders(["/a/sub", "/b"], adding: "/a")
        XCTAssertEqual(Set(out), Set(["/a", "/b"]))
    }

    func testNormalizedAppendsUnrelated() {
        let out = AppState.normalizedIndexFolders(["/a"], adding: "/b")
        XCTAssertEqual(out, ["/a", "/b"])
    }

    @MainActor
    func testIndexSearchStateDefaults() {
        let app = AppState()
        XCTAssertFalse(app.showIndexSearch)
        XCTAssertTrue(app.indexSearchResults.isEmpty)
        XCTAssertFalse(app.indexInProgress)
    }
}
```

- [ ] **Step 2: 테스트 실패 확인**

Run: `swift test --filter AppIndexSearchTests`
Expected: 컴파일 실패("cannot find 'normalizedIndexFolders'" 등).

- [ ] **Step 3: 인스턴스·상태 추가**

`Sources/App/AppState.swift`의 서비스 인스턴스 근처(`private let kordocService = KordocService()` line ~110 아래)에 추가:
```swift
    private let searchIndex: SearchIndex
    private let searchIndexer: SearchIndexer
    private let folderWatcher = FolderWatcher()
```
기존 `init()`(AppState.swift line 542)은 이미 AppSupport 디렉터리를 만든다(line ~546-547: `appSupport`/`appDir`). 그 `appDir`를 **재사용**해, init 본문에서 `loadUserData()` 호출(line ~556) **이전에** 두 인스턴스를 대입한다(stored `let`은 init에서 1회 대입):
```swift
        // (기존 line 546-547에서 만든 appDir 재사용)
        let idx = SearchIndex(dbURL: appDir.appendingPathComponent("searchindex.sqlite"))
        self.searchIndex = idx
        self.searchIndexer = SearchIndexer(index: idx, kordoc: kordocService)
```
> `kordocService`는 `private let kordocService = KordocService()` 기본값이라 init 진입 시 이미 초기화돼 있어 참조 가능. `searchIndex`/`searchIndexer`는 기본값 없는 `let`이므로 반드시 init에서 대입한다. 기존 `init()`이 `appDir`를 만드는 위치 바로 뒤에 위 세 줄을 넣는다. (만약 `appDir` 변수명이 다르면 그 변수를 쓰고, 없으면 line 546 패턴으로 한 줄 계산해 쓴다.)

상태 프로퍼티 추가(다른 UI 상태 근처):
```swift
    var showIndexSearch: Bool = false
    var indexSearchText: String = ""
    var indexSearchResults: [IndexHit] = []
    var indexInProgress: Bool = false
    var indexProgress: (done: Int, total: Int)? = nil
```

- [ ] **Step 4: 순수 정규화 헬퍼 추가**

AppState에 추가(static):
```swift
    /// 등록 폴더 목록 정규화: 중복·기존 하위 추가는 무시하고, 새 상위가 기존 하위를 흡수한다.
    /// 경로는 표준화 후 접두 비교("/a"는 "/a/"로 보고 "/a/sub"를 하위로 본다).
    static func normalizedIndexFolders(_ existing: [String], adding: String) -> [String] {
        func norm(_ p: String) -> String { (p as NSString).standardizingPath }
        let add = norm(adding)
        func isAncestor(_ anc: String, _ desc: String) -> Bool {
            desc == anc || desc.hasPrefix(anc.hasSuffix("/") ? anc : anc + "/")
        }
        // 이미 등록됐거나 기존 항목의 하위면 변화 없음.
        for e in existing where isAncestor(norm(e), add) { return existing }
        // 새 항목의 하위인 기존 항목들을 제거(흡수)하고 새 항목 추가.
        var kept = existing.filter { !isAncestor(add, norm($0)) }
        kept.append(add)
        return kept
    }
```

- [ ] **Step 5: 메서드 추가(등록/해제/재인덱싱/검색/열기/감시)**

AppState에 추가:
```swift
    // MARK: - 내용 검색(인덱스)

    /// 폴더를 등록 목록에 정규화 추가하고 인덱싱·감시를 시작한다.
    @MainActor
    func registerIndexFolder(_ url: URL) {
        let next = Self.normalizedIndexFolders(settings.indexedFolders, adding: url.path)
        guard next != settings.indexedFolders else { return }
        settings.indexedFolders = next
        saveUserData()
        startFolderWatching()
        reindexFolder(url.path)
    }

    /// 등록 해제: 목록에서 빼고 인덱스에서 그 하위를 제거한다(디스크 파일은 불변).
    @MainActor
    func unregisterIndexFolder(_ path: String) {
        settings.indexedFolders.removeAll { $0 == path }
        saveUserData()
        startFolderWatching()
        Task { _ = await searchIndex.removeUnder(folder: path) }
    }

    /// 한 폴더를 (재)인덱싱한다(진행률 표시).
    @MainActor
    func reindexFolder(_ path: String) {
        indexInProgress = true
        indexProgress = (0, 0)
        Task {
            await searchIndexer.indexFolder(URL(fileURLWithPath: path)) { done, total in
                Task { @MainActor in self.indexProgress = (done, total) }
            }
            await MainActor.run {
                self.indexInProgress = false
                self.indexProgress = nil
                if !self.indexSearchText.isEmpty {
                    Task { await self.runIndexSearch(query: self.indexSearchText) }
                }
            }
        }
    }

    /// 인덱스 검색 실행(결과를 indexSearchResults에 채운다).
    @MainActor
    func runIndexSearch(query: String) async {
        guard !query.isEmpty else { indexSearchResults = []; return }
        let hits = await searchIndex.search(query: query)
        indexSearchResults = hits
    }

    /// 결과 경로를 연다.
    @MainActor
    func openIndexHit(_ hit: IndexHit) {
        let url = URL(fileURLWithPath: hit.path)
        showIndexSearch = false
        Task { await loadAndActivateDocument(at: url, inNewTab: true) }
    }

    /// 등록 폴더로 파일 감시를 (재)시작한다. 변경 경로를 증분 재인덱싱.
    @MainActor
    func startFolderWatching() {
        folderWatcher.onChangedPaths = { [weak self] paths in
            guard let self else { return }
            Task { @MainActor in
                for p in Set(paths) {
                    await self.searchIndexer.reindex(path: p)
                }
                if !self.indexSearchText.isEmpty {
                    await self.runIndexSearch(query: self.indexSearchText)
                }
            }
        }
        folderWatcher.start(folders: settings.indexedFolders)
    }
```

> `loadAndActivateDocument`가 `private`이면 같은 타입 내부 호출이라 접근 가능. `init`에서 stored property 대입 순서 때문에 빌드가 막히면, `searchIndex`/`searchIndexer`를 `private var ... !`(암시적 언래핑) 대신 `let`으로 두고 `init` 본문 끝에서 대입하되, 그 전에 다른 모든 stored property가 기본값을 갖도록 둔다(이미 그러함).

- [ ] **Step 6: 앱 시작 시 감시 시작**

기존 `init()`(line 542)은 끝부분에서 `loadUserData()`를 호출한다(line ~556). 그 `loadUserData()` 호출 **바로 다음 줄**(init 본문 끝)에 감시 시작을 추가한다:
```swift
        // 등록 폴더 파일 감시 시작(앱 시작 시 1회).
        Task { @MainActor in self.startFolderWatching() }
```
(init 본문 끝이라 `self`는 완전 초기화 상태. `startFolderWatching`는 `@MainActor`이므로 `Task { @MainActor in ... }`로 감싼다.)

- [ ] **Step 7: 테스트 통과 + 빌드 확인**

Run: `swift test --filter AppIndexSearchTests`
Expected: PASS (5 tests).
Run: `swift build`
Expected: 빌드 성공.

- [ ] **Step 8: 커밋**

```bash
git add Sources/App/AppState.swift Tests/CmdMDTests/AppIndexSearchTests.swift
git commit -m "기능(검색): AppState 인덱스 배선(등록·해제·재인덱싱·검색·파일감시)

normalizedIndexFolders 정규화·읽기전용 인덱싱·FSEvents 증분 재인덱싱.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01S2QuZUALidkTNRswXFL6xM"
```

---

### Task 7: IndexSearchView UI + 진입점

**Files:**
- Create: `Sources/Views/IndexSearchView.swift`
- Modify: `Sources/Views/ContentView.swift` (`.sheet(isPresented: $state.showIndexSearch)`)
- Modify: `Sources/Views/CommandPaletteView.swift` (Command 항목 추가)
- Test: 없음(UI; `swift build` + `swift test` 회귀만)

**Interfaces:**
- Consumes: `AppState.showIndexSearch`/`indexSearchText`/`indexSearchResults`/`indexInProgress`/`indexProgress`/`registerIndexFolder`/`unregisterIndexFolder`/`reindexFolder`/`runIndexSearch`/`openIndexHit`(Task 6), `AppSettings.indexedFolders`(Task 5), `IndexHit`(Task 1)
- Produces: `struct IndexSearchView: View`

- [ ] **Step 1: IndexSearchView 작성**

`Sources/Views/IndexSearchView.swift`:
```swift
import SwiftUI
import AppKit

/// 전용 내용 검색 시트: 등록 폴더 관리 + FTS5 키워드 검색(파일+스니펫).
struct IndexSearchView: View {
    @Environment(AppState.self) private var appState
    @State private var query: String = ""
    @State private var debounce: Task<Void, Never>?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("내용 검색")
                    .font(.headline)
                Spacer()
                Button("닫기") { appState.showIndexSearch = false }
                    .buttonStyle(.borderless)
            }
            .padding()
            .background(.bar)

            Form {
                Section("등록 폴더") {
                    if appState.settings.indexedFolders.isEmpty {
                        Text("폴더를 추가해 인덱싱하세요.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(appState.settings.indexedFolders, id: \.self) { folder in
                        HStack {
                            Text((folder as NSString).lastPathComponent)
                            Text(folder).font(.caption).foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button("재인덱싱") { appState.reindexFolder(folder) }
                                .controlSize(.small)
                            Button(role: .destructive) { appState.unregisterIndexFolder(folder) } label: {
                                Image(systemName: "minus.circle")
                            }
                            .controlSize(.small)
                        }
                    }
                    HStack {
                        Button("폴더 추가…") { addFolder() }
                        if appState.indexInProgress, let p = appState.indexProgress {
                            ProgressView(value: p.total == 0 ? 0 : Double(p.done) / Double(p.total))
                            Text("\(p.done)/\(p.total)").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }

                Section("검색") {
                    TextField("키워드", text: $query)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: query) { _, q in
                            appState.indexSearchText = q
                            debounce?.cancel()
                            debounce = Task {
                                try? await Task.sleep(nanoseconds: 200_000_000)
                                if Task.isCancelled { return }
                                await appState.runIndexSearch(query: q)
                            }
                        }

                    if appState.indexSearchResults.isEmpty && !query.isEmpty {
                        Text("결과 없음").font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(appState.indexSearchResults, id: \.path) { hit in
                        Button { appState.openIndexHit(hit) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Image(systemName: "doc.text")
                                    Text((hit.path as NSString).lastPathComponent)
                                        .font(.callout.weight(.medium))
                                    if hit.isFilenameMatch {
                                        Text("파일명").font(.caption2)
                                            .padding(.horizontal, 4).background(.quaternary).clipShape(Capsule())
                                    }
                                }
                                if !hit.snippet.isEmpty {
                                    Text(hit.snippet).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                                Text((hit.path as NSString).deletingLastPathComponent)
                                    .font(.caption2).foregroundStyle(.tertiary)
                                    .lineLimit(1).truncationMode(.middle)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .formStyle(.grouped)
        }
        .frame(width: 560, height: 600)
        .tint(.cmdsAccent)
    }

    private func addFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            appState.registerIndexFolder(url)
        }
    }
}
```

- [ ] **Step 2: ContentView에 시트 추가**

`Sources/Views/ContentView.swift`의 다른 `.sheet(...)` 블록들 옆(예 `officeFillSession` 시트 근처)에 추가:
```swift
        .sheet(isPresented: $state.showIndexSearch) {
            IndexSearchView()
        }
```
(`$state`는 해당 파일이 쓰는 기존 바인딩 패턴을 따른다.)

- [ ] **Step 3: 커맨드 팔레트 항목 추가**

`Sources/Views/CommandPaletteView.swift`의 `Command(...)` 목록(예 `appState.showOmnisearch = true` 항목 근처)에 같은 형식으로 항목 추가:
```swift
            Command(
                title: "내용 검색 (인덱스)",
                subtitle: "등록 폴더의 본문을 키워드로 검색",
                icon: "magnifyingglass.circle"
            ) {
                appState.showIndexSearch = true
            },
```
> 실제 `Command` 이니셜라이저 시그니처는 파일의 기존 항목을 그대로 본떠 맞춘다(title/subtitle/icon/action 필드명이 다르면 기존 항목 형식에 맞춤).

- [ ] **Step 4: 빌드·회귀 확인**

Run: `swift build`
Expected: 빌드 성공(경고 없음).
Run: `swift test`
Expected: 모든 테스트 PASS(UI 단위테스트 없음).

- [ ] **Step 5: 커밋**

```bash
git add Sources/Views/IndexSearchView.swift Sources/Views/ContentView.swift Sources/Views/CommandPaletteView.swift
git commit -m "기능(검색): IndexSearchView 시트·커맨드팔레트 진입점 추가

등록 폴더 관리·진행률·FTS5 검색(파일+스니펫)·클릭 열기.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01S2QuZUALidkTNRswXFL6xM"
```

---

### Task 8: Phase 게이트 — 전체 테스트·수동 검증·문서

**Files:**
- Modify: `CLAUDE.md`

**Interfaces:** 없음(통합 검증·문서).

- [ ] **Step 1: 전체 테스트**

Run: `swift test`
Expected: 모든 테스트 PASS(기존 154 + 신규 약 21 = 약 175). 실패 0.

- [ ] **Step 2: 수동 검증(앱)**

앱 실행 → 커맨드 팔레트 "내용 검색" → "폴더 추가…"로 HWP/PDF/오피스가 있는 폴더 등록 → 진행률 후 키워드 입력 → 1초 안에 파일+스니펫 결과 → 클릭으로 열림 확인. 폴더 안 파일을 수정/추가하면 자동 재인덱싱돼 검색에 반영되는지(FSEvents), 등록 해제 시 결과에서 빠지고 원본 파일은 그대로인지 확인. 검증 샘플 HWP: `/Users/ahbaik/Downloads/제9회_전국동시지방선거_정의당_평가서.hwp`.

- [ ] **Step 3: CLAUDE.md 상태 갱신**

`## 현재 상태`의 Phase 6 줄 아래에 한 줄 추가(실제 수치로):
```markdown
- Phase 7 완료(2026-06-30). 내용 검색(FTS5 영속 인덱스+파일감시) — `import SQLite3`(무依存, 검증)로 `SearchIndex`(FTS5 docs/files, snippet·needsIndex·removeUnder, 읽기전용) + `ContentExtractor`(text/pdf 로컬·office는 kordoc) + `SearchIndexer`(폴더 워킹·mtime 스킵·삭제 제거) + `FolderWatcher`(FSEvents 파일이벤트 증분 재인덱싱) + `AppSettings.indexedFolders` + `IndexSearchView`(등록폴더·진행률·파일+스니펫·클릭 열기, 커맨드팔레트 진입). 인덱싱 읽기전용·삭제 없음, 등록폴더 정규화(중복/중첩). 약 NN개 테스트 통과(SQLite는 in-process라 인덱스 단위테스트).
```
그리고 `다음 액션:` 줄을 Phase 8(폴더 정리)로 갱신.

- [ ] **Step 4: 커밋**

```bash
git add CLAUDE.md
git commit -m "문서: Phase 7 내용 검색(FTS5) 완료 상태 기록

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01S2QuZUALidkTNRswXFL6xM"
```

---

## Self-Review

**Spec coverage:**
- 3.1 SearchIndex(스키마·API·sanitize·IndexHit) → Task 1 ✓
- 3.2 ContentExtractor(localBody/body) → Task 2 ✓
- 3.3 SearchIndexer(indexFolder/reindex) → Task 3 ✓
- 3.4 FolderWatcher(FSEvents) → Task 4 ✓
- 3.5 AppSettings.indexedFolders → Task 5 ✓
- 3.6 AppState 배선(인스턴스·상태·register/unregister/reindex/runIndexSearch/openIndexHit/startFolderWatching) → Task 6 ✓
- 3.7 IndexSearchView + 진입점(팔레트·시트) → Task 7 ✓
- 4 에러/안전(읽기전용·kordoc 실패 스킵·DB 재생성·등록해제 DB만·디바운스·limit) → Task 1(DB 재생성·limit)·3(스킵)·4(디바운스)·6(읽기전용·removeUnder) ✓
- 5 테스트(SearchIndex·sanitize·ContentExtractor·indexedFolders·정규화) → Task 1·2·5·6 ✓

**Placeholder scan:** NN(테스트 수)·실제 수치만 실행 시 채움. 코드/명령은 구체값. Task 7 Step 3의 `Command` 시그니처는 "기존 항목 형식에 맞춤" 지시 — 실제 파일 형식을 따르라는 구체 지침(플레이스홀더 아님). 그 외 TBD 없음.

**Type consistency:** `IndexHit{path,snippet,isFilenameMatch}`(Task 1·6·7 일치), `FTSQuery.sanitize`(Task 1), `SearchIndex` 메서드 시그니처(Task 1·3·6 일치), `ContentExtractor.body(for:kordoc:)`/`localBody(for:)`(Task 2·3 일치), `SearchIndexer.indexFolder(_:progress:)`/`reindex(path:)`(Task 3·6 일치), `FolderWatcher.onChangedPaths`/`start(folders:)`/`stop()`(Task 4·6 일치), `normalizedIndexFolders(_:adding:)`·`registerIndexFolder`·`unregisterIndexFolder`·`reindexFolder`·`runIndexSearch`·`openIndexHit`·`startFolderWatching`·상태 프로퍼티명(Task 6·7 일치), `settings.indexedFolders`(Task 5·6·7 일치). 일관성 확인됨.

**Note(실행 중 확인):** Task 1 `filename MATCH`가 FTS5에서 기대대로 동작하지 않으면 Step 4 주석의 INSTR 대안으로 전환(테스트가 가드). Task 6 `init` stored-property 대입 순서는 빌드가 가드 — 막히면 주석의 대안(본문 끝 대입)을 따른다.
