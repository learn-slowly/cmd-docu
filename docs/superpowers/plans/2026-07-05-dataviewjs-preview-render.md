# dataviewjs 프리뷰 렌더 구현 계획

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 옵시디언 dataviewjs 블록(주간·월간 회고 표/목록)을 cmdALL 프리뷰에서 렌더한다.

**Architecture:** 블록 코드를 WKWebView가 아니라 JSContext(JavaScriptCore)에서 실행한다. `dv` shim(JS)+luxon(로컬 동봉)을 올리고, `dv.pages(...)`의 동기 네이티브 콜백이 페이지 메타 인덱스(mtime 캐시)에서 JSON을 공급한다. `dv.table/list/…` 호출을 수집해 Swift에서 HTML로 직렬화, 프리뷰의 placeholder를 `evaluateJavaScript`로 교체한다. 볼트 안 노트만 자동 실행, 밖은 클릭-투-런.

**Tech Stack:** Swift 5.9/SwiftUI, JavaScriptCore(시스템), luxon 3.x(로컬 자산), XCTest.

**스펙:** `docs/superpowers/specs/2026-07-05-dataviewjs-preview-render-design.md` (승인됨). 스펙과의 의도적 차이 1건: 스펙 §5는 `DataviewPageIndex`를 actor로 적었으나 JSContext 동기 콜백에서 actor를 await할 수 없으므로 **NSLock 캐시를 든 final class**로 구현한다(Task 8에서 스펙 정정).

## Global Constraints

- 비샌드박스 유지. 새 패키지 의존성 0 — JavaScriptCore는 시스템 프레임워크, luxon은 로컬 자산 동봉.
- 신규 코드는 전부 별도 파일(업스트림 머지 용이). 기존 파일은 가산·최소 수정만.
- 코드 주석·커밋 메시지는 한국어. 커밋 트레일러 2줄 필수:
  `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>` / `Claude-Session: https://claude.ai/code/session_01KkbE4Y2c6XkrPDLLW4apUG`
- 각 태스크 끝에 `swift test` 전체 통과(기준선 603 = XCTest 585+Testing 18, 신규 포함 증가만 허용). 빌드 경고 0 유지.
- 읽기 전용 기능 — 어떤 경로에서도 노트 파일을 쓰거나 이동·삭제하지 않는다.
- 비지원 API(dv.el/view/io/query)는 조용히 무시하지 말고 한국어 오류로 폴백(스펙 §8).
- 지원 확장자: md/markdown만 색인(스펙 §5).

## 파일 구조 총람

| 파일 | 역할 |
|---|---|
| `Sources/Services/DataviewBlockExtractor.swift` (신규) | 순수: ```dataviewjs 펜스 추출·placeholder 치환 |
| `Sources/Models/DataviewPageMeta.swift` (신규) | 순수: 페이지 메타 모델(Codable)+단일 파일 파서 |
| `Sources/Services/DataviewPageIndex.swift` (신규) | 스레드 세이프 클래스: 폴더 재귀·mtime 캐시·태그/단건 조회+루트별 레지스트리 |
| `Sources/Resources/web/luxon/luxon.min.js` (신규, vendor) | luxon 3.x |
| `Sources/Resources/web/dataview/dv-shim.js` (신규, 수제) | dv API 서브셋 shim |
| `Sources/Services/DataviewOutput.swift` (신규) | 순수: 출력 모델+HTML 직렬화+오류 카드 |
| `Sources/Services/DataviewEngine.swift` (신규) | JSContext 실행·동기 브릿지·3s 타임아웃 |
| `Sources/Services/DataviewRunPolicy.swift` (신규) | 순수: 자동/클릭-투-런 판정·루트 해석 |
| `Sources/Services/LocalWebAssets.swift` (수정) | luxonJS·dvShimJS 자산 추가 |
| `Sources/Services/MarkdownRenderer.swift` (수정) | `wikiLinkHref(target:)` static 추출(기존 processWikiLinks가 재사용) |
| `Sources/Views/PreviewView.swift` (수정) | 추출·자동/수동 placeholder·백그라운드 실행·교체 주입·dataviewRun 메시지 |
| `scripts/vendor_web_assets.sh` (수정) | luxon 다운로드 추가 |
| `THIRD-PARTY-NOTICES.md` (수정) | luxon(MIT) 고지 |

---

### Task 1: DataviewBlockExtractor (순수)

**Files:**
- Create: `Sources/Services/DataviewBlockExtractor.swift`
- Test: `Tests/CmdMDTests/DataviewBlockExtractorTests.swift`

**Interfaces:**
- Produces: `struct DataviewBlock: Equatable { let id: Int; let code: String }`
- Produces: `DataviewBlockExtractor.extract(_ markdown: String, placeholderHTML: (Int) -> String) -> (markdown: String, blocks: [DataviewBlock])`
- placeholder는 호출자가 만든 HTML(자동=스피너/수동=코드+버튼, Task 7). 마크다운에 raw HTML로 삽입 — 기존 processCallouts가 같은 방식으로 HTML을 선주입하므로 파서 통과가 검증돼 있다.

- [ ] **Step 1: 실패하는 테스트 작성**

```swift
import XCTest
@testable import CmdMD

final class DataviewBlockExtractorTests: XCTestCase {

    private func placeholder(_ id: Int) -> String { "<div id=\"dv-b\(id)\">PH\(id)</div>" }

    func testExtractsSingleBlock() {
        let md = """
        # 제목

        ```dataviewjs
        dv.paragraph("hi");
        ```

        본문
        """
        let r = DataviewBlockExtractor.extract(md, placeholderHTML: placeholder)
        XCTAssertEqual(r.blocks.count, 1)
        XCTAssertEqual(r.blocks[0].id, 0)
        XCTAssertEqual(r.blocks[0].code, "dv.paragraph(\"hi\");")
        XCTAssertTrue(r.markdown.contains("<div id=\"dv-b0\">PH0</div>"))
        XCTAssertFalse(r.markdown.contains("```dataviewjs"))
        XCTAssertTrue(r.markdown.contains("본문"), "블록 밖 본문 보존")
    }

    func testMultipleBlocksGetSequentialIds() {
        let md = "```dataviewjs\na\n```\n중간\n```dataviewjs\nb\n```"
        let r = DataviewBlockExtractor.extract(md, placeholderHTML: placeholder)
        XCTAssertEqual(r.blocks.map(\.id), [0, 1])
        XCTAssertEqual(r.blocks.map(\.code), ["a", "b"])
        XCTAssertTrue(r.markdown.contains("PH0") && r.markdown.contains("PH1"))
    }

    func testIgnoresDataviewjsInsideOtherFence() {
        // 다른 펜스 안 예시 코드는 추출하면 안 된다.
        let md = "````markdown\n```dataviewjs\nx\n```\n````"
        let r = DataviewBlockExtractor.extract(md, placeholderHTML: placeholder)
        XCTAssertTrue(r.blocks.isEmpty)
        XCTAssertEqual(r.markdown, md, "변경 없음")
    }

    func testUnclosedFenceLeftAsIs() {
        let md = "```dataviewjs\ndv.paragraph(1);"
        let r = DataviewBlockExtractor.extract(md, placeholderHTML: placeholder)
        XCTAssertTrue(r.blocks.isEmpty)
        XCTAssertEqual(r.markdown, md)
    }

    func testPlainDataviewFenceNotExtracted() {
        // DQL(```dataview)은 비지원 — 손대지 않고 일반 코드블록으로 남긴다(스펙 §3).
        let md = "```dataview\nLIST\n```"
        let r = DataviewBlockExtractor.extract(md, placeholderHTML: placeholder)
        XCTAssertTrue(r.blocks.isEmpty)
        XCTAssertEqual(r.markdown, md)
    }
}
```

- [ ] **Step 2: 실패 확인** — Run: `swift test --filter DataviewBlockExtractorTests` / Expected: 컴파일 실패("cannot find 'DataviewBlockExtractor'")

- [ ] **Step 3: 최소 구현**

```swift
import Foundation

/// dataviewjs 블록 1개(문서 내 등장 순서 id + 코드 원문).
struct DataviewBlock: Equatable {
    let id: Int
    let code: String
}

/// 마크다운에서 ```dataviewjs 펜스를 추출하고 그 자리를 호출자가 준 HTML로 치환한다(순수).
/// 렌더러의 코드 마스킹(maskCodeRegions)보다 먼저, 호출자(PreviewView)가 원문에 적용한다.
/// 다른 펜스(``` 등) 안에 든 예시는 건드리지 않도록 일반 펜스 상태도 함께 추적한다.
enum DataviewBlockExtractor {

