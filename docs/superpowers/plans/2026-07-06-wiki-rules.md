# Wiki 설정 + 규칙 기반 인제스트 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 설정 "Wiki" 탭에서 위키 루트를 지정하고 위키의 규칙 파일(CLAUDE.md·templates)을 1회 파악해 요약 저장하면, 인제스트가 그 규칙대로(명명·위치·frontmatter·언어·구조) 문서를 생성한다 — 새 페이지는 위치·파일명까지 자동 제안.

**Architecture:** 순수 헬퍼 확장(`WikiIngestModels` — 규칙 주입 프롬프트·경로 마커 파싱·검증, `WikiPageLister` — 재귀 목록) 위에 `WikiRulesService`(actor, 규칙 요약 생성)를 신설하고, 기존 `WikiIngestService.propose`에 `.auto` 분기와 `rulesSummary` 전달을 더한다. 쓰기·백업·더티 가드는 기존 `applyWikiMerge` 경로 불변(중간 디렉터리 생성만 가산).

**Tech Stack:** Swift 5.9 / SwiftUI / XCTest. 새 패키지 의존성 0.

**스펙:** `docs/superpowers/specs/2026-07-06-wiki-rules-design.md` (승인됨 2026-07-06)

## Global Constraints

- macOS 14+ / Swift 5.9+ / SPM. 비샌드박스. 새 패키지 의존성 금지.
- 코드 주석·커밋 메시지는 한국어. '박다/박는다/박았다' 계열 어휘 금지. 지정 파일 밖 수정 금지.
- 정확값(스펙 §2.1·§2.4): 규칙 소스 입력 상한 **40,000자**, 규칙 요약 상한 **8,000자**, 경로 마커 형식 **`<!-- page: 상대/경로.md -->`**.
- 앱 계약(위키 규칙과 무관하게 항상 유지): frontmatter `sources:` 누적, 전문 md만 출력, 기존 정보 유실 금지, 발췌본 고지.
- 제안→확인→실행: propose 단계 디스크 쓰기 금지(기존 규칙).
- 테스트 게이트: `swift test` 전체 GREEN(기준 689 XCTest + 18 Testing, 신규만큼 증가).
- 커밋 트레일러 2줄: `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>` / `Claude-Session: https://claude.ai/code/session_01NJAwrLizMG4WbpBfCfxj7J`

---

### Task 1: WikiIngestModels 확장 — 규칙 주입 프롬프트·경로 마커 파싱·검증

**Files:**
- Modify: `Sources/Services/WikiIngestModels.swift`
- Test: `Tests/CmdMDTests/WikiIngestModelsTests.swift` (기존 파일에 추가 + `mergePrompt` 호출부 시그니처 갱신)

**Interfaces:**
- Consumes: 기존 `WikiIngestModels.mergePrompt(pageTitle:pageBody:sourceName:sourceExcerpt:excerptTruncated:isNewPage:today:)`(43행), `WikiIngestTarget`(4행).
- Produces(후속 태스크가 사용):
  - `WikiIngestTarget`에 `case auto` 추가.
  - `mergePrompt(pageTitle:pageBody:sourceName:sourceExcerpt:excerptTruncated:isNewPage:autoPlacement:rulesSummary:today:)` — 새 파라미터 `autoPlacement: Bool = false`, `rulesSummary: String? = nil`(기본값으로 기존 호출 하위호환).
  - `static func extractAutoPage(from stdout: String) -> (relativePath: String, body: String)?` — 첫 줄 마커 파싱.
  - `static func validatedAutoPageURL(relativePath: String, wikiFolder: URL) -> URL?` — 4중 검증(상대·탈출 차단·루트 하위·.md 강제), 통과 시 결합 URL(존재 검사는 하지 않음 — Service 몫).

- [ ] **Step 1: 실패하는 테스트 작성**

`Tests/CmdMDTests/WikiIngestModelsTests.swift`에 추가:

```swift
    // MARK: - 규칙 주입 (스펙 §2.3)

    func testMergePromptWithoutRulesSummaryIsUnchanged() {
        // 하위호환 — rulesSummary nil이면 기존 프롬프트와 동일해야 한다.
        let old = WikiIngestModels.mergePrompt(
            pageTitle: "t", pageBody: "b", sourceName: "s.pdf", sourceExcerpt: "e",
            excerptTruncated: false, isNewPage: false, today: "2026-07-06")
        let new = WikiIngestModels.mergePrompt(
            pageTitle: "t", pageBody: "b", sourceName: "s.pdf", sourceExcerpt: "e",
            excerptTruncated: false, isNewPage: false,
            autoPlacement: false, rulesSummary: nil, today: "2026-07-06")
        XCTAssertEqual(old.prompt, new.prompt)
        XCTAssertEqual(old.context, new.context)
    }

    func testMergePromptInjectsRulesSummaryWithPrecedenceAndContract() {
        let (prompt, _) = WikiIngestModels.mergePrompt(
            pageTitle: "t", pageBody: "b", sourceName: "s.pdf", sourceExcerpt: "e",
            excerptTruncated: false, isNewPage: false,
            autoPlacement: false, rulesSummary: "모든 요약은 반말로 쓴다.", today: "2026-07-06")
        XCTAssertTrue(prompt.contains("모든 요약은 반말로 쓴다."))
        XCTAssertTrue(prompt.contains("위키 규칙"))
        XCTAssertTrue(prompt.contains("우선"))            // 위키 규칙 우선 명시
        XCTAssertTrue(prompt.contains("sources"))         // 앱 계약(sources 누적)은 여전히 존재
        XCTAssertTrue(prompt.contains("유실"))            // 앱 계약(유실 금지) 유지
    }

    func testMergePromptAutoPlacementAddsMarkerInstruction() {
        let (prompt, _) = WikiIngestModels.mergePrompt(
            pageTitle: "자료", pageBody: "", sourceName: "자료.pdf", sourceExcerpt: "e",
            excerptTruncated: false, isNewPage: true,
            autoPlacement: true, rulesSummary: "규칙", today: "2026-07-06")
        XCTAssertTrue(prompt.contains("<!-- page:"))
        XCTAssertTrue(prompt.contains("상대"))
        // 자동 배치에선 고정 제목 헤딩 강제("# 자료")가 없어야 한다(규칙이 제목을 정함).
        XCTAssertFalse(prompt.contains("\"# 자료\" 헤딩으로 시작"))
    }

    // MARK: - 경로 마커 파싱·검증 (스펙 §2.4)

    func testExtractAutoPageParsesMarkerAndBody() {
        let out = "<!-- page: references/신진욱2011.md -->\n---\ntitle: x\n---\n# 신진욱2011\n본문"
        let r = WikiIngestModels.extractAutoPage(from: out)
        XCTAssertEqual(r?.relativePath, "references/신진욱2011.md")
        XCTAssertEqual(r?.body.hasPrefix("---"), true)
        XCTAssertFalse(r?.body.contains("<!-- page:") ?? true)
    }

    func testExtractAutoPageAllowsLeadingWhitespaceAndFence() {
        // 전체 코드펜스에 감싸여 와도 벗긴 뒤 첫 줄 마커를 읽는다.
        let out = "```markdown\n<!-- page: a/b.md -->\n# 제목\n본문\n```"
        let r = WikiIngestModels.extractAutoPage(from: out)
        XCTAssertEqual(r?.relativePath, "a/b.md")
    }

    func testExtractAutoPageReturnsNilWithoutMarker() {
        XCTAssertNil(WikiIngestModels.extractAutoPage(from: "# 제목\n본문"))
        XCTAssertNil(WikiIngestModels.extractAutoPage(from: ""))
    }

    func testValidatedAutoPageURLAcceptsRelativeMd() {
        let url = WikiIngestModels.validatedAutoPageURL(relativePath: "references/신진욱2011.md",
                                                        wikiFolder: tempDir)
        XCTAssertEqual(url?.lastPathComponent, "신진욱2011.md")
        XCTAssertTrue(url!.standardizedFileURL.path.hasPrefix(tempDir.standardizedFileURL.path + "/"))
    }

    func testValidatedAutoPageURLRejectsBadPaths() {
        for bad in ["/etc/passwd.md", "../밖.md", "a/../../밖.md", "~/x.md",
                    "references/문서.txt", "", "references/"] {
            XCTAssertNil(WikiIngestModels.validatedAutoPageURL(relativePath: bad, wikiFolder: tempDir),
                         "거부돼야 함: \(bad)")
        }
    }
