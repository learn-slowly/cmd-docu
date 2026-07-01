# Phase 9 — 가벼운 RAG (자료에 묻기) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 등록한 인덱스 폴더의 본문을 근거로 자연어 질문에 Claude가 답하고, 앱이 만든 출처 [n]을 클릭하면 그 문서의 위치(줄/페이지)로 여는 "자료에 묻기(RAG)" 시트를 추가한다.

**Architecture:** 임베딩 없이 기존 FTS5(`SearchIndex`)로 근거를 추리고, 각 파일에서 질의어 주변 문단을 뽑아 번호(`[1]..[N]`)를 부여해 `ClaudeService.ask`에 컨텍스트로 넘긴다. 앱이 무엇을 보냈는지 알기에 출처 칩을 앱이 만들어 `openDocument(...scrollToLine/scrollToPDFPage)`로 점프한다. 신규 로직은 전부 별도 `Rag*` 파일(순수 헬퍼는 단위테스트), 기존 파일은 가산만.

**Tech Stack:** Swift 5.9+ / SwiftUI, SPM, macOS 14+. 시스템 SQLite3(FTS5, 기존), `claude` CLI(Process, 기존 `ClaudeService`), PDFKit(기존), kordoc(Process, office 본문). 새 패키지 의존성 없음.

## Global Constraints

- 비샌드박스 유지 — `Process` CLI 호출이 막히면 안 됨.
- 검색/읽기 전용 — 어떤 파일도 이동·이름변경·삭제하지 않음.
- kordoc·claude는 직접 구현 안 함 — 기존 `KordocService`/`ClaudeService`를 `Process`로 호출·재사용. 경로 탐지 실패 시 안내만, 크래시 금지.
- 새 패키지 의존성 추가 금지(macOS 내장 + 기존 서비스만).
- 신규 기능은 별도 파일·모듈로 분리(업스트림 CmdMD 머지 용이). 기존 파일은 가산(additive)만.
- 코드 주석·커밋 메시지는 한국어. '박다/박는다' 류 표현 금지.
- Phase 게이트 — 시작·종료 시 `swift test`로 기존 277개 + 신규 전부 통과 확인(정식 Xcode 필요; CLT는 build만).
- 추정을 사실로 적지 않음 — 불확실하면 코드로 검증 후 확정.
- 테스트 격리 — AppState 테스트는 `AppState(dataDirectory:)`에 `TempDataDirectory.make()` 주입, teardown에서 `cleanup`.
- 근거가 0건이면 Claude를 호출하지 않는다(무근거 생성 차단·크레딧 절약).

**참조 스펙:** `docs/superpowers/specs/2026-07-01-phase9-lightweight-rag-design.md`

---

## 파일 구조 (생성/수정)

**생성:**
- `Sources/Models/RagSource.swift` — `RagSource`, `RagLocation`.
- `Sources/Services/RagQueryExpansion.swift` — 질의 확장 prompt/parse/orMatch(순수).
- `Sources/Services/RagRetriever.swift` — FTS5 검색 + 경로 병합.
- `Sources/Services/RagPassageExtractor.swift` — 근거 문단창 + 위치.
- `Sources/Services/RagContextBuilder.swift` — 번호부여 컨텍스트 + 출처목록(순수).
- `Sources/Services/RagPromptBuilder.swift` — 답변 프롬프트(순수).
- `Sources/Services/RagService.swift` — actor 오케스트레이션.
- `Sources/Views/AskCorpusView.swift` — 시트 UI.
- 테스트: `RagSourceTests`, `RagQueryExpansionTests`, `RagRetrieverTests`, `RagPassageExtractorTests`, `RagContextBuilderTests`, `RagPromptBuilderTests`, `SearchIndexMatchTests`, `RagExpandQuerySettingsTests`, `RagServiceTests`, `AppAskCorpusTests`.

**수정(가산):**
- `Sources/Services/SearchIndex.swift` — `searchMatch(_:limit:)` 추가.
- `Sources/Models/Settings.swift` — `ragExpandQuery` 필드 + decode 한 줄.
- `Sources/App/AppState.swift` — `ragService` 인스턴스, RAG 상태, `runRagQuery()`, `openRagSource(_:)`.
- `Sources/Views/ContentView.swift` — `.sheet(isPresented: $state.showAskCorpus)`.
- `Sources/Views/CommandPaletteView.swift` — "자료에 묻기 (RAG)" 항목.

**단일 실행 필터:** `swift test --filter <ClassName>` (전체는 `swift test`). ⚠️ `swift test`는 정식 Xcode 필요.

---

### Task 1: RagSource 모델

**Files:**
- Create: `Sources/Models/RagSource.swift`
- Test: `Tests/CmdMDTests/RagSourceTests.swift`

**Interfaces:**
- Produces: `struct RagSource: Equatable, Identifiable { let index: Int; let path: String; let snippet: String; let location: RagLocation; var id: Int { index } }`, `enum RagLocation: Equatable { case line(Int); case page(Int); case unknown }`

- [ ] **Step 1: 실패하는 테스트 작성**

`Tests/CmdMDTests/RagSourceTests.swift`:
```swift
import XCTest
@testable import CmdMD

final class RagSourceTests: XCTestCase {
    func testIdentifiableUsesIndex() {
        let s = RagSource(index: 3, path: "/d/a.md", snippet: "…", location: .line(42))
        XCTAssertEqual(s.id, 3)
    }

    func testEquatable() {
        let a = RagSource(index: 1, path: "/d/a.md", snippet: "x", location: .page(2))
        let b = RagSource(index: 1, path: "/d/a.md", snippet: "x", location: .page(2))
        XCTAssertEqual(a, b)
        let c = RagSource(index: 1, path: "/d/a.md", snippet: "x", location: .unknown)
        XCTAssertNotEqual(a, c)
    }
}
```

- [ ] **Step 2: 테스트 실패 확인**

Run: `swift test --filter RagSourceTests`
Expected: FAIL — "cannot find 'RagSource' in scope".

- [ ] **Step 3: 최소 구현**

`Sources/Models/RagSource.swift`:
```swift
import Foundation

/// RAG 답변의 근거 1건 + 원본 위치.
struct RagSource: Equatable, Identifiable {
    let index: Int          // [n] (1-based). 프롬프트 번호와 표시에 공용.
    let path: String        // 원본 파일 절대경로
    let snippet: String     // 표시용 발췌
    let location: RagLocation
    var id: Int { index }
}

/// 근거의 원본 위치. 클릭 점프에 쓴다.
enum RagLocation: Equatable {
    case line(Int)          // text/md: 1-based 줄
    case page(Int)          // pdf: 1-based 페이지
    case unknown            // office 등 위치 매핑 불가 → 파일만 연다
}
```

- [ ] **Step 4: 테스트 통과 확인**

Run: `swift test --filter RagSourceTests`
Expected: PASS (2 tests).

- [ ] **Step 5: 커밋**

```bash
git add Sources/Models/RagSource.swift Tests/CmdMDTests/RagSourceTests.swift
git commit -m "기능(RAG): RagSource·RagLocation 모델 + 테스트"
```

---

### Task 2: SearchIndex.searchMatch (OR 재검색용 가산)