    static func extract(_ markdown: String,
                        placeholderHTML: (Int) -> String) -> (markdown: String, blocks: [DataviewBlock]) {
        let lines = markdown.components(separatedBy: "\n")
        var out: [String] = []
        var blocks: [DataviewBlock] = []
        var i = 0
        var insideOtherFence = false
        var otherFenceMarker = ""   // 열었던 펜스 문자열(백틱 3+개) — 같은 길이 이상으로 닫힘

        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if insideOtherFence {
                out.append(line)
                if trimmed.hasPrefix(otherFenceMarker), trimmed.allSatisfy({ $0 == "`" }) {
                    insideOtherFence = false
                }
                i += 1
                continue
            }

            if trimmed == "```dataviewjs" {
                // 닫는 펜스 탐색 — 없으면(미종결) 원문 그대로 둔다.
                var j = i + 1
                var body: [String] = []
                var closed = false
                while j < lines.count {
                    if lines[j].trimmingCharacters(in: .whitespaces) == "```" { closed = true; break }
                    body.append(lines[j]); j += 1
                }
                if closed {
                    let id = blocks.count
                    blocks.append(DataviewBlock(id: id, code: body.joined(separator: "\n")))
                    out.append(placeholderHTML(id))
                    i = j + 1
                    continue
                }
            }

            // 일반 펜스 진입 감지(``` 3개 이상 + 언어 태그 여부 무관, dataviewjs 제외)
            if trimmed.hasPrefix("```"), trimmed != "```dataviewjs" {
                let backticks = trimmed.prefix(while: { $0 == "`" })
                if backticks.count >= 3 {
                    insideOtherFence = true
                    otherFenceMarker = String(backticks)
                }
            }
            out.append(line)
            i += 1
        }
        return (out.joined(separator: "\n"), blocks)
    }
}
```

- [ ] **Step 4: 통과 확인** — Run: `swift test --filter DataviewBlockExtractorTests` / Expected: 5 tests PASS
- [ ] **Step 5: 전체 게이트** — Run: `swift test 2>&1 | grep -E "Executed .* tests"` / Expected: 실패 0
- [ ] **Step 6: 커밋** — `git add Sources/Services/DataviewBlockExtractor.swift Tests/CmdMDTests/DataviewBlockExtractorTests.swift && git commit -m "기능(dataview): 블록 추출기 — dataviewjs 펜스를 placeholder로 치환(순수)"` (+트레일러)

---

### Task 2: DataviewPageMeta 모델 + 단일 파일 파서 (순수)

**Files:**
- Create: `Sources/Models/DataviewPageMeta.swift`
- Test: `Tests/CmdMDTests/DataviewPageMetaTests.swift`

**Interfaces:**
- Produces(모델 — JSON으로 JSContext에 전달되므로 Codable, 키 이름이 shim 계약):

```swift
struct DataviewListItemMeta: Codable, Equatable {
    let text: String            // 마커([-*+]·체크박스) 뗀 항목 텍스트
    let headerSubpath: String   // 직전 헤딩 텍스트("" 가능)
    let tags: [String]          // 항목 안 인라인 태그, "#" 포함
    let task: Bool              // 체크박스 항목 여부
    let completed: Bool         // [x]/[X]
}

enum DataviewYAMLValue: Codable, Equatable {
    case string(String), number(Double), bool(Bool), array([DataviewYAMLValue])
}

struct DataviewPageMeta: Codable, Equatable {
    let name: String            // 확장자 없는 파일명
    let folder: String          // 루트 상대 폴더 경로("" = 루트)
    let path: String            // 루트 상대 파일 경로(확장자 포함)
    let day: String?            // "yyyy-MM-dd" — 파일명 우선, frontmatter date 폴백
    let mtime: Double           // epoch ms
    let ctime: Double
    let tags: [String]          // frontmatter tags + 본문 인라인 태그, "#" 포함 정규화
    let frontmatter: [String: DataviewYAMLValue]
    let lists: [DataviewListItemMeta]
}
```

- Produces(파서): `DataviewPageMeta.parse(content:name:folder:path:mtime:ctime:) -> DataviewPageMeta`
- Consumes: `CompanionNote.splitFrontmatter(_:) -> (yaml: String, body: String)?` (기존 공용)

- [ ] **Step 1: 실패하는 테스트 작성**

```swift
import XCTest
@testable import CmdMD

final class DataviewPageMetaTests: XCTestCase {

    /// 실제 데일리 노트 축약 픽스처(notebox Calendar 형식).
    private let daily = """
    ---
    date: '2026-07-05'
    day: "일요일"
    tags: [daily, log]
    ---
    # 2026-07-05 일요일

    ## 🌡️ 컨디션 #daily_condition
    - 전반적: 좀 우울함
    - 식사: 아침 프로틴쉐이크

    ## 📋 할 일
    - [ ] 산책
    - [x] 상담

    ## 💭 메모 #daily_memo
    - 종일 잤다

    ```bash
    - 코드펜스 안 리스트는 무시
    ```
    """

    private func parse(_ content: String, name: String = "2026-07-05") -> DataviewPageMeta {
        DataviewPageMeta.parse(content: content, name: name, folder: "Calendar",
                               path: "Calendar/\(name).md", mtime: 1000, ctime: 500)
    }

    func testDayFromFilename() {
        XCTAssertEqual(parse(daily).day, "2026-07-05")
    }

    func testDayFallsBackToFrontmatterDate() {
        let meta = parse(daily, name: "메모없는이름")
        XCTAssertEqual(meta.day, "2026-07-05", "파일명에 날짜 없으면 frontmatter date")
    }

    func testFrontmatterScalarsAndArray() {
        let m = parse(daily)
        XCTAssertEqual(m.frontmatter["date"], .string("2026-07-05"), "따옴표 벗김")
        XCTAssertEqual(m.frontmatter["day"], .string("일요일"))
        XCTAssertEqual(m.frontmatter["tags"], .array([.string("daily"), .string("log")]))
        XCTAssertTrue(m.tags.contains("#daily"), "frontmatter tags는 # 붙여 정규화")
    }

    func testListsWithHeaderSubpathAndInlineTags() {
        let m = parse(daily)
        let condition = m.lists.filter { $0.headerSubpath.contains("컨디션") }
        XCTAssertEqual(condition.count, 2)
        XCTAssertEqual(condition[0].text, "전반적: 좀 우울함")
        XCTAssertTrue(condition[0].headerSubpath.contains("#daily_condition") == false,
                      "subpath는 헤딩 텍스트(태그 포함 원문이어도 무방) — 실사용은 includes 매칭")
        // 인라인 태그는 헤딩이 아니라 항목의 것만: 컨디션 항목엔 태그 없음
        XCTAssertTrue(condition[0].tags.isEmpty)
    }

    func testTaskItems() {
        let m = parse(daily)
        let tasks = m.lists.filter { $0.task }
        XCTAssertEqual(tasks.count, 2)
        XCTAssertEqual(tasks.filter { $0.completed }.map(\.text), ["상담"])
        XCTAssertEqual(tasks.filter { !$0.completed }.map(\.text), ["산책"])
    }

    func testCodeFenceListsIgnored() {
        let m = parse(daily)
        XCTAssertFalse(m.lists.contains { $0.text.contains("코드펜스") })
    }

    func testNoFrontmatterOK() {
        let m = parse("# 그냥 노트\n- 항목", name: "노트")
        XCTAssertNil(m.day)
        XCTAssertTrue(m.frontmatter.isEmpty)
        XCTAssertEqual(m.lists.count, 1)
    }
}
```

주의(테스트 픽스처 결함 방지): `testListsWithHeaderSubpathAndInlineTags`의 subpath 단언은 "헤딩 원문 포함" 수준으로 느슨하게 유지 — 실사용 블록이 `header.subpath.includes("컨디션")` 형태라 정확 포맷은 계약이 아니다.

- [ ] **Step 2: 실패 확인** — Run: `swift test --filter DataviewPageMetaTests` / Expected: 컴파일 실패

- [ ] **Step 3: 구현**

```swift
import Foundation

// (위 Interfaces의 세 타입 선언 그대로. DataviewYAMLValue의 Codable은 아래 수동 구현.)

extension DataviewYAMLValue {
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let b = try? c.decode(Bool.self) { self = .bool(b); return }
        if let n = try? c.decode(Double.self) { self = .number(n); return }
        if let a = try? c.decode([DataviewYAMLValue].self) { self = .array(a); return }
        self = .string(try c.decode(String.self))
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b): try c.encode(b)
        case .array(let a): try c.encode(a)
        }
    }
}

extension DataviewPageMeta {

