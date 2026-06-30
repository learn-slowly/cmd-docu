# Phase 8 — 폴더 정리(배치) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 어수선한 폴더를 Claude가 종류·주제별 스킴으로 제안 → 사용자가 승인한 만큼만 하위폴더 또는 PARA 볼트로 이동하고, 배치 단위로 되돌릴 수 있게 한다(삭제 없음).

**Architecture:** 플랜을 제네릭 이동 목록(`[from→to]`)으로 모델링한다. 순수 헬퍼(`CleanupPlanner`, `FileScanner`)가 프롬프트 생성·strict JSON 파싱·경로 안전·배정 병합을 담당하고(테스트 대상), actor(`CleanupService`/`MoveExecutor`/`MoveLogStore`)가 Claude 호출·파일 이동·영속 로그를 맡는다. UI(`FolderCleanupView`)는 제안→확인→실행 흐름을 시트로 노출한다. 기존 `ClaudeService`·`ContentExtractor`·`URL.uniquified()`를 재사용한다.

**Tech Stack:** Swift 5.9 / SwiftUI, Foundation `FileManager`·`Process`, XCTest. macOS 14+. 비샌드박스.

## Global Constraints

- macOS 14+, Swift 5.9+, SPM, **비샌드박스 유지**(서브프로세스 호출 보호). 값 그대로.
- **삭제 절대 없음.** 이동·이름변경만. undo의 폴더 제거는 *우리가 생성한 빈 폴더*만.
- **제안 → 확인 → 실행.** 승인 없이 어떤 파일도 이동 금지. 자동 정리 토글 없음.
- 신규 기능은 **별도 파일·모듈**로 분리(업스트림 CmdMD 머지 용이).
- 코드 주석·커밋 메시지는 **한국어**. '박다/박는다' 표현 금지.
- 커밋 메시지 푸터: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>` / `Claude-Session: https://claude.ai/code/session_01Qeysoi8eVrcjX87xBeZ4Pf`
- 테스트 실행은 정식 Xcode 필요(`swift test`). CLT만이면 `swift build`까지만 — 그 경우 빌드+수동검증으로 게이트.
- 모듈명 `CmdMD`(`@testable import CmdMD`). 테스트는 `Tests/CmdMDTests/`.

---

### Task 1: CleanupModels (데이터 모델)

**Files:**
- Create: `Sources/Models/CleanupModels.swift`
- Test: `Tests/CmdMDTests/CleanupModelsTests.swift`

**Interfaces:**
- Consumes: 기존 `Vault`(`rootPath: URL`, `displayName: String`), `ParaFolder`(`id: UUID`, `label`, `folder`, `hint`).
- Produces:
  - `enum CleanupMode { case subfolder(root: URL); case para(vault: Vault) }` — `var root: URL`, `var label: String`
  - `struct CleanupBucket: Identifiable, Equatable, Codable, Hashable { var id: String; var name: String; var hint: String; var relativePath: String }`
  - `typealias CleanupScheme = [CleanupBucket]`
  - `struct FileMeta: Equatable { let url: URL; let name: String; let ext: String; let size: Int64; let createdAt: Date; let modifiedAt: Date }`
  - `struct CleanupAssignment: Equatable { let fileURL: URL; let bucketId: String; let reason: String; let confidence: Double }`
  - `struct CleanupMove: Identifiable, Equatable { let id: UUID; let source: URL; let bucketId: String; let reason: String; let confidence: Double; var approved: Bool }`
  - `struct CleanupPlan: Equatable { let scheme: CleanupScheme; var moves: [CleanupMove] }`
  - `struct MoveRecord: Codable, Equatable { let from: URL; let to: URL }`
  - `struct MoveBatch: Codable, Equatable, Identifiable { let id: UUID; let date: Date; let modeLabel: String; let records: [MoveRecord]; let createdDirs: [URL] }`
  - `static func CleanupBucket.from(para: ParaFolder) -> CleanupBucket`

- [ ] **Step 1: 실패하는 테스트 작성**

```swift
import XCTest
@testable import CmdMD

final class CleanupModelsTests: XCTestCase {
    func testParaBucketMapsFolderToRelativePath() {
        let pf = ParaFolder(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000aa")!,
                            label: "Resources", folder: "30000_Resources", hint: "참고 자료")
        let bucket = CleanupBucket.from(para: pf)
        XCTAssertEqual(bucket.id, pf.id.uuidString)
        XCTAssertEqual(bucket.name, "Resources")
        XCTAssertEqual(bucket.relativePath, "30000_Resources")
        XCTAssertEqual(bucket.hint, "참고 자료")
    }

    func testMoveBatchCodableRoundTrip() throws {
        let batch = MoveBatch(
            id: UUID(uuidString: "00000000-0000-0000-0000-0000000000bb")!,
            date: Date(timeIntervalSince1970: 1_700_000_000),
            modeLabel: "하위폴더 정리 — Downloads",
            records: [MoveRecord(from: URL(fileURLWithPath: "/a/x.pdf"),
                                 to: URL(fileURLWithPath: "/a/문서/x.pdf"))],
            createdDirs: [URL(fileURLWithPath: "/a/문서")]
        )
        let data = try JSONEncoder().encode(batch)
        let decoded = try JSONDecoder().decode(MoveBatch.self, from: data)
        XCTAssertEqual(decoded, batch)
    }

    func testSubfolderModeRootAndLabel() {
        let root = URL(fileURLWithPath: "/Users/x/Downloads")
        let mode = CleanupMode.subfolder(root: root)
        XCTAssertEqual(mode.root, root)
        XCTAssertTrue(mode.label.contains("Downloads"))
    }
}
```

- [ ] **Step 2: 실패 확인**

Run: `swift test --filter CleanupModelsTests`
Expected: 컴파일 실패("cannot find 'CleanupBucket' in scope" 등).

- [ ] **Step 3: 모델 구현**

```swift
import Foundation

/// 정리 목적지 모드. 두 모드 공통으로 root 하위로만 이동한다.
enum CleanupMode: Equatable {
    case subfolder(root: URL)
    case para(vault: Vault)

    var root: URL {
        switch self {
        case .subfolder(let r): return r
        case .para(let v): return v.rootPath
        }
    }

    var label: String {
        switch self {
        case .subfolder(let r): return "하위폴더 정리 — \(r.lastPathComponent)"
        case .para(let v): return "PARA — \(v.displayName)"
        }
    }
}

/// 정리 스킴의 한 폴더(버킷). subfolder 모드는 name==relativePath, PARA 모드는 ParaFolder에서 매핑.
struct CleanupBucket: Identifiable, Equatable, Codable, Hashable {
    var id: String
    var name: String          // 표시·폴더명
    var hint: String          // Claude 분류용 설명
    var relativePath: String  // root 기준 상대경로

    static func from(para: ParaFolder) -> CleanupBucket {
        CleanupBucket(id: para.id.uuidString, name: para.label, hint: para.hint, relativePath: para.folder)
    }
}

typealias CleanupScheme = [CleanupBucket]

/// 폴더 스캔으로 수집한 파일 메타데이터.
struct FileMeta: Equatable {
    let url: URL
    let name: String
    let ext: String
    let size: Int64
    let createdAt: Date
    let modifiedAt: Date
}

/// Claude가 파일을 버킷에 배정한 결과(미분류면 bucketId == "").
struct CleanupAssignment: Equatable {
    let fileURL: URL
    let bucketId: String
    let reason: String
    let confidence: Double
}

/// 미리보기·승인 단위. 목적지 URL은 실행 시 root + bucket에서 해석한다.
struct CleanupMove: Identifiable, Equatable {
    let id: UUID
    let source: URL
    let bucketId: String
    let reason: String
    let confidence: Double
    var approved: Bool
}

struct CleanupPlan: Equatable {
    let scheme: CleanupScheme
    var moves: [CleanupMove]
}

/// undo용 from→to 기록.
struct MoveRecord: Codable, Equatable {
    let from: URL
    let to: URL
}

/// 한 번의 정리 실행(배치). undo 단위.
struct MoveBatch: Codable, Equatable, Identifiable {
    let id: UUID
    let date: Date
    let modeLabel: String
    let records: [MoveRecord]
    let createdDirs: [URL]   // 우리가 생성한 폴더(undo 시 비었으면 제거 후보)
}
```

- [ ] **Step 4: 통과 확인**

Run: `swift test --filter CleanupModelsTests`
Expected: PASS (3 tests).

- [ ] **Step 5: 커밋**

```bash
git add Sources/Models/CleanupModels.swift Tests/CmdMDTests/CleanupModelsTests.swift
git commit -m "기능(정리): Phase 8 CleanupModels 모델 추가"
```

---