**Files:**
- Modify: `Sources/Services/SearchIndex.swift` (`search(query:limit:)` 바로 다음, 약 187행 뒤에 추가)
- Test: `Tests/CmdMDTests/SearchIndexMatchTests.swift`

**Interfaces:**
- Consumes: 기존 `SearchIndex`, `IndexHit`.
- Produces: `func searchMatch(_ match: String, limit: Int = 200) -> [IndexHit]` (호출자가 만든 MATCH를 sanitize 없이 실행; `isFilenameMatch`는 항상 false).

- [ ] **Step 1: 실패하는 테스트 작성**

`Tests/CmdMDTests/SearchIndexMatchTests.swift`:
```swift
import XCTest
@testable import CmdMD

final class SearchIndexMatchTests: XCTestCase {
    private func tempDBURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("cmddocu-idxm-\(UUID().uuidString)")
            .appendingPathExtension("sqlite")
    }

    func testSearchMatchORFindsEitherTerm() async {
        let idx = SearchIndex(dbURL: tempDBURL())
        await idx.upsert(path: "/d/a.md", filename: "a.md", body: "지방선거 총평", mtime: 1, ext: "md")
        await idx.upsert(path: "/d/b.md", filename: "b.md", body: "평가서 초안", mtime: 1, ext: "md")
        await idx.upsert(path: "/d/c.md", filename: "c.md", body: "무관한 내용", mtime: 1, ext: "md")
        // "지방선거" OR "평가서" → a, b 만.
        let hits = await idx.searchMatch("\"지방선거\" OR \"평가서\"")
        let paths = Set(hits.map { $0.path })
        XCTAssertEqual(paths, ["/d/a.md", "/d/b.md"])
    }

    func testExistingSearchUnchangedRegression() async {
        // 기존 search()가 그대로 동작하는지 회귀 확인.
        let idx = SearchIndex(dbURL: tempDBURL())
        await idx.upsert(path: "/d/a.md", filename: "a.md", body: "선거 분석", mtime: 1, ext: "md")
        let hits = await idx.search(query: "선거")
        XCTAssertEqual(hits.first?.path, "/d/a.md")
    }
}
```

- [ ] **Step 2: 테스트 실패 확인**

Run: `swift test --filter SearchIndexMatchTests`
Expected: FAIL — "value of type 'SearchIndex' has no member 'searchMatch'".

- [ ] **Step 3: 최소 구현**

`Sources/Services/SearchIndex.swift` — `search(query:limit:)`(187행에서 끝남) 다음, `clear()` 앞에 추가:
```swift
    /// 호출자가 직접 만든 MATCH 문자열로 검색한다(sanitize 안 함). RAG 확장 OR 질의용.
    /// 파일명 매칭 판정은 하지 않는다(isFilenameMatch = false).
    func searchMatch(_ match: String, limit: Int = 200) -> [IndexHit] {
        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = """
        SELECT path, snippet(docs, 2, '[', ']', '…', 10)
        FROM docs WHERE docs MATCH ? ORDER BY rank LIMIT ?;
        """
        var out: [IndexHit] = []
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        sqlite3_bind_text(stmt, 1, match, -1, TRANSIENT)
        sqlite3_bind_int(stmt, 2, Int32(limit))
        while sqlite3_step(stmt) == SQLITE_ROW {
            guard let pathC = sqlite3_column_text(stmt, 0) else { continue }
            let path = String(cString: pathC)
            let snippet = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            out.append(IndexHit(path: path, snippet: snippet, isFilenameMatch: false))
        }
        return out
    }
```

- [ ] **Step 4: 테스트 통과 확인**

Run: `swift test --filter SearchIndexMatchTests`
Expected: PASS (2 tests).

- [ ] **Step 5: 커밋**

```bash
git add Sources/Services/SearchIndex.swift Tests/CmdMDTests/SearchIndexMatchTests.swift
git commit -m "기능(RAG): SearchIndex.searchMatch 가산(OR 재검색용) + 회귀 테스트"
```

---

### Task 3: RagQueryExpansion (질의 확장 — 순수)

**Files:**
- Create: `Sources/Services/RagQueryExpansion.swift`
- Test: `Tests/CmdMDTests/RagQueryExpansionTests.swift`

**Interfaces:**
- Produces:
  - `static func prompt() -> String`
  - `static func parse(_ stdout: String) -> [String]` (stdout에서 첫 `[`~마지막 `]` 추출 → `[String]`, 공백 trim·빈값 제거·중복 제거. 실패 시 `[]`)
  - `static func orMatch(_ terms: [String]) -> String?` (용어 → `"a" OR "b"`, 따옴표 `""` 이스케이프, 빈 배열 nil)

- [ ] **Step 1: 실패하는 테스트 작성**

`Tests/CmdMDTests/RagQueryExpansionTests.swift`:
```swift
import XCTest
@testable import CmdMD

final class RagQueryExpansionTests: XCTestCase {
    func testPromptAsksForJSONArray() {
        let p = RagQueryExpansion.prompt()
        XCTAssertTrue(p.lowercased().contains("json"))
        XCTAssertTrue(p.contains("["))
    }

    func testParseValidArray() {
        XCTAssertEqual(RagQueryExpansion.parse(#"["지방선거","총평"]"#), ["지방선거", "총평"])
    }

    func testParseExtractsFromProse() {
        let out = """
        확장 검색어입니다:
        ["지방선거", "6·1 선거", "평가서"]
        """
        XCTAssertEqual(RagQueryExpansion.parse(out), ["지방선거", "6·1 선거", "평가서"])
    }

    func testParseDropsBlanksAndDuplicates() {
        XCTAssertEqual(RagQueryExpansion.parse(#"["a"," a ","","a"]"#), ["a"])
    }

    func testParseMalformedReturnsEmpty() {
        XCTAssertEqual(RagQueryExpansion.parse("JSON 아님"), [])
    }

    func testOrMatchQuotesAndEscapes() {
        XCTAssertEqual(RagQueryExpansion.orMatch(["선거", "평가"]), "\"선거\" OR \"평가\"")
        XCTAssertEqual(RagQueryExpansion.orMatch(["a\"b"]), "\"a\"\"b\"")
    }

    func testOrMatchEmptyIsNil() {
        XCTAssertNil(RagQueryExpansion.orMatch([]))
        XCTAssertNil(RagQueryExpansion.orMatch(["", "  "]))
    }
}
```

- [ ] **Step 2: 테스트 실패 확인**

Run: `swift test --filter RagQueryExpansionTests`
Expected: FAIL — "cannot find 'RagQueryExpansion' in scope".

- [ ] **Step 3: 최소 구현**