    private static let dayRegex = try! NSRegularExpression(pattern: #"\d{4}-\d{2}-\d{2}"#)
    private static let tagRegex = try! NSRegularExpression(pattern: #"#[\p{L}\p{N}_/-]+"#)

    /// 파일 1개의 본문에서 Dataview식 페이지 메타를 뽑는다(순수).
    /// - day: 파일명 안 yyyy-MM-dd 우선, 없으면 frontmatter date(스펙 §12 — 옵시디언 대조는 스모크에서).
    /// - lists: 코드펜스 밖 리스트 항목만, 직전 헤딩 텍스트를 subpath로.
    static func parse(content: String, name: String, folder: String, path: String,
                      mtime: Double, ctime: Double) -> DataviewPageMeta {
        var frontmatter: [String: DataviewYAMLValue] = [:]
        var body = content
        if let split = CompanionNote.splitFrontmatter(content) {
            frontmatter = parseYAMLLite(split.yaml)
            body = split.body
        }

        var day = firstMatch(dayRegex, in: name)
        if day == nil, case .string(let d)? = frontmatter["date"] {
            day = firstMatch(dayRegex, in: d)
        }

        var tags = Set<String>()
        if case .array(let arr)? = frontmatter["tags"] {
            for case .string(let t) in arr { tags.insert(t.hasPrefix("#") ? t : "#\(t)") }
        } else if case .string(let t)? = frontmatter["tags"] {
            tags.insert(t.hasPrefix("#") ? t : "#\(t)")
        }

        var lists: [DataviewListItemMeta] = []
        var currentHeader = ""
        var inFence = false
        for rawLine in body.components(separatedBy: "\n") {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") { inFence.toggle(); continue }
            if inFence { continue }
            if trimmed.hasPrefix("#"), let range = trimmed.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
                currentHeader = String(trimmed[range.upperBound...])
                continue
            }
            guard let markerRange = trimmed.range(of: #"^[-*+]\s+"#, options: .regularExpression) else { continue }
            var text = String(trimmed[markerRange.upperBound...])
            var task = false, completed = false
            if let boxRange = text.range(of: #"^\[( |x|X|~|<|>|-)\]\s*"#, options: .regularExpression) {
                task = true
                completed = text.hasPrefix("[x]") || text.hasPrefix("[X]")
                text = String(text[boxRange.upperBound...])
            }
            let itemTags = allMatches(tagRegex, in: text)
            itemTags.forEach { tags.insert($0) }
            lists.append(DataviewListItemMeta(text: text, headerSubpath: currentHeader,
                                              tags: itemTags, task: task, completed: completed))
        }

        return DataviewPageMeta(name: name, folder: folder, path: path, day: day,
                                mtime: mtime, ctime: ctime, tags: tags.sorted(),
                                frontmatter: frontmatter, lists: lists)
    }

    /// YAML 라이트 파서: 최상위 `키: 값` 스칼라(따옴표 벗김)·인라인 배열 [a, b]·
    /// `키:` 다음 `- 항목` 블록 리스트만. 중첩 맵·멀티라인은 문자열로 뭉갠다(실사용 충분).
    private static func parseYAMLLite(_ yaml: String) -> [String: DataviewYAMLValue] {
        var result: [String: DataviewYAMLValue] = [:]
        var pendingListKey: String?
        var pendingList: [DataviewYAMLValue] = []
        func flushList() {
            if let k = pendingListKey { result[k] = .array(pendingList) }
            pendingListKey = nil; pendingList = []
        }
        for line in yaml.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if trimmed.hasPrefix("- "), pendingListKey != nil {
                pendingList.append(scalar(String(trimmed.dropFirst(2))))
                continue
            }
            flushList()
            guard let colon = trimmed.firstIndex(of: ":") else { continue }
            let key = String(trimmed[..<colon]).trimmingCharacters(in: .whitespaces)
            let raw = String(trimmed[trimmed.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if raw.isEmpty { pendingListKey = key; continue }
            if raw.hasPrefix("["), raw.hasSuffix("]") {
                let inner = raw.dropFirst().dropLast()
                result[key] = .array(inner.split(separator: ",").map { scalar(String($0).trimmingCharacters(in: .whitespaces)) })
            } else {
                result[key] = scalar(raw)
            }
        }
        flushList()
        return result
    }

    private static func scalar(_ raw: String) -> DataviewYAMLValue {
        var s = raw
        if s.count >= 2, (s.hasPrefix("'") && s.hasSuffix("'")) || (s.hasPrefix("\"") && s.hasSuffix("\"")) {
            s = String(s.dropFirst().dropLast())
            return .string(s)   // 따옴표가 있으면 항상 문자열(YAML 시맨틱)
        }
        if s == "true" { return .bool(true) }
        if s == "false" { return .bool(false) }
        if let n = Double(s) { return .number(n) }
        return .string(s)
    }

    private static func firstMatch(_ regex: NSRegularExpression, in s: String) -> String? {
        let ns = s as NSString
        guard let m = regex.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return ns.substring(with: m.range)
    }

    private static func allMatches(_ regex: NSRegularExpression, in s: String) -> [String] {
        let ns = s as NSString
        return regex.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }
    }
}
```

구현 주의: 체크박스 정규식이 `[~]`·`[<]`·`[>]`·`[-]`(사용자 커스텀 상태)도 task로 인식하되 completed는 x/X만 — 실제 데일리가 커스텀 상태를 쓴다(픽스처 `2026-07-05.md` 참고).

- [ ] **Step 4: 통과 확인** — Run: `swift test --filter DataviewPageMetaTests` / Expected: 7 tests PASS
- [ ] **Step 5: 전체 게이트** — `swift test` 실패 0
- [ ] **Step 6: 커밋** — `기능(dataview): 페이지 메타 모델+파서 — frontmatter·lists·day·태그(순수)`

---

### Task 3: DataviewPageIndex (스레드 세이프 캐시 인덱스)

**Files:**
- Create: `Sources/Services/DataviewPageIndex.swift`
- Test: `Tests/CmdMDTests/DataviewPageIndexTests.swift`

**Interfaces:**
- Produces:

```swift
final class DataviewPageIndex {
    init(root: URL)
    func allPages() -> [DataviewPageMeta]                 // 루트 재귀(md/markdown, 숨김 제외)
    func pages(inFolder relativeFolder: String) -> [DataviewPageMeta]   // 하위 재귀 포함('/' 경계)
    func pages(withTag tag: String) -> [DataviewPageMeta] // "#" 유무 정규화
    func page(at pathOrName: String) -> DataviewPageMeta? // 루트 상대 경로(확장자 유무) 또는 파일명
    func meta(forFileURL url: URL) -> DataviewPageMeta?   // 현재 노트용 단건
    static func shared(for root: URL) -> DataviewPageIndex // 루트별 레지스트리(mtime 캐시 유지)
}
```

- Consumes: `DataviewPageMeta.parse(...)` (Task 2)
- 스펙 §5의 actor 대신 NSLock — JSContext 동기 콜백에서 호출되기 때문(계획 헤더 참조). 캐시는 `[상대경로: (mtime: Double, meta: DataviewPageMeta)]`, 조회 시 파일 mtime 비교로 무효화. FS 열거는 매 호출(수백 파일 열거는 싸다 — 비싼 건 본문 파싱).

- [ ] **Step 1: 실패하는 테스트 작성**

```swift
import XCTest
@testable import CmdMD

final class DataviewPageIndexTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dv-index-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: root.appendingPathComponent("Calendar/2025"),
                                                 withIntermediateDirectories: true)
        write("Calendar/2026-07-05.md", "---\ntags: [daily]\n---\n- 항목")
        write("Calendar/2025/2025-12-01.md", "# 옛날")
        write("Calendar/2026-W27.md", "# 주간")
        write("루트노트.md", "#inline_tag 본문")
        write("Calendar/.hidden.md", "숨김")
        write("Calendar/ignore.txt", "md 아님")
    }

    override func tearDown() { try? FileManager.default.removeItem(at: root); super.tearDown() }

    private func write(_ rel: String, _ content: String) {
        let url = root.appendingPathComponent(rel)
        try! content.write(to: url, atomically: true, encoding: .utf8)
    }

    func testAllPagesRecursiveMdOnlyNoHidden() {
        let idx = DataviewPageIndex(root: root)
        XCTAssertEqual(Set(idx.allPages().map(\.path)),
                       ["Calendar/2026-07-05.md", "Calendar/2025/2025-12-01.md",
                        "Calendar/2026-W27.md", "루트노트.md"])
    }

    func testFolderQueryIsRecursiveWithSlashBoundary() {
        let idx = DataviewPageIndex(root: root)
        XCTAssertEqual(idx.pages(inFolder: "Calendar").count, 3, "하위 연도 폴더 포함")
        XCTAssertEqual(idx.pages(inFolder: "Cal").count, 0, "'/' 경계 — 접두사 오매칭 금지")
    }

    func testTagQueryNormalizesHash() {
        let idx = DataviewPageIndex(root: root)
        XCTAssertEqual(idx.pages(withTag: "#daily").map(\.name), ["2026-07-05"])
        XCTAssertEqual(idx.pages(withTag: "inline_tag").map(\.name), ["루트노트"])
    }

    func testPageLookupByPathAndName() {
        let idx = DataviewPageIndex(root: root)
        XCTAssertNotNil(idx.page(at: "Calendar/2026-W27.md"))
        XCTAssertNotNil(idx.page(at: "Calendar/2026-W27"))
        XCTAssertNotNil(idx.page(at: "2026-W27"), "파일명만으로도")
        XCTAssertNil(idx.page(at: "없는노트"))
    }

    func testMtimeCacheInvalidation() throws {
        let idx = DataviewPageIndex(root: root)
        XCTAssertFalse(idx.allPages().first { $0.name == "2026-07-05" }!.lists.contains { $0.text == "새 항목" })
        // mtime을 확실히 바꾼다(초 단위 해상도 방어).
        let url = root.appendingPathComponent("Calendar/2026-07-05.md")
        try "---\ntags: [daily]\n---\n- 새 항목".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(10)],
                                              ofItemAtPath: url.path)
        XCTAssertTrue(idx.allPages().first { $0.name == "2026-07-05" }!.lists.contains { $0.text == "새 항목" })
    }

    func testSharedRegistryReturnsSameInstance() {
        XCTAssertTrue(DataviewPageIndex.shared(for: root) === DataviewPageIndex.shared(for: root))
    }
}
```

- [ ] **Step 2: 실패 확인** — `swift test --filter DataviewPageIndexTests` / Expected: 컴파일 실패
- [ ] **Step 3: 구현**

```swift
import Foundation

/// 페이지 메타 공급자 — 폴더 재귀 열거 + 파일별 mtime 캐시.
/// JSContext의 동기 브릿지에서 불리므로 actor가 아니라 NSLock으로 지킨다(스펙 §5 정정).
final class DataviewPageIndex {
    private let root: URL
    private let lock = NSLock()
    private var cache: [String: (mtime: Double, meta: DataviewPageMeta)] = [:]

    private static let registryLock = NSLock()
    private static var registry: [String: DataviewPageIndex] = [:]

    init(root: URL) { self.root = root.standardizedFileURL }

    /// 루트별 공유 인스턴스 — mtime 캐시가 렌더를 넘어 살아남는다.
    static func shared(for root: URL) -> DataviewPageIndex {
        let key = root.standardizedFileURL.path
        registryLock.lock(); defer { registryLock.unlock() }
        if let existing = registry[key] { return existing }
        let created = DataviewPageIndex(root: root)
        registry[key] = created
        return created
    }

