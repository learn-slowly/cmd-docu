# LLM-Wiki 단일 문서 인제스트 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 파일 하나(주로 PDF)를 골라 사용자가 지정한 위키 페이지(md)에 Claude가 병합한 갱신 전문을 생성하고, 줄 diff 승인 → 백업 → 덮어쓰기로 적용한다.

**Architecture:** 순수 헬퍼(`WikiIngestModels`·`LineDiff`) 위에 actor 2개(`WikiIngestService`=제안 생성만, `WikiBackupStore`=백업·복원)를 두고, AppState가 시트 상태·적용을 배선한다. Claude 결과는 diff 승인 전까지 디스크에 닿지 않는다(제안→확인→실행). 기존 `ContentExtractor`·`ClaudeAsking`·`CleanupPlanner.sanitizeBucketName`·`uniquified()`를 재사용한다.

**Tech Stack:** Swift 5.9 / SwiftUI / XCTest. 새 패키지 의존성 0.

**스펙:** `docs/superpowers/specs/2026-07-06-wiki-ingest-design.md` (승인됨 2026-07-06)

## Global Constraints

- macOS 14+ / Swift 5.9+ / SPM. 비샌드박스 유지. 새 패키지 의존성 금지.
- 코드 주석·커밋 메시지는 한국어. '박다/박는다/박았다' 계열 어휘 금지.
- 신규 기능은 별도 파일로 분리(업스트림 머지 용이성). 이 계획의 지정 파일 밖 수정 금지.
- **제안→확인→실행**: Claude 결과는 승인 전 디스크 접근 금지. 원본 소스 파일 불변. 삭제 없음(복원의 새 페이지 제거도 휴지통).
- 크기 한도(스펙 §2.1 — 정확값): 소스 발췌 12,000자, 대상 페이지 24,000자.
- 테스트 게이트: `swift test` 전체 GREEN(기준 661 = XCTest 643 + Testing 18, 신규만큼 증가). swift test엔 정식 Xcode 필요.
- 커밋 트레일러 2줄(저장소 관례):
  `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`
  `Claude-Session: https://claude.ai/code/session_01NJAwrLizMG4WbpBfCfxj7J`

---

### Task 1: WikiIngestModels (순수 — 대상·프롬프트·응답 검증·한도)

**Files:**
- Create: `Sources/Services/WikiIngestModels.swift`
- Test: `Tests/CmdMDTests/WikiIngestModelsTests.swift`

**Interfaces:**
- Consumes: `CleanupPlanner.sanitizeBucketName(_:) -> String`(`Sources/Services/CleanupPlanner.swift:24`), `URL.uniquified()`(`Sources/App/AppState.swift` 파일 끝 extension).
- Produces(후속 태스크가 사용):
  - `enum WikiIngestTarget: Equatable { case existing(URL); case new(name: String) }`
  - `struct WikiMergeProposal: Equatable { let pageURL: URL; let isNewPage: Bool; let oldBody: String; let newBody: String; let sourceURL: URL }`
  - `enum WikiIngestModels`: `sourceExcerptLimit = 12_000`, `pageBodyLimit = 24_000`, `newPageURL(name:wikiFolder:) -> URL?`, `truncatedExcerpt(_:) -> (text: String, truncated: Bool)`, `mergePrompt(pageTitle:pageBody:sourceName:sourceExcerpt:excerptTruncated:isNewPage:today:) -> (prompt: String, context: String)`, `extractMarkdown(from:oldBodyLength:) -> String?`

- [ ] **Step 1: 실패하는 테스트 작성**

`Tests/CmdMDTests/WikiIngestModelsTests.swift`:

```swift
import XCTest
@testable import CmdMD

/// 위키 인제스트 순수 헬퍼 — 대상 URL·프롬프트 계약·응답 검증·크기 한도(스펙 §2.1).
final class WikiIngestModelsTests: XCTestCase {
    var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = TempDataDirectory.make()
    }
    override func tearDown() {
        TempDataDirectory.cleanup(tempDir)
        super.tearDown()
    }

    // MARK: - newPageURL

    func testNewPageURLSanitizesAndAppendsMd() {
        let url = WikiIngestModels.newPageURL(name: "미디어/이론: 개요", wikiFolder: tempDir)
        XCTAssertEqual(url?.lastPathComponent, "미디어-이론- 개요.md")
        XCTAssertEqual(url?.deletingLastPathComponent().path, tempDir.path)
    }

    func testNewPageURLRejectsEmptyAfterSanitize() {
        XCTAssertNil(WikiIngestModels.newPageURL(name: "///", wikiFolder: tempDir))
        XCTAssertNil(WikiIngestModels.newPageURL(name: "  ", wikiFolder: tempDir))
    }

    func testNewPageURLUniquifiesOnCollision() throws {
        let taken = tempDir.appendingPathComponent("주제.md")
        try "x".write(to: taken, atomically: true, encoding: .utf8)
        let url = WikiIngestModels.newPageURL(name: "주제", wikiFolder: tempDir)
        XCTAssertEqual(url?.lastPathComponent, "주제 (1).md")
    }

    func testNewPageURLBlocksPathEscape() {
        // sanitize가 구분자·".."을 제거하므로 결과는 항상 wikiFolder 직속이어야 한다.
        let url = WikiIngestModels.newPageURL(name: "../밖", wikiFolder: tempDir)
        XCTAssertEqual(url?.deletingLastPathComponent().standardizedFileURL.path,
                       tempDir.standardizedFileURL.path)
    }

    // MARK: - truncatedExcerpt

    func testExcerptUnderLimitPassesThrough() {
        let r = WikiIngestModels.truncatedExcerpt("짧은 본문")
        XCTAssertEqual(r.text, "짧은 본문")
        XCTAssertFalse(r.truncated)
    }

    func testExcerptOverLimitTruncates() {
        let long = String(repeating: "가", count: WikiIngestModels.sourceExcerptLimit + 100)
        let r = WikiIngestModels.truncatedExcerpt(long)
        XCTAssertEqual(r.text.count, WikiIngestModels.sourceExcerptLimit)
        XCTAssertTrue(r.truncated)
    }

    // MARK: - mergePrompt

    func testMergePromptContainsSchemaRules() {
        let (prompt, context) = WikiIngestModels.mergePrompt(
            pageTitle: "미디어 이론", pageBody: "# 미디어 이론\n\n기존 내용.",
            sourceName: "논문.pdf", sourceExcerpt: "새 자료 본문",
            excerptTruncated: false, isNewPage: false, today: "2026-07-06")
        XCTAssertTrue(prompt.contains("마크다운 전문만"))
        XCTAssertTrue(prompt.contains("sources"))
        XCTAssertTrue(prompt.contains("논문.pdf (2026-07-06)"))
        XCTAssertTrue(prompt.contains("유실"))
        XCTAssertTrue(prompt.contains("한국어"))
        XCTAssertFalse(prompt.contains("발췌본"))          // truncated=false면 발췌 고지 없음
        XCTAssertTrue(context.contains("[위키 페이지: 미디어 이론]"))
        XCTAssertTrue(context.contains("기존 내용."))
        XCTAssertTrue(context.contains("[새 자료: 논문.pdf]"))
        XCTAssertTrue(context.contains("새 자료 본문"))
    }

    func testMergePromptNewPageAndTruncatedNotices() {
        let (prompt, context) = WikiIngestModels.mergePrompt(
            pageTitle: "새주제", pageBody: "",
            sourceName: "자료.pdf", sourceExcerpt: "발췌",
            excerptTruncated: true, isNewPage: true, today: "2026-07-06")
        XCTAssertTrue(prompt.contains("새 페이지"))
        XCTAssertTrue(prompt.contains("# 새주제"))
        XCTAssertTrue(prompt.contains("발췌본"))
        XCTAssertTrue(context.contains("(새 페이지 — 본문 없음)"))
    }

    // MARK: - extractMarkdown

    func testExtractStripsWholeCodeFence() {
        let out = "```markdown\n---\nupdated: 2026-07-06\n---\n# 제목\n본문\n```"
        XCTAssertEqual(WikiIngestModels.extractMarkdown(from: out, oldBodyLength: 0),
                       "---\nupdated: 2026-07-06\n---\n# 제목\n본문")
    }

    func testExtractDropsPreambleBeforeFrontmatter() {
        let out = "네, 갱신된 페이지입니다.\n---\nupdated: x\n---\n# 제목\n본문"
        XCTAssertEqual(WikiIngestModels.extractMarkdown(from: out, oldBodyLength: 0),
                       "---\nupdated: x\n---\n# 제목\n본문")
    }

    func testExtractDropsPreambleBeforeHeading() {
        let out = "설명 한 줄\n# 제목\n본문"
        XCTAssertEqual(WikiIngestModels.extractMarkdown(from: out, oldBodyLength: 0), "# 제목\n본문")
    }

    func testExtractPassesCleanBodyThrough() {
        let body = "---\na: b\n---\n# 제목\n본문"
        XCTAssertEqual(WikiIngestModels.extractMarkdown(from: body, oldBodyLength: 0), body)
    }

    func testExtractRejectsEmpty() {
        XCTAssertNil(WikiIngestModels.extractMarkdown(from: "   \n  ", oldBodyLength: 0))
    }

    func testExtractRejectsSevereShrinkOnExistingPage() {
        // 기존 1000자 페이지가 100자로 축소 — 유실 방어(스펙 §2.1: 40% 미만 거부)
        let small = "# 짧음\n" + String(repeating: "a", count: 90)
        XCTAssertNil(WikiIngestModels.extractMarkdown(from: small, oldBodyLength: 1000))
        // 새 페이지(기존 0자)엔 미적용
        XCTAssertNotNil(WikiIngestModels.extractMarkdown(from: small, oldBodyLength: 0))
    }
}
```

- [ ] **Step 2: 실패 확인**

Run: `swift test --filter WikiIngestModelsTests 2>&1 | tail -5`
Expected: 컴파일 실패(`WikiIngestModels` 미존재) — 신규 API라 RED로 인정.

- [ ] **Step 3: 구현**

`Sources/Services/WikiIngestModels.swift`:

```swift
import Foundation