### Task 2: FileScanner (폴더 메타데이터 스캔)

**Files:**
- Create: `Sources/Services/FileScanner.swift`
- Test: `Tests/CmdMDTests/FileScannerTests.swift`

**Interfaces:**
- Consumes: `FileMeta`(Task 1).
- Produces: `enum FileScanner { static func scan(_ folder: URL) -> [FileMeta] }` — top-level 파일만, 숨김파일·하위폴더 제외, 이름순 정렬.

- [ ] **Step 1: 실패하는 테스트 작성**

```swift
import XCTest
@testable import CmdMD

final class FileScannerTests: XCTestCase {
    private func makeTempDir() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("scan-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func testScanReturnsTopLevelFilesOnly() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        try "a".write(to: dir.appendingPathComponent("note.md"), atomically: true, encoding: .utf8)
        try "b".write(to: dir.appendingPathComponent("pic.png"), atomically: true, encoding: .utf8)
        // 하위폴더와 숨김파일은 제외돼야 한다
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("sub"), withIntermediateDirectories: true)
        try "c".write(to: dir.appendingPathComponent(".hidden"), atomically: true, encoding: .utf8)

        let metas = FileScanner.scan(dir)
        XCTAssertEqual(metas.map { $0.name }, ["note.md", "pic.png"])
        XCTAssertEqual(metas.first?.ext, "md")
    }

    func testScanMissingFolderReturnsEmpty() {
        let metas = FileScanner.scan(URL(fileURLWithPath: "/nonexistent-\(UUID().uuidString)"))
        XCTAssertTrue(metas.isEmpty)
    }
}
```

- [ ] **Step 2: 실패 확인**

Run: `swift test --filter FileScannerTests`
Expected: 컴파일 실패("cannot find 'FileScanner'").

- [ ] **Step 3: 구현**

```swift
import Foundation

/// 폴더 1단계(top-level) 파일만 메타데이터로 수집한다. 숨김파일·하위폴더 제외.
enum FileScanner {
    static func scan(_ folder: URL) -> [FileMeta] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .creationDateKey, .contentModificationDateKey]
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return [] }

        var result: [FileMeta] = []
        for url in items {
            let rv = try? url.resourceValues(forKeys: Set(keys))
            if rv?.isDirectory == true { continue }
            result.append(FileMeta(
                url: url,
                name: url.lastPathComponent,
                ext: url.pathExtension.lowercased(),
                size: Int64(rv?.fileSize ?? 0),
                createdAt: rv?.creationDate ?? Date(),
                modifiedAt: rv?.contentModificationDate ?? Date()
            ))
        }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
```

- [ ] **Step 4: 통과 확인**

Run: `swift test --filter FileScannerTests`
Expected: PASS (2 tests).

- [ ] **Step 5: 커밋**

```bash
git add Sources/Services/FileScanner.swift Tests/CmdMDTests/FileScannerTests.swift
git commit -m "기능(정리): FileScanner(top-level 메타데이터 스캔) 추가"
```

---

### Task 3: CleanupPlanner — 스킴 프롬프트·파싱·이름 sanitize

**Files:**
- Create: `Sources/Services/CleanupPlanner.swift`
- Test: `Tests/CmdMDTests/CleanupPlannerSchemeTests.swift`

**Interfaces:**
- Consumes: `FileMeta`, `CleanupBucket`, `CleanupScheme`(Task 1).
- Produces (이 태스크 분량):
  - `enum CleanupPlanner`
  - `static func metadataList(_ metas: [FileMeta]) -> String`
  - `static func sanitizeBucketName(_ name: String) -> String`
  - `static func buildSchemePrompt(metadata metas: [FileMeta]) -> String`
  - `static func parseScheme(_ stdout: String) -> CleanupScheme?`
  - `static func extractJSONObject(_ stdout: String) -> String?` (내부 공용, `RouteHelper` 패턴)

- [ ] **Step 1: 실패하는 테스트 작성**

```swift
import XCTest
@testable import CmdMD

final class CleanupPlannerSchemeTests: XCTestCase {
    private func metas() -> [FileMeta] {
        [
            FileMeta(url: URL(fileURLWithPath: "/d/세금신고.pdf"), name: "세금신고.pdf", ext: "pdf",
                     size: 100, createdAt: Date(), modifiedAt: Date()),
            FileMeta(url: URL(fileURLWithPath: "/d/사진.png"), name: "사진.png", ext: "png",
                     size: 200, createdAt: Date(), modifiedAt: Date()),
        ]
    }

    func testSchemePromptListsFilesAndAsksJSON() {
        let p = CleanupPlanner.buildSchemePrompt(metadata: metas())
        XCTAssertTrue(p.contains("세금신고.pdf"))
        XCTAssertTrue(p.contains("사진.png"))
        XCTAssertTrue(p.lowercased().contains("json"))
        XCTAssertTrue(p.contains("\"buckets\""))
    }

    func testParseSchemeExtractsBuckets() {
        let out = "여기 결과:\n{\"buckets\":[{\"name\":\"문서\",\"hint\":\"PDF·서류\"},{\"name\":\"이미지\",\"hint\":\"사진\"}]}\n끝"
        let scheme = CleanupPlanner.parseScheme(out)
        XCTAssertEqual(scheme?.count, 2)
        XCTAssertEqual(scheme?.first?.name, "문서")
        XCTAssertEqual(scheme?.first?.id, "문서")
        XCTAssertEqual(scheme?.first?.relativePath, "문서")
        XCTAssertEqual(scheme?.first?.hint, "PDF·서류")
    }

    func testParseSchemeSanitizesAndDedupes() {
        let out = "{\"buckets\":[{\"name\":\"../탈출\",\"hint\":\"x\"},{\"name\":\"a/b\",\"hint\":\"y\"},{\"name\":\"a-b\",\"hint\":\"z\"}]}"
        let scheme = CleanupPlanner.parseScheme(out)
        // "a/b" → "a-b" 가 되어 "a-b"와 중복 → 하나만 남는다. "../탈출" → ".." 제거.
        XCTAssertNotNil(scheme)
        XCTAssertFalse(scheme!.contains { $0.id.contains("/") || $0.id.contains("..") })
        XCTAssertEqual(scheme!.filter { $0.id == "a-b" }.count, 1)
    }

    func testParseSchemeReturnsNilOnGarbage() {
        XCTAssertNil(CleanupPlanner.parseScheme("그냥 텍스트 아무것도 없음"))
        XCTAssertNil(CleanupPlanner.parseScheme("{\"buckets\":[]}"))
    }
}
```

- [ ] **Step 2: 실패 확인**

Run: `swift test --filter CleanupPlannerSchemeTests`
Expected: 컴파일 실패("cannot find 'CleanupPlanner'").

- [ ] **Step 3: 구현**

```swift
import Foundation

/// 정리 프롬프트 생성·strict JSON 파싱·경로 안전·배정 병합을 담당하는 순수 헬퍼.
/// RouteHelper와 동형(테스트 대상).
enum CleanupPlanner {

    /// 파일 메타데이터 목록을 "이름 | 확장자 | 크기" 줄로 직렬화.
    static func metadataList(_ metas: [FileMeta]) -> String {
        metas.map { m in
            "- \(m.name) | \(m.ext.isEmpty ? "(없음)" : m.ext) | \(m.size)B"
        }.joined(separator: "\n")
    }

    /// 폴더명 안전화: 경로 구분자·금지문자·`..` 제거.
    static func sanitizeBucketName(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>\u{0}")
        var cleaned = name.components(separatedBy: invalid).joined(separator: "-")
        cleaned = cleaned.replacingOccurrences(of: "..", with: "")
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// stdout에서 첫 `{` ~ 마지막 `}` 구간만 추출(RouteHelper 패턴).
    static func extractJSONObject(_ stdout: String) -> String? {
        guard let start = stdout.firstIndex(of: "{"),
              let end = stdout.lastIndex(of: "}"), start < end else { return nil }
        return String(stdout[start...end])
    }

    static func buildSchemePrompt(metadata metas: [FileMeta]) -> String {
        """
        아래는 한 폴더의 파일 목록(이름 | 확장자 | 크기)이다. 이 파일들을 종류·주제별로
        정리할 하위폴더 묶음(스킴)을 제안하라. 폴더는 3~8개로 적절히 묶고 한국어 폴더명을 쓴다.
        경로 구분자(/·\\)나 ..는 폴더명에 쓰지 않는다.

        \(metadataList(metas))

        답은 다른 텍스트 없이 strict JSON 한 줄로만 한다:
        {"buckets":[{"name":"<폴더명>","hint":"<무엇을 담는지 한 줄>"}]}
        """
    }

    private struct SchemeParse: Decodable { let buckets: [BucketParse] }
    private struct BucketParse: Decodable { let name: String; let hint: String? }

    /// strict JSON 추출·디코드 후 이름 sanitize·중복 제거. 결과 없으면 nil.
    static func parseScheme(_ stdout: String) -> CleanupScheme? {
        guard let json = extractJSONObject(stdout),
              let data = json.data(using: .utf8),
              let parsed = try? JSONDecoder().decode(SchemeParse.self, from: data)
        else { return nil }

        var seen = Set<String>()
        var buckets: CleanupScheme = []
        for b in parsed.buckets {
            let clean = sanitizeBucketName(b.name)
            guard !clean.isEmpty, !seen.contains(clean) else { continue }
            seen.insert(clean)
            buckets.append(CleanupBucket(id: clean, name: clean, hint: b.hint ?? "", relativePath: clean))
        }
        return buckets.isEmpty ? nil : buckets
    }
}
```