    func allPages() -> [DataviewPageMeta] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys:
            [.contentModificationDateKey, .creationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]) else { return [] }
        var result: [DataviewPageMeta] = []
        for case let url as URL in enumerator {
            let ext = url.pathExtension.lowercased()
            guard ext == "md" || ext == "markdown" else { continue }
            if let meta = meta(forFileURL: url) { result.append(meta) }
        }
        return result.sorted { $0.path < $1.path }
    }

    func pages(inFolder relativeFolder: String) -> [DataviewPageMeta] {
        let prefix = relativeFolder.hasSuffix("/") ? relativeFolder : relativeFolder + "/"
        return allPages().filter { $0.path.hasPrefix(prefix) || $0.folder == relativeFolder }
    }

    func pages(withTag tag: String) -> [DataviewPageMeta] {
        let normalized = tag.hasPrefix("#") ? tag : "#\(tag)"
        return allPages().filter { $0.tags.contains(normalized) }
    }

    func page(at pathOrName: String) -> DataviewPageMeta? {
        let all = allPages()
        if let exact = all.first(where: { $0.path == pathOrName }) { return exact }
        if let noExt = all.first(where: { ($0.path as NSString).deletingPathExtension == pathOrName }) { return noExt }
        return all.first(where: { $0.name == pathOrName })
    }

    func meta(forFileURL url: URL) -> DataviewPageMeta? {
        let std = url.standardizedFileURL
        let rootPath = root.path
        guard std.path == rootPath || std.path.hasPrefix(rootPath + "/") else {
            return parseUncached(std, relativePath: std.lastPathComponent)   // 루트 밖(클릭-투-런 현재 파일)
        }
        let rel = String(std.path.dropFirst(rootPath.count + 1))
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: std.path),
              let mdate = attrs[.modificationDate] as? Date else { return nil }
        let mtime = mdate.timeIntervalSince1970 * 1000

        lock.lock()
        if let cached = cache[rel], cached.mtime == mtime { lock.unlock(); return cached.meta }
        lock.unlock()

        guard let meta = parseUncached(std, relativePath: rel, mtimeMs: mtime,
                                       ctimeMs: ((attrs[.creationDate] as? Date)?.timeIntervalSince1970 ?? 0) * 1000)
        else { return nil }
        lock.lock(); cache[rel] = (mtime, meta); lock.unlock()
        return meta
    }

    private func parseUncached(_ url: URL, relativePath: String,
                               mtimeMs: Double = 0, ctimeMs: Double = 0) -> DataviewPageMeta? {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }   // 깨진 파일은 건너뜀(스펙 §8)
        let name = url.deletingPathExtension().lastPathComponent
        let folder = (relativePath as NSString).deletingLastPathComponent
        return DataviewPageMeta.parse(content: content, name: name, folder: folder,
                                      path: relativePath, mtime: mtimeMs, ctime: ctimeMs)
    }
}
```

- [ ] **Step 4: 통과 확인** — `swift test --filter DataviewPageIndexTests` / Expected: 6 tests PASS
- [ ] **Step 5: 전체 게이트** — `swift test` 실패 0
- [ ] **Step 6: 커밋** — `기능(dataview): 페이지 인덱스 — 폴더 재귀·mtime 캐시·태그/단건 조회(NSLock)`

---

### Task 4: luxon 동봉 + dv-shim.js + LocalWebAssets

**Files:**
- Modify: `scripts/vendor_web_assets.sh` (luxon 섹션 추가)
- Create: `Sources/Resources/web/luxon/luxon.min.js` (스크립트 산출물)
- Create: `Sources/Resources/web/dataview/dv-shim.js` (수제 — vendor 스크립트가 지우지 않는 별도 디렉터리)
- Modify: `Sources/Services/LocalWebAssets.swift`
- Modify: `THIRD-PARTY-NOTICES.md`
- Test: `Tests/CmdMDTests/LocalWebAssetsTests.swift` (기존 파일에 추가)

**Interfaces:**
- Produces: `LocalWebAssets.luxonJS: String?`, `LocalWebAssets.dvShimJS: String?`
- shim 전역 계약(Task 6 엔진이 이 이름으로 브릿지·출력을 읽는다):
  - 입력 브릿지: `__dvNative.currentPage(): String(JSON)`, `__dvNative.pages(source: String): String(JSON 배열 또는 {"error":…})`, `__dvNative.page(path: String): String(JSON)|null`
  - 출력: `globalThis.__dvOutput: Array<{type:'table'|'list'|'paragraph'|'header'|'span', …}>`
  - 링크 셀 마커: `{__dvLink: true, path, display}`

- [ ] **Step 1: vendor 스크립트에 luxon 추가**

`scripts/vendor_web_assets.sh` 끝(기존 mermaid 섹션 뒤)에 추가 — 기존 섹션의 다운로드·검증 스타일을 따른다:

```bash
# ---- luxon (dataviewjs용 날짜 라이브러리, MIT) ----
LUXON_VERSION="3.5.0"
LUXON_DIR="$WEB_DIR/luxon"
mkdir -p "$LUXON_DIR"
curl -fsSL "https://cdn.jsdelivr.net/npm/luxon@${LUXON_VERSION}/build/global/luxon.min.js" \
  -o "$LUXON_DIR/luxon.min.js"
grep -q "DateTime" "$LUXON_DIR/luxon.min.js" || { echo "luxon 다운로드 검증 실패" >&2; exit 1; }
echo "luxon ${LUXON_VERSION} OK"
```

- [ ] **Step 2: 스크립트 실행·산출 확인** — Run: `./scripts/vendor_web_assets.sh && ls -la Sources/Resources/web/luxon/` / Expected: `luxon.min.js` 존재(수십 KB). 기존 katex/mermaid 자산이 삭제되지 않았는지 `git status`로 확인.

- [ ] **Step 3: dv-shim.js 작성** — `Sources/Resources/web/dataview/dv-shim.js`:

```javascript
// cmdALL dataviewjs 실행용 dv API 서브셋 shim (JSContext에서 로드).
// 전제: 전역 luxon, 동기 브릿지 __dvNative.{currentPage,pages,page}(JSON 문자열 반환).
// 렌더 호출은 __dvOutput 배열에 수집되고 네이티브가 HTML로 직렬화한다.
// 지원 범위는 스펙 §3(실사용 서브셋+여유분) — 그 밖은 한국어 에러를 던진다.
(function () {
  'use strict';
  var L = luxon;

  function toDay(s) { return s ? L.DateTime.fromISO(s) : null; }

  function makeLink(path, display) {
    return {
      __dvLink: true, path: path, display: display || null,
      toString: function () { return this.display || this.path; }
    };
  }

  function wrapPage(m) {
    var lists = m.lists.map(function (li) {
      return { text: li.text, header: { subpath: li.headerSubpath },
               tags: li.tags, task: li.task, completed: li.completed };
    });
    var file = {
      name: m.name, folder: m.folder, path: m.path,
      day: toDay(m.day),
      mtime: L.DateTime.fromMillis(m.mtime), ctime: L.DateTime.fromMillis(m.ctime),
      link: makeLink(m.path, m.name),
      tags: m.tags, frontmatter: m.frontmatter,
      lists: lists,
      tasks: lists.filter(function (li) { return li.task; })
    };
    var page = {};
    for (var k in m.frontmatter) page[k] = m.frontmatter[k];   // p.필드명 접근(여유분)
    page.file = file;
    return page;
  }

  function DataArray(values) { this.values = values; }
  DataArray.prototype.where = function (f) { return new DataArray(this.values.filter(f)); };
  DataArray.prototype.filter = DataArray.prototype.where;
  DataArray.prototype.map = function (f) { return new DataArray(this.values.map(f)); };
  DataArray.prototype.forEach = function (f) { this.values.forEach(f); };
  DataArray.prototype.array = function () { return this.values.slice(); };
  // Dataview 시맨틱: sort(키 함수, 'asc'|'desc') — 비교자가 아니라 키 추출.
  DataArray.prototype.sort = function (keyFn, dir) {
    var mul = dir === 'desc' ? -1 : 1;
    var sorted = this.values.slice().sort(function (a, b) {
      var ka = keyFn ? keyFn(a) : a, kb = keyFn ? keyFn(b) : b;
      if (ka < kb) return -mul;
      if (ka > kb) return mul;
      return 0;
    });
    return new DataArray(sorted);
  };
  Object.defineProperty(DataArray.prototype, 'length',
    { get: function () { return this.values.length; } });
  if (typeof Symbol !== 'undefined') {
    DataArray.prototype[Symbol.iterator] = function () { return this.values[Symbol.iterator](); };
  }

  function toArray(x) {
    if (x instanceof DataArray) return x.values;
    if (Array.isArray(x)) return x;
    return x == null ? [] : [x];
  }

  // 셀 정규화: 링크는 마커 유지, luxon 날짜는 ISO 날짜 문자열, 나머지는 문자열.
  function cell(v) {
    if (v && v.__dvLink) return v;
    if (v instanceof DataArray) return toArray(v).map(cell);
    if (Array.isArray(v)) return v.map(cell);
    if (v && v.isLuxonDateTime) return v.toISODate() || v.toISO();
    return v == null ? '' : String(v);
  }

  function parsed(json) {
    var r = JSON.parse(json);
    if (r && r.error) throw new Error(r.error);
    return r;
  }

  globalThis.__dvOutput = [];
  var out = globalThis.__dvOutput;

  function unsupported(name) {
    return function () { throw new Error('cmdALL은 ' + name + '을(를) 지원하지 않습니다'); };
  }

  globalThis.dv = {
    luxon: L,
    current: function () { return wrapPage(parsed(__dvNative.currentPage())); },
    pages: function (source) {
      return new DataArray(parsed(__dvNative.pages(source == null ? '' : String(source))).map(wrapPage));
    },
    page: function (path) {
      var j = __dvNative.page(String(path));
      return j ? wrapPage(parsed(j)) : null;
    },
    // ISO 전체 파싱 시도 → 문자열 안 yyyy-MM-dd 추출 폴백 → null.
    date: function (s) {
      if (s == null) return null;
      if (s.isLuxonDateTime) return s;
      var str = String(s);
      var dt = L.DateTime.fromISO(str);
      if (dt.isValid) return dt;
      var m = str.match(/\d{4}-\d{2}-\d{2}/);
      return m ? L.DateTime.fromISO(m[0]) : null;
    },
    fileLink: function (path, _embed, display) { return makeLink(path, display); },
    table: function (headers, rows) {
      out.push({ type: 'table', headers: toArray(headers).map(cell),
                 rows: toArray(rows).map(function (r) { return toArray(r).map(cell); }) });
    },
    list: function (items) { out.push({ type: 'list', items: toArray(items).map(cell) }); },
    paragraph: function (t) { out.push({ type: 'paragraph', text: cell(t) }); },
    header: function (level, t) { out.push({ type: 'header', level: Number(level) || 1, text: cell(t) }); },
    span: function (t) { out.push({ type: 'span', text: cell(t) }); },
    el: unsupported('dv.el(DOM 조작)'),
    view: unsupported('dv.view(외부 스크립트)'),
    query: unsupported('dv.query(DQL)'),
    tryQuery: unsupported('dv.tryQuery(DQL)'),
    io: { load: unsupported('dv.io'), csv: unsupported('dv.io') }
  };
})();
```

- [ ] **Step 4: 실패하는 자산 테스트 추가** — `Tests/CmdMDTests/LocalWebAssetsTests.swift`에 추가:

```swift
    func testLuxonAssetBundled() throws {
        let js = try XCTUnwrap(LocalWebAssets.luxonJS, "luxon.min.js 동봉")
        XCTAssertTrue(js.contains("DateTime"))
    }

    func testDvShimAssetBundled() throws {
        let js = try XCTUnwrap(LocalWebAssets.dvShimJS, "dv-shim.js 동봉")
        XCTAssertTrue(js.contains("__dvOutput"))
        XCTAssertTrue(js.contains("__dvNative"))
    }