/// 위키 인제스트 병합 대상 — 기존 페이지 또는 새 페이지 이름(스펙 §2.1).
enum WikiIngestTarget: Equatable {
    case existing(URL)
    case new(name: String)
}

/// Claude 병합 제안 — 승인 전까지 디스크에 닿지 않는 순수 값(제안→확인→실행).
struct WikiMergeProposal: Equatable {
    let pageURL: URL        // 최종 쓰기 대상(existing 경로 또는 new의 uniquified 경로)
    let isNewPage: Bool
    let oldBody: String     // 기존 전문(새 페이지면 "")
    let newBody: String     // Claude 갱신 전문
    let sourceURL: URL
}

/// 위키 인제스트 순수 헬퍼 — 대상 URL·병합 프롬프트(페이지 스키마 내장)·응답 검증·크기 한도.
enum WikiIngestModels {
    /// 소스 발췌 한도 — 출력이 아니라 입력 절단(RagContextBuilder 12k 전례).
    static let sourceExcerptLimit = 12_000
    /// 대상 페이지 한도 — 출력=페이지 전문이라 이 값이 곧 출력 상한(타임아웃 방어, 폴더 정리 교훈).
    static let pageBodyLimit = 24_000

    /// 새 페이지 파일 URL. 이름 정제(구분자·".." 제거)는 CleanupPlanner 정책 재사용,
    /// 충돌은 uniquified(). 정제 결과가 비면 nil — 항상 wikiFolder 직속(경로탈출 불가).
    static func newPageURL(name: String, wikiFolder: URL) -> URL? {
        let cleaned = CleanupPlanner.sanitizeBucketName(name)
        guard !cleaned.isEmpty else { return nil }
        return wikiFolder.appendingPathComponent(cleaned + ".md").uniquified()
    }

    static func truncatedExcerpt(_ body: String) -> (text: String, truncated: Bool) {
        guard body.count > sourceExcerptLimit else { return (body, false) }
        return (String(body.prefix(sourceExcerptLimit)), true)
    }

    /// 병합 프롬프트 — 규칙(=앱 안의 페이지 스키마)은 prompt에, 본문들은 context(stdin)에.
    static func mergePrompt(pageTitle: String, pageBody: String,
                            sourceName: String, sourceExcerpt: String,
                            excerptTruncated: Bool, isNewPage: Bool,
                            today: String) -> (prompt: String, context: String) {
        var rules = """
        당신은 개인 지식 위키의 사서다. 아래 [위키 페이지]에 [새 자료]의 내용을 병합해, \
        갱신된 페이지 전문을 출력하라.

        규칙:
        1. 출력은 갱신된 페이지의 마크다운 전문만 쓴다. 서문·설명·코드펜스로 감싸기 금지.
        2. 페이지 맨 위 YAML frontmatter를 유지·갱신한다(없으면 만든다). updated: \(today), \
        sources 목록에는 기존 항목을 전부 보존하고 "- \(sourceName) (\(today))" 항목을 추가한다.
        3. 기존 페이지의 정보를 유실하지 말 것 — 재구성·중복 제거는 허용, 내용 삭제는 금지.
        4. 새 자료의 핵심(요약·개념·근거)을 페이지 구조에 녹여 넣고, 필요하면 섹션을 신설한다.
        5. sources에 이미 있는 자료가 다시 오면 중복 서술을 만들지 말고 해당 부분을 갱신만 한다.
        6. 위키 본문은 한국어로 쓴다(자료가 외국어여도).
        """
        if isNewPage {
            rules += "\n7. 이 페이지는 새 페이지다. \"# \(pageTitle)\" 헤딩으로 시작해 새 자료의 요약으로 구성하라."
        }
        if excerptTruncated {
            rules += "\n주의: [새 자료]는 앞부분 발췌본이다."
        }
        let context = """
        [위키 페이지: \(pageTitle)]
        \(pageBody.isEmpty ? "(새 페이지 — 본문 없음)" : pageBody)

        [새 자료: \(sourceName)]
        \(sourceExcerpt)
        """
        return (rules, context)
    }