- [ ] **Step 4: 통과 확인**

Run: `swift test --filter CleanupPlannerSchemeTests`
Expected: PASS (4 tests).

- [ ] **Step 5: 커밋**

```bash
git add Sources/Services/CleanupPlanner.swift Tests/CmdMDTests/CleanupPlannerSchemeTests.swift
git commit -m "기능(정리): CleanupPlanner 스킴 프롬프트·파싱·sanitize 추가"
```

---

### Task 4: CleanupPlanner — 배정 프롬프트·파싱·병합·moves 빌드

**Files:**
- Modify: `Sources/Services/CleanupPlanner.swift` (메서드 추가)
- Test: `Tests/CmdMDTests/CleanupPlannerAssignTests.swift`

**Interfaces:**
- Consumes: `CleanupScheme`, `FileMeta`, `CleanupAssignment`, `CleanupMove`(Task 1), `extractJSONObject`/`metadataList`(Task 3).
- Produces:
  - `static func buildAssignPrompt(scheme: CleanupScheme, metadata metas: [FileMeta]) -> String`
  - `static func buildAmbiguousContext(_ items: [(name: String, excerpt: String)], maxCharsEach: Int = 1500) -> String`
  - `static func parseAssignments(_ stdout: String, scheme: CleanupScheme, metadata metas: [FileMeta]) -> [CleanupAssignment]?`
  - `static func merge(_ base: [CleanupAssignment], with overrides: [CleanupAssignment]) -> [CleanupAssignment]`
  - `static func buildMoves(from assignments: [CleanupAssignment]) -> [CleanupMove]`

- [ ] **Step 1: 실패하는 테스트 작성**

```swift
import XCTest
@testable import CmdMD

final class CleanupPlannerAssignTests: XCTestCase {
    private func scheme() -> CleanupScheme {
        [CleanupBucket(id: "문서", name: "문서", hint: "서류", relativePath: "문서"),
         CleanupBucket(id: "이미지", name: "이미지", hint: "사진", relativePath: "이미지")]
    }
    private func metas() -> [FileMeta] {
        [FileMeta(url: URL(fileURLWithPath: "/d/세금.pdf"), name: "세금.pdf", ext: "pdf", size: 1, createdAt: Date(), modifiedAt: Date()),
         FileMeta(url: URL(fileURLWithPath: "/d/사진.png"), name: "사진.png", ext: "png", size: 1, createdAt: Date(), modifiedAt: Date())]
    }

    func testAssignPromptIncludesSchemeIdsAndFiles() {
        let p = CleanupPlanner.buildAssignPrompt(scheme: scheme(), metadata: metas())
        XCTAssertTrue(p.contains("문서"))
        XCTAssertTrue(p.contains("이미지"))
        XCTAssertTrue(p.contains("세금.pdf"))
        XCTAssertTrue(p.contains("\"assignments\""))
    }

    func testParseAssignmentsMatchesByNameAndValidatesId() {
        let out = """
        {"assignments":[
          {"name":"세금.pdf","id":"문서","reason":"서류","confidence":0.9},
          {"name":"사진.png","id":"없는버킷","reason":"?","confidence":0.4},
          {"name":"유령.txt","id":"문서","reason":"x","confidence":1.0}
        ]}
        """
        let a = CleanupPlanner.parseAssignments(out, scheme: scheme(), metadata: metas())
        XCTAssertEqual(a?.count, 2) // 유령.txt는 메타에 없어 버려짐
        XCTAssertEqual(a?.first(where: { $0.fileURL.lastPathComponent == "세금.pdf" })?.bucketId, "문서")
        // 없는 버킷 id는 ""(미분류)로 강등
        XCTAssertEqual(a?.first(where: { $0.fileURL.lastPathComponent == "사진.png" })?.bucketId, "")
    }

    func testParseAssignmentsClampsConfidence() {
        let out = "{\"assignments\":[{\"name\":\"세금.pdf\",\"id\":\"문서\",\"reason\":\"x\",\"confidence\":9.9}]}"
        let a = CleanupPlanner.parseAssignments(out, scheme: scheme(), metadata: metas())
        XCTAssertEqual(a?.first?.confidence, 1.0)
    }

    func testParseAssignmentsNilOnGarbage() {
        XCTAssertNil(CleanupPlanner.parseAssignments("없음", scheme: scheme(), metadata: metas()))
    }

    func testMergeOverridesByURL() {
        let base = [CleanupAssignment(fileURL: URL(fileURLWithPath: "/d/세금.pdf"), bucketId: "", reason: "모호", confidence: 0.2)]
        let over = [CleanupAssignment(fileURL: URL(fileURLWithPath: "/d/세금.pdf"), bucketId: "문서", reason: "본문 확인", confidence: 0.95)]
        let merged = CleanupPlanner.merge(base, with: over)
        XCTAssertEqual(merged.first?.bucketId, "문서")
        XCTAssertEqual(merged.first?.confidence, 0.95)
    }

    func testBuildMovesApprovesOnlyClassified() {
        let assigns = [
            CleanupAssignment(fileURL: URL(fileURLWithPath: "/d/세금.pdf"), bucketId: "문서", reason: "x", confidence: 0.9),
            CleanupAssignment(fileURL: URL(fileURLWithPath: "/d/사진.png"), bucketId: "", reason: "모호", confidence: 0.1),
        ]
        let moves = CleanupPlanner.buildMoves(from: assigns)
        XCTAssertEqual(moves.count, 2)
        XCTAssertEqual(moves.first(where: { $0.source.lastPathComponent == "세금.pdf" })?.approved, true)
        XCTAssertEqual(moves.first(where: { $0.source.lastPathComponent == "사진.png" })?.approved, false)
    }

    func testAmbiguousContextTruncates() {
        let ctx = CleanupPlanner.buildAmbiguousContext([("a.md", String(repeating: "가", count: 5000))], maxCharsEach: 100)
        XCTAssertTrue(ctx.contains("a.md"))
        XCTAssertTrue(ctx.contains("생략"))
        XCTAssertLessThan(ctx.count, 5000)
    }
}
```

- [ ] **Step 2: 실패 확인**

Run: `swift test --filter CleanupPlannerAssignTests`
Expected: 컴파일 실패("cannot find 'buildAssignPrompt'").

- [ ] **Step 3: 구현 (`CleanupPlanner`에 메서드 추가)**