```

Run: `swift test --filter LocalWebAssetsTests` / Expected: 신규 2건 컴파일 실패

- [ ] **Step 5: LocalWebAssets 가산** — 기존 katexJS 선언들 옆에:

```swift
    /// dataviewjs용 luxon(로컬 동봉) — 스펙 §5.
    static let luxonJS: String? = readWebResource("luxon/luxon.min.js")

    /// dv API 서브셋 shim — 스펙 §3 범위, JSContext 전용.
    static let dvShimJS: String? = readWebResource("dataview/dv-shim.js")
```

- [ ] **Step 6: THIRD-PARTY-NOTICES.md §1에 luxon 추가** — 기존 KaTeX 항목과 같은 형식으로: 이름 luxon, 버전 3.5.0, 라이선스 MIT, Copyright 2019 JS Foundation and other contributors, 경로 `Sources/Resources/web/luxon/`.

- [ ] **Step 7: 통과 확인** — `swift test --filter LocalWebAssetsTests` / Expected: 전체 PASS(기존 포함)
- [ ] **Step 8: 전체 게이트** — `swift test` 실패 0
- [ ] **Step 9: 커밋** — `기능(dataview): luxon 동봉+dv shim 자산 — vendor 스크립트·THIRD-PARTY 갱신`

---

### Task 5: 출력 모델 + HTML 직렬화 (순수)

**Files:**
- Create: `Sources/Services/DataviewOutput.swift`
- Modify: `Sources/Services/MarkdownRenderer.swift` — `processWikiLinks` 안의 href 조립 2줄을 `static func wikiLinkHref(target: String) -> String`으로 추출(동작 불변), `internalLinkQueryValueAllowed`는 그 함수 안으로
- Test: `Tests/CmdMDTests/DataviewOutputTests.swift`

**Interfaces:**
- Produces:

```swift
enum DataviewCellValue: Equatable {
    case text(String)                          // 원문 HTML 허용(아래 근거 주석 참조)
    case link(path: String, display: String?)
    case nested([DataviewCellValue])
}
enum DataviewOutputItem: Equatable {
    case table(headers: [DataviewCellValue], rows: [[DataviewCellValue]])
    case list([DataviewCellValue])
    case paragraph(DataviewCellValue)
    case header(level: Int, DataviewCellValue)
    case span(DataviewCellValue)
}
enum DataviewHTMLSerializer {
    static func html(for items: [DataviewOutputItem]) -> String
    static func errorCard(message: String, code: String) -> String   // <details>에 원본 코드
    static func runButtonCard(blockId: Int, code: String) -> String  // 클릭-투-런 placeholder
    static func pendingCard() -> String                              // 자동 실행 스피너 placeholder
}
```

- Consumes: `MarkdownRenderer.wikiLinkHref(target:)` (이 태스크에서 추출)
- 텍스트 셀 HTML 허용 근거(코드 주석에 남길 것): 실사용 블록이 `<br>` join을 쓴다. 프리뷰는 어차피 노트 마크다운의 raw HTML 블록을 그대로 렌더하므로, 자기 노트가 넣는 HTML은 기존 표면과 동위험 — 추가 이스케이프는 실사용을 깨기만 한다.

- [ ] **Step 1: 실패하는 테스트 작성**

```swift
import XCTest
@testable import CmdMD

final class DataviewOutputTests: XCTestCase {

    func testTableHTMLWithLinkAndBr() {
        let items: [DataviewOutputItem] = [.table(
            headers: [.text("날짜"), .text("메모")],
            rows: [[.link(path: "Calendar/2026-07-05.md", display: "2026-07-05"),
                    .text("줄1<br>줄2")]])]
        let html = DataviewHTMLSerializer.html(for: items)
        XCTAssertTrue(html.contains("<table class=\"dataview\">"))
        XCTAssertTrue(html.contains("<th>날짜</th>"))
        XCTAssertTrue(html.contains("줄1<br>줄2"), "셀 HTML 통과(<br> 실사용)")
        XCTAssertTrue(html.contains("class=\"wiki-link\""))
        XCTAssertTrue(html.contains("cmdmd://open?note="), "기존 위키링크 스킴 재사용")
        XCTAssertTrue(html.contains(">2026-07-05</a>"))
    }

    func testListParagraphHeaderSpan() {
        let html = DataviewHTMLSerializer.html(for: [
            .list([.text("a"), .link(path: "b.md", display: nil)]),
            .paragraph(.text("문단")),
            .header(level: 3, .text("헤딩")),
            .span(.text("스팬")),
        ])
        XCTAssertTrue(html.contains("<ul class=\"dataview\">"))
        XCTAssertTrue(html.contains("<li>a</li>"))
        XCTAssertTrue(html.contains("<p class=\"dataview\">문단</p>"))
        XCTAssertTrue(html.contains("<h3 class=\"dataview\">헤딩</h3>"))
        XCTAssertTrue(html.contains("<span class=\"dataview\">스팬</span>"))
    }

    func testNestedCellJoinsWithBr() {
        let html = DataviewHTMLSerializer.html(for: [.table(
            headers: [.text("h")], rows: [[.nested([.text("x"), .text("y")])]])])
        XCTAssertTrue(html.contains("x<br>y"))
    }

    func testErrorCardEscapesAndFoldsCode() {
        let card = DataviewHTMLSerializer.errorCard(message: "타임아웃", code: "<script>x</script>")
        XCTAssertTrue(card.contains("타임아웃"))
        XCTAssertTrue(card.contains("<details>"))
        XCTAssertTrue(card.contains("&lt;script&gt;"), "오류 카드의 코드는 이스케이프")
        XCTAssertFalse(card.contains("<script>x"))
    }

    func testRunButtonCardPostsMessage() {
        let card = DataviewHTMLSerializer.runButtonCard(blockId: 2, code: "dv.x()")
        XCTAssertTrue(card.contains("dataviewRun"))
        XCTAssertTrue(card.contains("\"id\":2") || card.contains("id: 2") || card.contains("id:2"))
        XCTAssertTrue(card.contains("dv.x()"))
    }

    func testWikiLinkHrefMatchesRendererBehavior() {
        // processWikiLinks 추출 리팩터가 동작 불변임을 고정: 렌더러 산출과 동일 href.
        let renderer = MarkdownRenderer()
        let html = renderer.renderToHTML(markdown: "[[한글 노트]]", baseURL: nil, theme: .github)
        XCTAssertTrue(html.contains(MarkdownRenderer.wikiLinkHref(target: "한글 노트").replacingOccurrences(of: "&", with: "&amp;"))
                      || html.contains(MarkdownRenderer.wikiLinkHref(target: "한글 노트")))
    }
}
```

- [ ] **Step 2: 실패 확인** — `swift test --filter DataviewOutputTests` / Expected: 컴파일 실패

- [ ] **Step 3: 구현** — `DataviewOutput.swift`:

```swift
import Foundation

// (위 Interfaces의 두 enum 선언 그대로)

/// dv 렌더 호출 결과를 프리뷰 HTML로 직렬화한다(순수).
/// 텍스트 셀은 HTML을 통과시킨다 — 실사용 블록이 "<br>" join을 쓰고, 프리뷰는 어차피
/// 노트의 raw HTML 블록을 그대로 렌더하므로 자기 노트 HTML은 기존 표면과 동위험.
/// 오류 카드의 코드만은 이스케이프한다(코드를 HTML로 실행할 이유가 없다).
enum DataviewHTMLSerializer {

    static func html(for items: [DataviewOutputItem]) -> String {
        items.map { item in
            switch item {
            case .table(let headers, let rows):
                let head = headers.map { "<th>\(cellHTML($0))</th>" }.joined()
                let body = rows.map { row in
                    "<tr>" + row.map { "<td>\(cellHTML($0))</td>" }.joined() + "</tr>"
                }.joined()
                return "<table class=\"dataview\"><thead><tr>\(head)</tr></thead><tbody>\(body)</tbody></table>"
            case .list(let items):
                return "<ul class=\"dataview\">" + items.map { "<li>\(cellHTML($0))</li>" }.joined() + "</ul>"
            case .paragraph(let t): return "<p class=\"dataview\">\(cellHTML(t))</p>"
            case .header(let level, let t):
                let l = min(max(level, 1), 6)
                return "<h\(l) class=\"dataview\">\(cellHTML(t))</h\(l)>"
            case .span(let t): return "<span class=\"dataview\">\(cellHTML(t))</span>"
            }
        }.joined(separator: "\n")
    }

    private static func cellHTML(_ cell: DataviewCellValue) -> String {
        switch cell {
        case .text(let s): return s
        case .link(let path, let display):
            let target = (path as NSString).deletingPathExtension
            let label = escape(display ?? (target as NSString).lastPathComponent)
            return "<a href=\"\(escape(MarkdownRenderer.wikiLinkHref(target: target)))\" class=\"wiki-link\">\(label)</a>"
        case .nested(let cells): return cells.map(cellHTML).joined(separator: "<br>")
        }
    }

    static func errorCard(message: String, code: String) -> String {
        """
        <div class="dataview-error"><p>⚠️ dataviewjs: \(escape(message))</p>\
        <details><summary>원본 코드</summary><pre><code>\(escape(code))</code></pre></details></div>
        """
    }