    /// 응답에서 페이지 전문을 추출·검증한다. 실패(빈 값·기존 대비 40% 미만 급축소)는 nil —
    /// 유실 방어 1차(최종 방어는 diff 승인). 새 페이지(oldBodyLength 0)엔 축소 검증 미적용.
    static func extractMarkdown(from stdout: String, oldBodyLength: Int) -> String? {
        var text = stdout.trimmingCharacters(in: .whitespacesAndNewlines)

        // 전체가 코드펜스로 감싸인 응답 벗기기(```markdown … ```).
        let lines = text.components(separatedBy: "\n")
        if lines.count >= 2, lines[0].hasPrefix("```"),
           lines[lines.count - 1].trimmingCharacters(in: .whitespaces) == "```" {
            text = lines.dropFirst().dropLast().joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // 서문 제거 — frontmatter("---") 또는 첫 헤딩("#") 시작 전 잡담을 걷어낸다.
        if !text.hasPrefix("---") && !text.hasPrefix("#") {
            if let r = text.range(of: "\n---\n") {
                text = String(text[text.index(after: r.lowerBound)...])
            } else if let r = text.range(of: "\n#") {
                text = String(text[text.index(after: r.lowerBound)...])
            }
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !text.isEmpty else { return nil }
        if oldBodyLength > 0, text.count < oldBodyLength * 40 / 100 { return nil }
        return text
    }
}
```

- [ ] **Step 4: 통과 확인**

Run: `swift test --filter WikiIngestModelsTests 2>&1 | tail -3`
Expected: `Executed 13 tests, with 0 failures`
주의: `testNewPageURLSanitizesAndAppendsMd`의 기대 파일명은 `sanitizeBucketName` 실동작(구분자→"-" 치환)을 따른다 — 구현 후 실값과 다르면 **기대값을 실동작에 맞춰 수정**하고 주석으로 남긴다(정책 원본은 CleanupPlanner).

- [ ] **Step 5: 커밋**

```bash
git add Sources/Services/WikiIngestModels.swift Tests/CmdMDTests/WikiIngestModelsTests.swift
git commit -m "기능(위키): 인제스트 순수 헬퍼 — 대상 URL·병합 프롬프트(페이지 스키마)·응답 검증·크기 한도 (스펙 §2.1)"
```

---

### Task 2: LineDiff (순수 — LCS 줄 diff)

**Files:**
- Create: `Sources/Services/LineDiff.swift`
- Test: `Tests/CmdMDTests/LineDiffTests.swift`

**Interfaces:**
- Consumes: 없음(독립).
- Produces: `enum LineDiff` — `enum Kind: Equatable { case same, added, removed }`, `struct Line: Equatable { let kind: Kind; let text: String }`, `static func diff(old: String, new: String) -> [Line]`.

- [ ] **Step 1: 실패하는 테스트 작성**

`Tests/CmdMDTests/LineDiffTests.swift`:

```swift
import XCTest
@testable import CmdMD

/// LCS 줄 diff — 위키 병합 미리보기 렌더용(스펙 §2.2).
final class LineDiffTests: XCTestCase {
    private func kinds(_ lines: [LineDiff.Line]) -> [LineDiff.Kind] { lines.map(\.kind) }

    func testIdenticalIsAllSame() {
        let r = LineDiff.diff(old: "a\nb", new: "a\nb")
        XCTAssertEqual(kinds(r), [.same, .same])
    }

    func testAddedLine() {
        let r = LineDiff.diff(old: "a\nc", new: "a\nb\nc")
        XCTAssertEqual(r, [
            LineDiff.Line(kind: .same, text: "a"),
            LineDiff.Line(kind: .added, text: "b"),
            LineDiff.Line(kind: .same, text: "c"),
        ])
    }

    func testRemovedLine() {
        let r = LineDiff.diff(old: "a\nb\nc", new: "a\nc")
        XCTAssertEqual(r, [
            LineDiff.Line(kind: .same, text: "a"),
            LineDiff.Line(kind: .removed, text: "b"),
            LineDiff.Line(kind: .same, text: "c"),
        ])
    }

    func testChangedLineIsRemovePlusAdd() {
        let r = LineDiff.diff(old: "a\nX\nc", new: "a\nY\nc")
        XCTAssertEqual(kinds(r), [.same, .removed, .added, .same])
    }

    func testEmptyOldIsAllAdded() {
        let r = LineDiff.diff(old: "", new: "a\nb")
        XCTAssertEqual(kinds(r), [.added, .added])
    }

    func testEmptyNewIsAllRemoved() {
        let r = LineDiff.diff(old: "a\nb", new: "")
        XCTAssertEqual(kinds(r), [.removed, .removed])
    }

    func testWholeReplacement() {
        let r = LineDiff.diff(old: "x\ny", new: "p\nq")
        XCTAssertEqual(kinds(r).filter { $0 == .removed }.count, 2)
        XCTAssertEqual(kinds(r).filter { $0 == .added }.count, 2)
        XCTAssertEqual(kinds(r).filter { $0 == .same }.count, 0)
    }
}
```

- [ ] **Step 2: 실패 확인**

Run: `swift test --filter LineDiffTests 2>&1 | tail -5`
Expected: 컴파일 실패(`LineDiff` 미존재).

- [ ] **Step 3: 구현**

`Sources/Services/LineDiff.swift`:

```swift
import Foundation

/// LCS 기반 줄 diff — 위키 병합 diff 미리보기용. 페이지 한도 24k자(수백 줄) 규모라
/// O(n·m) DP로 충분하다(스펙 §2.2).
enum LineDiff {
    enum Kind: Equatable { case same, added, removed }
    struct Line: Equatable {
        let kind: Kind
        let text: String
    }

    static func diff(old: String, new: String) -> [Line] {
        let a = old.isEmpty ? [] : old.components(separatedBy: "\n")
        let b = new.isEmpty ? [] : new.components(separatedBy: "\n")

        var dp = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
        if !a.isEmpty && !b.isEmpty {
            for i in stride(from: a.count - 1, through: 0, by: -1) {
                for j in stride(from: b.count - 1, through: 0, by: -1) {
                    dp[i][j] = a[i] == b[j] ? dp[i + 1][j + 1] + 1 : max(dp[i + 1][j], dp[i][j + 1])
                }
            }
        }

        var out: [Line] = []
        var i = 0, j = 0
        while i < a.count && j < b.count {
            if a[i] == b[j] {
                out.append(Line(kind: .same, text: a[i])); i += 1; j += 1
            } else if dp[i + 1][j] >= dp[i][j + 1] {
                out.append(Line(kind: .removed, text: a[i])); i += 1
            } else {
                out.append(Line(kind: .added, text: b[j])); j += 1
            }
        }
        while i < a.count { out.append(Line(kind: .removed, text: a[i])); i += 1 }
        while j < b.count { out.append(Line(kind: .added, text: b[j])); j += 1 }
        return out
    }
}
```

- [ ] **Step 4: 통과 확인**

Run: `swift test --filter LineDiffTests 2>&1 | tail -3`
Expected: `Executed 7 tests, with 0 failures`

- [ ] **Step 5: 커밋**

```bash
git add Sources/Services/LineDiff.swift Tests/CmdMDTests/LineDiffTests.swift
git commit -m "기능(위키): LineDiff — LCS 줄 diff(병합 미리보기 렌더용)"
```

---

### Task 3: WikiBackupStore (actor — 백업·기록·복원)

**Files:**
- Create: `Sources/Services/WikiBackupStore.swift`
- Test: `Tests/CmdMDTests/WikiBackupStoreTests.swift`

**Interfaces:**
- Consumes: `FileOperations.trash(at:) throws -> URL`(`Sources/Services/FileOperations.swift:66`), `URL.uniquified()`.
- Produces:
  - `struct WikiIngestLogEntry: Codable, Identifiable, Equatable { let id: UUID; let pageURL: URL; let backupFile: String?; let sourceName: String; let date: Date }`
  - `actor WikiBackupStore`: `init(directory: URL)`, `func recordApply(pageURL: URL, oldBody: String?, sourceName: String) throws -> WikiIngestLogEntry`, `func allEntries() -> [WikiIngestLogEntry]`(최신순), `func restore(_ entry: WikiIngestLogEntry) throws`

- [ ] **Step 1: 실패하는 테스트 작성**

`Tests/CmdMDTests/WikiBackupStoreTests.swift`:

```swift
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
}
```

- [ ] **Step 2: 실패 확인**

Run: `swift test --filter WikiBackupStoreTests 2>&1 | tail -5`
Expected: 컴파일 실패(`WikiBackupStore` 미존재).

- [ ] **Step 3: 구현**

`Sources/Services/WikiBackupStore.swift`:

```swift
import Foundation

/// 위키 인제스트 적용 기록 한 건. backupFile은 wiki-backups/ 안 파일명 — 새 페이지
/// 생성이면 nil(복원 = 휴지통 이동).
struct WikiIngestLogEntry: Codable, Identifiable, Equatable {
    let id: UUID
    let pageURL: URL
    let backupFile: String?
    let sourceName: String
    let date: Date
}

/// 덮어쓰기 직전 본 백업·기록·복원(스펙 §2.4). 앱 데이터 디렉터리에만 쓴다 —
/// 볼트 안엔 잡파일을 만들지 않는다. 복원도 삭제 없음(새 페이지는 휴지통).
actor WikiBackupStore {
    private let backupsDir: URL
    private let logURL: URL
    private var entries: [WikiIngestLogEntry]

    init(directory: URL) {
        backupsDir = directory.appendingPathComponent("wiki-backups")
        logURL = directory.appendingPathComponent("wiki-ingest-log.json")
        try? FileManager.default.createDirectory(at: backupsDir, withIntermediateDirectories: true)
        if let data = try? Data(contentsOf: logURL),
           let loaded = try? JSONDecoder().decode([WikiIngestLogEntry].self, from: data) {
            entries = loaded
        } else {
            entries = []
        }
    }

    /// 적용 직전 호출 — oldBody가 있으면 백업 파일로 저장하고 로그에 기록한다.
    func recordApply(pageURL: URL, oldBody: String?, sourceName: String) throws -> WikiIngestLogEntry {
        var backupFile: String? = nil
        if let oldBody {
            let stamp = Self.timestampFormatter.string(from: Date())
            let base = pageURL.deletingPathExtension().lastPathComponent
            let file = backupsDir.appendingPathComponent("\(base)-\(stamp).md").uniquified()
            try oldBody.write(to: file, atomically: true, encoding: .utf8)
            backupFile = file.lastPathComponent
        }
        let entry = WikiIngestLogEntry(
            id: UUID(), pageURL: pageURL, backupFile: backupFile,
            sourceName: sourceName, date: Date())
        entries.append(entry)
        persist()
        return entry
    }

    /// 최신순 기록.
    func allEntries() -> [WikiIngestLogEntry] { entries.reversed() }

    /// 복원 — 백업이 있으면 현재 본을 다시 백업(왕복 안전) 후 백업본으로 교체,
    /// 새 페이지(backupFile nil)면 생성 파일을 휴지통으로. 로그는 보존.
    func restore(_ entry: WikiIngestLogEntry) throws {
        if let backupFile = entry.backupFile {
            let backup = backupsDir.appendingPathComponent(backupFile)
            let restored = try String(contentsOf: backup, encoding: .utf8)
            let current = try? String(contentsOf: entry.pageURL, encoding: .utf8)
            if let current {
                _ = try recordApply(pageURL: entry.pageURL, oldBody: current,
                                    sourceName: "복원 전 자동 백업")
            }
            try restored.write(to: entry.pageURL, atomically: true, encoding: .utf8)
        } else {
            _ = try FileOperations.trash(at: entry.pageURL)
        }
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(entries) {
            try? data.write(to: logURL)
        }
    }

    private static let timestampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}
```

주의: init의 로그 디코드는 `JSONDecoder()` 기본인데 persist는 `.iso8601` — **디코더에도 `decoder.dateDecodingStrategy = .iso8601`을 지정**해야 왕복이 맞는다(테스트 `testRecordApplySavesBackupAndLog`의 재로딩 단언이 이 결함을 잡는다 — 구현 시 빼먹지 말 것):

```swift
        if let data = try? Data(contentsOf: logURL) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let loaded = try? decoder.decode([WikiIngestLogEntry].self, from: data) {
                entries = loaded
            } else { entries = [] }
        } else { entries = [] }