```swift
extension CleanupPlanner {

    static func buildAssignPrompt(scheme: CleanupScheme, metadata metas: [FileMeta]) -> String {
        let list = scheme.map { "- \($0.id) — \($0.hint)" }.joined(separator: "\n")
        return """
        아래 폴더 스킴(id — 설명)이 있다:

        \(list)

        다음 파일들을 각각 위 스킴의 id 중 하나에 배정하라. 확신이 없으면 confidence를 낮게 준다.
        어디에도 맞지 않으면 id를 빈 문자열("")로 둔다.

        \(metadataList(metas))

        답은 다른 텍스트 없이 strict JSON 한 줄로만 한다:
        {"assignments":[{"name":"<파일명>","id":"<스킴 id 또는 \\"\\">","reason":"<한 줄>","confidence":0.0}]}
        """
    }

    /// 모호 파일의 본문 발췌를 파일명 헤더와 함께 묶는다. 각 발췌는 maxCharsEach로 truncate.
    static func buildAmbiguousContext(_ items: [(name: String, excerpt: String)], maxCharsEach: Int = 1500) -> String {
        items.map { item in
            let body = item.excerpt.count > maxCharsEach
                ? String(item.excerpt.prefix(maxCharsEach)) + "\n…(생략)"
                : item.excerpt
            return "## \(item.name)\n\(body)"
        }.joined(separator: "\n\n")
    }

    private struct AssignParse: Decodable { let assignments: [AssignmentParse] }
    private struct AssignmentParse: Decodable {
        let name: String; let id: String; let reason: String?; let confidence: Double?
    }

    /// 파일명으로 메타와 매칭하고 id를 스킴 허용 목록으로 검증(밖이면 ""). confidence는 0...1 클램프.
    static func parseAssignments(_ stdout: String, scheme: CleanupScheme, metadata metas: [FileMeta]) -> [CleanupAssignment]? {
        guard let json = extractJSONObject(stdout),
              let data = json.data(using: .utf8),
              let parsed = try? JSONDecoder().decode(AssignParse.self, from: data)
        else { return nil }

        let validIds = Set(scheme.map { $0.id })
        let byName = Dictionary(metas.map { ($0.name, $0.url) }, uniquingKeysWith: { a, _ in a })

        var result: [CleanupAssignment] = []
        for a in parsed.assignments {
            guard let url = byName[a.name] else { continue }
            let validId = validIds.contains(a.id) ? a.id : ""
            let conf = min(1.0, max(0.0, a.confidence ?? 0))
            result.append(CleanupAssignment(fileURL: url, bucketId: validId, reason: a.reason ?? "", confidence: conf))
        }
        return result
    }

    /// overrides(2차 본문 재배정)를 fileURL 기준으로 base에 덮어쓴다.
    static func merge(_ base: [CleanupAssignment], with overrides: [CleanupAssignment]) -> [CleanupAssignment] {
        var byURL = Dictionary(base.map { ($0.fileURL, $0) }, uniquingKeysWith: { a, _ in a })
        for o in overrides { byURL[o.fileURL] = o }
        return base.map { byURL[$0.fileURL] ?? $0 }
    }

    /// 배정을 미리보기용 move로 변환. 분류된 것만 기본 승인.
    static func buildMoves(from assignments: [CleanupAssignment]) -> [CleanupMove] {
        assignments.map {
            CleanupMove(id: UUID(), source: $0.fileURL, bucketId: $0.bucketId,
                        reason: $0.reason, confidence: $0.confidence, approved: !$0.bucketId.isEmpty)
        }
    }
}
```

- [ ] **Step 4: 통과 확인**

Run: `swift test --filter CleanupPlannerAssignTests`
Expected: PASS (7 tests).

- [ ] **Step 5: 커밋**

```bash
git add Sources/Services/CleanupPlanner.swift Tests/CmdMDTests/CleanupPlannerAssignTests.swift
git commit -m "기능(정리): CleanupPlanner 배정 프롬프트·파싱·병합·moves 빌드 추가"
```

---

### Task 5: CleanupPlanner — destinationDir (경로 탈출 방지)

**Files:**
- Modify: `Sources/Services/CleanupPlanner.swift`
- Test: `Tests/CmdMDTests/CleanupPathSafetyTests.swift`

**Interfaces:**
- Consumes: `CleanupBucket`(Task 1).
- Produces: `static func destinationDir(root: URL, bucket: CleanupBucket) -> URL?` — root 하위가 아니면 nil.

- [ ] **Step 1: 실패하는 테스트 작성**

```swift
import XCTest
@testable import CmdMD

final class CleanupPathSafetyTests: XCTestCase {
    func testDestinationWithinRoot() {
        let root = URL(fileURLWithPath: "/Users/x/Downloads")
        let bucket = CleanupBucket(id: "문서", name: "문서", hint: "", relativePath: "문서")
        let dest = CleanupPlanner.destinationDir(root: root, bucket: bucket)
        XCTAssertEqual(dest?.path, "/Users/x/Downloads/문서")
    }

    func testNestedRelativePathWithinRoot() {
        let root = URL(fileURLWithPath: "/v")
        let bucket = CleanupBucket(id: "p", name: "p", hint: "", relativePath: "10000_Projects/Living")
        let dest = CleanupPlanner.destinationDir(root: root, bucket: bucket)
        XCTAssertEqual(dest?.path, "/v/10000_Projects/Living")
    }

    func testEscapeAttemptReturnsNil() {
        let root = URL(fileURLWithPath: "/Users/x/Downloads")
        let bucket = CleanupBucket(id: "e", name: "e", hint: "", relativePath: "../../etc")
        XCTAssertNil(CleanupPlanner.destinationDir(root: root, bucket: bucket))
    }
}
```

- [ ] **Step 2: 실패 확인**

Run: `swift test --filter CleanupPathSafetyTests`
Expected: 컴파일 실패("cannot find 'destinationDir'").

- [ ] **Step 3: 구현 (`CleanupPlanner` extension에 추가)**

```swift
extension CleanupPlanner {
    /// bucket의 목적지 디렉터리. 표준화 후 root 하위가 아니면 nil(디렉터리 탈출 방지).
    static func destinationDir(root: URL, bucket: CleanupBucket) -> URL? {
        let dir = root.appendingPathComponent(bucket.relativePath)
        let rootPath = root.standardizedFileURL.path
        let dirPath = dir.standardizedFileURL.path
        guard dirPath == rootPath || dirPath.hasPrefix(rootPath + "/") else { return nil }
        return dir
    }
}
```

- [ ] **Step 4: 통과 확인**

Run: `swift test --filter CleanupPathSafetyTests`
Expected: PASS (3 tests).

- [ ] **Step 5: 커밋**

```bash
git add Sources/Services/CleanupPlanner.swift Tests/CmdMDTests/CleanupPathSafetyTests.swift
git commit -m "기능(정리): destinationDir 경로 탈출 방지 추가"
```

---

### Task 6: MoveLogStore (배치 로그 영속)

**Files:**
- Create: `Sources/Services/MoveLogStore.swift`
- Test: `Tests/CmdMDTests/MoveLogStoreTests.swift`

**Interfaces:**
- Consumes: `MoveBatch`(Task 1).
- Produces:
  - `actor MoveLogStore`
  - `init(directory: URL)` — `directory/cleanup-moves.json`에 영속
  - `func load() -> [MoveBatch]`
  - `func append(_ batch: MoveBatch)`
  - `func remove(id: UUID)`

- [ ] **Step 1: 실패하는 테스트 작성**

```swift
import XCTest
@testable import CmdMD

final class MoveLogStoreTests: XCTestCase {
    private func tempDir() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("log-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private func batch(_ label: String) -> MoveBatch {
        MoveBatch(id: UUID(), date: Date(timeIntervalSince1970: 1), modeLabel: label,
                  records: [MoveRecord(from: URL(fileURLWithPath: "/a/x"), to: URL(fileURLWithPath: "/a/d/x"))],
                  createdDirs: [URL(fileURLWithPath: "/a/d")])
    }

    func testAppendThenLoadRoundTrip() async {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = MoveLogStore(directory: dir)
        let b = batch("배치1")
        await store.append(b)
        let loaded = await store.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first, b)
    }

    func testRemoveById() async {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = MoveLogStore(directory: dir)
        let b1 = batch("b1"); let b2 = batch("b2")
        await store.append(b1); await store.append(b2)
        await store.remove(id: b1.id)
        let loaded = await store.load()
        XCTAssertEqual(loaded.map { $0.id }, [b2.id])
    }

    func testLoadEmptyWhenNoFile() async {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let store = MoveLogStore(directory: dir)
        let loaded = await store.load()
        XCTAssertTrue(loaded.isEmpty)
    }
}
```

- [ ] **Step 2: 실패 확인**

Run: `swift test --filter MoveLogStoreTests`
Expected: 컴파일 실패("cannot find 'MoveLogStore'").

- [ ] **Step 3: 구현**

```swift
import Foundation

/// 정리 배치 로그를 JSON 파일로 영속한다(undo용). 삭제 없음 — 로그만 관리.
actor MoveLogStore {
    private let fileURL: URL

    init(directory: URL) {
        self.fileURL = directory.appendingPathComponent("cleanup-moves.json")
    }

    func load() -> [MoveBatch] {
        guard let data = try? Data(contentsOf: fileURL),
              let batches = try? JSONDecoder().decode([MoveBatch].self, from: data) else { return [] }
        return batches
    }

    func append(_ batch: MoveBatch) {
        var all = load()
        all.append(batch)
        save(all)
    }

    func remove(id: UUID) {
        save(load().filter { $0.id != id })
    }

    private func save(_ batches: [MoveBatch]) {
        guard let data = try? JSONEncoder().encode(batches) else { return }
        try? data.write(to: fileURL, options: [.atomic])
    }
}
```

- [ ] **Step 4: 통과 확인**

Run: `swift test --filter MoveLogStoreTests`
Expected: PASS (3 tests).

- [ ] **Step 5: 커밋**

```bash
git add Sources/Services/MoveLogStore.swift Tests/CmdMDTests/MoveLogStoreTests.swift
git commit -m "기능(정리): MoveLogStore(배치 로그 영속) 추가"
```