`Sources/Services/RagQueryExpansion.swift`:
```swift
import Foundation

/// 질문을 FTS 확장 검색어로 넓히기 위한 Claude 프롬프트/응답 파서(순수).
/// 임베딩 없는 RAG(B안)에서 동의어 recall을 메우는 값싼 레버.
enum RagQueryExpansion {
    /// Claude에게 확장 검색어를 JSON 배열로만 요청하는 프롬프트.
    static func prompt() -> String {
        """
        아래 사용자의 질문을 문서 검색에 쓸 한국어 검색어로 확장하라.
        동의어·유의어·바꿔 부르는 표현을 포함해 최대 6개를 고르되, 질문의 핵심 명사를 유지하라.
        다른 텍스트 없이 JSON 문자열 배열로만 답하라. 예: ["지방선거","총평","평가서"]
        """
    }

    /// stdout에서 첫 '['~마지막 ']'를 잘라 [String]으로 디코드한다.
    /// 앞뒤에 설명이 섞여도 배열만 추출. 실패하면 [](확장 없이 진행).
    static func parse(_ stdout: String) -> [String] {
        guard let open = stdout.firstIndex(of: "["),
              let close = stdout.lastIndex(of: "]"),
              open < close else { return [] }
        let json = String(stdout[open...close])
        guard let data = json.data(using: .utf8),
              let raw = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        var seen = Set<String>()
        var out: [String] = []
        for term in raw {
            let t = term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty, !seen.contains(t.lowercased()) else { continue }
            seen.insert(t.lowercased())
            out.append(t)
        }
        return out
    }

    /// 확장 용어 → FTS5 OR MATCH. 각 용어를 "..."로 감싸고 내부 따옴표를 ""로 이스케이프.
    /// 유효 용어가 없으면 nil.
    static func orMatch(_ terms: [String]) -> String? {
        let quoted = terms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .map { "\"\($0.replacingOccurrences(of: "\"", with: "\"\""))\"" }
        guard !quoted.isEmpty else { return nil }
        return quoted.joined(separator: " OR ")
    }
}
```

- [ ] **Step 4: 테스트 통과 확인**

Run: `swift test --filter RagQueryExpansionTests`
Expected: PASS (7 tests).

- [ ] **Step 5: 커밋**

```bash
git add Sources/Services/RagQueryExpansion.swift Tests/CmdMDTests/RagQueryExpansionTests.swift
git commit -m "기능(RAG): RagQueryExpansion(확장 프롬프트·JSON 파싱·OR MATCH) + 테스트"
```

---

### Task 4: RagRetriever (FTS5 검색 + 경로 병합)

**Files:**
- Create: `Sources/Services/RagRetriever.swift`
- Test: `Tests/CmdMDTests/RagRetrieverTests.swift`

**Interfaces:**
- Consumes: `SearchIndex.search(query:limit:)`, `SearchIndex.searchMatch(_:limit:)`(Task 2), `RagQueryExpansion.orMatch`(Task 3), `IndexHit`.
- Produces:
  - `struct RagRetriever { let index: SearchIndex; func topFiles(question: String, expandedTerms: [String], limit: Int = 8) async -> [String] }`
  - `static func mergePaths(primary: [IndexHit], secondary: [IndexHit], limit: Int) -> [String]` (primary 순서 우선, secondary의 새 경로만 이어붙임, 중복 제거, limit 상한)

- [ ] **Step 1: 실패하는 테스트 작성**

`Tests/CmdMDTests/RagRetrieverTests.swift`:
```swift
import XCTest
@testable import CmdMD

final class RagRetrieverTests: XCTestCase {
    private func hit(_ p: String) -> IndexHit { IndexHit(path: p, snippet: "", isFilenameMatch: false) }

    func testMergeKeepsPrimaryOrderThenNewSecondary() {
        let out = RagRetriever.mergePaths(
            primary: [hit("/a"), hit("/b")],
            secondary: [hit("/b"), hit("/c"), hit("/d")],
            limit: 3)
        XCTAssertEqual(out, ["/a", "/b", "/c"])
    }

    func testMergeDedupesWithinPrimary() {
        let out = RagRetriever.mergePaths(
            primary: [hit("/a"), hit("/a"), hit("/b")],
            secondary: [],
            limit: 8)
        XCTAssertEqual(out, ["/a", "/b"])
    }

    func testMergeRespectsLimit() {
        let out = RagRetriever.mergePaths(
            primary: [hit("/a"), hit("/b"), hit("/c")],
            secondary: [hit("/d")],
            limit: 2)
        XCTAssertEqual(out, ["/a", "/b"])
    }

    func testTopFilesMergesOriginalAndExpansion() async {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmddocu-ret-\(UUID().uuidString)").appendingPathExtension("sqlite")
        let idx = SearchIndex(dbURL: url)
        await idx.upsert(path: "/d/a.md", filename: "a.md", body: "지방선거 결과", mtime: 1, ext: "md")
        await idx.upsert(path: "/d/b.md", filename: "b.md", body: "평가서 내용", mtime: 1, ext: "md")
        let retriever = RagRetriever(index: idx)
        // 원질문 "지방선거"는 a만, 확장 "평가서"가 b를 추가.
        let paths = await retriever.topFiles(question: "지방선거", expandedTerms: ["평가서"])
        XCTAssertEqual(Set(paths), ["/d/a.md", "/d/b.md"])
    }
}
```

- [ ] **Step 2: 테스트 실패 확인**

Run: `swift test --filter RagRetrieverTests`
Expected: FAIL — "cannot find 'RagRetriever' in scope".

- [ ] **Step 3: 최소 구현**

`Sources/Services/RagRetriever.swift`:
```swift
import Foundation

/// FTS5 인덱스에서 근거 후보 파일 경로를 추린다. 원질문 + (확장) OR 질의를 합친다.
struct RagRetriever {
    let index: SearchIndex

    /// 원질문 히트(우선) + 확장 OR 히트(신규 경로만)를 합쳐 파일 경로 top-N.
    func topFiles(question: String, expandedTerms: [String], limit: Int = 8) async -> [String] {
        let primary = await index.search(query: question)
        var secondary: [IndexHit] = []
        if let orMatch = RagQueryExpansion.orMatch(expandedTerms) {
            secondary = await index.searchMatch(orMatch)
        }
        return Self.mergePaths(primary: primary, secondary: secondary, limit: limit)
    }

    /// primary 순서를 유지하며 중복 제거, 이어서 secondary의 새 경로만 붙이고 limit로 자른다(순수).
    static func mergePaths(primary: [IndexHit], secondary: [IndexHit], limit: Int) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for hit in primary + secondary {
            guard !seen.contains(hit.path) else { continue }
            seen.insert(hit.path)
            out.append(hit.path)
            if out.count >= limit { break }
        }
        return out
    }
}
```

- [ ] **Step 4: 테스트 통과 확인**

Run: `swift test --filter RagRetrieverTests`
Expected: PASS (4 tests).

- [ ] **Step 5: 커밋**

```bash
git add Sources/Services/RagRetriever.swift Tests/CmdMDTests/RagRetrieverTests.swift
git commit -m "기능(RAG): RagRetriever(원질문+확장 OR 병합) + 테스트"
```

---

### Task 5: RagPassageExtractor (근거 문단창 + 위치)

**Files:**
- Create: `Sources/Services/RagPassageExtractor.swift`
- Test: `Tests/CmdMDTests/RagPassageExtractorTests.swift`

**Interfaces:**
- Consumes: `RagLocation`(Task 1), `ContentExtractor.localBody(for:)` / `ContentExtractor.body(for:kordoc:)`(기존), `KordocService`(기존), `DocumentKind`(기존), PDFKit.
- Produces:
  - `struct Passage: Equatable { let text: String; let location: RagLocation }`
  - `static func passage(inText body: String, terms: [String], maxChars: Int = 1200) -> Passage` (순수)
  - `static func passage(for url: URL, terms: [String], kordoc: KordocService, maxChars: Int = 1200) async -> Passage?`