    static func runButtonCard(blockId: Int, code: String) -> String {
        """
        <div class="dataview-block" id="dv-b\(blockId)">\
        <button onclick='window.webkit.messageHandlers.cmdmd.postMessage({"type":"dataviewRun","id":\(blockId)})'>▶ 이 블록 실행</button>\
        <details><summary>dataviewjs 코드</summary><pre><code>\(escape(code))</code></pre></details></div>
        """
    }

    static func pendingCard() -> String {
        "<p class=\"dataview-pending\">dataviewjs 실행 중…</p>"
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
```

`MarkdownRenderer.swift` 수정 — processWikiLinks의 두 줄:

```swift
                let encoded = target.addingPercentEncoding(withAllowedCharacters: Self.internalLinkQueryValueAllowed) ?? target
                let href = "cmdmd://open?note=\(encoded)"
```

을 다음 static으로 추출하고 원 위치는 `let href = Self.wikiLinkHref(target: target)`로:

```swift
    /// 위키링크 href 조립 — 프리뷰 위키링크와 dataview 링크 셀이 같은 스킴을 쓴다.
    static func wikiLinkHref(target: String) -> String {
        let encoded = target.addingPercentEncoding(withAllowedCharacters: internalLinkQueryValueAllowed) ?? target
        return "cmdmd://open?note=\(encoded)"
    }
```

- [ ] **Step 4: 통과 확인** — `swift test --filter DataviewOutputTests` / Expected: 6 tests PASS
- [ ] **Step 5: 전체 게이트** — `swift test` 실패 0 (렌더러 리팩터가 기존 위키링크 테스트를 깨지 않는지 특히 확인)
- [ ] **Step 6: 커밋** — `기능(dataview): 출력 모델+HTML 직렬화 — 위키링크 href 공용 추출(동작 불변)`

---

### Task 6: DataviewEngine (JSContext 실행)

**Files:**
- Create: `Sources/Services/DataviewEngine.swift`
- Test: `Tests/CmdMDTests/DataviewEngineTests.swift`

**Interfaces:**
- Produces:

```swift
enum DataviewError: Error, Equatable {
    case assetsMissing            // luxon/shim 로드 실패
    case timeout
    case script(String)           // JS 예외 메시지(비지원 API 포함)
}
struct DataviewRunContext {
    let noteURL: URL              // 현재 노트(절대)
    let rootURL: URL              // 볼트/등록 폴더 루트(밖이면 노트의 폴더)
}
final class DataviewEngine {
    /// 동기 실행(호출자가 백그라운드 스레드 담당). 컨텍스트는 매 호출 새로 만든다(전역 오염 방지).
    static func run(code: String, context: DataviewRunContext,
                    timeLimit: Double = 3.0) -> Result<[DataviewOutputItem], DataviewError>
}
```

- Consumes: `LocalWebAssets.luxonJS/dvShimJS`(Task 4), `DataviewPageIndex.shared(for:)`(Task 3), `DataviewOutputItem/DataviewCellValue`(Task 5), shim 전역 계약(Task 4).

- [ ] **Step 1: 실패하는 테스트 작성** — 핵심은 **실제 주간·월간 블록 전문 fixture**:

```swift
import XCTest
@testable import CmdMD

final class DataviewEngineTests: XCTestCase {
    private var root: URL!

    override func setUp() {
        super.setUp()
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dv-engine-\(UUID().uuidString)/Calendar", isDirectory: true)
        try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // 2026-W27 = 2026-06-29(월)~2026-07-05(일). 주 안 2개 + 주 밖 1개.
        write("2026-06-30.md", """
        ---
        date: '2026-06-30'
        ---
        ## 🌡️ 컨디션 #daily_condition
        - 전반적: 좋음
        - 식사: 죽
        ## 💭 메모 #daily_memo
        - 메모A
        """)
        write("2026-07-05.md", """
        ## 🌡️ 컨디션 #daily_condition
        - 전반적: 우울
        - 식사: 군고구마
        ## 💊 치료 메모 #daily_medical
        - 캐싸일라 d+4
        """)
        write("2026-06-20.md", "## 🌡️ 컨디션 #daily_condition\n- 주 밖")
        write("2026-W27.md", "# 주간")
        write("2026-W26.md", "# 전주")   // 월간 블록용
    }

    override func tearDown() { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()); super.tearDown() }

    private func write(_ name: String, _ content: String) {
        try! content.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    private func run(_ code: String, note: String) -> Result<[DataviewOutputItem], DataviewError> {
        DataviewEngine.run(code: code,
                           context: DataviewRunContext(noteURL: root.appendingPathComponent(note),
                                                       rootURL: root.deletingLastPathComponent()))
    }

    /// notebox 주간리뷰 템플릿 블록 전문(실사용 검증 — 스펙 §10).
    private let weeklyBlock = #"""
    let filename = dv.current().file.name;
    let match = filename.match(/^(\d{4})-[wW](\d{1,2})$/);
    if (!match) {
        dv.paragraph("⚠️ 파일 이름 형식이 맞지 않습니다.");
    } else {
        let year = parseInt(match[1]);
        let week = parseInt(match[2]);
        let startOfWeek = dv.luxon.DateTime.fromObject({ weekYear: year, weekNumber: week, weekday: 1 });
        let endOfWeek = startOfWeek.plus({ days: 6 });
        let pages = dv.pages('"' + dv.current().file.folder + '"')
            .where(p => {
                let day = p.file.day || dv.date(p.file.name);
                return day && day >= startOfWeek && day <= endOfWeek;
            })
            .sort(p => p.file.name);
        let tableData = pages.map(p => {
            let allLists = p.file.lists;
            let condition = [];
            let meals = [];
            let medical = [];
            let memo = [];
            allLists.forEach(L => {
                let text = L.text;
                let header = (L.header.subpath || "").toString();
                if (header.includes("컨디션") || L.tags.includes("#daily_condition")) {
                    if (text.includes("식사:")) {
                        meals.push(text.replace("식사:", "").trim());
                    } else {
                        condition.push(text);
                    }
                }
                else if ((header.includes("치료") && !header.includes("주차")) || L.tags.includes("#daily_medical")) {
                    medical.push(text);
                }
                else if (header.includes("메모") || L.tags.includes("#daily_memo")) {
                    memo.push(text);
                }
            });
            return [
                p.file.link,
                condition.join("<br>"),
                meals.join("<br>"),
                medical.join("<br>"),
                memo.join("<br>")
            ];
        });
        dv.table(
            ["날짜", "컨디션/통증", "식사", "치료/증상", "메모/생각"],
            tableData
        );
    }
    """#

    func testRealWeeklyBlockEndToEnd() throws {
        let items = try run(weeklyBlock, note: "2026-W27.md").get()
        guard case .table(let headers, let rows) = items.first else { return XCTFail("표여야 함") }
        XCTAssertEqual(headers.first, .text("날짜"))
        XCTAssertEqual(rows.count, 2, "주 안 데일리 2개만(2026-06-20 제외) — luxon 주차 계산 검증(스펙 §12)")
        // 이름순 정렬: 06-30 먼저. 링크 셀 + lists 헤딩/태그 라우팅 검증.
        guard case .link(let path, _) = rows[0][0] else { return XCTFail("첫 셀은 링크") }
        XCTAssertTrue(path.contains("2026-06-30"))
        XCTAssertEqual(rows[0][1], .text("전반적: 좋음"))
        XCTAssertEqual(rows[0][2], .text("죽"), "식사: 접두사 제거")
        XCTAssertEqual(rows[1][3], .text("캐싸일라 d+4"), "치료 헤딩 라우팅")
        XCTAssertEqual(rows[0][4], .text("메모A"))
    }

    func testRealMonthlyBlockListsWeeklies() throws {
        // notebox 월간리뷰 템플릿 블록 전문(축약 없이).
        let monthly = #"""
        let filename = dv.current().file.name;
        let match = filename.match(/^(\d{4})-(\d{2})$/);
        if (!match) {
            dv.paragraph("⚠️ 파일 이름 형식이 맞지 않습니다. (예: 2026-01)");
        } else {
            let year = parseInt(match[1]);
            let month = parseInt(match[2]);
            let weeklyReviews = dv.pages('"' + dv.current().file.folder + '"')
                .where(p => {
                    let weekMatch = p.file.name.match(/^(\d{4})-[wW](\d{1,2})$/);
                    if (!weekMatch) return false;
                    let weekYear = parseInt(weekMatch[1]);
                    let weekNum = parseInt(weekMatch[2]);
                    let weekStart = dv.luxon.DateTime.fromObject({
                        weekYear: weekYear,
                        weekNumber: weekNum,
                        weekday: 1
                    });
                    return weekStart.year === year && weekStart.month === month;
                })
                .sort(p => p.file.name);
            if (weeklyReviews.length === 0) {
                dv.paragraph("⚠️ 이번 달의 주간 리뷰가 없습니다.");
            } else {
                dv.list(weeklyReviews.map(p => p.file.link));
            }
        }
        """#
        write("2026-06.md", "# 월간")
        let items = try run(monthly, note: "2026-06.md").get()
        guard case .list(let links) = items.first else { return XCTFail("목록이어야 함") }
        // W26(6/22 시작)·W27(6/29 시작) 둘 다 6월 시작 → 2건.
        XCTAssertEqual(links.count, 2)
    }

    func testScriptErrorSurfaced() {
        let r = run("dv.el('div', 'x');", note: "2026-W27.md")
        guard case .failure(.script(let msg)) = r else { return XCTFail("script 에러여야 함") }
        XCTAssertTrue(msg.contains("dv.el"), "비지원 API 한국어 안내")
    }

    func testTimeout() {
        let r = DataviewEngine.run(code: "while(true){}",
                                   context: DataviewRunContext(noteURL: root.appendingPathComponent("2026-W27.md"),
                                                               rootURL: root.deletingLastPathComponent()),
                                   timeLimit: 0.5)
        guard case .failure(.timeout) = r else { return XCTFail("타임아웃이어야 함") }
    }

    func testUnsupportedSourceError() {
        let r = run("dv.pages('\"A\" or \"B\"');", note: "2026-W27.md")
        guard case .failure(.script(let msg)) = r else { return XCTFail() }
        XCTAssertTrue(msg.contains("소스"), "복합 소스 미지원 안내")
    }
}
```

- [ ] **Step 2: 실패 확인** — `swift test --filter DataviewEngineTests` / Expected: 컴파일 실패

- [ ] **Step 3: 구현** — `DataviewEngine.swift`:

```swift
import Foundation
import JavaScriptCore

enum DataviewError: Error, Equatable {
    case assetsMissing
    case timeout
    case script(String)
}

struct DataviewRunContext {
    let noteURL: URL
    let rootURL: URL
}

/// dataviewjs 블록을 JSContext에서 실행한다(스펙 §4~5 — C안).
/// 컨텍스트는 실행 단위로 생성·폐기(블록 간 전역 오염 방지), 시간 제한은
/// JSContextGroupSetExecutionTimeLimit(무한루프도 강제 종료). fetch/DOM이 없는
/// 환경이라 블록이 읽은 메타데이터를 밖으로 보낼 방법이 없다(스펙 §4).
final class DataviewEngine {

    static func run(code: String, context runCtx: DataviewRunContext,
                    timeLimit: Double = 3.0) -> Result<[DataviewOutputItem], DataviewError> {
        guard let luxon = LocalWebAssets.luxonJS, let shim = LocalWebAssets.dvShimJS,
              let ctx = JSContext() else { return .failure(.assetsMissing) }

        // 시간 제한 — 콜백이 true를 돌려주면 실행을 끊는다(캡처 없는 C 함수 포인터).
        let group = JSContextGetGroup(ctx.jsGlobalContextRef)
        JSContextGroupSetExecutionTimeLimit(group, timeLimit, { _, _ in true }, nil)

        let index = DataviewPageIndex.shared(for: runCtx.rootURL)
        installBridge(in: ctx, index: index, runCtx: runCtx)

        ctx.evaluateScript(luxon)
        ctx.evaluateScript(shim)
        guard ctx.exception == nil else { return .failure(.assetsMissing) }

        let started = Date()
        ctx.evaluateScript(code)
        if let exception = ctx.exception {
            // 시간 제한 종료도 예외로 나온다 — 경과 시간으로 판별.
            if Date().timeIntervalSince(started) >= timeLimit { return .failure(.timeout) }
            return .failure(.script(exception.toString() ?? "알 수 없는 오류"))
        }

        guard let json = ctx.evaluateScript("JSON.stringify(__dvOutput)")?.toString(),
              let data = json.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return .failure(.script("출력을 해석하지 못했습니다")) }
        return .success(raw.compactMap(Self.outputItem(from:)))
    }

    // MARK: 동기 브릿지

    private static func installBridge(in ctx: JSContext, index: DataviewPageIndex,
                                      runCtx: DataviewRunContext) {
        let encoder = JSONEncoder()
        func jsonString<T: Encodable>(_ value: T) -> String {
            (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "null"
        }

        let native = JSValue(newObjectIn: ctx)!

        let currentPage: @convention(block) () -> String = {
            guard let meta = index.meta(forFileURL: runCtx.noteURL) else {
                return #"{"error":"현재 노트를 읽지 못했습니다"}"#
            }
            return jsonString(meta)
        }
        native.setObject(currentPage, forKeyedSubscript: "currentPage" as NSString)

        let pages: @convention(block) (String) -> String = { source in
            let s = source.trimmingCharacters(in: .whitespaces)
            if s.lowercased().contains(" or ") || s.lowercased().contains(" and ") || s.hasPrefix("-") {
                return #"{"error":"cmdALL은 복합 소스를 지원하지 않습니다(폴더·태그 단일 소스만)"}"#
            }
            if s.isEmpty { return jsonString(index.allPages()) }
            if s.hasPrefix("#") { return jsonString(index.pages(withTag: s)) }
            if s.hasPrefix("\""), s.hasSuffix("\""), s.count >= 2 {
                return jsonString(index.pages(inFolder: String(s.dropFirst().dropLast())))
            }
            return #"{"error":"지원하지 않는 dv.pages 소스입니다: "# + s + "\"}"
        }
        native.setObject(pages, forKeyedSubscript: "pages" as NSString)

        let page: @convention(block) (String) -> JSValue = { pathOrName in
            guard let meta = index.page(at: pathOrName) else { return JSValue(nullIn: ctx) }
            return JSValue(object: jsonString(meta), in: ctx)
        }
        native.setObject(page, forKeyedSubscript: "page" as NSString)

        ctx.setObject(native, forKeyedSubscript: "__dvNative" as NSString)
    }

    // MARK: 출력 디코드

    private static func outputItem(from dict: [String: Any]) -> DataviewOutputItem? {
        switch dict["type"] as? String {
        case "table":
            let headers = (dict["headers"] as? [Any] ?? []).map(cellValue(from:))
            let rows = (dict["rows"] as? [[Any]] ?? []).map { $0.map(cellValue(from:)) }
            return .table(headers: headers, rows: rows)
        case "list": return .list((dict["items"] as? [Any] ?? []).map(cellValue(from:)))
        case "paragraph": return .paragraph(cellValue(from: dict["text"] ?? ""))
        case "header": return .header(level: dict["level"] as? Int ?? 1, cellValue(from: dict["text"] ?? ""))
        case "span": return .span(cellValue(from: dict["text"] ?? ""))
        default: return nil
        }
    }

    private static func cellValue(from any: Any) -> DataviewCellValue {
        if let link = any as? [String: Any], link["__dvLink"] as? Bool == true {
            return .link(path: link["path"] as? String ?? "", display: link["display"] as? String)
        }
        if let arr = any as? [Any] { return .nested(arr.map(cellValue(from:))) }
        return .text(any as? String ?? String(describing: any))
    }
}
```

구현 주의 2건: ① `page` 브릿지는 null 반환이 필요해 JSValue를 돌려준다 — shim의 `dv.page`가 null 체크. ② `pages`의 마지막 오류 문자열 조립에서 `s` 안 따옴표로 JSON이 깨질 수 있다 — 구현 시 `s`를 JSON 인코드해 넣을 것(테스트: `dv.pages('bad"quote')`가 깨지지 않고 에러 메시지로).

- [ ] **Step 4: 통과 확인** — `swift test --filter DataviewEngineTests` / Expected: 6 tests PASS. `testRealWeeklyBlockEndToEnd`의 rows==2가 luxon 주차 계산(스펙 §12 확인 필요 항목)을 함께 실증한다.
- [ ] **Step 5: 전체 게이트** — `swift test` 실패 0
- [ ] **Step 6: 커밋** — `기능(dataview): JSContext 엔진 — 동기 브릿지·3s 강제 종료·실제 주간/월간 블록 e2e`

---

### Task 7: 실행 정책 + PreviewView 배선

**Files:**
- Create: `Sources/Services/DataviewRunPolicy.swift`
- Modify: `Sources/Views/PreviewView.swift`
- Test: `Tests/CmdMDTests/DataviewRunPolicyTests.swift`

**Interfaces:**
- Produces:

```swift
enum DataviewRunPolicy {
    /// 볼트/등록 폴더 하위면 자동 실행('/' 경계 — 형제 폴더 접두사 오매칭 금지).
    static func isAutoRun(notePath: String, vaultPaths: [String], indexedFolders: [String]) -> Bool
    /// 매칭 루트(가장 긴 것). 자동 아니면 nil — 호출자는 노트의 폴더를 루트로 쓴다.
    static func rootPath(for notePath: String, vaultPaths: [String], indexedFolders: [String]) -> String?
}
```

- Consumes: Task 1(추출)·5(카드 HTML)·6(엔진). AppState: `settings.vaults[].rootPath.path`, `settings.indexedFolders`(AppState.shared 경유 — PreviewView coordinator가 기존에 `AppState.shared?.toggleTask`를 쓰는 패턴 그대로).

- [ ] **Step 1: 정책 실패 테스트**

```swift
import XCTest
@testable import CmdMD

final class DataviewRunPolicyTests: XCTestCase {
    func testInsideVaultOrIndexedFolderIsAuto() {
        XCTAssertTrue(DataviewRunPolicy.isAutoRun(notePath: "/v/notebox/Calendar/a.md",
                                                  vaultPaths: ["/v/notebox"], indexedFolders: []))
        XCTAssertTrue(DataviewRunPolicy.isAutoRun(notePath: "/idx/f/a.md",
                                                  vaultPaths: [], indexedFolders: ["/idx/f"]))
        XCTAssertFalse(DataviewRunPolicy.isAutoRun(notePath: "/Users/x/Downloads/a.md",
                                                   vaultPaths: ["/v/notebox"], indexedFolders: ["/idx/f"]))
    }
    func testSlashBoundaryNoSiblingPrefixMatch() {
        XCTAssertFalse(DataviewRunPolicy.isAutoRun(notePath: "/v/notebox2/a.md",
                                                   vaultPaths: ["/v/notebox"], indexedFolders: []))
    }
    func testRootPathPicksLongestMatch() {
        XCTAssertEqual(DataviewRunPolicy.rootPath(for: "/v/notebox/Calendar/a.md",
                                                  vaultPaths: ["/v/notebox"],
                                                  indexedFolders: ["/v/notebox/Calendar"]),
                       "/v/notebox/Calendar")
        XCTAssertNil(DataviewRunPolicy.rootPath(for: "/elsewhere/a.md",
                                                vaultPaths: ["/v/notebox"], indexedFolders: []))
    }
}
```

- [ ] **Step 2: 실패 확인** — `swift test --filter DataviewRunPolicyTests` / Expected: 컴파일 실패

- [ ] **Step 3: 정책 구현**

```swift
import Foundation

/// dataviewjs 자동 실행 판정(스펙 §7) — 결정 2: 볼트 안만 자동, 밖은 클릭-투-런.
enum DataviewRunPolicy {

    static func isAutoRun(notePath: String, vaultPaths: [String], indexedFolders: [String]) -> Bool {
        rootPath(for: notePath, vaultPaths: vaultPaths, indexedFolders: indexedFolders) != nil
    }

    static func rootPath(for notePath: String, vaultPaths: [String], indexedFolders: [String]) -> String? {
        let note = (notePath as NSString).standardizingPath
        return (vaultPaths + indexedFolders)
            .map { ($0 as NSString).standardizingPath }
            .filter { note == $0 || note.hasPrefix($0 + "/") }
            .max(by: { $0.count < $1.count })
    }
}
```

- [ ] **Step 4: 정책 통과 확인** — `swift test --filter DataviewRunPolicyTests` / Expected: 3 tests PASS

- [ ] **Step 5: PreviewView 배선** — coordinator에 다음을 추가(수동 검증 영역 — 코드는 그대로 적용):

Coordinator 프로퍼티:

```swift
        // MARK: dataviewjs (스펙 §5·§7)
        var dataviewBlocks: [DataviewBlock] = []
        var dataviewApproved = false          // 클릭-투-런 승인 — 문서 바뀌면 리셋
        var dataviewRunToken = 0              // 재렌더/탭 전환 시 증가 — 스테일 주입 가드
```

렌더 직전 호출할 메서드(coordinator 안):

```swift
        /// dataviewjs 블록을 추출하고 placeholder를 끼운 마크다운을 돌려준다.
        /// renderToHTML의 코드 마스킹 전에 원문에서 떼어내야 하므로 모든 렌더 경로가 이걸 먼저 거친다.
        func prepareDataview(_ markdown: String, baseURL: URL?) -> String {
            dataviewRunToken += 1
            let (settingsVaults, indexed) = dataviewPolicyInputs()
            let notePath = AppState.shared?.currentDocumentURL?.path ?? baseURL?.path ?? ""
            let auto = dataviewApproved
                || DataviewRunPolicy.isAutoRun(notePath: notePath, vaultPaths: settingsVaults, indexedFolders: indexed)
            let result = DataviewBlockExtractor.extract(markdown) { id in
                auto ? "<div class=\"dataview-block\" id=\"dv-b\(id)\">\(DataviewHTMLSerializer.pendingCard())</div>"
                     : DataviewHTMLSerializer.runButtonCard(blockId: id, code: dataviewCode(id: id, in: markdown))
            }
            dataviewBlocks = result.blocks
            if auto { scheduleDataviewRuns(baseURL: baseURL) }
            return result.markdown
        }
```

구현 주의: `runButtonCard`가 코드 원문을 필요로 하는데 extract 클로저 시점엔 blocks 배열이 아직 미완 — extract API를 쓰는 쪽에서 두 단계로: 먼저 `extract`를 스피너 placeholder로 수행해 blocks를 얻고, 수동 모드면 markdown 내 placeholder 문자열(`dv-b<i>` div)을 `runButtonCard(blockId:code:)`로 치환하는 후처리. (Task 1의 extract 시그니처는 그대로 두고 여기서 문자열 치환.)

백그라운드 실행·주입(coordinator 안):

```swift
        func scheduleDataviewRuns(baseURL: URL?) {
            guard !dataviewBlocks.isEmpty else { return }
            let token = dataviewRunToken
            let blocks = dataviewBlocks
            let (vaults, indexed) = dataviewPolicyInputs()
            let noteURL = AppState.shared?.currentDocumentURL ?? baseURL
            guard let noteURL else { return }
            let rootPath = DataviewRunPolicy.rootPath(for: noteURL.path, vaultPaths: vaults, indexedFolders: indexed)
            let rootURL = rootPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? noteURL.deletingLastPathComponent()

            Task.detached(priority: .userInitiated) { [weak self] in
                for block in blocks {
                    let result = DataviewEngine.run(code: block.code,
                                                    context: DataviewRunContext(noteURL: noteURL, rootURL: rootURL))
                    let html: String
                    switch result {
                    case .success(let items): html = DataviewHTMLSerializer.html(for: items)
                    case .failure(.timeout):
                        html = DataviewHTMLSerializer.errorCard(message: "실행이 3초를 넘어 중단했습니다", code: block.code)
                    case .failure(.assetsMissing):
                        html = DataviewHTMLSerializer.errorCard(message: "렌더 자산을 찾지 못했습니다", code: block.code)
                    case .failure(.script(let msg)):
                        html = DataviewHTMLSerializer.errorCard(message: msg, code: block.code)
                    }
                    await MainActor.run { [weak self] in
                        guard let self, self.dataviewRunToken == token else { return }   // 스테일 가드
                        self.injectDataviewResult(blockId: block.id, html: html)
                    }
                }
            }
        }

        private func injectDataviewResult(blockId: Int, html: String) {
            guard let data = try? JSONEncoder().encode(html),
                  let quoted = String(data: data, encoding: .utf8) else { return }
            let js = "(function(){var el=document.getElementById('dv-b\(blockId)');if(el){el.innerHTML=\(quoted);}})();"
            webView?.evaluateJavaScript(js, completionHandler: nil)
        }

        private func dataviewPolicyInputs() -> ([String], [String]) {
            guard let state = AppState.shared else { return ([], []) }
            return (state.settings.vaults.map { $0.rootPath.path }, state.settings.indexedFolders)
        }
```

메시지 핸들러 확장(`userContentController(_:didReceive:)`의 toggleTask 분기 아래):

```swift
            if type == "dataviewRun", body["id"] is Int {
                // 클릭-투-런 승인 — 이 탭·이 문서가 열려 있는 동안 유지(스펙 §7), 재렌더로 실행.
                dataviewApproved = true
                rerenderCurrentMarkdown()   // 기존 재렌더 경로(lastSource 재사용) 호출
            }
```

3개 렌더 경로(`makeNSView`·`updateNSView` 문서 전환·디바운스)의 `renderer.renderToHTML(markdown: X, ...)`를 `renderer.renderToHTML(markdown: context.coordinator.prepareDataview(X, baseURL: baseURL), ...)` 형태로 연결하고, 문서 전환 분기에서 `dataviewApproved = false` 리셋. `rerenderCurrentMarkdown`은 coordinator의 기존 디바운스 재렌더 메서드(PreviewView.swift:151 부근)를 public 헬퍼로 감싼 것 — 구현자가 기존 메서드명에 맞춘다. `AppState.currentDocumentURL`이 없으면(grep으로 실명 확인) 활성 탭 URL 접근자를 쓴다 — 없을 경우 PreviewView에 `documentURL: URL?` 파라미터를 추가하고 MainEditorView 호출부에서 활성 탭 fileURL을 넘기는 쪽이 침습이 적다(구현 시 판단, 리뷰에서 확인).

- [ ] **Step 6: 전체 게이트+빌드 경고 0** — `swift build 2>&1 | grep -c warning` → 0, `swift test` 실패 0
- [ ] **Step 7: 커밋** — `기능(dataview): 실행 정책+프리뷰 배선 — 볼트 안 자동/밖 클릭-투-런·스테일 가드`

---

### Task 8: 마무리 — 스펙 정정·문서·수동 스모크

**Files:**
- Modify: `docs/superpowers/specs/2026-07-05-dataviewjs-preview-render-design.md` (§5 actor→NSLock 클래스 정정 1줄)
- Modify: `CLAUDE.md` (현재 상태 항목 추가·다음 액션 갱신)

- [ ] **Step 1: 스펙 §5 정정** — `DataviewPageIndex` 항목의 "(actor)"를 "(final class — JSContext 동기 콜백에서 actor await 불가, NSLock 캐시)"로 수정.
- [ ] **Step 2: 전체 게이트 최종** — `swift test 2>&1 | grep Executed | tail -2` — 총 테스트 수 기록(CLAUDE.md에 반영).
- [ ] **Step 3: 수동 스모크 체크리스트 실행**(실 notebox — 읽기 전용이라 안전):
  1. notebox의 `Calendar/2026-W27.md` 열기 → 프리뷰에 주간 표가 옵시디언과 동일 행으로 렌더되는가(옵시디언 화면과 대조).
  2. 표의 날짜 링크 클릭 → 해당 데일리 노트가 열리는가.
  3. `Calendar/2026/2026-06.md`(월간) → 주간 리뷰 목록 렌더.
  4. Downloads 등 볼트 밖에 dataviewjs 든 md를 복사해 열기 → "▶ 이 블록 실행" 버튼 → 클릭 시 렌더, 탭 닫고 재열기 시 다시 버튼.
  5. `while(true){}` 블록 든 노트 → 3초 후 타임아웃 오류 카드, 앱 정상.
  6. 편집 모드에서 데일리에 줄 추가 후 위클리 재열기 → 표에 반영(mtime 캐시 무효화).
  - 주의: notebox가 cmdALL에 볼트/인덱스 폴더로 등록돼 있어야 자동 실행 — 아니면 등록 후 진행.
- [ ] **Step 4: CLAUDE.md 갱신** — 현재 상태에 완료 항목(테스트 수·스모크 결과 포함), 다음 액션 ⓪ 제거·세션 복원을 ⓪로 승격.
- [ ] **Step 5: 커밋** — `문서: dataviewjs 프리뷰 렌더 완료 기록 — 스펙 §5 정정·CLAUDE.md`

## Self-Review 결과 (계획 작성 후 점검)

- 스펙 커버리지: §3 서브셋(T4 shim+T6)·여유분(shim tasks/page/태그/frontmatter — T2·T3·T4)·§5 컴포넌트 전부(T1~7)·§7 정책(T7)·§8 에러(T5 카드+T6 분류)·§9 캐시(T3)·§10 테스트(각 태스크)·§12 확인 필요 중 luxon 주차는 T6 e2e가, file.day·폴더 매칭은 T8 스모크 1이 커버.
- 타입 일관성: `DataviewBlock/PageMeta/OutputItem/CellValue/Error/RunContext` 이름·시그니처를 태스크 간 Interfaces 블록에 명시(생산 태스크와 소비 태스크 동일 표기 확인).
- 알려진 구현 재량 2곳을 명시함: T6 pages 오류 JSON 인코드, T7 currentDocumentURL 실명 확인 — 둘 다 구현 주의로 계획 안에 적시.