```

- [ ] **Step 4: 통과 확인**

Run: `swift test --filter WikiBackupStoreTests 2>&1 | tail -3`
Expected: `Executed 5 tests, with 0 failures`

- [ ] **Step 5: 커밋**

```bash
git add Sources/Services/WikiBackupStore.swift Tests/CmdMDTests/WikiBackupStoreTests.swift
git commit -m "기능(위키): WikiBackupStore — 적용 직전 본 백업·기록·복원(새 페이지 복원=휴지통) (스펙 §2.4)"
```

---

### Task 4: WikiIngestService (actor — 병합 제안 생성)

**Files:**
- Create: `Sources/Services/WikiIngestService.swift`
- Test: `Tests/CmdMDTests/WikiIngestServiceTests.swift`

**Interfaces:**
- Consumes: Task 1의 `WikiIngestTarget`/`WikiMergeProposal`/`WikiIngestModels.*`, `ContentExtractor.body(for:kordoc:) async -> String?`(`Sources/Services/ContentExtractor.swift`), `protocol ClaudeAsking`(`Sources/Services/ClaudeService.swift:13` — `func ask(prompt: String, context: String) async throws -> String`), `ClaudeError.timeout`, `KordocService()`.
- Produces:
  - `enum WikiIngestError: Error, Equatable { case sourceUnreadable, pageUnreadable, pageTooLarge, invalidNewPageName, badResponse }`
  - `actor WikiIngestService`: `init(claude: any ClaudeAsking, kordoc: KordocService)`, `func propose(source: URL, target: WikiIngestTarget, wikiFolder: URL, today: String) async throws -> WikiMergeProposal`

- [ ] **Step 1: 실패하는 테스트 작성**

`Tests/CmdMDTests/WikiIngestServiceTests.swift`:

```swift
import XCTest
@testable import CmdMD

/// 병합 제안 생성 — FakeClaude 주입(폴더 정리 전례). 제안 단계는 디스크에 쓰지 않는다.
final class WikiIngestServiceTests: XCTestCase {
    var wikiDir: URL!
    var srcDir: URL!

    override func setUp() {
        super.setUp()
        wikiDir = TempDataDirectory.make()
        srcDir = TempDataDirectory.make()
    }
    override func tearDown() {
        TempDataDirectory.cleanup(wikiDir)
        TempDataDirectory.cleanup(srcDir)
        super.tearDown()
    }