---

### Task 7: MoveExecutor (이동 실행 + undo)

**Files:**
- Create: `Sources/Services/MoveExecutor.swift`
- Test: `Tests/CmdMDTests/MoveExecutorTests.swift`

**Interfaces:**
- Consumes: `CleanupPlan`, `CleanupMode`, `MoveBatch`, `MoveRecord`(Task 1); `CleanupPlanner.destinationDir`(Task 5); `MoveLogStore`(Task 6); `URL.uniquified()`(기존 AppState.swift extension).
- Produces:
  - `struct MoveOutcome { let batch: MoveBatch; let moved: Int; let failed: [URL] }`
  - `actor MoveExecutor`
  - `init(store: MoveLogStore)`
  - `func apply(plan: CleanupPlan, mode: CleanupMode) async -> MoveOutcome`
  - `func undo(_ batch: MoveBatch) async -> (restored: Int, failed: Int)`

- [ ] **Step 1: 실패하는 테스트 작성**

```swift
import XCTest
@testable import CmdMD

final class MoveExecutorTests: XCTestCase {
    private func tempDir() -> URL {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mv-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
    private func write(_ name: String, in dir: URL) -> URL {
        let url = dir.appendingPathComponent(name)
        try? "x".write(to: url, atomically: true, encoding: .utf8)
        return url
    }
    private func plan(scheme: CleanupScheme, moves: [CleanupMove]) -> CleanupPlan {
        CleanupPlan(scheme: scheme, moves: moves)
    }

    func testApplyMovesApprovedFilesAndLogsBatch() async {
        let root = tempDir(); defer { try? FileManager.default.removeItem(at: root) }
        let src = write("세금.pdf", in: root)
        let scheme = [CleanupBucket(id: "문서", name: "문서", hint: "", relativePath: "문서")]
        let move = CleanupMove(id: UUID(), source: src, bucketId: "문서", reason: "x", confidence: 0.9, approved: true)
        let store = MoveLogStore(directory: root)
        let exec = MoveExecutor(store: store)

        let outcome = await exec.apply(plan: plan(scheme: scheme, moves: [move]), mode: .subfolder(root: root))

        XCTAssertEqual(outcome.moved, 1)
        XCTAssertTrue(outcome.failed.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: src.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("문서/세금.pdf").path))
        let loaded = await store.load()
        XCTAssertEqual(loaded.count, 1)
    }

    func testUnapprovedAndUnclassifiedNotMoved() async {
        let root = tempDir(); defer { try? FileManager.default.removeItem(at: root) }
        let src1 = write("a.png", in: root)
        let src2 = write("b.txt", in: root)
        let scheme = [CleanupBucket(id: "img", name: "img", hint: "", relativePath: "img")]
        let m1 = CleanupMove(id: UUID(), source: src1, bucketId: "img", reason: "", confidence: 0.9, approved: false)
        let m2 = CleanupMove(id: UUID(), source: src2, bucketId: "", reason: "", confidence: 0.1, approved: true)
        let exec = MoveExecutor(store: MoveLogStore(directory: root))
        let outcome = await exec.apply(plan: plan(scheme: scheme, moves: [m1, m2]), mode: .subfolder(root: root))
        XCTAssertEqual(outcome.moved, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: src1.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: src2.path))
    }

    func testCollisionUniquifiesNoOverwrite() async {
        let root = tempDir(); defer { try? FileManager.default.removeItem(at: root) }
        // 목적지에 동명 파일을 미리 둔다
        let destDir = root.appendingPathComponent("문서")
        try? FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        try? "old".write(to: destDir.appendingPathComponent("x.pdf"), atomically: true, encoding: .utf8)
        let src = write("x.pdf", in: root)
        let scheme = [CleanupBucket(id: "문서", name: "문서", hint: "", relativePath: "문서")]
        let move = CleanupMove(id: UUID(), source: src, bucketId: "문서", reason: "", confidence: 1, approved: true)
        let exec = MoveExecutor(store: MoveLogStore(directory: root))
        let outcome = await exec.apply(plan: plan(scheme: scheme, moves: [move]), mode: .subfolder(root: root))
        XCTAssertEqual(outcome.moved, 1)
        // 기존 x.pdf는 그대로, 새 파일은 uniquify된 이름으로
        XCTAssertEqual(try? String(contentsOf: destDir.appendingPathComponent("x.pdf"), encoding: .utf8), "old")
        let count = (try? FileManager.default.contentsOfDirectory(atPath: destDir.path))?.count
        XCTAssertEqual(count, 2)
    }

    func testUndoRestoresFilesAndRemovesCreatedEmptyDir() async {
        let root = tempDir(); defer { try? FileManager.default.removeItem(at: root) }
        let src = write("세금.pdf", in: root)
        let scheme = [CleanupBucket(id: "문서", name: "문서", hint: "", relativePath: "문서")]
        let move = CleanupMove(id: UUID(), source: src, bucketId: "문서", reason: "", confidence: 1, approved: true)
        let exec = MoveExecutor(store: MoveLogStore(directory: root))
        let outcome = await exec.apply(plan: plan(scheme: scheme, moves: [move]), mode: .subfolder(root: root))

        let result = await exec.undo(outcome.batch)
        XCTAssertEqual(result.restored, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: src.path)) // 원위치 복귀
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("문서").path)) // 빈 생성폴더 제거
    }

    func testEscapingBucketIsFailedNotMoved() async {
        let root = tempDir(); defer { try? FileManager.default.removeItem(at: root) }
        let src = write("x.txt", in: root)
        let scheme = [CleanupBucket(id: "e", name: "e", hint: "", relativePath: "../../etc")]
        let move = CleanupMove(id: UUID(), source: src, bucketId: "e", reason: "", confidence: 1, approved: true)
        let exec = MoveExecutor(store: MoveLogStore(directory: root))
        let outcome = await exec.apply(plan: plan(scheme: scheme, moves: [move]), mode: .subfolder(root: root))
        XCTAssertEqual(outcome.moved, 0)
        XCTAssertEqual(outcome.failed, [src])
        XCTAssertTrue(FileManager.default.fileExists(atPath: src.path))
    }
}
```

- [ ] **Step 2: 실패 확인**

Run: `swift test --filter MoveExecutorTests`
Expected: 컴파일 실패("cannot find 'MoveExecutor'").

- [ ] **Step 3: 구현**

```swift
import Foundation

struct MoveOutcome {
    let batch: MoveBatch
    let moved: Int
    let failed: [URL]
}

/// 승인된 move만 실행하고 배치 로그를 남긴다. 삭제 없음.
/// undo는 역방향 이동 + 우리가 생성한 빈 폴더만 제거.
actor MoveExecutor {
    private let store: MoveLogStore

    init(store: MoveLogStore) {
        self.store = store
    }

    func apply(plan: CleanupPlan, mode: CleanupMode) async -> MoveOutcome {
        let fm = FileManager.default
        let root = mode.root
        var records: [MoveRecord] = []
        var createdDirs: [URL] = []
        var failed: [URL] = []

        let approved = plan.moves.filter { $0.approved && !$0.bucketId.isEmpty }
        for move in approved {
            guard let bucket = plan.scheme.first(where: { $0.id == move.bucketId }),
                  let destDir = CleanupPlanner.destinationDir(root: root, bucket: bucket) else {
                failed.append(move.source); continue
            }
            if !fm.fileExists(atPath: destDir.path) {
                do {
                    try fm.createDirectory(at: destDir, withIntermediateDirectories: true)
                    createdDirs.append(destDir)
                } catch { failed.append(move.source); continue }
            }
            let dest = destDir.appendingPathComponent(move.source.lastPathComponent).uniquified()
            do {
                try fm.moveItem(at: move.source, to: dest)
                records.append(MoveRecord(from: move.source, to: dest))
            } catch { failed.append(move.source) }
        }

        let batch = MoveBatch(id: UUID(), date: Date(), modeLabel: mode.label,
                              records: records, createdDirs: createdDirs)
        if !records.isEmpty { await store.append(batch) }
        return MoveOutcome(batch: batch, moved: records.count, failed: failed)
    }

    func undo(_ batch: MoveBatch) async -> (restored: Int, failed: Int) {
        let fm = FileManager.default
        var restored = 0, failed = 0

        for record in batch.records.reversed() {
            guard fm.fileExists(atPath: record.to.path) else { failed += 1; continue }
            // 원위치가 다시 점유됐으면 덮어쓰지 않고 uniquify.
            let target = record.from.uniquified()
            do { try fm.moveItem(at: record.to, to: target); restored += 1 }
            catch { failed += 1 }
        }

        // 우리가 만든 폴더 중 비어 있는 것만 제거(깊은 경로부터).
        for dir in batch.createdDirs.sorted(by: { $0.path.count > $1.path.count }) {
            if let contents = try? fm.contentsOfDirectory(atPath: dir.path), contents.isEmpty {
                try? fm.removeItem(at: dir)
            }
        }

        await store.remove(id: batch.id)
        return (restored, failed)
    }
}
```