**동작 규칙(순수 함수):** 질의어(대소문자 무시) 첫 매치가 든 **문단**(빈 줄 `\n\n`로 구분)을 반환하고, 매치 줄의 1-based 줄 번호를 `.line`으로 준다. 매치가 없으면 본문 앞 `maxChars`(줄 1). 문단이 `maxChars`보다 길면 매치 중심으로 `maxChars`까지 자른다.

- [ ] **Step 1: 실패하는 테스트 작성**

`Tests/CmdMDTests/RagPassageExtractorTests.swift`:
```swift
import XCTest
@testable import CmdMD

final class RagPassageExtractorTests: XCTestCase {
    func testReturnsParagraphWithMatchAndLine() {
        let body = "머리말\n\n둘째 문단 선거 분석 내용\n\n셋째 문단"
        let p = RagPassageExtractor.passage(inText: body, terms: ["선거"])
        XCTAssertEqual(p.text, "둘째 문단 선거 분석 내용")
        XCTAssertEqual(p.location, .line(3))
    }

    func testCaseInsensitiveMatch() {
        let body = "intro\n\nSee the Budget report here"
        let p = RagPassageExtractor.passage(inText: body, terms: ["budget"])
        XCTAssertEqual(p.text, "See the Budget report here")
        XCTAssertEqual(p.location, .line(3))
    }

    func testNoMatchReturnsPrefixLineOne() {
        let body = "관계 없는 첫 문단\n\n관계 없는 둘째 문단"
        let p = RagPassageExtractor.passage(inText: body, terms: ["없는단어"], maxChars: 8)
        XCTAssertEqual(p.location, .line(1))
        XCTAssertLessThanOrEqual(p.text.count, 8)
        XCTAssertEqual(p.text, "관계 없는 첫")
    }

    func testLongParagraphCappedToMaxChars() {
        let long = String(repeating: "가", count: 500) + "선거" + String(repeating: "나", count: 500)
        let p = RagPassageExtractor.passage(inText: long, terms: ["선거"], maxChars: 100)
        XCTAssertLessThanOrEqual(p.text.count, 100)
        XCTAssertTrue(p.text.contains("선거"))
    }

    func testEmptyTermsReturnsPrefixLineOne() {
        let p = RagPassageExtractor.passage(inText: "본문 내용", terms: [], maxChars: 100)
        XCTAssertEqual(p.location, .line(1))
        XCTAssertEqual(p.text, "본문 내용")
    }
}
```

- [ ] **Step 2: 테스트 실패 확인**

Run: `swift test --filter RagPassageExtractorTests`
Expected: FAIL — "cannot find 'RagPassageExtractor' in scope".

- [ ] **Step 3: 최소 구현**

`Sources/Services/RagPassageExtractor.swift`:
```swift
import Foundation
import PDFKit

/// 근거 파일에서 질의어 주변 문단(창)과 원본 위치를 뽑는다.
/// text 경로는 순수·결정적(테스트 대상), pdf/office는 기존 추출기를 재사용.
enum RagPassageExtractor {
    struct Passage: Equatable { let text: String; let location: RagLocation }

    /// 본문 문자열에서 질의어 첫 매치가 든 문단을 반환(순수). 매치 없으면 앞 maxChars·줄 1.
    static func passage(inText body: String, terms: [String], maxChars: Int = 1200) -> Passage {
        let cleanTerms = terms.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                              .filter { !$0.isEmpty }
        let lower = body.lowercased()
        // 가장 이른 매치 오프셋(정수) 탐색.
        var best: Int? = nil
        for term in cleanTerms {
            if let r = lower.range(of: term.lowercased()) {
                let off = lower.distance(from: lower.startIndex, to: r.lowerBound)
                if best == nil || off < best! { best = off }
            }
        }
        guard let matchOff = best else {
            return Passage(text: String(body.prefix(maxChars)), location: .line(1))
        }
        let chars = Array(body)
        // 매치 줄 번호 = 매치 앞의 개행 수 + 1.
        let line = chars[0..<matchOff].reduce(1) { $0 + ($1 == "\n" ? 1 : 0) }
        // 문단 경계: 앞뒤로 빈 줄("\n\n")을 찾는다.
        let paraStart = paragraphStart(chars, before: matchOff)
        let paraEnd = paragraphEnd(chars, from: matchOff)
        var paragraph = String(chars[paraStart..<paraEnd]).trimmingCharacters(in: .whitespacesAndNewlines)
        if paragraph.count > maxChars {
            paragraph = centeredWindow(String(chars[paraStart..<paraEnd]), around: matchOff - paraStart, maxChars: maxChars)
        }
        return Passage(text: paragraph, location: .line(line))
    }

    /// 종류별 근거 추출: text/md=줄, pdf=페이지, office=위치 unknown. 실패 시 nil.
    static func passage(for url: URL, terms: [String], kordoc: KordocService, maxChars: Int = 1200) async -> Passage? {
        let ext = url.pathExtension.lowercased()
        if DocumentKind.pdfExtensions.contains(ext) {
            return pdfPassage(url: url, terms: terms, maxChars: maxChars)
        }
        if DocumentKind.officeExtensions.contains(ext) {
            guard let body = await ContentExtractor.body(for: url, kordoc: kordoc) else { return nil }
            let p = passage(inText: body, terms: terms, maxChars: maxChars)
            return Passage(text: p.text, location: .unknown)   // 원본 위치 매핑 불가
        }
        guard let body = ContentExtractor.localBody(for: url) else { return nil }
        return passage(inText: body, terms: terms, maxChars: maxChars)
    }

    // MARK: - private

    private static func pdfPassage(url: URL, terms: [String], maxChars: Int) -> Passage? {
        guard let doc = PDFDocument(url: url) else { return nil }
        let cleanTerms = terms.map { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
                              .filter { !$0.isEmpty }
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i), let text = page.string else { continue }
            let lower = text.lowercased()
            if cleanTerms.contains(where: { lower.contains($0) }) {
                let p = passage(inText: text, terms: terms, maxChars: maxChars)
                return Passage(text: p.text, location: .page(i + 1))
            }
        }
        // 매치 없으면 1페이지 앞부분.
        if let first = doc.page(at: 0)?.string {
            return Passage(text: String(first.prefix(maxChars)), location: .page(1))
        }
        return nil
    }

    private static func paragraphStart(_ chars: [Character], before off: Int) -> Int {
        var i = off
        while i > 1 {
            if chars[i - 1] == "\n" && chars[i - 2] == "\n" { return i }
            i -= 1
        }
        return 0
    }

    private static func paragraphEnd(_ chars: [Character], from off: Int) -> Int {
        var i = off
        while i < chars.count - 1 {
            if chars[i] == "\n" && chars[i + 1] == "\n" { return i }
            i += 1
        }
        return chars.count
    }

    private static func centeredWindow(_ s: String, around off: Int, maxChars: Int) -> String {
        let chars = Array(s)
        let half = maxChars / 2
        let start = max(0, min(off - half, chars.count - maxChars))
        let clampedStart = max(0, start)
        let end = min(chars.count, clampedStart + maxChars)
        return String(chars[clampedStart..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
```