    private func makeSource(_ name: String = "자료.md", body: String = "# 자료\n핵심 내용") -> URL {
        let url = srcDir.appendingPathComponent(name)
        try? body.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// 항상 지정 응답을 돌려주는 가짜. 호출 기록으로 프롬프트 계약을 검증한다.
    private actor FakeClaude: ClaudeAsking {
        let response: String
        var timeoutsBeforeSuccess: Int
        private(set) var calls: [(prompt: String, context: String)] = []
        init(response: String, timeoutsBeforeSuccess: Int = 0) {
            self.response = response
            self.timeoutsBeforeSuccess = timeoutsBeforeSuccess
        }
        func ask(prompt: String, context: String) async throws -> String {
            calls.append((prompt, context))
            if timeoutsBeforeSuccess > 0 {
                timeoutsBeforeSuccess -= 1
                throw ClaudeError.timeout
            }
            return response
        }
        func callCount() -> Int { calls.count }
        func lastContext() -> String? { calls.last?.context }
    }

    func testProposeMergesIntoExistingPage() async throws {
        let page = wikiDir.appendingPathComponent("주제.md")
        try "# 주제\n\n기존 본문".write(to: page, atomically: true, encoding: .utf8)
        let merged = "---\nupdated: 2026-07-06\n---\n# 주제\n\n기존 본문\n\n새 내용"
        let fake = FakeClaude(response: merged)
        let service = WikiIngestService(claude: fake, kordoc: KordocService())

        let p = try await service.propose(source: makeSource(), target: .existing(page),
                                          wikiFolder: wikiDir, today: "2026-07-06")
        XCTAssertEqual(p.pageURL, page)
        XCTAssertFalse(p.isNewPage)
        XCTAssertEqual(p.oldBody, "# 주제\n\n기존 본문")
        XCTAssertEqual(p.newBody, merged)
        // 제안 단계 — 페이지는 아직 그대로다.
        XCTAssertEqual(try String(contentsOf: page, encoding: .utf8), "# 주제\n\n기존 본문")
        // 컨텍스트에 기존 본문·소스 본문이 실렸다.
        let ctx = await fake.lastContext()
        XCTAssertTrue(ctx?.contains("기존 본문") == true)
        XCTAssertTrue(ctx?.contains("핵심 내용") == true)
    }

    func testProposeNewPage() async throws {
        let fake = FakeClaude(response: "# 새주제\n\n요약")
        let service = WikiIngestService(claude: fake, kordoc: KordocService())
        let p = try await service.propose(source: makeSource(), target: .new(name: "새주제"),
                                          wikiFolder: wikiDir, today: "2026-07-06")
        XCTAssertTrue(p.isNewPage)
        XCTAssertEqual(p.oldBody, "")
        XCTAssertEqual(p.pageURL.lastPathComponent, "새주제.md")
        XCTAssertFalse(FileManager.default.fileExists(atPath: p.pageURL.path))   // 아직 안 만든다
    }

    func testProposeRetriesOnceOnTimeout() async throws {
        let page = wikiDir.appendingPathComponent("p.md")
        try "# p\n본문본문본문".write(to: page, atomically: true, encoding: .utf8)
        let fake = FakeClaude(response: "# p\n본문본문본문\n추가", timeoutsBeforeSuccess: 1)
        let service = WikiIngestService(claude: fake, kordoc: KordocService())
        _ = try await service.propose(source: makeSource(), target: .existing(page),
                                      wikiFolder: wikiDir, today: "2026-07-06")
        let count = await fake.callCount()
        XCTAssertEqual(count, 2)
    }

    func testProposeThrowsOnMissingSource() async {
        let fake = FakeClaude(response: "x")
        let service = WikiIngestService(claude: fake, kordoc: KordocService())
        let missing = srcDir.appendingPathComponent("없음.md")
        do {
            _ = try await service.propose(source: missing, target: .new(name: "n"),
                                          wikiFolder: wikiDir, today: "2026-07-06")
            XCTFail("에러여야 함")
        } catch let e as WikiIngestError {
            XCTAssertEqual(e, .sourceUnreadable)
        } catch { XCTFail("다른 에러: \(error)") }
    }

    func testProposeThrowsWhenPageTooLarge() async throws {
        let page = wikiDir.appendingPathComponent("큰페이지.md")
        try String(repeating: "가", count: WikiIngestModels.pageBodyLimit + 1)
            .write(to: page, atomically: true, encoding: .utf8)
        let fake = FakeClaude(response: "x")
        let service = WikiIngestService(claude: fake, kordoc: KordocService())
        do {
            _ = try await service.propose(source: makeSource(), target: .existing(page),
                                          wikiFolder: wikiDir, today: "2026-07-06")
            XCTFail("에러여야 함")
        } catch let e as WikiIngestError {
            XCTAssertEqual(e, .pageTooLarge)
            let count = await fake.callCount()
            XCTAssertEqual(count, 0)   // Claude 호출 전에 거부(크레딧 절약)
        } catch { XCTFail("다른 에러: \(error)") }
    }

    func testProposeThrowsOnBadResponse() async throws {
        let page = wikiDir.appendingPathComponent("p.md")
        try String(repeating: "본문", count: 200).write(to: page, atomically: true, encoding: .utf8)
        let fake = FakeClaude(response: "짧음")   // 기존 대비 40% 미만 급축소 → 검증 실패
        let service = WikiIngestService(claude: fake, kordoc: KordocService())
        do {
            _ = try await service.propose(source: makeSource(), target: .existing(page),
                                          wikiFolder: wikiDir, today: "2026-07-06")
            XCTFail("에러여야 함")
        } catch let e as WikiIngestError {
            XCTAssertEqual(e, .badResponse)
        } catch { XCTFail("다른 에러: \(error)") }
    }

    func testProposeThrowsOnInvalidNewPageName() async {
        let fake = FakeClaude(response: "x")
        let service = WikiIngestService(claude: fake, kordoc: KordocService())
        do {
            _ = try await service.propose(source: makeSource(), target: .new(name: "///"),
                                          wikiFolder: wikiDir, today: "2026-07-06")
            XCTFail("에러여야 함")
        } catch let e as WikiIngestError {
            XCTAssertEqual(e, .invalidNewPageName)
        } catch { XCTFail("다른 에러: \(error)") }
    }
}
```

- [ ] **Step 2: 실패 확인**

Run: `swift test --filter WikiIngestServiceTests 2>&1 | tail -5`
Expected: 컴파일 실패(`WikiIngestService` 미존재).

- [ ] **Step 3: 구현**

`Sources/Services/WikiIngestService.swift`:

```swift
import Foundation

enum WikiIngestError: Error, Equatable {
    case sourceUnreadable      // 소스 본문 추출 실패(미지원 형식·kordoc 실패 포함)
    case pageUnreadable        // 기존 페이지 읽기 실패
    case pageTooLarge          // 페이지 한도 초과(출력=전문이라 타임아웃 방어)
    case invalidNewPageName    // 정제 후 빈 이름
    case badResponse           // 응답 검증 실패(빈 값·급축소)
}

/// 병합 제안 생성만 담당 — 디스크에 쓰지 않는다(적용은 AppState+WikiBackupStore,
/// 제안→확인→실행). 의존은 ClaudeAsking으로 좁혀 가짜 주입 테스트(스펙 §2.3).
actor WikiIngestService {
    private let claude: any ClaudeAsking
    private let kordoc: KordocService

    init(claude: any ClaudeAsking, kordoc: KordocService) {
        self.claude = claude
        self.kordoc = kordoc
    }

    func propose(source: URL, target: WikiIngestTarget,
                 wikiFolder: URL, today: String) async throws -> WikiMergeProposal {
        guard let sourceBody = await ContentExtractor.body(for: source, kordoc: kordoc) else {
            throw WikiIngestError.sourceUnreadable
        }

        let pageURL: URL
        let oldBody: String
        let isNewPage: Bool
        switch target {
        case .existing(let url):
            guard let body = try? String(contentsOf: url, encoding: .utf8) else {
                throw WikiIngestError.pageUnreadable
            }
            guard body.count <= WikiIngestModels.pageBodyLimit else {
                throw WikiIngestError.pageTooLarge
            }
            pageURL = url; oldBody = body; isNewPage = false
        case .new(let name):
            guard let url = WikiIngestModels.newPageURL(name: name, wikiFolder: wikiFolder) else {
                throw WikiIngestError.invalidNewPageName
            }
            pageURL = url; oldBody = ""; isNewPage = true
        }

        let (excerpt, truncated) = WikiIngestModels.truncatedExcerpt(sourceBody)
        let title = pageURL.deletingPathExtension().lastPathComponent
        let (prompt, context) = WikiIngestModels.mergePrompt(
            pageTitle: title, pageBody: oldBody,
            sourceName: source.lastPathComponent, sourceExcerpt: excerpt,
            excerptTruncated: truncated, isNewPage: isNewPage, today: today)

        let stdout = try await askWithRetry(prompt: prompt, context: context)
        guard let newBody = WikiIngestModels.extractMarkdown(from: stdout,
                                                             oldBodyLength: oldBody.count) else {
            throw WikiIngestError.badResponse
        }
        return WikiMergeProposal(pageURL: pageURL, isNewPage: isNewPage,
                                 oldBody: oldBody, newBody: newBody, sourceURL: source)
    }

    /// 타임아웃 1회 재시도 — 경계선 방어(CleanupService 전례). 다른 에러는 전파.
    private func askWithRetry(prompt: String, context: String) async throws -> String {
        do { return try await claude.ask(prompt: prompt, context: context) }
        catch ClaudeError.timeout { return try await claude.ask(prompt: prompt, context: context) }
    }
}
```

- [ ] **Step 4: 통과 확인**

Run: `swift test --filter WikiIngestServiceTests 2>&1 | tail -3`
Expected: `Executed 7 tests, with 0 failures`

- [ ] **Step 5: 커밋**

```bash
git add Sources/Services/WikiIngestService.swift Tests/CmdMDTests/WikiIngestServiceTests.swift
git commit -m "기능(위키): WikiIngestService — 병합 제안 생성(추출→한도→프롬프트→검증, 쓰기 없음) (스펙 §2.3)"
```

---

### Task 5: 설정·AppState 배선 (wikiFolder·시트 상태·적용·복원)

**Files:**
- Modify: `Sources/Models/Settings.swift` (필드 1개 + decodeIfPresent 1줄)
- Modify: `Sources/App/AppState.swift` (상태 프로퍼티·서비스 조립·메서드 4개)
- Test: `Tests/CmdMDTests/AppWikiIngestStateTests.swift` (신규), `Tests/CmdMDTests/SettingsCodableTests.swift`가 있으면 거기에 wikiFolder 하위호환 1건 추가(없으면 신규 테스트 파일에 포함)

**Interfaces:**
- Consumes: Task 1 `WikiMergeProposal`/`WikiIngestTarget`, Task 3 `WikiBackupStore`/`WikiIngestLogEntry`, Task 4 `WikiIngestService`/`WikiIngestError`. 기존: `AppState(dataDirectory:)`·`dataURL`·`claudeService`/`kordocService`(AppState.swift:225-226)·`saveUserData()`·`showToast(_:)`.
- Produces(Task 6 UI가 사용):
  - `AppSettings.wikiFolder: String?`
  - `struct WikiIngestRequest: Identifiable { let id: UUID; let url: URL }` (WikiIngestModels.swift에 추가)
  - `AppState`: `var wikiIngestRequest: WikiIngestRequest?`, `var wikiIngestBusy: Bool`, `var wikiMergeProposal: WikiMergeProposal?`, `var wikiIngestError: String?`, `var wikiIngestService: WikiIngestService`(테스트 교체용 var), `let wikiBackupStore: WikiBackupStore`, `func requestWikiIngest(source: URL)`, `func generateWikiMerge(source: URL, target: WikiIngestTarget) async`, `func applyWikiMerge(_ proposal: WikiMergeProposal) async -> Bool`, `func restoreWikiIngest(_ entry: WikiIngestLogEntry) async -> Bool`

- [ ] **Step 1: 실패하는 테스트 작성**

`Tests/CmdMDTests/AppWikiIngestStateTests.swift`:

```swift
import XCTest
@testable import CmdMD

/// 위키 인제스트 AppState 배선 — 시트 상태·제안 생성(busy 가드)·적용(백업→쓰기)·복원.
@MainActor
final class AppWikiIngestStateTests: XCTestCase {
    var tempData: URL!
    var wikiDir: URL!
    var app: AppState!