```

주의: `WikiIngestTarget`에 `case auto`가 추가되면 기존 테스트 파일들의 switch 전수성엔 영향 없음(테스트는 케이스 생성만 사용).

- [ ] **Step 2: 실패 확인**

Run: `swift test --filter WikiIngestModelsTests 2>&1 | grep -E "error|Executed" | head -5`
Expected: 컴파일 실패(`autoPlacement`/`extractAutoPage`/`validatedAutoPageURL` 미존재).

- [ ] **Step 3: 구현**

`Sources/Services/WikiIngestModels.swift`:

**(a)** `WikiIngestTarget`에 케이스 추가:

```swift
enum WikiIngestTarget: Equatable {
    case existing(URL)
    case new(name: String)
    case auto              // 규칙 기반 자동 배치 — Claude가 위치·파일명 제안(스펙 §2.4)
}
```

**(b)** `mergePrompt` 시그니처·본문 교체(기존 규칙 문자열은 그대로 유지하고 분기만 추가):

```swift
    /// 병합 프롬프트 — 규칙(=페이지 스키마)은 prompt에, 본문들은 context(stdin)에.
    /// rulesSummary가 있으면 위키 자체 규칙이 내용 구성·언어(기본 규칙 4·6)에 우선한다.
    /// 앱 계약(전문 출력·sources 누적·유실 금지·재인제스트 갱신 = 규칙 1·2·3·5)은 항상 유지.
    static func mergePrompt(pageTitle: String, pageBody: String,
                            sourceName: String, sourceExcerpt: String,
                            excerptTruncated: Bool, isNewPage: Bool,
                            autoPlacement: Bool = false,
                            rulesSummary: String? = nil,
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
        if autoPlacement {
            rules += "\n7. 이 페이지는 새 페이지다. 아래 위키 규칙에 따라 이 문서가 놓일 위치와 " +
                "파일명을 정해, 출력 **첫 줄**에 정확히 `<!-- page: 상대/경로.md -->` 형식의 " +
                "주석을 쓰고(위키 루트 기준 상대 경로), 다음 줄부터 페이지 전문을 출력하라. " +
                "제목 헤딩도 위키 규칙에 맞게 정한다."
        } else if isNewPage {
            rules += "\n7. 이 페이지는 새 페이지다. \"# \(pageTitle)\" 헤딩으로 시작해 새 자료의 요약으로 구성하라."
        }
        if let rulesSummary, !rulesSummary.isEmpty {
            rules += """


            이 위키에는 자체 규칙이 있다. 아래 <위키 규칙>이 위 기본 규칙 4·6(내용 구성·언어)과 \
            제목·명명·frontmatter 필드 구성에 **우선한다**. 단 기본 규칙 1·2·3·5(전문 출력·\
            sources 누적·유실 금지·재인제스트 갱신)는 앱의 계약이므로 항상 지킨다.

            <위키 규칙>
            \(rulesSummary)
            </위키 규칙>
            """
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
```

주의: `excerptTruncated` 추가 위치가 기존과 동일(규칙 블록 끝)이어야 `testMergePromptWithoutRulesSummaryIsUnchanged`가 성립한다 — rulesSummary 블록은 truncated 고지 **앞**에 삽입되지만 nil이면 문자열이 완전히 동일해짐을 확인.

**(c)** 마커 파싱·검증 추가(`extractMarkdown` 아래):

```swift
    /// 자동 배치 응답 파싱 — 첫 줄 `<!-- page: 상대/경로.md -->` 마커를 읽고 본문에서 제거.
    /// 전체 코드펜스는 먼저 벗긴다. 마커가 없으면 nil(자동 배치 실패).
    static func extractAutoPage(from stdout: String) -> (relativePath: String, body: String)? {
        var text = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let fenceLines = text.components(separatedBy: "\n")
        if fenceLines.count >= 2, fenceLines[0].hasPrefix("```"),
           fenceLines[fenceLines.count - 1].trimmingCharacters(in: .whitespaces) == "```" {
            text = fenceLines.dropFirst().dropLast().joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var lines = text.components(separatedBy: "\n")
        guard let first = lines.first?.trimmingCharacters(in: .whitespaces),
              first.hasPrefix("<!--"), first.hasSuffix("-->") else { return nil }
        let inner = first.dropFirst(4).dropLast(3).trimmingCharacters(in: .whitespaces)
        guard inner.hasPrefix("page:") else { return nil }
        let path = inner.dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard !path.isEmpty else { return nil }
        lines.removeFirst()
        let body = lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return (String(path), body)
    }

    /// 자동 배치 상대 경로 4중 검증 — 상대 경로만·탈출("..", 절대, "~") 차단·루트 하위 확인·
    /// .md 강제(CleanupPlanner.destinationDir 전례). 존재 여부 검사는 하지 않는다(Service 몫).
    static func validatedAutoPageURL(relativePath: String, wikiFolder: URL) -> URL? {
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/"), !relativePath.hasPrefix("~"),
              relativePath.lowercased().hasSuffix(".md"),
              !relativePath.components(separatedBy: "/").contains("..") else { return nil }
        let dest = wikiFolder.appendingPathComponent(relativePath)
        let rootPath = wikiFolder.standardizedFileURL.path
        let destPath = dest.standardizedFileURL.path
        guard destPath.hasPrefix(rootPath + "/") else { return nil }
        // 마지막 구성요소가 실제 파일명인지("references/" 같은 디렉터리 경로 거부).
        guard dest.lastPathComponent.lowercased().hasSuffix(".md"),
              dest.lastPathComponent.count > 3 else { return nil }
        return dest
    }
```

- [ ] **Step 4: 통과 확인**

Run: `swift test --filter WikiIngestModelsTests 2>&1 | grep -E "Executed" | tail -1`
Expected: `Executed 23 tests, with 0 failures` (기존 15 + 신규 8)

- [ ] **Step 5: 커밋**

```bash
git add Sources/Services/WikiIngestModels.swift Tests/CmdMDTests/WikiIngestModelsTests.swift
git commit -m "기능(위키): 프롬프트 규칙 주입·자동 배치 마커 파싱·경로 4중 검증 (스펙 §2.3-2.4)"
```

---

### Task 2: WikiPageLister — 재귀 페이지 목록(순수)

**Files:**
- Create: `Sources/Services/WikiPageLister.swift`
- Test: `Tests/CmdMDTests/WikiPageListerTests.swift`

**Interfaces:**
- Consumes: 없음(FileManager만).
- Produces: `enum WikiPageLister { static func relativePages(under root: URL) -> [String] }` — 위키 루트 아래 전체 `.md`의 상대경로, 숨김 디렉터리/파일 제외, `localizedStandardCompare` 이름순.

- [ ] **Step 1: 실패하는 테스트 작성**

`Tests/CmdMDTests/WikiPageListerTests.swift`:

```swift
import XCTest
@testable import CmdMD

/// 위키 재귀 페이지 목록(스펙 §2.6) — 하위 폴더 포함·숨김 제외·상대경로·이름순.
final class WikiPageListerTests: XCTestCase {
    var root: URL!

    override func setUp() {
        super.setUp()
        root = TempDataDirectory.make()
    }
    override func tearDown() {
        TempDataDirectory.cleanup(root)
        super.tearDown()
    }

    private func touch(_ rel: String) {
        let url = root.appendingPathComponent(rel)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        try? "x".write(to: url, atomically: true, encoding: .utf8)
    }

    func testListsRecursivelyWithRelativePathsSorted() {
        touch("index.md")
        touch("references/신진욱2011.md")
        touch("references/Baker_1993.md")
        touch("claims/c1.md")
        touch("notes.txt")                       // 비md 제외
        let pages = WikiPageLister.relativePages(under: root)
        XCTAssertEqual(pages, ["claims/c1.md",
                               "index.md",
                               "references/Baker_1993.md",
                               "references/신진욱2011.md"])
    }

    func testExcludesHiddenDirectoriesAndFiles() {
        touch(".git/objects/a.md")
        touch(".obsidian/config.md")
        touch(".hidden.md")
        touch("visible.md")
        XCTAssertEqual(WikiPageLister.relativePages(under: root), ["visible.md"])
    }

    func testEmptyOrMissingRootReturnsEmpty() {
        XCTAssertEqual(WikiPageLister.relativePages(under: root), [])
        XCTAssertEqual(WikiPageLister.relativePages(
            under: root.appendingPathComponent("없는폴더")), [])
    }
}
```

- [ ] **Step 2: 실패 확인**

Run: `swift test --filter WikiPageListerTests 2>&1 | grep -E "error|Executed" | head -3`
Expected: 컴파일 실패(`WikiPageLister` 미존재).

- [ ] **Step 3: 구현**

`Sources/Services/WikiPageLister.swift`:

```swift
import Foundation

/// 위키 루트 아래 페이지(.md) 목록 — 인제스트 대상 Picker용(스펙 §2.6).
/// 하위 폴더 포함 상대경로, 숨김(점 시작) 디렉터리·파일 제외, 이름순.
enum WikiPageLister {
    static func relativePages(under root: URL) -> [String] {
        guard let enumerator = FileManager.default.enumerator(atPath: root.path) else { return [] }
        var pages: [String] = []
        for case let rel as String in enumerator {
            let components = rel.components(separatedBy: "/")
            if components.contains(where: { $0.hasPrefix(".") }) { continue }
            guard rel.lowercased().hasSuffix(".md") else { continue }
            pages.append(rel)
        }
        return pages.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}
```

- [ ] **Step 4: 통과 확인**

Run: `swift test --filter WikiPageListerTests 2>&1 | grep Executed | tail -1`
Expected: `Executed 3 tests, with 0 failures`

- [ ] **Step 5: 커밋**

```bash
git add Sources/Services/WikiPageLister.swift Tests/CmdMDTests/WikiPageListerTests.swift
git commit -m "기능(위키): WikiPageLister — 재귀 페이지 목록(상대경로·숨김 제외·이름순)"
```

---

### Task 3: WikiRulesService — 규칙 파악(1회 요약)

**Files:**
- Create: `Sources/Services/WikiRulesService.swift`
- Test: `Tests/CmdMDTests/WikiRulesServiceTests.swift`

**Interfaces:**
- Consumes: `protocol ClaudeAsking`(`Sources/Services/ClaudeService.swift:13`), `ClaudeError.timeout`.
- Produces:
  - `enum WikiRulesError: Error, Equatable { case noRuleSources, badResponse }`
  - `actor WikiRulesService`: `init(claude: any ClaudeAsking)`, `func captureRules(wikiFolder: URL) async throws -> String`
  - `static let sourceInputLimit = 40_000`, `static let summaryLimit = 8_000`
  - `static func collectRuleSources(wikiFolder: URL) -> String?` — CLAUDE.md + templates/*.md(이름순), 파일별 `## 파일: <이름>` 헤더로 연결. 하나도 없으면 nil.

- [ ] **Step 1: 실패하는 테스트 작성**

`Tests/CmdMDTests/WikiRulesServiceTests.swift`:

```swift
import XCTest
@testable import CmdMD

/// 위키 규칙 파악(스펙 §2.1) — 규칙 소스 수집·추출 프롬프트·요약 검증. FakeClaude 주입.
final class WikiRulesServiceTests: XCTestCase {
    var wikiDir: URL!

    override func setUp() {
        super.setUp()
        wikiDir = TempDataDirectory.make()
    }
    override func tearDown() {
        TempDataDirectory.cleanup(wikiDir)
        super.tearDown()
    }

    private actor FakeClaude: ClaudeAsking {
        let response: String
        private(set) var calls: [(prompt: String, context: String)] = []
        init(response: String) { self.response = response }
        func ask(prompt: String, context: String) async throws -> String {
            calls.append((prompt, context))
            return response
        }
        func lastPrompt() -> String? { calls.last?.prompt }
        func lastContext() -> String? { calls.last?.context }
    }

    private func seedRules(claudeMd: String? = "# 규칙\n한국어로 쓴다.",
                           templates: [String: String] = [:]) {
        if let claudeMd {
            try? claudeMd.write(to: wikiDir.appendingPathComponent("CLAUDE.md"),
                                atomically: true, encoding: .utf8)
        }
        if !templates.isEmpty {
            let dir = wikiDir.appendingPathComponent("templates")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for (name, body) in templates {
                try? body.write(to: dir.appendingPathComponent(name),
                                atomically: true, encoding: .utf8)
            }
        }
    }

    func testCollectGathersClaudeMdAndTemplatesInOrder() {
        seedRules(claudeMd: "루트 규칙",
                  templates: ["b_concept.md": "개념 템플릿", "a_paper.md": "논문 템플릿"])
        let src = WikiRulesService.collectRuleSources(wikiFolder: wikiDir)
        XCTAssertNotNil(src)
        let s = src!
        XCTAssertTrue(s.contains("루트 규칙"))
        // 템플릿은 이름순(a_paper 먼저), 파일별 헤더 포함.
        let aPos = s.range(of: "a_paper.md")!.lowerBound
        let bPos = s.range(of: "b_concept.md")!.lowerBound
        XCTAssertLessThan(aPos, bPos)
        XCTAssertTrue(s.contains("## 파일:"))
    }

    func testCollectReturnsNilWithoutAnySources() {
        XCTAssertNil(WikiRulesService.collectRuleSources(wikiFolder: wikiDir))
    }

    func testCaptureRulesReturnsSummary() async throws {
        seedRules()
        let fake = FakeClaude(response: "- 모든 문서는 한국어.\n- references/에 저자연도.md로.")
        let service = WikiRulesService(claude: fake)
        let summary = try await service.captureRules(wikiFolder: wikiDir)
        XCTAssertTrue(summary.contains("한국어"))
        // 추출 프롬프트 계약 — 문서 생성 규칙만·워크플로우 제외 지시가 실려 있다.
        let prompt = await fake.lastPrompt()
        XCTAssertTrue(prompt?.contains("명명") == true)
        XCTAssertTrue(prompt?.contains("frontmatter") == true)
        XCTAssertTrue(prompt?.contains("워크플로우") == true)
        let ctx = await fake.lastContext()
        XCTAssertTrue(ctx?.contains("한국어로 쓴다") == true)
    }

    func testCaptureRulesThrowsWithoutSources() async {
        let service = WikiRulesService(claude: FakeClaude(response: "x"))
        do {
            _ = try await service.captureRules(wikiFolder: wikiDir)
            XCTFail("에러여야 함")
        } catch let e as WikiRulesError {
            XCTAssertEqual(e, .noRuleSources)
        } catch { XCTFail("다른 에러: \(error)") }
    }

    func testCaptureRulesRejectsEmptyResponse() async {
        seedRules()
        let service = WikiRulesService(claude: FakeClaude(response: "   \n "))
        do {
            _ = try await service.captureRules(wikiFolder: wikiDir)
            XCTFail("에러여야 함")
        } catch let e as WikiRulesError {
            XCTAssertEqual(e, .badResponse)
        } catch { XCTFail("다른 에러: \(error)") }
    }

    func testCaptureRulesTruncatesLongSummary() async throws {
        seedRules()
        let long = String(repeating: "규", count: WikiRulesService.summaryLimit + 500)
        let service = WikiRulesService(claude: FakeClaude(response: long))
        let summary = try await service.captureRules(wikiFolder: wikiDir)
        XCTAssertEqual(summary.count, WikiRulesService.summaryLimit)
    }

    func testCollectTruncatesOversizedInput() {
        seedRules(claudeMd: String(repeating: "가", count: WikiRulesService.sourceInputLimit + 1000))
        let src = WikiRulesService.collectRuleSources(wikiFolder: wikiDir)
        XCTAssertNotNil(src)
        XCTAssertLessThanOrEqual(src!.count, WikiRulesService.sourceInputLimit)
    }
}
```

- [ ] **Step 2: 실패 확인**

Run: `swift test --filter WikiRulesServiceTests 2>&1 | grep -E "error|Executed" | head -3`
Expected: 컴파일 실패(`WikiRulesService` 미존재).

- [ ] **Step 3: 구현**

`Sources/Services/WikiRulesService.swift`:

```swift
import Foundation

enum WikiRulesError: Error, Equatable {
    case noRuleSources     // CLAUDE.md·templates 어느 것도 없음 — 내장 기본 스키마로 동작
    case badResponse       // 요약이 빈 값
}

/// 위키 규칙 1회 파악(스펙 §2.1) — 위키의 CLAUDE.md·templates에서 "문서 생성에 적용할
/// 규칙만" 추출·요약한다. 요약은 설정에 저장돼 매 인제스트 프롬프트에 주입된다.
actor WikiRulesService {
    /// 규칙 소스 입력 상한 — 초과분 truncate + 프롬프트 고지.
    static let sourceInputLimit = 40_000
    /// 요약 상한 — 매 인제스트 프롬프트에 실리므로 간결해야 한다.
    static let summaryLimit = 8_000

    private let claude: any ClaudeAsking

    init(claude: any ClaudeAsking) {
        self.claude = claude
    }

    func captureRules(wikiFolder: URL) async throws -> String {
        guard let raw = Self.collectRuleSources(wikiFolder: wikiFolder) else {
            throw WikiRulesError.noRuleSources
        }
        let truncated = raw.count >= Self.sourceInputLimit
        let (prompt, context) = Self.capturePrompt(truncatedInput: truncated)
        let stdout = try await askWithRetry(prompt: prompt, context: context + raw)
        let summary = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty else { throw WikiRulesError.badResponse }
        return summary.count > Self.summaryLimit
            ? String(summary.prefix(Self.summaryLimit)) : summary
    }

    /// 규칙 소스 수집 — CLAUDE.md + templates/*.md(이름순), 파일별 헤더로 연결.
    /// 하나도 없으면 nil. 합계가 상한을 넘으면 앞에서부터 상한까지 truncate.
    static func collectRuleSources(wikiFolder: URL) -> String? {
        var parts: [String] = []
        let claudeMd = wikiFolder.appendingPathComponent("CLAUDE.md")
        if let body = try? String(contentsOf: claudeMd, encoding: .utf8) {
            parts.append("## 파일: CLAUDE.md\n\n\(body)")
        }
        let templatesDir = wikiFolder.appendingPathComponent("templates")
        if let names = try? FileManager.default.contentsOfDirectory(atPath: templatesDir.path) {
            for name in names.sorted() where name.lowercased().hasSuffix(".md") {
                if let body = try? String(contentsOf: templatesDir.appendingPathComponent(name),
                                          encoding: .utf8) {
                    parts.append("## 파일: templates/\(name)\n\n\(body)")
                }
            }
        }
        guard !parts.isEmpty else { return nil }
        let joined = parts.joined(separator: "\n\n---\n\n")
        return joined.count > sourceInputLimit ? String(joined.prefix(sourceInputLimit)) : joined
    }

    /// 추출 프롬프트 — 문서 생성 규칙만 추리고, 도구 실행이 필요한 워크플로우 규칙은 제외.
    static func capturePrompt(truncatedInput: Bool) -> (prompt: String, context: String) {
        var prompt = """
        아래는 한 지식 위키의 운영 규칙·템플릿 문서들이다. 이 위키에 **새 문서를 생성하거나 \
        기존 문서에 병합할 때 적용해야 할 규칙만** 추려, 간결한 지시문 목록으로 요약하라.

        반드시 포함할 것(문서에 있으면): 파일 명명 규칙, 문서 유형별로 새 문서가 놓일 폴더(상대 \
        경로), frontmatter 스키마(필드·형식), 언어 정책, 섹션 구조·필수 섹션(템플릿), 서술 \
        금지사항(예: 소스에 없는 내용 금지, 빈 섹션 허용).

        제외할 것: 도구 실행이 필요한 워크플로우 규칙(웹 다운로드, 다층 검증 절차, 인덱스/로그 \
        파일 갱신, 외부 파일 조작, git 조작). 단 검증 규칙의 정신은 "문서가 소스 발췌 기반임을 \
        명시하고, 소스에 없는 내용을 쓰지 말라" 수준의 서술 지침으로 반영하라.

        출력은 요약 지시문만 쓴다(서문·설명 금지). 한국어로 쓴다.
        """
        if truncatedInput {
            prompt += "\n주의: 입력 문서는 분량 한도로 잘린 발췌본이다."
        }
        return (prompt, "")
    }

    /// 타임아웃 1회 재시도(CleanupService 전례).
    private func askWithRetry(prompt: String, context: String) async throws -> String {
        do { return try await claude.ask(prompt: prompt, context: context) }
        catch ClaudeError.timeout { return try await claude.ask(prompt: prompt, context: context) }
    }
}
```

- [ ] **Step 4: 통과 확인**

Run: `swift test --filter WikiRulesServiceTests 2>&1 | grep Executed | tail -1`
Expected: `Executed 7 tests, with 0 failures`

- [ ] **Step 5: 커밋**

```bash
git add Sources/Services/WikiRulesService.swift Tests/CmdMDTests/WikiRulesServiceTests.swift
git commit -m "기능(위키): WikiRulesService — 규칙 소스 수집·문서 생성 규칙 추출 요약(40k/8k 한도) (스펙 §2.1)"
```

---

### Task 4: WikiIngestService.propose 확장 — .auto 분기 + rulesSummary

**Files:**
- Modify: `Sources/Services/WikiIngestService.swift`
- Test: `Tests/CmdMDTests/WikiIngestServiceTests.swift` (기존 호출부 시그니처 갱신 + 신규 케이스)

**Interfaces:**
- Consumes: Task 1의 `WikiIngestTarget.auto`·`mergePrompt(autoPlacement:rulesSummary:)`·`extractAutoPage`·`validatedAutoPageURL`.
- Produces:
  - `WikiIngestError`에 `case autoPathInvalid`(마커 없음/검증 실패), `case autoPathOccupied(String)`(제안 경로에 파일 존재 — payload는 상대경로) 추가.
  - `propose(source:target:wikiFolder:rulesSummary:today:)` — `rulesSummary: String?` 파라미터 추가(기존 호출은 nil 전달로 갱신).

- [ ] **Step 1: 실패하는 테스트 작성**

`Tests/CmdMDTests/WikiIngestServiceTests.swift`의 기존 `propose(...)` 호출 전부에 `rulesSummary: nil,`을 추가하고(컴파일 갱신), 신규 케이스 추가:

```swift
    func testProposeAutoParsesSuggestedPath() async throws {
        let merged = "<!-- page: references/신진욱2011.md -->\n# 신진욱2011\n\n요약"
        let fake = FakeClaude(response: merged)
        let service = WikiIngestService(claude: fake, kordoc: KordocService())
        let p = try await service.propose(source: makeSource(), target: .auto,
                                          wikiFolder: wikiDir, rulesSummary: "규칙",
                                          today: "2026-07-06")
        XCTAssertTrue(p.isNewPage)
        XCTAssertEqual(p.pageURL,
                       wikiDir.appendingPathComponent("references/신진욱2011.md"))
        XCTAssertFalse(p.newBody.contains("<!-- page:"))   // 마커는 본문에서 제거
        XCTAssertFalse(FileManager.default.fileExists(atPath: p.pageURL.path))  // 무쓰기
    }

    func testProposeAutoThrowsWithoutMarker() async {
        let fake = FakeClaude(response: "# 마커 없음\n본문")
        let service = WikiIngestService(claude: fake, kordoc: KordocService())
        do {
            _ = try await service.propose(source: makeSource(), target: .auto,
                                          wikiFolder: wikiDir, rulesSummary: "규칙",
                                          today: "2026-07-06")
            XCTFail("에러여야 함")
        } catch let e as WikiIngestError {
            XCTAssertEqual(e, .autoPathInvalid)
        } catch { XCTFail("다른 에러: \(error)") }
    }

    func testProposeAutoThrowsOnEscapePath() async {
        let fake = FakeClaude(response: "<!-- page: ../밖.md -->\n# x\n본문")
        let service = WikiIngestService(claude: fake, kordoc: KordocService())
        do {
            _ = try await service.propose(source: makeSource(), target: .auto,
                                          wikiFolder: wikiDir, rulesSummary: nil,
                                          today: "2026-07-06")
            XCTFail("에러여야 함")
        } catch let e as WikiIngestError {
            XCTAssertEqual(e, .autoPathInvalid)
        } catch { XCTFail("다른 에러: \(error)") }
    }

    func testProposeAutoThrowsWhenPathOccupied() async throws {
        let refDir = wikiDir.appendingPathComponent("references")
        try FileManager.default.createDirectory(at: refDir, withIntermediateDirectories: true)
        try "# 기존".write(to: refDir.appendingPathComponent("신진욱2011.md"),
                          atomically: true, encoding: .utf8)
        let fake = FakeClaude(response: "<!-- page: references/신진욱2011.md -->\n# x\n본문")
        let service = WikiIngestService(claude: fake, kordoc: KordocService())
        do {
            _ = try await service.propose(source: makeSource(), target: .auto,
                                          wikiFolder: wikiDir, rulesSummary: nil,
                                          today: "2026-07-06")
            XCTFail("에러여야 함")
        } catch let e as WikiIngestError {
            XCTAssertEqual(e, .autoPathOccupied("references/신진욱2011.md"))
        } catch { XCTFail("다른 에러: \(error)") }
    }

    func testProposeExistingPassesRulesSummaryToPrompt() async throws {
        let page = wikiDir.appendingPathComponent("주제.md")
        try "# 주제\n\n기존 본문".write(to: page, atomically: true, encoding: .utf8)
        let fake = FakeClaude(response: "# 주제\n\n기존 본문\n\n추가")
        let service = WikiIngestService(claude: fake, kordoc: KordocService())
        _ = try await service.propose(source: makeSource(), target: .existing(page),
                                      wikiFolder: wikiDir, rulesSummary: "반말로 쓴다",
                                      today: "2026-07-06")
        let calls = await fake.calls
        XCTAssertTrue(calls.last?.prompt.contains("반말로 쓴다") == true)
    }
```

(기존 FakeClaude에 `var calls`가 private(set)이면 접근자 추가 — 파일 내 기존 패턴 유지.)

- [ ] **Step 2: 실패 확인**

Run: `swift test --filter WikiIngestServiceTests 2>&1 | grep -E "error|Executed" | head -5`
Expected: 컴파일 실패(`rulesSummary` 파라미터·`.auto`·신규 에러 케이스 미존재).

- [ ] **Step 3: 구현**

`Sources/Services/WikiIngestService.swift`:

**(a)** 에러 케이스 추가:

```swift
enum WikiIngestError: Error, Equatable {
    case sourceUnreadable
    case pageUnreadable
    case pageTooLarge
    case invalidNewPageName
    case badResponse
    case autoPathInvalid           // 자동 배치 — 마커 없음/경로 검증 실패
    case autoPathOccupied(String)  // 자동 배치 — 제안 경로에 이미 페이지 존재(상대경로)
}
```

**(b)** `propose` 재구성(auto 분기 — 자동은 응답 파싱이 달라 별도 경로):

```swift
    func propose(source: URL, target: WikiIngestTarget,
                 wikiFolder: URL, rulesSummary: String?,
                 today: String) async throws -> WikiMergeProposal {
        guard let sourceBody = await ContentExtractor.body(for: source, kordoc: kordoc) else {
            throw WikiIngestError.sourceUnreadable
        }
        let (excerpt, truncated) = WikiIngestModels.truncatedExcerpt(sourceBody)

        // 자동 배치 — Claude가 위치·파일명을 마커로 제안(스펙 §2.4).
        if case .auto = target {
            let title = source.deletingPathExtension().lastPathComponent
            let (prompt, context) = WikiIngestModels.mergePrompt(
                pageTitle: title, pageBody: "",
                sourceName: source.lastPathComponent, sourceExcerpt: excerpt,
                excerptTruncated: truncated, isNewPage: true,
                autoPlacement: true, rulesSummary: rulesSummary, today: today)
            let stdout = try await askWithRetry(prompt: prompt, context: context)
            guard let (relPath, rawBody) = WikiIngestModels.extractAutoPage(from: stdout),
                  let pageURL = WikiIngestModels.validatedAutoPageURL(
                      relativePath: relPath, wikiFolder: wikiFolder) else {
                throw WikiIngestError.autoPathInvalid
            }
            guard !FileManager.default.fileExists(atPath: pageURL.path) else {
                throw WikiIngestError.autoPathOccupied(relPath)
            }
            guard let newBody = WikiIngestModels.extractMarkdown(from: rawBody,
                                                                 oldBodyLength: 0) else {
                throw WikiIngestError.badResponse
            }
            return WikiMergeProposal(pageURL: pageURL, isNewPage: true,
                                     oldBody: "", newBody: newBody, sourceURL: source)
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
        case .auto:
            // 도달 불가(위에서 조기 반환) — switch 전수성용. 크래시 대신 안전한 에러.
            throw WikiIngestError.autoPathInvalid
        }

        let title = pageURL.deletingPathExtension().lastPathComponent
        let (prompt, context) = WikiIngestModels.mergePrompt(
            pageTitle: title, pageBody: oldBody,
            sourceName: source.lastPathComponent, sourceExcerpt: excerpt,
            excerptTruncated: truncated, isNewPage: isNewPage,
            rulesSummary: rulesSummary, today: today)

        let stdout = try await askWithRetry(prompt: prompt, context: context)
        guard let newBody = WikiIngestModels.extractMarkdown(from: stdout,
                                                             oldBodyLength: oldBody.count) else {
            throw WikiIngestError.badResponse
        }
        return WikiMergeProposal(pageURL: pageURL, isNewPage: isNewPage,
                                 oldBody: oldBody, newBody: newBody, sourceURL: source)
    }
```

**(c)** `AppState.generateWikiMerge`(AppState.swift:3352 부근)의 `propose` 호출에 `rulesSummary:` 인자 자리가 필요해 **컴파일이 깨진다** — 이 태스크에서는 최소 갱신만: `rulesSummary: nil`을 넣어 컴파일 유지(실제 전달은 Task 5 몫, 주석으로 표시).

```swift
            wikiMergeProposal = try await wikiIngestService.propose(
                source: source, target: target,
                wikiFolder: URL(fileURLWithPath: folderPath),
                rulesSummary: nil,   // Task 5에서 settings.wikiRulesSummary 전달로 교체
                today: today)
```

- [ ] **Step 4: 통과 확인 + 전체 회귀**

Run: `swift test --filter WikiIngestServiceTests 2>&1 | grep Executed | tail -1`
Expected: `Executed 12 tests, with 0 failures` (기존 7 + 신규 5)
Run: `swift test 2>&1 | grep -E "Executed [0-9]+ tests" | tail -1` → 전체 GREEN.

- [ ] **Step 5: 커밋**

```bash
git add Sources/Services/WikiIngestService.swift Sources/App/AppState.swift Tests/CmdMDTests/WikiIngestServiceTests.swift
git commit -m "기능(위키): propose에 .auto 분기(경로 마커 왕복·점유 에러)와 rulesSummary 전달 (스펙 §2.5)"
```

---

### Task 5: 설정 필드 + AppState 배선(규칙 파악·규칙 전달·중간 디렉터리)

**Files:**
- Modify: `Sources/Models/Settings.swift` (필드 2개 + decodeIfPresent 2줄)
- Modify: `Sources/App/AppState.swift` (wikiRulesService 조립·captureWikiRules·generateWikiMerge rulesSummary 전달·에러 매핑·applyWikiMerge 중간 디렉터리)
- Test: `Tests/CmdMDTests/AppWikiIngestStateTests.swift` (기존 파일에 추가)

**Interfaces:**
- Consumes: Task 3 `WikiRulesService`/`WikiRulesError`, Task 4 `propose(rulesSummary:)`·신규 에러 케이스.
- Produces(Task 6 UI가 사용):
  - `AppSettings.wikiRulesSummary: String?`, `AppSettings.wikiRulesCapturedAt: Date?`
  - `AppState`: `var wikiRulesService: WikiRulesService`(테스트 교체용 var), `var wikiRulesBusy: Bool`, `var wikiRulesMessage: String?`, `func captureWikiRules() async -> Bool`
  - `generateWikiMerge`가 `settings.wikiRulesSummary`(공백 trim 후 비면 nil)를 전달.
  - `applyWikiMerge`가 쓰기 전 중간 디렉터리 생성(`withIntermediateDirectories`).

- [ ] **Step 1: 실패하는 테스트 작성**

`Tests/CmdMDTests/AppWikiIngestStateTests.swift`에 추가:

```swift
    private actor RecordingClaude: ClaudeAsking {
        let response: String
        private(set) var prompts: [String] = []
        init(response: String) { self.response = response }
        func ask(prompt: String, context: String) async throws -> String {
            prompts.append(prompt)
            return response
        }
        func lastPrompt() -> String? { prompts.last }
    }

    func testCaptureWikiRulesStoresSummaryAndDate() async throws {
        try "# 규칙\n한국어로 쓴다.".write(
            to: wikiDir.appendingPathComponent("CLAUDE.md"), atomically: true, encoding: .utf8)
        app.wikiRulesService = WikiRulesService(claude: RecordingClaude(response: "- 한국어 전용"))
        let ok = await app.captureWikiRules()
        XCTAssertTrue(ok)
        XCTAssertEqual(app.settings.wikiRulesSummary, "- 한국어 전용")
        XCTAssertNotNil(app.settings.wikiRulesCapturedAt)
        XCTAssertFalse(app.wikiRulesBusy)
    }

    func testCaptureWikiRulesWithoutSourcesSetsMessage() async {
        app.wikiRulesService = WikiRulesService(claude: RecordingClaude(response: "x"))
        let ok = await app.captureWikiRules()   // wikiDir에 규칙 파일 없음
        XCTAssertFalse(ok)
        XCTAssertNotNil(app.wikiRulesMessage)
        XCTAssertNil(app.settings.wikiRulesSummary)
    }

    func testGenerateWikiMergePassesStoredRulesSummary() async {
        app.settings.wikiRulesSummary = "반말로 쓴다"
        let claude = RecordingClaude(response: "# 새주제\n\n요약")
        app.wikiIngestService = WikiIngestService(claude: claude, kordoc: KordocService())
        await app.generateWikiMerge(source: makeSource(), target: .new(name: "새주제"))
        let prompt = await claude.lastPrompt()
        XCTAssertTrue(prompt?.contains("반말로 쓴다") == true)
    }

    func testGenerateWikiMergeMapsAutoErrors() async {
        app.settings.wikiRulesSummary = "규칙"
        app.wikiIngestService = WikiIngestService(
            claude: RecordingClaude(response: "# 마커 없음"), kordoc: KordocService())
        await app.generateWikiMerge(source: makeSource(), target: .auto)
        XCTAssertNil(app.wikiMergeProposal)
        XCTAssertNotNil(app.wikiIngestError)
    }

    func testApplyCreatesIntermediateDirectoriesForAutoPage() async {
        let page = wikiDir.appendingPathComponent("references/새논문.md")   // references/ 미존재
        let proposal = WikiMergeProposal(pageURL: page, isNewPage: true,
                                         oldBody: "", newBody: "# 새논문\n요약",
                                         sourceURL: makeSource())
        let dest = await app.applyWikiMerge(proposal)
        XCTAssertNotNil(dest)
        XCTAssertEqual(try? String(contentsOf: dest!, encoding: .utf8), "# 새논문\n요약")
    }

    func testWikiRulesSettingsDecodeBackwardCompatible() throws {
        let old = "{\"hasCompletedOnboarding\": true}".data(using: .utf8)!
        let decoded = try JSONDecoder().decode(AppSettings.self, from: old)
        XCTAssertNil(decoded.wikiRulesSummary)
        XCTAssertNil(decoded.wikiRulesCapturedAt)
    }
```

- [ ] **Step 2: 실패 확인**

Run: `swift test --filter AppWikiIngestStateTests 2>&1 | grep -E "error|Executed" | head -5`
Expected: 컴파일 실패(`wikiRulesService`·`captureWikiRules` 등 미존재).

- [ ] **Step 3: 구현**

**(a)** `Sources/Models/Settings.swift` — `wikiFolder` 선언 옆에:

```swift
    var wikiRulesSummary: String? = nil      // 위키 규칙 요약(파악 결과·사용자 편집 가능)
    var wikiRulesCapturedAt: Date? = nil     // 규칙 파악 일시(표시용)
```

`init(from decoder:)`에:

```swift
        wikiRulesSummary = try c.decodeIfPresent(String.self, forKey: .wikiRulesSummary) ?? d.wikiRulesSummary
        wikiRulesCapturedAt = try c.decodeIfPresent(Date.self, forKey: .wikiRulesCapturedAt) ?? d.wikiRulesCapturedAt
```

**(b)** `Sources/App/AppState.swift`:

프로퍼티(위키 인제스트 상태 블록에 이어서):

```swift
    var wikiRulesBusy: Bool = false
    var wikiRulesMessage: String? = nil
```

서비스(wikiIngestService 옆):

```swift
    var wikiRulesService: WikiRulesService   // var — 테스트에서 가짜 Claude 주입
```

init 조립(wikiIngestService 조립 옆):

```swift
        wikiRulesService = WikiRulesService(claude: claudeService)
```

메서드(위키 인제스트 섹션에 이어서):

```swift
    /// 위키 규칙 파악(스펙 §2.1) — 성공 시 요약·일시를 설정에 저장. 성공 여부 반환.
    func captureWikiRules() async -> Bool {
        guard !wikiRulesBusy else { return false }
        guard let folderPath = settings.wikiFolder else {
            wikiRulesMessage = "위키 폴더가 설정되지 않았습니다."
            return false
        }
        wikiRulesBusy = true
        wikiRulesMessage = nil
        defer { wikiRulesBusy = false }
        do {
            let summary = try await wikiRulesService.captureRules(
                wikiFolder: URL(fileURLWithPath: folderPath))
            settings.wikiRulesSummary = summary
            settings.wikiRulesCapturedAt = Date()
            saveUserData()
            wikiRulesMessage = "규칙을 파악했습니다."
            return true
        } catch WikiRulesError.noRuleSources {
            wikiRulesMessage = "규칙 파일(CLAUDE.md·templates)이 없습니다 — 내장 기본 스키마로 동작합니다."
            return false
        } catch {
            wikiRulesMessage = "규칙 파악에 실패했습니다: \(error.localizedDescription)"
            return false
        }
    }
```

`generateWikiMerge`의 propose 호출 교체(Task 4의 `rulesSummary: nil` 임시분):

```swift
            let trimmedRules = settings.wikiRulesSummary?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            wikiMergeProposal = try await wikiIngestService.propose(
                source: source, target: target,
                wikiFolder: URL(fileURLWithPath: folderPath),
                rulesSummary: (trimmedRules?.isEmpty == false) ? trimmedRules : nil,
                today: today)
```

`wikiErrorMessage`에 신규 케이스 추가:

```swift
        case .autoPathInvalid:
            return "자동 위치 제안에 실패했습니다 — 새 페이지 이름을 직접 입력해 보세요."
        case .autoPathOccupied(let rel):
            return "규칙상 위치에 같은 페이지가 이미 있습니다: \(rel) — 대상 목록에서 그 페이지를 선택하세요."
```

`applyWikiMerge`의 write 직전에 중간 디렉터리 생성(자동 배치가 references/ 등 없는 폴더를 제안할 수 있음):

```swift
            try FileManager.default.createDirectory(
                at: dest.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try proposal.newBody.write(to: dest, atomically: true, encoding: .utf8)
```

- [ ] **Step 4: 통과 확인 + 전체 회귀**

Run: `swift test --filter AppWikiIngestStateTests 2>&1 | grep Executed | tail -1`
Expected: `Executed 17 tests, with 0 failures` (기존 11 + 신규 6)
Run: `swift test 2>&1 | grep -E "Executed [0-9]+ tests" | tail -1` → 전체 GREEN.

- [ ] **Step 5: 커밋**

```bash
git add Sources/Models/Settings.swift Sources/App/AppState.swift Tests/CmdMDTests/AppWikiIngestStateTests.swift
git commit -m "기능(위키): 규칙 파악 배선 — 설정 저장(요약·일시)·병합에 규칙 전달·자동 에러 매핑·중간 디렉터리 (스펙 §2.2·§2.5)"
```

---

### Task 6: UI — 설정 Wiki 탭 + 인제스트 시트(재귀 목록·자동 옵션·경로 표시)

**Files:**
- Modify: `Sources/Views/SettingsView.swift` (Wiki 탭 신설·Tools의 LLM-Wiki 섹션 축소)
- Modify: `Sources/Views/WikiIngestView.swift` (재귀 목록·자동 옵션·diff 헤더 경로)

**Interfaces:**
- Consumes: Task 5의 AppState API(`captureWikiRules`·`wikiRulesBusy`·`wikiRulesMessage`·settings 필드), Task 2 `WikiPageLister.relativePages(under:)`, Task 1 `WikiIngestTarget.auto`.
- Produces: 사용자 대면 UI(수동 스모크 대상).

- [ ] **Step 1: SettingsView — Wiki 탭 신설**

`Sources/Views/SettingsView.swift`의 `TabView`(5행) 안, Tools 탭 다음에:

```swift
            WikiSettingsView()
                .tabItem {
                    Label("Wiki", systemImage: "text.book.closed")
                }
```

파일 하단에 뷰 추가(기존 ToolsSettingsView의 `Form`/`Section` 스타일 준수):

```swift
/// LLM-Wiki 설정(스펙 §2.6) — 위키 루트 지정·규칙 파악·요약 검토/수정.
struct WikiSettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState
        Form {
            Section("위키 폴더") {
                HStack {
                    Text(appState.settings.wikiFolder ?? "설정 안 됨")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button(appState.settings.wikiFolder == nil ? "지정…" : "변경…") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        panel.allowsMultipleSelection = false
                        if panel.runModal() == .OK, let url = panel.url {
                            // 심링크는 실경로로 정규화(규칙 파일·페이지 나열의 기준 경로).
                            appState.settings.wikiFolder = url.resolvingSymlinksInPath().path
                            appState.saveUserData()
                        }
                    }
                }
                Text("위키의 루트 폴더를 지정합니다 — 규칙 파일(CLAUDE.md·templates/)이 있는 곳.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("위키 규칙") {
                HStack(spacing: 10) {
                    Button(appState.settings.wikiRulesSummary == nil ? "위키 규칙 파악" : "재파악") {
                        Task { await appState.captureWikiRules() }
                    }
                    .disabled(appState.settings.wikiFolder == nil || appState.wikiRulesBusy)
                    if appState.wikiRulesBusy {
                        ProgressView().controlSize(.small)
                        Text("Claude가 규칙을 읽는 중…")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if let at = appState.settings.wikiRulesCapturedAt {
                        Text("파악: \(at.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let message = appState.wikiRulesMessage {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
                TextEditor(text: Binding(
                    get: { state.settings.wikiRulesSummary ?? "" },
                    set: { newValue in
                        state.settings.wikiRulesSummary = newValue.isEmpty ? nil : newValue
                        state.saveUserData()
                    }))
                    .font(.system(.caption, design: .monospaced))
                    .frame(minHeight: 160)
                Text("인제스트가 이 요약을 따릅니다. 직접 수정할 수 있고, 재파악하면 덮어씁니다(수정분 유실 주의).")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}
```

Tools 탭의 기존 "LLM-Wiki" `Section`(763행 부근)은 본문을 다음 한 줄로 교체:

```swift
            Section("LLM-Wiki") {
                Text("위키 설정은 Wiki 탭으로 이동했습니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
```

- [ ] **Step 2: WikiIngestView — 재귀 목록·자동 옵션·경로 표시**

`Sources/Views/WikiIngestView.swift` 수정:

**(a)** 마커 상수·상태(17행 부근):

```swift
    private static let newMarker = "__NEW__"
    private static let autoMarker = "__AUTO__"
    @State private var pages: [String] = []     // 위키 루트 기준 상대경로(기존 [URL]에서 교체)
```

**(b)** `target` 계산(24행 부근) 교체:

```swift
    private var target: WikiIngestTarget? {
        if selection == Self.autoMarker { return .auto }
        if selection == Self.newMarker {
            let name = newPageName.trimmingCharacters(in: .whitespaces)
            return name.isEmpty ? nil : .new(name: name)
        }
        guard !selection.isEmpty, let root = wikiFolderURL else { return nil }
        return .existing(root.appendingPathComponent(selection))
    }
```

**(c)** `targetPicker`(95행 부근) 교체:

```swift
    private var targetPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("대상 페이지", selection: $selection) {
                Text("선택…").tag("")
                if appState.settings.wikiRulesSummary?.isEmpty == false {
                    Text("자동(규칙에 따름)").tag(Self.autoMarker)
                }
                Divider()
                ForEach(pages, id: \.self) { rel in
                    Text(rel.hasSuffix(".md") ? String(rel.dropLast(3)) : rel).tag(rel)
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
```

**(d)** `reload()`(208행 부근)의 페이지 나열을 `WikiPageLister`로 교체:

```swift
        if let folder = wikiFolderURL {
            pages = WikiPageLister.relativePages(under: folder)
        } else {
            pages = []
        }
```

**(e)** diff 헤더(`diffSection`의 제목 Text) — 상대경로 표시로 교체:

```swift
            Text(proposal.isNewPage
                 ? "새 페이지: \(relativeDisplayPath(proposal.pageURL))"
                 : "변경 미리보기: \(relativeDisplayPath(proposal.pageURL))")
                .font(.subheadline).bold()
```

헬퍼 추가:

```swift
    /// 위키 루트 기준 상대경로 표시(자동 제안 경로 확인용 — 스펙 §2.6). 루트 밖이면 파일명만.
    private func relativeDisplayPath(_ url: URL) -> String {
        guard let root = wikiFolderURL else { return url.lastPathComponent }
        let rootPath = root.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        return path.hasPrefix(rootPath) ? String(path.dropFirst(rootPath.count)) : url.lastPathComponent
    }
```

- [ ] **Step 3: 게이트**

Run: `swift build 2>&1 | grep -ci warning` → `0`
Run: `swift test 2>&1 | grep -E "Executed [0-9]+ tests" | tail -1` → 전체 GREEN.

- [ ] **Step 4: 커밋**

```bash
git add Sources/Views/SettingsView.swift Sources/Views/WikiIngestView.swift
git commit -m "기능(위키): 설정 Wiki 탭(폴더·규칙 파악·요약 편집) + 시트 재귀 목록·자동 옵션·상대경로 표시 (스펙 §2.6)"
```

---

## 계획 밖(코디네이터 몫)

- 최종 whole-branch 리뷰 → fix wave → CLAUDE.md·데일리·재패키징.
- 수동 스모크(스펙 §4): socwiki 실규칙 파악(요약 품질), 신진욱2011 재인제스트가 socwiki 규칙대로 나오는지, 자동 위치 제안 실측 — Claude 실호출이라 실기만 가능.