- [ ] **Step 4: 테스트 통과 확인**

Run: `swift test --filter RagPassageExtractorTests`
Expected: PASS (5 tests).

(참고: `passage(for:terms:kordoc:)`의 pdf/office 경로는 실파일이 필요해 수동 검증한다. Task 11 스모크에서 확인.)

- [ ] **Step 5: 커밋**

```bash
git add Sources/Services/RagPassageExtractor.swift Tests/CmdMDTests/RagPassageExtractorTests.swift
git commit -m "기능(RAG): RagPassageExtractor(문단창+줄/페이지 위치) + 순수 테스트"
```

---

### Task 6: RagContextBuilder (번호부여 컨텍스트 + 출처)

**Files:**
- Create: `Sources/Services/RagContextBuilder.swift`
- Test: `Tests/CmdMDTests/RagContextBuilderTests.swift`

**Interfaces:**
- Consumes: `RagSource`, `RagLocation`(Task 1), `RagPassageExtractor.Passage`(Task 5).
- Produces:
  - `struct Built: Equatable { let context: String; let sources: [RagSource] }`
  - `static func build(paths: [String], passages: [RagPassageExtractor.Passage], budget: Int = 12000) -> Built`

**규칙:** `paths[i]`↔`passages[i]`를 짝지어 `[1]..[N]` 번호 부여. 각 블록 = `[n] <파일명>(위치)\n<본문>\n---\n`. 누적이 budget을 넘고 이미 1건 이상이면 이후 버림(최소 1건 포함). `sources[i].snippet` = 패시지 앞 160자.

- [ ] **Step 1: 실패하는 테스트 작성**

`Tests/CmdMDTests/RagContextBuilderTests.swift`:
```swift
import XCTest
@testable import CmdMD

final class RagContextBuilderTests: XCTestCase {
    private func pass(_ t: String, _ l: RagLocation) -> RagPassageExtractor.Passage {
        RagPassageExtractor.Passage(text: t, location: l)
    }

    func testNumbersSourcesAndBuildsContext() {
        let built = RagContextBuilder.build(
            paths: ["/d/a.md", "/d/b.pdf"],
            passages: [pass("첫 근거", .line(3)), pass("둘째 근거", .page(2))])
        XCTAssertEqual(built.sources.count, 2)
        XCTAssertEqual(built.sources[0].index, 1)
        XCTAssertEqual(built.sources[0].path, "/d/a.md")
        XCTAssertEqual(built.sources[0].location, .line(3))
        XCTAssertEqual(built.sources[1].index, 2)
        XCTAssertTrue(built.context.contains("[1] a.md (줄 3)"))
        XCTAssertTrue(built.context.contains("첫 근거"))
        XCTAssertTrue(built.context.contains("[2] b.pdf (p.2)"))
    }

    func testBudgetTruncatesButKeepsAtLeastOne() {
        let big = String(repeating: "가", count: 1000)
        let built = RagContextBuilder.build(
            paths: ["/d/a.md", "/d/b.md"],
            passages: [pass(big, .line(1)), pass(big, .line(1))],
            budget: 200)
        XCTAssertEqual(built.sources.count, 1)          // 예산 초과분 버림
        XCTAssertTrue(built.context.contains("[1]"))
        XCTAssertFalse(built.context.contains("[2]"))
    }

    func testEmptyInput() {
        let built = RagContextBuilder.build(paths: [], passages: [])
        XCTAssertTrue(built.sources.isEmpty)
        XCTAssertEqual(built.context, "")
    }
}
```

- [ ] **Step 2: 테스트 실패 확인**

Run: `swift test --filter RagContextBuilderTests`
Expected: FAIL — "cannot find 'RagContextBuilder' in scope".

- [ ] **Step 3: 최소 구현**

`Sources/Services/RagContextBuilder.swift`:
```swift
import Foundation

/// 근거 패시지들을 번호([1]..[N])가 붙은 Claude 컨텍스트 문자열과 출처 목록으로 만든다(순수).
enum RagContextBuilder {
    struct Built: Equatable { let context: String; let sources: [RagSource] }

    static func build(paths: [String], passages: [RagPassageExtractor.Passage], budget: Int = 12000) -> Built {
        let n = min(paths.count, passages.count)
        var context = ""
        var sources: [RagSource] = []
        for i in 0..<n {
            let idx = i + 1
            let filename = URL(fileURLWithPath: paths[i]).lastPathComponent
            let block = "[\(idx)] \(filename)\(locationLabel(passages[i].location))\n\(passages[i].text)\n---\n"
            // 예산 초과 & 이미 1건 이상이면 중단(최소 1건은 넣는다).
            if !context.isEmpty, context.count + block.count > budget { break }
            context += block
            sources.append(RagSource(
                index: idx,
                path: paths[i],
                snippet: String(passages[i].text.prefix(160)),
                location: passages[i].location))
        }
        return Built(context: context, sources: sources)
    }

    private static func locationLabel(_ loc: RagLocation) -> String {
        switch loc {
        case .line(let n): return " (줄 \(n))"
        case .page(let p): return " (p.\(p))"
        case .unknown: return ""
        }
    }
}
```

- [ ] **Step 4: 테스트 통과 확인**

Run: `swift test --filter RagContextBuilderTests`
Expected: PASS (3 tests).

- [ ] **Step 5: 커밋**

```bash
git add Sources/Services/RagContextBuilder.swift Tests/CmdMDTests/RagContextBuilderTests.swift
git commit -m "기능(RAG): RagContextBuilder(번호부여 컨텍스트+예산절단+출처) + 테스트"
```

---

### Task 7: RagPromptBuilder (답변 프롬프트 — 순수)

**Files:**
- Create: `Sources/Services/RagPromptBuilder.swift`
- Test: `Tests/CmdMDTests/RagPromptBuilderTests.swift`

**Interfaces:**
- Produces: `static func prompt(question: String) -> String`

- [ ] **Step 1: 실패하는 테스트 작성**

`Tests/CmdMDTests/RagPromptBuilderTests.swift`:
```swift
import XCTest
@testable import CmdMD

final class RagPromptBuilderTests: XCTestCase {
    func testPromptEmbedsQuestionAndGroundingRules() {
        let p = RagPromptBuilder.prompt(question: "지방선거 평가 정리해줘")
        XCTAssertTrue(p.contains("지방선거 평가 정리해줘"))   // 질문 포함
        XCTAssertTrue(p.contains("["))                        // [n] 인용 규칙
        XCTAssertTrue(p.contains("자료에 없"))                // grounding(모르면 없다고)
    }
}
```

- [ ] **Step 2: 테스트 실패 확인**

Run: `swift test --filter RagPromptBuilderTests`
Expected: FAIL — "cannot find 'RagPromptBuilder' in scope".

- [ ] **Step 3: 최소 구현**

`Sources/Services/RagPromptBuilder.swift`:
```swift
import Foundation

/// RAG 답변 지시 프롬프트(순수). 근거만 사용·[n] 인용·근거 없으면 모른다고 답하게 강제.
enum RagPromptBuilder {
    static func prompt(question: String) -> String {
        """
        당신은 사용자의 개인 자료를 근거로만 답하는 조수다.
        아래 stdin으로 주어진 [1], [2] … 근거 안의 내용만 사용해 한국어로 답하라.
        답에 근거를 쓸 때마다 해당 번호를 [1]처럼 붙여라.
        근거에서 답을 찾을 수 없으면 지어내지 말고 "자료에 없습니다"라고만 답하라.

        질문: \(question)
        """
    }
}
```