    override func setUp() {
        super.setUp()
        tempData = TempDataDirectory.make()
        wikiDir = TempDataDirectory.make()
        app = AppState(dataDirectory: tempData)
        app.settings.wikiFolder = wikiDir.path
    }
    override func tearDown() {
        TempDataDirectory.cleanup(tempData)
        TempDataDirectory.cleanup(wikiDir)
        super.tearDown()
    }

    private actor StubClaude: ClaudeAsking {
        let response: String
        init(response: String) { self.response = response }
        func ask(prompt: String, context: String) async throws -> String { response }
    }

    private func makeSource(_ body: String = "# 자료\n내용") -> URL {
        let url = wikiDir.appendingPathComponent("src-\(UUID().uuidString).md")
        try? body.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    func testRequestOpensSheetWithCleanState() {
        let src = makeSource()
        app.wikiIngestError = "이전 에러"
        app.requestWikiIngest(source: src)
        XCTAssertEqual(app.wikiIngestRequest?.url, src)
        XCTAssertNil(app.wikiMergeProposal)
        XCTAssertNil(app.wikiIngestError)
        XCTAssertFalse(app.wikiIngestBusy)
    }

    func testGenerateProducesProposal() async {
        app.wikiIngestService = WikiIngestService(
            claude: StubClaude(response: "# 새주제\n\n요약"), kordoc: KordocService())
        await app.generateWikiMerge(source: makeSource(), target: .new(name: "새주제"))
        XCTAssertNotNil(app.wikiMergeProposal)
        XCTAssertNil(app.wikiIngestError)
        XCTAssertFalse(app.wikiIngestBusy)
    }

    func testGenerateMapsErrorToKoreanMessage() async {
        app.wikiIngestService = WikiIngestService(
            claude: StubClaude(response: "x"), kordoc: KordocService())
        let missing = wikiDir.appendingPathComponent("없음.pdf")
        await app.generateWikiMerge(source: missing, target: .new(name: "n"))
        XCTAssertNil(app.wikiMergeProposal)
        XCTAssertNotNil(app.wikiIngestError)
    }

    func testGenerateWithoutWikiFolderSetsError() async {
        app.settings.wikiFolder = nil
        await app.generateWikiMerge(source: makeSource(), target: .new(name: "n"))
        XCTAssertNotNil(app.wikiIngestError)
    }

    func testApplyWritesPageAndLogsBackup() async throws {
        let page = wikiDir.appendingPathComponent("주제.md")
        try "# 이전".write(to: page, atomically: true, encoding: .utf8)
        let proposal = WikiMergeProposal(pageURL: page, isNewPage: false,
                                         oldBody: "# 이전", newBody: "# 병합 후",
                                         sourceURL: makeSource())
        let ok = await app.applyWikiMerge(proposal)
        XCTAssertTrue(ok)
        XCTAssertEqual(try String(contentsOf: page, encoding: .utf8), "# 병합 후")
        let entries = await app.wikiBackupStore.allEntries()
        XCTAssertEqual(entries.count, 1)
        XCTAssertNotNil(entries.first?.backupFile)
    }

    func testApplyNewPageCreatesFile() async {
        let page = wikiDir.appendingPathComponent("새주제.md")
        let proposal = WikiMergeProposal(pageURL: page, isNewPage: true,
                                         oldBody: "", newBody: "# 새주제\n요약",
                                         sourceURL: makeSource())
        let ok = await app.applyWikiMerge(proposal)
        XCTAssertTrue(ok)
        XCTAssertEqual(try? String(contentsOf: page, encoding: .utf8), "# 새주제\n요약")
    }

    func testRestoreRoundTripThroughAppState() async throws {
        let page = wikiDir.appendingPathComponent("주제.md")
        try "# 이전".write(to: page, atomically: true, encoding: .utf8)
        let proposal = WikiMergeProposal(pageURL: page, isNewPage: false,
                                         oldBody: "# 이전", newBody: "# 병합 후",
                                         sourceURL: makeSource())
        _ = await app.applyWikiMerge(proposal)
        let entry = await app.wikiBackupStore.allEntries().first!
        let ok = await app.restoreWikiIngest(entry)
        XCTAssertTrue(ok)
        XCTAssertEqual(try String(contentsOf: page, encoding: .utf8), "# 이전")
    }

    func testWikiFolderSettingDecodeBackwardCompatible() throws {
        // 구버전 settings.json(wikiFolder 키 없음)이 그대로 디코드된다.
        let old = "{\"hasCompletedOnboarding\": true}".data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AppSettings.self, from: old)
        XCTAssertNil(decoded.wikiFolder)
    }
}
```

- [ ] **Step 2: 실패 확인**

Run: `swift test --filter AppWikiIngestStateTests 2>&1 | tail -5`
Expected: 컴파일 실패(`wikiFolder`·`wikiIngestService` 등 미존재).

- [ ] **Step 3: 구현**

**(a)** `Sources/Models/Settings.swift` — 프로퍼티 블록(101행 `indexedFolders` 근처)에:

```swift
    var wikiFolder: String? = nil          // LLM-Wiki 인제스트 대상 폴더(절대 경로)
```

`init(from decoder:)`의 decodeIfPresent 블록(166행 근처)에:

```swift
        wikiFolder = try c.decodeIfPresent(String.self, forKey: .wikiFolder) ?? d.wikiFolder
```

**(b)** `Sources/Services/WikiIngestModels.swift` — 파일 끝에 시트 요청 타입 추가(기존 RenameRequest 패턴):

```swift
/// 인제스트 시트 요청 — .sheet(item:) 배선용(RenameRequest 패턴).
struct WikiIngestRequest: Identifiable {
    let id = UUID()
    let url: URL
}
```

**(c)** `Sources/App/AppState.swift`:

상태 프로퍼티(폴더 정리 상태 블록 176행 근처에 이어서):

```swift
    // MARK: - 위키 인제스트 (LLM-Wiki Ingest)
    var wikiIngestRequest: WikiIngestRequest? = nil
    var wikiIngestBusy: Bool = false
    var wikiMergeProposal: WikiMergeProposal? = nil
    var wikiIngestError: String? = nil
```

서비스 보관(233행 `var cleanupService` 근처):

```swift
    var wikiIngestService: WikiIngestService   // var — 테스트에서 가짜 Claude 주입(클린업 전례)
    let wikiBackupStore: WikiBackupStore
```

init 조립(764행 `cleanupService = ...` 근처):

```swift
        wikiIngestService = WikiIngestService(claude: claudeService, kordoc: kordocService)
        wikiBackupStore = WikiBackupStore(directory: appDir)
```

메서드(폴더 정리 진입 함수 `startCleanup` 3187행 근처에 이어서):

```swift
    // MARK: - 위키 인제스트 흐름 (제안→확인→실행, 스펙 §2.5)