- [ ] **Step 4: 통과 확인**

Run: `swift test --filter MoveExecutorTests`
Expected: PASS (5 tests).

- [ ] **Step 5: 커밋**

```bash
git add Sources/Services/MoveExecutor.swift Tests/CmdMDTests/MoveExecutorTests.swift
git commit -m "기능(정리): MoveExecutor(이동 실행+undo, 삭제 없음) 추가"
```

---

### Task 8: CleanupService (actor 오케스트레이션)

**Files:**
- Create: `Sources/Services/CleanupService.swift`
- Test: 없음(Claude 호출 의존 — 빌드 + Task 11 수동검증). 순수 로직은 Task 3·4에서 이미 커버.

**Interfaces:**
- Consumes: `ClaudeService.ask(prompt:context:) async throws -> String`(기존), `KordocService`(기존), `ContentExtractor.body(for:kordoc:) async -> String?`(기존), `FileScanner.scan`(Task 2), `CleanupPlanner.*`(Task 3·4), `CleanupScheme`/`CleanupAssignment`(Task 1).
- Produces:
  - `enum CleanupError: Error { case parseFailed }`
  - `actor CleanupService`
  - `init(claude: ClaudeService, kordoc: KordocService, confidenceThreshold: Double = 0.6)`
  - `func proposeScheme(metas: [FileMeta]) async throws -> CleanupScheme`
  - `func assign(scheme: CleanupScheme, metas: [FileMeta]) async throws -> [CleanupAssignment]`

- [ ] **Step 1: 구현 (테스트 없음 — Claude 의존)**

```swift
import Foundation

enum CleanupError: Error {
    case parseFailed
}

/// 스캔 → (subfolder)스킴 제안 → 배정 → 모호 파일 본문 재배정을 오케스트레이션한다.
/// Claude·kordoc 호출만 담당하고, 프롬프트·파싱·병합은 CleanupPlanner(순수)에 위임한다.
actor CleanupService {
    private let claude: ClaudeService
    private let kordoc: KordocService
    private let confidenceThreshold: Double

    init(claude: ClaudeService, kordoc: KordocService, confidenceThreshold: Double = 0.6) {
        self.claude = claude
        self.kordoc = kordoc
        self.confidenceThreshold = confidenceThreshold
    }

    /// subfolder 모드: Claude가 스킴 제안. (PARA 모드는 호출하지 않고 설정 폴더를 스킴으로 쓴다.)
    func proposeScheme(metas: [FileMeta]) async throws -> CleanupScheme {
        let prompt = CleanupPlanner.buildSchemePrompt(metadata: metas)
        let out = try await claude.ask(prompt: prompt, context: CleanupPlanner.metadataList(metas))
        guard let scheme = CleanupPlanner.parseScheme(out) else { throw CleanupError.parseFailed }
        return scheme
    }

    /// 1차 메타데이터 배정 → confidence 낮은 파일만 본문 발췌로 2차 재배정 후 병합.
    func assign(scheme: CleanupScheme, metas: [FileMeta]) async throws -> [CleanupAssignment] {
        let prompt = CleanupPlanner.buildAssignPrompt(scheme: scheme, metadata: metas)
        let out = try await claude.ask(prompt: prompt, context: CleanupPlanner.metadataList(metas))
        guard let base = CleanupPlanner.parseAssignments(out, scheme: scheme, metadata: metas) else {
            throw CleanupError.parseFailed
        }

        // 모호 파일만 본문 발췌해 재배정.
        let ambiguousURLs = Set(base.filter { $0.confidence < confidenceThreshold }.map { $0.fileURL })
        guard !ambiguousURLs.isEmpty else { return base }

        let ambiguousMetas = metas.filter { ambiguousURLs.contains($0.url) }
        var excerpts: [(name: String, excerpt: String)] = []
        for meta in ambiguousMetas {
            if let body = await ContentExtractor.body(for: meta.url, kordoc: kordoc), !body.isEmpty {
                excerpts.append((meta.name, body))
            }
        }
        guard !excerpts.isEmpty else { return base }

        let reassignPrompt = CleanupPlanner.buildAssignPrompt(scheme: scheme, metadata: ambiguousMetas)
        let context = CleanupPlanner.buildAmbiguousContext(excerpts)
        let out2 = try await claude.ask(prompt: reassignPrompt, context: context)
        guard let overrides = CleanupPlanner.parseAssignments(out2, scheme: scheme, metadata: ambiguousMetas) else {
            return base // 2차 실패 시 1차 결과 유지
        }
        return CleanupPlanner.merge(base, with: overrides)
    }
}
```

- [ ] **Step 2: 빌드 확인**

Run: `swift build`
Expected: 빌드 성공(경고 없이 컴파일).

- [ ] **Step 3: 커밋**

```bash
git add Sources/Services/CleanupService.swift
git commit -m "기능(정리): CleanupService(스킴 제안·배정·본문 재배정 오케스트레이션) 추가"
```

---

### Task 9: AppState 배선 (상태·서비스·메서드)

**Files:**
- Modify: `Sources/App/AppState.swift`
  - 서비스 추가: line 115-120 부근 서비스 묶음 옆
  - 상태 추가: line 95-97 부근(`showIndexSearch` 옆)
  - 메서드 추가: 파일 하단 적당한 위치
- Test: `Tests/CmdMDTests/AppCleanupStateTests.swift`

**Interfaces:**
- Consumes: `CleanupService`(Task 8), `MoveExecutor`/`MoveOutcome`(Task 7), `MoveLogStore`(Task 6), `FileScanner`(Task 2), `CleanupPlanner`(Task 3·4), `CleanupMode`/`CleanupPlan`/`CleanupScheme`/`MoveBatch`(Task 1). 기존 `kordocService`·`claudeService`·`vaults`·`settings.paraFolders`·`claudeErrorMessage`·`showToast`·`dataURL`.
- Produces (AppState에 추가, 모두 `@MainActor`):
  - `var showFolderCleanup: Bool`
  - `var cleanupMode: CleanupMode?`
  - `var cleanupScheme: CleanupScheme`
  - `var cleanupPlan: CleanupPlan?`
  - `var cleanupBusy: Bool`
  - `var cleanupBatches: [MoveBatch]`
  - `func startCleanup(folder: URL)` — subfolder 모드 진입(시트 열기)
  - `func startCleanupToPara(vault: Vault)` — PARA 모드 진입
  - `func runCleanupPlan() async` — 현재 scheme로 배정→plan 생성
  - `func applyCleanup() async` — 승인분 실행
  - `func undoCleanupBatch(_ batch: MoveBatch) async`
  - `func loadCleanupBatches() async`

- [ ] **Step 1: 실패하는 테스트 작성** (Claude 비의존 기본 상태만 검증)

```swift
import XCTest
@testable import CmdMD

@MainActor
final class AppCleanupStateTests: XCTestCase {
    func testCleanupDefaults() {
        let state = AppState()
        XCTAssertFalse(state.showFolderCleanup)
        XCTAssertNil(state.cleanupPlan)
        XCTAssertTrue(state.cleanupScheme.isEmpty)
        XCTAssertFalse(state.cleanupBusy)
    }

    func testStartCleanupSetsSubfolderModeAndShows() {
        let state = AppState()
        let folder = URL(fileURLWithPath: "/Users/x/Downloads")
        state.startCleanup(folder: folder)
        XCTAssertTrue(state.showFolderCleanup)
        if case .subfolder(let root)? = state.cleanupMode {
            XCTAssertEqual(root, folder)
        } else { XCTFail("subfolder 모드여야 함") }
    }
}
```

- [ ] **Step 2: 실패 확인**

Run: `swift test --filter AppCleanupStateTests`
Expected: 컴파일 실패("value of type 'AppState' has no member 'showFolderCleanup'").

- [ ] **Step 3: 서비스·상태 프로퍼티 추가**

`Sources/App/AppState.swift`의 서비스 묶음(line 117-120 `kordocFillService` 다음 줄)에 추가:

```swift
    private let moveLogStore: MoveLogStore
    private let cleanupService: CleanupService
    private let moveExecutor: MoveExecutor
```

`@Published`(또는 기존 `@Observable` 관례에 맞춰) 상태 묶음(`showIndexSearch` 부근)에 추가:

```swift
    var showFolderCleanup: Bool = false
    var cleanupMode: CleanupMode?
    var cleanupScheme: CleanupScheme = []
    var cleanupPlan: CleanupPlan?
    var cleanupBusy: Bool = false
    var cleanupBatches: [MoveBatch] = []
```

> 주의: AppState가 `@Observable`인지 `ObservableObject(@Published)`인지 기존 코드 관례를 확인해 그대로 따른다(`showIndexSearch` 선언 형태와 동일하게).

`init()`에서 `dataURL` 확정 직후(line 561 `dataURL = appDir` 부근) 서비스 초기화:

```swift
        moveLogStore = MoveLogStore(directory: appDir)
        cleanupService = CleanupService(claude: claudeService, kordoc: kordocService)
        moveExecutor = MoveExecutor(store: moveLogStore)
```

> 주의: `claudeService`·`kordocService`는 `let` 즉시 초기화 프로퍼티라 `init` 본문에서 참조 가능. 초기화 순서상 위 세 줄은 `claudeService`/`kordocService` 선언 이후 실행되는 `init` 본문에 둔다.

- [ ] **Step 4: 메서드 추가**

AppState 하단(예: `showToast` 부근)에 추가:

```swift
    // MARK: - 폴더 정리 (Phase 8)

    /// subfolder 모드 진입: 폴더를 스캔하고 시트를 연다.
    func startCleanup(folder: URL) {
        cleanupMode = .subfolder(root: folder)
        cleanupScheme = []
        cleanupPlan = nil
        showFolderCleanup = true
    }

    /// PARA 모드 진입: 설정된 PARA 폴더를 스킴으로 쓴다.
    func startCleanupToPara(vault: Vault) {
        cleanupMode = .para(vault: vault)
        cleanupScheme = settings.paraFolders.map { CleanupBucket.from(para: $0) }
        cleanupPlan = nil
        showFolderCleanup = true
    }

    /// 현재 모드·스킴으로 배정을 받아 미리보기 plan을 만든다.
    /// subfolder 모드에서 scheme이 비어 있으면 Claude로 스킴부터 제안한다.
    func runCleanupPlan() async {
        guard let mode = cleanupMode else { return }
        cleanupBusy = true
        defer { cleanupBusy = false }

        let metas = FileScanner.scan(mode.root)
        guard !metas.isEmpty else { showToast("정리할 파일이 없습니다"); return }

        do {
            if cleanupScheme.isEmpty {
                if case .subfolder = mode {
                    cleanupScheme = try await cleanupService.proposeScheme(metas: metas)
                } else {
                    showToast("PARA 폴더가 설정돼 있지 않습니다"); return
                }
            }
            let assignments = try await cleanupService.assign(scheme: cleanupScheme, metas: metas)
            cleanupPlan = CleanupPlan(scheme: cleanupScheme, moves: CleanupPlanner.buildMoves(from: assignments))
        } catch let error as ClaudeError {
            claudeErrorMessage = describeClaudeError(error)
        } catch {
            showToast("Claude 응답을 해석하지 못했습니다")
        }
    }

    /// 승인된 move만 실행하고 로그를 갱신한다.
    func applyCleanup() async {
        guard let mode = cleanupMode, let plan = cleanupPlan else { return }
        cleanupBusy = true
        defer { cleanupBusy = false }
        let outcome = await moveExecutor.apply(plan: plan, mode: mode)
        await loadCleanupBatches()
        cleanupPlan = nil
        let failedNote = outcome.failed.isEmpty ? "" : ", 실패 \(outcome.failed.count)"
        showToast("정리 완료: \(outcome.moved)개 이동\(failedNote)")
    }

    func undoCleanupBatch(_ batch: MoveBatch) async {
        let result = await moveExecutor.undo(batch)
        await loadCleanupBatches()
        showToast("되돌리기: \(result.restored)개 복귀")
    }

    func loadCleanupBatches() async {
        cleanupBatches = await moveLogStore.load().reversed()
    }
```

> 주의: `describeClaudeError(_:)`가 기존에 없으면, Phase 4의 `claudeErrorMessage` 설정 코드(라우팅/패널에서 ClaudeError를 메시지로 바꾸던 분기)를 찾아 같은 매핑을 재사용한다. 동일 매핑이 인라인으로 돼 있으면 이 파일에 작은 private 헬퍼로 추출해 재사용한다.

- [ ] **Step 5: 통과 확인**

Run: `swift test --filter AppCleanupStateTests`
Expected: PASS (2 tests).

- [ ] **Step 6: 전체 빌드 확인**

Run: `swift build`
Expected: 성공.

- [ ] **Step 7: 커밋**

```bash
git add Sources/App/AppState.swift Tests/CmdMDTests/AppCleanupStateTests.swift
git commit -m "기능(정리): AppState 폴더정리 배선(상태·서비스·스캔·실행·undo)"
```

---

### Task 10: FolderCleanupView (UI) + 진입점

**Files:**
- Create: `Sources/Views/FolderCleanupView.swift`
- Modify: `Sources/Views/ContentView.swift`(`.sheet` 추가, line 99 `showIndexSearch` 시트 옆)
- Modify: `Sources/Views/CommandPaletteView.swift`(커맨드 추가, line 261 "내용 검색" 커맨드 옆)
- Test: 없음(SwiftUI UI — Task 11 수동검증). 로직은 Task 1-9에서 커버.

**Interfaces:**
- Consumes: AppState의 `showFolderCleanup`·`cleanupMode`·`cleanupScheme`·`cleanupPlan`·`cleanupBusy`·`cleanupBatches`·`runCleanupPlan()`·`applyCleanup()`·`undoCleanupBatch(_:)`·`loadCleanupBatches()`·`startCleanup(folder:)`·`startCleanupToPara(vault:)`(Task 9); `vaults`(기존).

- [ ] **Step 1: 뷰 구현**

`Sources/Views/FolderCleanupView.swift` 생성. IndexSearchView의 시트 구조·`@EnvironmentObject`/`@Environment` 관례를 그대로 따른다(기존 뷰에서 AppState 주입 방식 확인). 핵심 구성:

```swift
import SwiftUI
import UniformTypeIdentifiers

struct FolderCleanupView: View {
    @EnvironmentObject var state: AppState   // 기존 뷰 관례에 맞춤(@Environment(AppState.self)면 그 형태로)
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            if state.cleanupBusy {
                ProgressView("Claude가 분류 중…").frame(maxWidth: .infinity)
            }
            if !state.cleanupScheme.isEmpty {
                schemeEditor
            }
            if let plan = state.cleanupPlan {
                planTable(plan)
            } else {
                planActions
            }
            Divider()
            historySection
        }
        .padding(16)
        .frame(minWidth: 640, minHeight: 520)
        .task { await state.loadCleanupBatches() }
    }

    private var header: some View {
        HStack {
            Text(state.cleanupMode?.label ?? "폴더 정리").font(.headline)
            Spacer()
            Button("폴더 선택…") { pickFolder() }
            Button("닫기") { dismiss() }
        }
    }

    // 스킴 편집: 버킷 이름/힌트 수정·삭제·추가. subfolder 모드에서 의미 있음.
    private var schemeEditor: some View {
        VStack(alignment: .leading) {
            Text("정리 스킴 (편집 가능)").font(.subheadline).bold()
            ForEach(state.cleanupScheme.indices, id: \.self) { i in
                HStack {
                    TextField("폴더명", text: Binding(
                        get: { state.cleanupScheme[i].name },
                        set: { newValue in
                            let clean = CleanupPlanner.sanitizeBucketName(newValue)
                            state.cleanupScheme[i].name = clean
                            state.cleanupScheme[i].id = clean
                            state.cleanupScheme[i].relativePath = clean
                        }))
                    TextField("설명", text: Binding(
                        get: { state.cleanupScheme[i].hint },
                        set: { state.cleanupScheme[i].hint = $0 }))
                    Button(role: .destructive) { state.cleanupScheme.remove(at: i) } label: { Image(systemName: "trash") }
                }
            }
            Button("버킷 추가") {
                state.cleanupScheme.append(CleanupBucket(id: "새폴더", name: "새폴더", hint: "", relativePath: "새폴더"))
            }
        }
    }

    private var planActions: some View {
        HStack {
            Button("정리 계획 만들기") { Task { await state.runCleanupPlan() } }
                .disabled(state.cleanupMode == nil || state.cleanupBusy)
            if let msg = state.claudeErrorMessage { Text(msg).foregroundColor(.red).font(.caption) }
        }
    }

    // 미리보기 표: source → bucket, 이유, confidence, 승인 체크박스
    private func planTable(_ plan: CleanupPlan) -> some View {
        VStack(alignment: .leading) {
            Text("미리보기 (체크된 것만 이동)").font(.subheadline).bold()
            ScrollView {
                ForEach(plan.moves.indices, id: \.self) { i in
                    let move = plan.moves[i]
                    HStack {
                        Toggle("", isOn: Binding(
                            get: { state.cleanupPlan?.moves[i].approved ?? false },
                            set: { state.cleanupPlan?.moves[i].approved = $0 }))
                            .labelsHidden()
                            .disabled(move.bucketId.isEmpty)
                        VStack(alignment: .leading) {
                            Text(move.source.lastPathComponent)
                            Text(move.bucketId.isEmpty ? "미분류" : "→ \(move.bucketId) · \(move.reason)")
                                .font(.caption).foregroundColor(.secondary)
                        }
                        Spacer()
                        Text(String(format: "%.0f%%", move.confidence * 100))
                            .font(.caption)
                            .foregroundColor(move.confidence < 0.6 ? .orange : .secondary)
                    }
                    .padding(.vertical, 2)
                }
            }
            HStack {
                Button("적용") { Task { await state.applyCleanup() } }.keyboardShortcut(.defaultAction)
                Button("취소") { state.cleanupPlan = nil }
            }
        }
    }

    private var historySection: some View {
        VStack(alignment: .leading) {
            Text("정리 기록").font(.subheadline).bold()
            if state.cleanupBatches.isEmpty {
                Text("기록 없음").font(.caption).foregroundColor(.secondary)
            } else {
                ForEach(state.cleanupBatches) { batch in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(batch.modeLabel).font(.caption)
                            Text("\(batch.records.count)개 이동 · \(batch.date.formatted())").font(.caption2).foregroundColor(.secondary)
                        }
                        Spacer()
                        Button("되돌리기") { Task { await state.undoCleanupBatch(batch) } }
                    }
                }
            }
        }
    }

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            state.startCleanup(folder: url)
        }
    }
}
```