- [ ] **Step 4: 테스트 통과 확인**

Run: `swift test --filter RagPromptBuilderTests`
Expected: PASS (1 test).

- [ ] **Step 5: 커밋**

```bash
git add Sources/Services/RagPromptBuilder.swift Tests/CmdMDTests/RagPromptBuilderTests.swift
git commit -m "기능(RAG): RagPromptBuilder(근거만·[n] 인용·grounding) + 테스트"
```

---

### Task 8: AppSettings.ragExpandQuery (질의 확장 토글)

**Files:**
- Modify: `Sources/Models/Settings.swift` (구조체 필드 101행 `indexedFolders` 다음, decode 158행 다음)
- Test: `Tests/CmdMDTests/RagExpandQuerySettingsTests.swift`

**Interfaces:**
- Produces: `AppSettings.ragExpandQuery: Bool`(기본 true, 하위호환 디코드).

- [ ] **Step 1: 실패하는 테스트 작성**

`Tests/CmdMDTests/RagExpandQuerySettingsTests.swift`:
```swift
import XCTest
@testable import CmdMD

final class RagExpandQuerySettingsTests: XCTestCase {
    func testDefaultsTrueWhenAbsent() throws {
        let json = #"{"fontSize":14}"#.data(using: .utf8)!
        let s = try JSONDecoder().decode(AppSettings.self, from: json)
        XCTAssertTrue(s.ragExpandQuery)
    }

    func testRoundTripsFalse() throws {
        var s = AppSettings()
        s.ragExpandQuery = false
        let data = try JSONEncoder().encode(s)
        let back = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertFalse(back.ragExpandQuery)
    }
}
```

- [ ] **Step 2: 테스트 실패 확인**

Run: `swift test --filter RagExpandQuerySettingsTests`
Expected: FAIL — "value of type 'AppSettings' has no member 'ragExpandQuery'".

- [ ] **Step 3: 최소 구현**

`Sources/Models/Settings.swift` — `var indexedFolders: [String] = []`(101행) 바로 다음에 추가:
```swift
    /// 자료에 묻기(RAG) 질의 확장 토글(동의어 recall 보완). 기본 ON.
    var ragExpandQuery: Bool = true
```
그리고 init(from:)의 `indexedFolders = try c.decodeIfPresent(...)`(158행) 다음 줄에 추가:
```swift
        ragExpandQuery = try c.decodeIfPresent(Bool.self, forKey: .ragExpandQuery) ?? d.ragExpandQuery
```

- [ ] **Step 4: 테스트 통과 확인**

Run: `swift test --filter RagExpandQuerySettingsTests`
Expected: PASS (2 tests).

- [ ] **Step 5: 커밋**

```bash
git add Sources/Models/Settings.swift Tests/CmdMDTests/RagExpandQuerySettingsTests.swift
git commit -m "기능(RAG): AppSettings.ragExpandQuery(기본 ON·하위호환) + 테스트"
```

---

### Task 9: RagService (actor 오케스트레이션)

**Files:**
- Create: `Sources/Services/RagService.swift`
- Test: `Tests/CmdMDTests/RagServiceTests.swift`

**Interfaces:**
- Consumes: `SearchIndex`, `ClaudeService`(`ask(prompt:context:)`), `KordocService`, `RagRetriever`(Task 4), `RagPassageExtractor`(Task 5), `RagContextBuilder`(Task 6), `RagPromptBuilder`(Task 7), `RagQueryExpansion`(Task 3), `RagSource`(Task 1), `ClaudeError`(기존).
- Produces:
  - `struct Answer: Equatable { let text: String; let sources: [RagSource] }`
  - `enum RagOutcome { case answered(Answer); case noEvidence; case failed(ClaudeError) }`
  - `actor RagService { init(index: SearchIndex, claude: ClaudeService, kordoc: KordocService); func ask(question: String, expandQuery: Bool) async -> RagOutcome }`

**흐름:** ① `expandQuery`면 Claude로 확장(실패 시 `[]`) → ② 검색 top-N → 0건이면 `.noEvidence` → ③ 공용 `terms`(질문 토큰+확장)로 각 파일 패시지 → 0건이면 `.noEvidence` → ④ 컨텍스트/프롬프트 → `claude.ask`. 실패는 `.failed`.

- [ ] **Step 1: 실패하는 테스트 작성**

`Tests/CmdMDTests/RagServiceTests.swift`:
```swift
import XCTest
@testable import CmdMD

final class RagServiceTests: XCTestCase {
    /// 빈 인덱스 + 확장 OFF → Claude를 호출하지 않고 .noEvidence(오프라인 결정성).
    func testEmptyIndexReturnsNoEvidenceWithoutNetwork() async {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmddocu-rag-\(UUID().uuidString)").appendingPathExtension("sqlite")
        let idx = SearchIndex(dbURL: url)
        let svc = RagService(index: idx, claude: ClaudeService(), kordoc: KordocService())
        let outcome = await svc.ask(question: "존재하지 않는 질의 xyzzy", expandQuery: false)
        if case .noEvidence = outcome { } else { XCTFail("expected .noEvidence, got \(outcome)") }
    }
}
```

- [ ] **Step 2: 테스트 실패 확인**

Run: `swift test --filter RagServiceTests`
Expected: FAIL — "cannot find 'RagService' in scope".

- [ ] **Step 3: 최소 구현**

`Sources/Services/RagService.swift`:
```swift
import Foundation

/// 자료에 묻기(RAG) 오케스트레이션: 확장→검색→패시지→컨텍스트→Claude.
/// 근거가 0건이면 Claude를 호출하지 않는다(무근거 생성 차단·크레딧 절약).
actor RagService {
    private let index: SearchIndex
    private let claude: ClaudeService
    private let kordoc: KordocService

    init(index: SearchIndex, claude: ClaudeService, kordoc: KordocService) {
        self.index = index
        self.claude = claude
        self.kordoc = kordoc
    }

    struct Answer: Equatable { let text: String; let sources: [RagSource] }
    enum RagOutcome { case answered(Answer); case noEvidence; case failed(ClaudeError) }

    func ask(question: String, expandQuery: Bool) async -> RagOutcome {
        // ① 확장(옵션). 실패해도 원질문만으로 진행.
        var expanded: [String] = []
        if expandQuery,
           let out = try? await claude.ask(prompt: RagQueryExpansion.prompt(), context: question) {
            expanded = RagQueryExpansion.parse(out)
        }

        // ② 검색.
        let paths = await RagRetriever(index: index).topFiles(question: question, expandedTerms: expanded)
        guard !paths.isEmpty else { return .noEvidence }

        // ③ 검색·하이라이트 공용 terms = 질문 토큰 + 확장.
        let terms = dedupedTerms(question: question, expanded: expanded)
        var keptPaths: [String] = []
        var passages: [RagPassageExtractor.Passage] = []
        for p in paths {
            if let passage = await RagPassageExtractor.passage(
                for: URL(fileURLWithPath: p), terms: terms, kordoc: kordoc) {
                keptPaths.append(p)
                passages.append(passage)
            }
        }
        guard !passages.isEmpty else { return .noEvidence }

        // ④ 컨텍스트 + 프롬프트 → Claude.
        let built = RagContextBuilder.build(paths: keptPaths, passages: passages)
        do {
            let text = try await claude.ask(
                prompt: RagPromptBuilder.prompt(question: question), context: built.context)
            return .answered(Answer(text: text, sources: built.sources))
        } catch let e as ClaudeError {
            return .failed(e)
        } catch {
            return .failed(.failed(error.localizedDescription))
        }
    }

    private func dedupedTerms(question: String, expanded: [String]) -> [String] {
        let tokens = question.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).map(String.init)
        var seen = Set<String>()
        var out: [String] = []
        for t in tokens + expanded {
            let k = t.lowercased()
            guard !t.isEmpty, !seen.contains(k) else { continue }
            seen.insert(k); out.append(t)
        }
        return out
    }
}
```