    /// 인제스트 시트 열기 — 이전 제안·에러를 비우고 소스를 지정한다.
    func requestWikiIngest(source: URL) {
        guard !wikiIngestBusy else { wikiIngestRequest = WikiIngestRequest(url: source); return }
        wikiMergeProposal = nil
        wikiIngestError = nil
        wikiIngestRequest = WikiIngestRequest(url: source)
    }

    /// 병합 제안 생성 — busy 가드, 에러는 한국어 메시지로 시트에 표시.
    func generateWikiMerge(source: URL, target: WikiIngestTarget) async {
        guard !wikiIngestBusy else { return }
        guard let folderPath = settings.wikiFolder else {
            wikiIngestError = "위키 폴더가 설정되지 않았습니다."
            return
        }
        wikiIngestBusy = true
        wikiIngestError = nil
        wikiMergeProposal = nil
        defer { wikiIngestBusy = false }
        do {
            let today = Self.wikiTodayFormatter.string(from: Date())
            wikiMergeProposal = try await wikiIngestService.propose(
                source: source, target: target,
                wikiFolder: URL(fileURLWithPath: folderPath), today: today)
        } catch let e as WikiIngestError {
            wikiIngestError = Self.wikiErrorMessage(e)
        } catch let e as ClaudeError {
            wikiIngestError = claudeErrorMessage(for: e)   // 기존 헬퍼 없으면 아래 참고
        } catch {
            wikiIngestError = "병합 생성에 실패했습니다: \(error.localizedDescription)"
        }
    }

    /// 적용 — 백업 기록 후 페이지 덮어쓰기(새 페이지면 생성). 성공 여부 반환.
    func applyWikiMerge(_ proposal: WikiMergeProposal) async -> Bool {
        do {
            _ = try await wikiBackupStore.recordApply(
                pageURL: proposal.pageURL,
                oldBody: proposal.isNewPage ? nil : proposal.oldBody,
                sourceName: proposal.sourceURL.lastPathComponent)
            try proposal.newBody.write(to: proposal.pageURL, atomically: true, encoding: .utf8)
            showToast("위키 페이지에 병합했습니다")
            return true
        } catch {
            wikiIngestError = "적용에 실패했습니다: \(error.localizedDescription)"
            return false
        }
    }

    /// 기록에서 되돌리기. 성공 여부 반환.
    func restoreWikiIngest(_ entry: WikiIngestLogEntry) async -> Bool {
        do {
            try await wikiBackupStore.restore(entry)
            showToast("되돌렸습니다")
            return true
        } catch {
            wikiIngestError = "되돌리기에 실패했습니다: \(error.localizedDescription)"
            return false
        }
    }

    private static func wikiErrorMessage(_ e: WikiIngestError) -> String {
        switch e {
        case .sourceUnreadable: return "소스 문서의 본문을 읽지 못했습니다(미지원 형식이거나 변환 실패)."
        case .pageUnreadable: return "대상 페이지를 읽지 못했습니다."
        case .pageTooLarge: return "페이지가 너무 큽니다(24,000자 초과) — 분할 후 다시 시도하세요."
        case .invalidNewPageName: return "새 페이지 이름이 비어 있거나 쓸 수 없습니다."
        case .badResponse: return "Claude 응답이 페이지 전문 형식이 아닙니다 — 다시 시도하세요."
        }
    }

    private static let wikiTodayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
```

`claudeErrorMessage(for:)` 기존 헬퍼가 없으면(grep으로 확인) 그 catch 절을 다음으로 대체:

```swift
        } catch {
            wikiIngestError = "병합 생성에 실패했습니다: \(error.localizedDescription)"
        }
```

(ClaudeError 분류 문구는 기존 Claude 패널의 처리 방식을 grep해 같은 문구 헬퍼가 있으면 재사용, 없으면 localizedDescription로 충분 — 과설계 금지.)

- [ ] **Step 4: 통과 확인 + 전체 회귀**

Run: `swift test --filter AppWikiIngestStateTests 2>&1 | tail -3`
Expected: `Executed 8 tests, with 0 failures`
Run: `swift test 2>&1 | tail -3` → 전체 GREEN.

- [ ] **Step 5: 커밋**

```bash
git add Sources/Models/Settings.swift Sources/App/AppState.swift Sources/Services/WikiIngestModels.swift Tests/CmdMDTests/AppWikiIngestStateTests.swift
git commit -m "기능(위키): 설정·AppState 배선 — wikiFolder·시트 상태·제안 생성(busy 가드)·적용(백업→쓰기)·복원 (스펙 §2.5)"
```

---

### Task 6: WikiIngestView 시트 + 진입점 3곳 + Tools 섹션

**Files:**
- Create: `Sources/Views/WikiIngestView.swift`
- Modify: `Sources/Views/ContentView.swift:82-118` (.sheet 배선 1개 추가)
- Modify: `Sources/Views/SidebarView.swift:534-548` (`FileTreeContextMenu.singleItemMenu` — 파일 분기에 항목 추가)
- Modify: `Sources/Views/LibraryView.swift:416-421` 근처 (`LibraryCellContextMenu` 단일 메뉴 — 파일 분기에 항목 추가)
- Modify: `Sources/Views/CommandPaletteView.swift:271-290` 근처 (`allCommands` 배열에 항목 추가)
- Modify: `Sources/Views/SettingsView.swift:682+` (`ToolsSettingsView`에 "LLM-Wiki" 섹션 추가)

**Interfaces:**
- Consumes: Task 5의 AppState API 전부(`wikiIngestRequest`·`wikiIngestBusy`·`wikiMergeProposal`·`wikiIngestError`·`requestWikiIngest`·`generateWikiMerge`·`applyWikiMerge`·`restoreWikiIngest`), Task 2 `LineDiff`, Task 3 `WikiIngestLogEntry`·`wikiBackupStore.allEntries()`, 기존 `appState.openDocument(at:inNewTab:)`·`saveUserData()`.
- Produces: 사용자 대면 UI 완성(수동 스모크 대상).

- [ ] **Step 1: WikiIngestView 작성**

`Sources/Views/WikiIngestView.swift`:

```swift
import SwiftUI