> 주의: AppState 주입이 `@EnvironmentObject`인지 `@Environment(AppState.self)`인지 IndexSearchView를 열어 확인하고 동일하게 맞춘다. `claudeErrorMessage`가 옵셔널 String인지도 확인(아니면 표시 분기 조정).

- [ ] **Step 2: ContentView에 시트 추가**

`Sources/Views/ContentView.swift` line 99 `.sheet(isPresented: $state.showIndexSearch)` 블록 다음에:

```swift
        .sheet(isPresented: $state.showFolderCleanup) {
            FolderCleanupView()
        }
```

- [ ] **Step 3: 커맨드 팔레트 진입점 추가**

`Sources/Views/CommandPaletteView.swift`의 "내용 검색 (인덱스)" `Command(...)` 블록 다음에:

```swift
            Command(
                title: "폴더 정리 (배치)",
                subtitle: "Claude 제안으로 폴더를 종류·주제별로 정리",
                icon: "folder.badge.gearshape",
                shortcut: nil,
                keywords: ["정리", "폴더", "cleanup", "organize", "batch", "para", "이동"]
            ) {
                if let folder = appState.lastUsedFolderForCleanup() {
                    appState.startCleanup(folder: folder)
                } else {
                    appState.showFolderCleanup = true
                }
            },
```

> 주의: `lastUsedFolderForCleanup()`이 없으면 단순히 `appState.showFolderCleanup = true`만 호출하고, 폴더 선택은 시트 내 "폴더 선택…" 버튼으로 하게 둔다(위 if/else를 한 줄로 단순화). 별도 메서드를 새로 만들 필요 없음 — YAGNI.

- [ ] **Step 4: 빌드 확인**

Run: `swift build`
Expected: 성공.

- [ ] **Step 5: 커밋**

```bash
git add Sources/Views/FolderCleanupView.swift Sources/Views/ContentView.swift Sources/Views/CommandPaletteView.swift
git commit -m "기능(정리): FolderCleanupView 시트·커맨드팔레트 진입점 추가"
```

---

### Task 11: Phase 게이트 — 전체 테스트·수동검증·상태 기록

**Files:**
- Modify: `CLAUDE.md`(현재 상태에 Phase 8 완료 한 줄 추가, "다음 액션" 갱신)
- Modify: 옵시디언 데일리 로그(세션 종료 시 — 별도 규칙)

- [ ] **Step 1: 전체 단위테스트 실행**

Run: `swift test`
Expected: 기존 ~175개 + 신규(CleanupModels 3, FileScanner 2, CleanupPlannerScheme 4, CleanupPlannerAssign 7, CleanupPathSafety 3, MoveLogStore 3, MoveExecutor 5, AppCleanupState 2 = 29개) 전부 통과. 깨진 기존 테스트 없음.

> Xcode가 없으면(`swift test` 불가) `swift build` 성공 + 아래 수동검증으로 대체.

- [ ] **Step 2: 수동검증 (실제 claude 필요)**

1. 앱 실행 → 커맨드 팔레트 → "폴더 정리 (배치)" → 테스트용 폴더(잡다한 파일 5~10개 복사본) 선택.
2. "정리 계획 만들기" → Claude 스킴 제안 확인 → 스킴 이름 1개 편집 → 다시 계획 생성.
3. 미리보기 표에서 1개 체크 해제 → "적용" → 해당 파일은 그대로, 나머지만 이동 확인.
4. "정리 기록"에서 방금 배치 "되돌리기" → 파일 원위치 복귀·빈 폴더 제거 확인.
5. claude 미로그인 상태로 한 번 → 에러 메시지 표시(크래시 없음) 확인.

검증은 **복사본 폴더**에서만. 원본 데이터로 하지 않는다.

- [ ] **Step 3: CLAUDE.md 상태 갱신**

`## 현재 상태` 끝에 추가(기존 줄 형식에 맞춤):

```markdown
- Phase 8 완료(YYYY-MM-DD). 폴더 정리(배치) — 두 모드(subfolder/PARA) 제네릭 이동 목록. `CleanupModels`·`FileScanner`(top-level 스캔)·`CleanupPlanner`(스킴/배정 프롬프트·strict JSON 파싱·허용 id 검증·경로 탈출 방지·병합)·`CleanupService`(actor: 스킴 제안→배정→모호 파일 본문 재배정)·`MoveExecutor`(actor: 승인분만 이동·충돌 uniquify·삭제 없음·undo=역이동+빈 생성폴더 제거)·`MoveLogStore`(배치 로그 영속)·`FolderCleanupView`(시트: 폴더선택·스킴편집·미리보기 승인·정리기록 되돌리기, 커맨드팔레트 진입). 제안→확인→실행, 자동 OFF. 약 204개 테스트(순수 로직 단위; Claude·UI 수동).
```

그리고 "다음 액션"을 Phase 9(시맨틱+RAG)로 갱신.

- [ ] **Step 4: 커밋**

```bash
git add CLAUDE.md
git commit -m "문서: Phase 8 폴더 정리(배치) 완료 상태 기록"
```

- [ ] **Step 5: 브랜치 마무리**

`superpowers:finishing-a-development-branch` 스킬로 머지/PR/푸시 옵션을 정리한다(기존 워크플로: main 머지·origin 푸시·데일리 로그).

---

## Self-Review

**Spec coverage (스펙 §1-10 ↔ 태스크):**
- §2 두 모드 → Task 1(`CleanupMode`), Task 9(`startCleanup`/`startCleanupToPara`) ✓
- §3 C안 스킴→배정 → Task 3(스킴), Task 4(배정), Task 8(오케스트레이션), Task 10(스킴 편집 UI) ✓
- §4 컴포넌트 전부 → Task 1-10 각각 매핑 ✓
- §5 데이터 흐름 → Task 8·9 ✓
- §6 안전(삭제없음·자동OFF·충돌uniquify·경로검증) → Task 5(경로), Task 7(이동·undo·충돌), Task 9(자동토글 없음) ✓
- §7 에러 처리 → Task 9(`runCleanupPlan` catch), Task 8(2차 실패 시 1차 유지), Task 10(에러 표시) ✓
- §8 테스트 → 각 태스크 TDD + Task 11 ✓
- §9 Phase 게이트 → Task 11 ✓
- §10 범위밖(재귀·리네임·자동) → 미포함 확인 ✓

**Placeholder scan:** 모든 코드 step에 실제 코드 포함. "주의" 주석은 기존 코드 관례 확인 지점(placeholder 아님). ✓

**Type consistency:** `CleanupBucket.id/name/relativePath`, `CleanupMove.approved`, `MoveBatch.records/createdDirs`, `CleanupService.proposeScheme/assign`, `MoveExecutor.apply/undo`, `CleanupPlanner.destinationDir/buildMoves/merge/parseAssignments` — 태스크 간 시그니처 일치 확인. ✓