- [ ] **Step 4: 테스트 통과 확인**

Run: `swift test --filter RagServiceTests`
Expected: PASS (1 test).

(참고: 실제 답변 생성 경로는 claude·kordoc 실행이 필요해 Task 11 스모크에서 수동 검증.)

- [ ] **Step 5: 커밋**

```bash
git add Sources/Services/RagService.swift Tests/CmdMDTests/RagServiceTests.swift
git commit -m "기능(RAG): RagService(확장→검색→패시지→Claude, 근거0=미호출) + 테스트"
```

---

### Task 10: AppState 배선 (상태·runRagQuery·openRagSource)

**Files:**
- Modify: `Sources/App/AppState.swift`
  - 인스턴스: 157–159행 `searchIndexer`/`folderWatcher` 인접에 `ragService` 선언, 617행(`self.searchIndexer = ...`) 다음에 초기화.
  - 상태: 111행 `showIndexSearch` 인접에 RAG 상태.
  - 메서드: `openIndexHit`(1111행) 인접에 `runRagQuery()`/`openRagSource(_:)`.
- Test: `Tests/CmdMDTests/AppAskCorpusTests.swift`

**Interfaces:**
- Consumes: `RagService`(Task 9), `RagSource`/`RagLocation`(Task 1), `settings.ragExpandQuery`(Task 8), 기존 `openDocument(at:inNewTab:scrollToLine:scrollToPDFPage:)`, `AppState.claudeErrorMessage(_:)`(static).
- Produces: `var showAskCorpus`, `var ragQuestion`, `var ragAnswer: String?`, `var ragSources: [RagSource]`, `var ragBusy`, `var ragMessage: String?`, `func runRagQuery() async`, `func openRagSource(_:)`.

- [ ] **Step 1: 실패하는 테스트 작성**

`Tests/CmdMDTests/AppAskCorpusTests.swift`:
```swift
import XCTest
@testable import CmdMD

final class AppAskCorpusTests: XCTestCase {
    @MainActor
    func testAskCorpusStateDefaults() {
        let dir = TempDataDirectory.make(); defer { TempDataDirectory.cleanup(dir) }
        let app = AppState(dataDirectory: dir)
        XCTAssertFalse(app.showAskCorpus)
        XCTAssertNil(app.ragAnswer)
        XCTAssertTrue(app.ragSources.isEmpty)
        XCTAssertFalse(app.ragBusy)
    }

    @MainActor
    func testRunRagQueryNoEvidenceOnEmptyIndex() async {
        let dir = TempDataDirectory.make(); defer { TempDataDirectory.cleanup(dir) }
        let app = AppState(dataDirectory: dir)
        app.settings.ragExpandQuery = false            // 오프라인 결정성: 확장 Claude 호출 안 함
        app.ragQuestion = "존재하지 않는 질의 xyzzy"
        await app.runRagQuery()
        XCTAssertFalse(app.ragBusy)
        XCTAssertNil(app.ragAnswer)
        XCTAssertTrue(app.ragSources.isEmpty)
        XCTAssertEqual(app.ragMessage, "자료에서 관련 내용을 찾지 못했습니다.")
    }
}
```

- [ ] **Step 2: 테스트 실패 확인**

Run: `swift test --filter AppAskCorpusTests`
Expected: FAIL — "value of type 'AppState' has no member 'showAskCorpus'".

- [ ] **Step 3: 최소 구현**

`Sources/App/AppState.swift` — 인스턴스 선언(159행 `folderWatcher` 다음):
```swift
    private let ragService: RagService
```
init 안(617행 `self.searchIndexer = SearchIndexer(index: idx, kordoc: kordocService)` 다음):
```swift
        self.ragService = RagService(index: idx, claude: claudeService, kordoc: kordocService)
```
RAG 상태(111행 `var showIndexSearch: Bool = false` 인접):
```swift
    // MARK: 자료에 묻기(RAG)
    var showAskCorpus: Bool = false
    var ragQuestion: String = ""
    var ragAnswer: String? = nil
    var ragSources: [RagSource] = []
    var ragBusy: Bool = false
    var ragMessage: String? = nil   // noEvidence·에러 안내
```
메서드(`openIndexHit`(1111–1115행) 다음):
```swift
    /// 자료에 묻기(RAG) 실행. 근거 없으면 안내, 성공하면 답변+출처를 채운다.
    @MainActor
    func runRagQuery() async {
        let q = ragQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        ragBusy = true
        ragAnswer = nil
        ragSources = []
        ragMessage = nil
        let outcome = await ragService.ask(question: q, expandQuery: settings.ragExpandQuery)
        ragBusy = false
        switch outcome {
        case .answered(let a):
            ragAnswer = a.text
            ragSources = a.sources
        case .noEvidence:
            ragMessage = "자료에서 관련 내용을 찾지 못했습니다."
        case .failed(let e):
            ragMessage = AppState.claudeErrorMessage(e)
        }
    }

    /// 근거 출처를 그 위치(줄/페이지)로 연다.
    @MainActor
    func openRagSource(_ source: RagSource) {
        showAskCorpus = false
        let url = URL(fileURLWithPath: source.path)
        switch source.location {
        case .line(let n): openDocument(at: url, inNewTab: true, scrollToLine: n)
        case .page(let p): openDocument(at: url, inNewTab: true, scrollToPDFPage: p)
        case .unknown: openDocument(at: url, inNewTab: true)
        }
    }
```

- [ ] **Step 4: 테스트 통과 확인**

Run: `swift test --filter AppAskCorpusTests`
Expected: PASS (2 tests).

- [ ] **Step 5: 커밋**

```bash
git add Sources/App/AppState.swift Tests/CmdMDTests/AppAskCorpusTests.swift
git commit -m "기능(RAG): AppState 배선(ragService·상태·runRagQuery·openRagSource) + 격리 테스트"
```

---

### Task 11: UI — AskCorpusView + 시트/팔레트 진입점

**Files:**
- Create: `Sources/Views/AskCorpusView.swift`
- Modify: `Sources/Views/ContentView.swift` (80행 `.sheet(...showOmnisearch...)` 인접에 시트 추가)
- Modify: `Sources/Views/CommandPaletteView.swift` (269행 "내용 검색 (인덱스)" 항목 다음에 팔레트 항목 추가)