/// LLM-Wiki 단일 문서 인제스트 시트(스펙 §2.5) — 대상 선택 → 병합 생성 → diff 승인 → 적용.
struct WikiIngestView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    let request: WikiIngestRequest

    @State private var pages: [URL] = []
    @State private var selection: String = ""          // 선택된 기존 페이지 path 또는 NEW
    @State private var newPageName: String = ""
    @State private var entries: [WikiIngestLogEntry] = []
    @State private var applied = false

    private static let newMarker = "__NEW__"

    private var wikiFolderURL: URL? {
        appState.settings.wikiFolder.map { URL(fileURLWithPath: $0) }
    }

    private var target: WikiIngestTarget? {
        if selection == Self.newMarker {
            let name = newPageName.trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? nil : .new(name: name)
        }
        return selection.isEmpty ? nil : .existing(URL(fileURLWithPath: selection))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("위키에 인제스트").font(.headline)
            Label(request.url.lastPathComponent, systemImage: "doc")
                .foregroundStyle(.secondary)

            if wikiFolderURL == nil {
                unsetFolderNotice
            } else {
                targetPicker
                generateSection
                if let proposal = appState.wikiMergeProposal {
                    diffSection(proposal)
                }
            }

            if let error = appState.wikiIngestError {
                Text(error).foregroundStyle(.red).font(.callout)
            }

            historySection
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button(applied ? "닫기" : "취소") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(minWidth: 640, minHeight: 520)
        .task { reload() }
    }

    // MARK: - 구획

    private var unsetFolderNotice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("위키 폴더가 설정되지 않았습니다.").foregroundStyle(.secondary)
            Button("위키 폴더 지정…") {
                if let url = Self.pickFolder() {
                    appState.settings.wikiFolder = url.path
                    appState.saveUserData()
                    reload()
                }
            }
        }
    }

    private var targetPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("대상 페이지", selection: $selection) {
                Text("선택…").tag("")
                ForEach(pages, id: \.path) { page in
                    Text(page.deletingPathExtension().lastPathComponent).tag(page.path)
                }
                Divider()
                Text("새 페이지…").tag(Self.newMarker)
            }
            if selection == Self.newMarker {
                TextField("새 페이지 이름", text: $newPageName)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    private var generateSection: some View {
        HStack(spacing: 10) {
            Button("병합 생성") {
                guard let target else { return }
                Task { await appState.generateWikiMerge(source: request.url, target: target) }
            }
            .disabled(target == nil || appState.wikiIngestBusy)
            if appState.wikiIngestBusy {
                ProgressView().controlSize(.small)
                Text("Claude가 병합 중…").foregroundStyle(.secondary).font(.callout)
            }
        }
    }

    @ViewBuilder
    private func diffSection(_ proposal: WikiMergeProposal) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(proposal.isNewPage
                 ? "새 페이지: \(proposal.pageURL.lastPathComponent)"
                 : "변경 미리보기: \(proposal.pageURL.lastPathComponent)")
                .font(.subheadline).bold()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(LineDiff.diff(old: proposal.oldBody,
                                                new: proposal.newBody).enumerated()),
                            id: \.offset) { _, line in
                        diffRow(line)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 180, maxHeight: 320)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 6))

            HStack {
                Button("적용") {
                    Task {
                        if await appState.applyWikiMerge(proposal) {
                            applied = true
                            appState.wikiMergeProposal = nil
                            reload()
                        }
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(appState.wikiIngestBusy)
                if applied {
                    Button("페이지 열기") {
                        appState.openDocument(at: proposal.pageURL, inNewTab: true)
                        dismiss()
                    }
                }
            }
        }
    }

    private func diffRow(_ line: LineDiff.Line) -> some View {
        Text(line.text.isEmpty ? " " : line.text)
            .font(.system(.caption, design: .monospaced))
            .strikethrough(line.kind == .removed)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 6)
            .background(
                line.kind == .added ? Color.green.opacity(0.18)
                : line.kind == .removed ? Color.red.opacity(0.15)
                : Color.clear)
    }

    private var historySection: some View {
        DisclosureGroup("인제스트 기록") {
            if entries.isEmpty {
                Text("기록 없음").foregroundStyle(.secondary).font(.callout)
            } else {
                ForEach(entries) { entry in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(entry.pageURL.lastPathComponent).font(.callout)
                            Text("\(entry.sourceName) · \(entry.date.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("되돌리기") {
                            Task {
                                if await appState.restoreWikiIngest(entry) { reload() }
                            }
                        }
                        .font(.caption)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .font(.callout)
    }

    // MARK: - 헬퍼

    /// 위키 폴더 최상위 .md 목록(이름순)과 기록을 다시 읽는다.
    private func reload() {
        if let folder = wikiFolderURL {
            let items = (try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles])) ?? []
            pages = items.filter { $0.pathExtension.lowercased() == "md" }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        } else {
            pages = []
        }
        Task {
            entries = await appState.wikiBackupStore.allEntries()
        }
    }

    private static func pickFolder() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }
}
```

- [ ] **Step 2: 배선 4곳**

**(a)** `Sources/Views/ContentView.swift` — 기존 `.sheet(item: $state.renameRequest)` 근처에:

```swift
        .sheet(item: $state.wikiIngestRequest) { request in
            WikiIngestView(request: request)
        }
```

**(b)** `Sources/Views/SidebarView.swift` — `FileTreeContextMenu.singleItemMenu`의 "정보 보기" 아래(파일·폴더 공통 구간이면 **파일 분기에만**: 메뉴 본문에서 `item.isDirectory`(또는 동등 플래그 — 파일에서 확인) 분기 안에 넣는다):

```swift
        if !item.isDirectory {
            Button {
                appState.requestWikiIngest(source: item.url)
            } label: {
                Label("위키에 인제스트…", systemImage: "text.badge.plus")
            }
        }
```

**(c)** `Sources/Views/LibraryView.swift` — `LibraryCellContextMenu` 단일 메뉴의 "정보 보기" 아래, 파일 분기에 동일 항목(코드 (b)와 같음 — item 타입에 맞는 디렉터리 판별 사용).

**(d)** `Sources/Views/CommandPaletteView.swift` — `allCommands` 배열의 "자료에 묻기 (RAG)" 항목 근처에:

```swift
            Command(
                title: "현재 문서를 위키에 인제스트",
                subtitle: "열린 문서를 위키 페이지에 Claude 병합",
                icon: "text.badge.plus",
                shortcut: nil,
                keywords: ["위키", "인제스트", "wiki", "ingest", "병합", "merge"]
            ) {
                if let url = appState.activeTab?.fileURL {
                    appState.requestWikiIngest(source: url)
                } else {
                    appState.showToast("열린 문서가 없습니다")
                }
            },
```

**(e)** `Sources/Views/SettingsView.swift` — `ToolsSettingsView` 본문(인덱스 폴더 나열 섹션 근처)에 "LLM-Wiki" 섹션:

```swift
            Section("LLM-Wiki") {
                HStack {
                    Text("위키 폴더")
                    Spacer()
                    Text(appState.settings.wikiFolder ?? "설정 안 됨")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button(appState.settings.wikiFolder == nil ? "지정…" : "변경…") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        panel.allowsMultipleSelection = false
                        if panel.runModal() == .OK, let url = panel.url {
                            appState.settings.wikiFolder = url.path
                            appState.saveUserData()
                        }
                    }
                }
                Text("파일을 위키 페이지에 병합하는 인제스트의 대상 폴더입니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
```

(ToolsSettingsView의 실제 레이아웃이 `Section`이 아니라 커스텀 VStack이면 **주변 섹션의 기존 스타일을 그대로 따라** 동등한 블록으로 넣는다 — 스타일 발명 금지.)

- [ ] **Step 3: 빌드·전체 게이트**

Run: `swift build 2>&1 | grep -ci warning` → `0`
Run: `swift test 2>&1 | tail -3` → 전체 GREEN.

- [ ] **Step 4: 커밋**

```bash
git add Sources/Views/WikiIngestView.swift Sources/Views/ContentView.swift Sources/Views/SidebarView.swift Sources/Views/LibraryView.swift Sources/Views/CommandPaletteView.swift Sources/Views/SettingsView.swift
git commit -m "기능(위키): 인제스트 시트(대상 선택·diff 승인·기록 복원) + 진입점(트리·라이브러리·팔레트)·Tools 섹션 (스펙 §2.5)"
```

---

## 계획 밖(코디네이터 몫)

- 최종 whole-branch 리뷰 → fix wave → CLAUDE.md·데일리 기록.
- 수동 스모크(스펙 §4): 실제 PDF → 기존 페이지 병합 diff·적용·복원, 새 페이지 생성, hwp 소스(kordoc), 한도 초과 안내, 팔레트 진입 — Claude 실호출 포함이라 실기로만 가능.