**Interfaces:**
- Consumes: `AppState`의 `showAskCorpus`/`ragQuestion`/`ragAnswer`/`ragSources`/`ragBusy`/`ragMessage`/`settings.ragExpandQuery`/`runRagQuery()`/`openRagSource(_:)`, `RagSource`/`RagLocation`.

이 태스크는 UI라 단위테스트 대신 **빌드 통과 + 수동 스모크**로 검증한다.

- [ ] **Step 1: AskCorpusView 작성**

`Sources/Views/AskCorpusView.swift`:
```swift
import SwiftUI

/// 등록 인덱스 폴더를 근거로 질문하고 Claude 답변 + 출처 점프를 보여주는 시트.
struct AskCorpusView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("자료에 묻기").font(.headline)
                Spacer()
                Toggle("질의 확장", isOn: $state.settings.ragExpandQuery)
                    .toggleStyle(.switch).controlSize(.small)
                    .onChange(of: state.settings.ragExpandQuery) { _, _ in appState.saveUserData() }
                Button("닫기") { state.showAskCorpus = false }
            }
            Text("등록한 인덱스 폴더의 근거가 Claude로 전송됩니다.")
                .font(.caption).foregroundStyle(.secondary)

            TextField("질문을 입력하세요 (⌘↩)", text: $state.ragQuestion, axis: .vertical)
                .lineLimit(2...5)
                .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                Button("질문 (⌘↩)") { Task { await appState.runRagQuery() } }
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(appState.ragBusy
                        || appState.ragQuestion.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            Divider()
            content
            Spacer()
        }
        .padding(16)
        .frame(width: 560, height: 600)
    }

    @ViewBuilder private var content: some View {
        if appState.ragBusy {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("자료에서 찾아 Claude에게 묻는 중…").foregroundStyle(.secondary)
            }
        } else if let msg = appState.ragMessage {
            Text(msg).foregroundStyle(.secondary)
        } else if let answer = appState.ragAnswer {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(answer).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if !appState.ragSources.isEmpty {
                        Text("근거").font(.subheadline).bold()
                        ForEach(appState.ragSources) { src in
                            Button { appState.openRagSource(src) } label: {
                                HStack(alignment: .top, spacing: 8) {
                                    Text("[\(src.index)]").font(.caption).monospaced()
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(URL(fileURLWithPath: src.path).lastPathComponent
                                             + locationLabel(src.location))
                                            .font(.caption).bold()
                                        Text(src.snippet).font(.caption)
                                            .foregroundStyle(.secondary).lineLimit(2)
                                    }
                                    Spacer()
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        } else {
            Text("등록한 폴더(인덱스)를 근거로 질문하면 출처와 함께 답합니다.\n인덱스 폴더가 없으면 '내용 검색'에서 먼저 폴더를 등록하세요.")
                .foregroundStyle(.secondary).font(.callout)
        }
    }

    private func locationLabel(_ loc: RagLocation) -> String {
        switch loc {
        case .line(let n): return " (줄 \(n))"
        case .page(let p): return " (p.\(p))"
        case .unknown: return ""
        }
    }
}
```

- [ ] **Step 2: ContentView에 시트 추가**

`Sources/Views/ContentView.swift` — 80행 `.sheet(isPresented: $state.showOmnisearch) { OmnisearchView() }` 다음에:
```swift
        .sheet(isPresented: $state.showAskCorpus) {
            AskCorpusView()
        }
```

- [ ] **Step 3: 커맨드 팔레트 항목 추가**

`Sources/Views/CommandPaletteView.swift` — 269–270행 "내용 검색 (인덱스)" `Command` 블록 다음(`폴더 정리` 항목 앞)에:
```swift
            Command(
                title: "자료에 묻기 (RAG)",
                subtitle: "등록 폴더를 근거로 Claude가 답하고 출처를 표시",
                icon: "text.magnifyingglass",
                shortcut: nil,
                keywords: ["자료", "질문", "묻기", "rag", "ask", "claude", "근거", "출처"]
            ) {
                appState.showAskCorpus = true
            },
```

- [ ] **Step 4: 빌드 + 전체 테스트 확인**

Run: `swift build`
Expected: 빌드 성공(에러 없음).

Run: `swift test`
Expected: 기존 277개 + 신규(Task 1–10) 전부 PASS.

- [ ] **Step 5: 수동 스모크(문서화)**

앱 실행 후 확인(불가 환경이면 결과를 커밋 메시지/보고에 남긴다):
1. ⌘K → "자료에 묻기 (RAG)" → 시트 열림. (인덱스 폴더 미등록이면 안내 문구 표시.)
2. notebox 폴더를 인덱스에 등록한 뒤 "지방선거 평가 정리해줘" 질문 → 로딩 후 답변 + 근거 [n] 목록.
3. text/md 근거 칩 클릭 → 그 파일이 그 줄로 열림. PDF 근거는 페이지 점프. `/Users/ahbaik/Downloads/제9회_전국동시지방선거_정의당_평가서.hwp`가 든 폴더면 office 근거는 파일만 열림(위치 unknown).
4. 질의 확장 토글 OFF 후 재질문 → 확장 없이 동작.

- [ ] **Step 6: 커밋**

```bash
git add Sources/Views/AskCorpusView.swift Sources/Views/ContentView.swift Sources/Views/CommandPaletteView.swift
git commit -m "기능(RAG): AskCorpusView + 시트/커맨드팔레트 진입점"
```

---

## 마무리 (플랜 종료 후)

- [ ] `swift test` 전체 재확인(277 + 신규). CLAUDE.md의 Phase 9 완료 기록 갱신.
- [ ] main 머지·origin 푸시(PR)·옵시디언 데일리 로그 — 개발 워크플로 대로.

## Self-Review (작성자 점검 결과)

**Spec 커버리지:** 스펙 3.1~3.11·4·5 전 항목이 Task 1~11에 매핑됨 — 모델(T1), searchMatch(T2), 확장(T3), 검색병합(T4), 패시지(T5), 컨텍스트(T6), 프롬프트(T7), 설정(T8), 서비스(T9), 배선(T10), UI(T11). 에러·안전(§4)은 T9(근거0=미호출)·T10(claudeErrorMessage)·T11(전송 안내)로 반영.

**플레이스홀더:** 없음 — 모든 코드/테스트 블록 실코드. "확인 필요"였던 PDF 페이지 점프는 코드로 확정(`openDocument(...scrollToPDFPage:)` 802/759행)해 해소.

**타입 일관성:** `RagLocation`(.line/.page/.unknown), `Passage{text,location}`, `Built{context,sources}`, `RagOutcome{answered,noEvidence,failed}`, `RagSource{index,path,snippet,location}`가 T1·T5·T6·T9·T10에서 동일 시그니처로 소비됨. `ClaudeService.ask(prompt:context:)`·`openDocument(at:inNewTab:scrollToLine:scrollToPDFPage:)`·`ContentExtractor.localBody`/`.body(for:kordoc:)`·`SearchIndex.search`/`.searchMatch`는 실제 코드와 대조 확인. `AppState.claudeErrorMessage`는 static(424행) — `AppState.claudeErrorMessage(e)`로 호출.
