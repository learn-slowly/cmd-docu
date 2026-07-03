# F1b 다중 선택 + 배치 파일 작업 구현 계획

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 라이브러리·트리에 Finder식 다중 선택(클릭=선택·더블클릭=열기)을 넣고, 배치 휴지통·이동·복사(⌘C/⌘V/⌥⌘V, Finder 페이스트보드 상호운용)와 배치 단위 되돌리기를 만든다.

**Architecture:** 순수 계층(FileOperations.move/copy, 선택 리졸버, 페이스트보드 헬퍼) → 로그 계층(FileOpsLogStore에 옵셔널 batchId·appendBatch·undoBatch) → AppState 배선(fileSelection 상태, performBatch 3종 — 건별 정합 처리 후 completeFileOperation 1회) → UI(라이브러리 클릭 시맨틱·트리 ⌘토글·선택 인지 컨텍스트 메뉴·기록 그룹). 키는 로컬 NSEvent 모니터 1개 + 엄격 가드.

**Tech Stack:** Swift 5.9 / SwiftUI / XCTest. 신규 패키지 의존성 0 (NSPasteboard·NSEvent·NSOpenPanel 모두 AppKit).

**스펙:** `docs/superpowers/specs/2026-07-03-f1b-multiselect-batch-design.md` (구현 전 필독)

## Global Constraints

- macOS 14+, SPM, **비샌드박스 유지**, 신규 패키지 의존성 0.
- **영구 삭제 금지** — 휴지통 이동만. **덮어쓰기 금지** — 충돌 시 `uniquified()`(" (1)" 접미, `AppState.swift:2809`).
- **⌘C/⌘V/⌘A/⌘⌫를 SwiftUI 메뉴 `.keyboardShortcut`으로 걸지 않는다** — 앱 전역이라 에디터(NSTextView) 시스템 복사/붙여넣기를 강탈한다. 로컬 NSEvent 모니터 + firstResponder 가드만 사용.
- 기존 단건 API(`performRename`/`performTrash`/`trashWithConfirmation`) 시그니처 불변. `undoFileOp`은 내부 확장만.
- 선택 상태 키는 **`Set<URL>`** — `FileTreeItem.id`는 트리 재빌드마다 새 UUID라 금지.
- 배치 처리 중 `completeFileOperation()`은 **배치 끝 1회만**(건별 호출 금지 — 트리 재스캔 N회).
- uniquified()는 존재검사-후-사용이라 배치 항목은 **순차 처리**(병렬 금지).
- 테스트: XCTest, `Tests/CmdMDTests/`. AppState 테스트는 `TempDataDirectory.make()` 주입(`AppState(dataDirectory:)`). 실행: `swift test --filter <클래스명>` (정식 Xcode 필요 — CLT는 build만).
- 코드 주석·커밋 메시지 한국어. '박다/박는다' 계열 어휘 금지.

---

### Task 1: FileOperations.move / copy (+ .invalidDestination)

**Files:**
- Modify: `Sources/Services/FileOperations.swift` (79줄 — rename/createFolder/trash 기존 3함수 불변)
- Test: `Tests/CmdMDTests/FileOperationsTests.swift` (기존 파일에 추가)

**Interfaces:**
- Consumes: `URL.uniquified()` (`Sources/App/AppState.swift:2809`), 기존 `FileOperationError`.
- Produces:
  - `FileOperationError.invalidDestination(String)` 케이스 추가.
  - `static func move(at url: URL, to destinationDir: URL) throws -> URL` — 결과 URL(uniquify 반영) 반환.
  - `static func copy(at url: URL, to destinationDir: URL) throws -> URL` — 사본 URL 반환.

- [ ] **Step 1: 실패하는 테스트 작성** — `FileOperationsTests.swift`에 추가:

```swift
    // MARK: move (F1b)

    func testMoveIntoFolder() throws {
        let src = try makeFile("a.md")
        let dest = try makeFolder("대상")
        let moved = try FileOperations.move(at: src, to: dest)
        XCTAssertEqual(moved, dest.appendingPathComponent("a.md"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: src.path))
    }

    func testMoveConflictUniquifies() throws {
        let src = try makeFile("a.md")
        let dest = try makeFolder("대상")
        try Data("점유".utf8).write(to: dest.appendingPathComponent("a.md"))
        let moved = try FileOperations.move(at: src, to: dest)
        XCTAssertEqual(moved.lastPathComponent, "a (1).md")
    }

    func testMoveToSameParentThrows() throws {
        // 제자리 이동을 허용하면 uniquify가 "a (1).md" 복제 개명으로 둔갑 — 반드시 에러.
        let src = try makeFile("a.md")
        XCTAssertThrowsError(try FileOperations.move(at: src, to: src.deletingLastPathComponent())) { error in
            guard case FileOperationError.invalidDestination = error else {
                return XCTFail("invalidDestination이어야 함: \(error)")
            }
        }
    }

    func testMoveFolderIntoItselfOrDescendantThrows() throws {
        let folder = try makeFolder("상위")
        let child = try makeFolder("상위/하위")
        XCTAssertThrowsError(try FileOperations.move(at: folder, to: folder))
        XCTAssertThrowsError(try FileOperations.move(at: folder, to: child))
        // '/' 경계 — 형제 "상위2"는 하위가 아니다.
        let sibling = try makeFolder("상위2")
        XCTAssertNoThrow(try FileOperations.move(at: folder, to: sibling))
    }

    func testMoveMissingSourceThrows() throws {
        let dest = try makeFolder("대상")
        let ghost = work.appendingPathComponent("없음.md")
        XCTAssertThrowsError(try FileOperations.move(at: ghost, to: dest)) { error in
            XCTAssertEqual(error as? FileOperationError, .sourceMissing)
        }
    }

    // MARK: copy (F1b)

    func testCopyIntoFolder() throws {
        let src = try makeFile("a.md")
        let dest = try makeFolder("대상")
        let copied = try FileOperations.copy(at: src, to: dest)
        XCTAssertEqual(copied, dest.appendingPathComponent("a.md"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: src.path), "원본 불변")
        XCTAssertTrue(FileManager.default.fileExists(atPath: copied.path))
    }

    func testCopyToSameParentMakesUniquifiedDuplicate() throws {
        // 같은 폴더 복사 = 사본 시맨틱("a (1).md") — move와 달리 허용.
        let src = try makeFile("a.md")
        let copied = try FileOperations.copy(at: src, to: src.deletingLastPathComponent())
        XCTAssertEqual(copied.lastPathComponent, "a (1).md")
    }

    func testCopyFolderIntoOwnDescendantThrows() throws {
        let folder = try makeFolder("상위")
        let child = try makeFolder("상위/하위")
        XCTAssertThrowsError(try FileOperations.copy(at: folder, to: child))
    }
```

기존 파일에 `makeFile`/`makeFolder` 헬퍼가 없으면(이름 확인 후) 다음을 추가:

```swift
    private func makeFolder(_ relative: String) throws -> URL {
        let url = work.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
```

(기존 FileOperationsTests의 셋업 프로퍼티 이름이 `work`가 아니면 그 파일 관례를 따른다.)

- [ ] **Step 2: 실패 확인**

Run: `swift test --filter FileOperationsTests`
Expected: FAIL — "type 'FileOperations' has no member 'move'" 컴파일 에러.

- [ ] **Step 3: 구현** — `FileOperations.swift`:

`FileOperationError`에 케이스 추가(switch에 메시지 포함):

```swift
    case invalidDestination(String)
    // errorDescription switch에:
    case .invalidDestination(let reason): return "이동할 수 없는 위치입니다: \(reason)"
```

함수 2개 추가(파일 끝, trash 아래):

```swift
    /// 다른 폴더로 이동. 충돌 시 uniquify(덮어쓰기 금지). 결과 URL 반환.
    /// 같은 부모로의 이동은 에러 — 허용하면 uniquify가 제자리 이동을 "이름 (1)" 복제 개명으로 만든다.
    static func move(at url: URL, to destinationDir: URL) throws -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { throw FileOperationError.sourceMissing }
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: destinationDir.path, isDirectory: &isDir), isDir.boolValue else {
            throw FileOperationError.invalidDestination("대상 폴더가 없습니다.")
        }
        let srcStd = url.standardizedFileURL.path
        let destStd = destinationDir.standardizedFileURL.path
        guard url.standardizedFileURL.deletingLastPathComponent().path != destStd else {
            throw FileOperationError.invalidDestination("이미 이 폴더에 있습니다.")
        }
        try Self.guardNotIntoSelf(sourcePath: srcStd, destinationPath: destStd, at: url)
        let target = destinationDir.appendingPathComponent(url.lastPathComponent).uniquified()
        do {
            try fm.moveItem(at: url, to: target)
        } catch {
            throw FileOperationError.failed(error.localizedDescription)
        }
        return target
    }

    /// 다른(또는 같은) 폴더로 복사. 같은 폴더면 uniquify가 사본("이름 (1)")을 만든다. 원본 불변.
    static func copy(at url: URL, to destinationDir: URL) throws -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { throw FileOperationError.sourceMissing }
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: destinationDir.path, isDirectory: &isDir), isDir.boolValue else {
            throw FileOperationError.invalidDestination("대상 폴더가 없습니다.")
        }
        try Self.guardNotIntoSelf(sourcePath: url.standardizedFileURL.path,
                                  destinationPath: destinationDir.standardizedFileURL.path, at: url)
        let target = destinationDir.appendingPathComponent(url.lastPathComponent).uniquified()
        do {
            try fm.copyItem(at: url, to: target)
        } catch {
            throw FileOperationError.failed(error.localizedDescription)
        }
        return target
    }

    /// 폴더를 자기 자신/자기 하위로 넣는 요청 차단 — '/' 경계 prefix(형제 폴더 오감지 방지).
    private static func guardNotIntoSelf(sourcePath: String, destinationPath: String, at url: URL) throws {
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        guard isDirectory else { return }
        if destinationPath == sourcePath || destinationPath.hasPrefix(sourcePath + "/") {
            throw FileOperationError.invalidDestination("폴더를 자기 자신 안으로 넣을 수 없습니다.")
        }
    }
```

파일 상단 doc 주석의 "단일 항목 파일 작업(F1a)"을 "단일 항목 파일 작업(F1a·F1b)"로 갱신.

- [ ] **Step 4: 통과 확인**

Run: `swift test --filter FileOperationsTests`
Expected: PASS (기존 케이스 포함 전부).

- [ ] **Step 5: 커밋**

```bash
git add Sources/Services/FileOperations.swift Tests/CmdMDTests/FileOperationsTests.swift
git commit -m "기능(F1b): FileOperations.move/copy — uniquify 충돌 회피·제자리 이동 차단·자기 하위 이동 금지"
```

---

### Task 2: FileOpsLogStore — batchId·appendBatch·undoBatch·copy undo

**Files:**
- Modify: `Sources/Services/FileOpsLogStore.swift` (69줄 전체 파악 후 수정)
- Test: `Tests/CmdMDTests/FileOpsLogStoreTests.swift` (기존 파일에 추가)

**Interfaces:**
- Consumes: Task 1의 `FileOperations.trash(at:) throws -> URL` (copy undo용 — F1a 기존 함수).
- Produces:
  - `FileOpKind`에 `.move`·`.copy` 추가.
  - `FileOpEntry.batchId: UUID?` (init 파라미터 `batchId: UUID? = nil`, `date` 앞 위치).
  - `func appendBatch(_ newEntries: [FileOpEntry])`
  - `func undoBatch(batchId: UUID) -> (succeeded: [FileOpEntry], failed: [FileOpEntry])` — 역순 처리. (스펙 §4.2는 Int 카운트라 했지만 AppState가 성공 엔트리로 탭 재조준을 해야 하므로 엔트리 배열 반환 — 의도된 강화.)
  - 기존 `undo(_:)`가 `.copy`면 역이동 대신 `FileOperations.trash(resultURL)`.

- [ ] **Step 1: 실패하는 테스트 작성** — `FileOpsLogStoreTests.swift`에 추가(기존 셋업 관례 확인 후 그 임시 디렉터리 프로퍼티 사용):

```swift
    // MARK: F1b — batchId·배치

    func testDecodesLegacyEntriesWithoutBatchId() async throws {
        // F1a 시절 로그(batchId 필드 없음)가 그대로 읽혀야 한다 — 옵셔널 하위호환.
        let legacy = """
        [{"id":"11111111-1111-1111-1111-111111111111","kind":"rename",
          "originalURL":"file:///tmp/a.md","resultURL":"file:///tmp/b.md",
          "date":712345678.0}]
        """.replacingOccurrences(of: "\n", with: "")
        try Data(legacy.utf8).write(to: dir.appendingPathComponent("fileops-log.json"))
        let store = FileOpsLogStore(directory: dir)
        let loaded = await store.load()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertNil(loaded[0].batchId)
    }

    func testAppendBatchWritesAllEntries() async throws {
        let store = FileOpsLogStore(directory: dir)
        let batchId = UUID()
        let a = FileOpEntry(kind: .move, originalURL: URL(fileURLWithPath: "/tmp/a"),
                            resultURL: URL(fileURLWithPath: "/tmp/x/a"), batchId: batchId)
        let b = FileOpEntry(kind: .move, originalURL: URL(fileURLWithPath: "/tmp/b"),
                            resultURL: URL(fileURLWithPath: "/tmp/x/b"), batchId: batchId)
        await store.appendBatch([a, b])
        let loaded = await store.load()
        XCTAssertEqual(loaded.map(\.id), [a.id, b.id])
        XCTAssertEqual(loaded.compactMap(\.batchId), [batchId, batchId])
    }

    func testUndoBatchReversesInOrderAndRemovesSucceeded() async throws {
        // move 2건: b를 a 안으로, 그 다음 a를 dest로 — 역순(a 먼저 복원)이 아니면 b 복원이 실패한다.
        let fm = FileManager.default
        let root = dir.appendingPathComponent("undo-root")
        let folderA = root.appendingPathComponent("a")
        let dest = root.appendingPathComponent("dest")
        try fm.createDirectory(at: folderA, withIntermediateDirectories: true)
        try fm.createDirectory(at: dest, withIntermediateDirectories: true)
        let fileB = root.appendingPathComponent("b.md")
        try Data("b".utf8).write(to: fileB)

        // 실행: b.md → a/b.md, 그 다음 a → dest/a (b는 dest/a/b.md가 됨)
        let movedB = try FileOperations.move(at: fileB, to: folderA)
        let movedA = try FileOperations.move(at: folderA, to: dest)

        let store = FileOpsLogStore(directory: dir)
        let batchId = UUID()
        let entryB = FileOpEntry(kind: .move, originalURL: fileB,
                                 resultURL: movedA.appendingPathComponent("b.md"), batchId: batchId)
        let entryA = FileOpEntry(kind: .move, originalURL: folderA, resultURL: movedA, batchId: batchId)
        await store.appendBatch([entryB, entryA])
        _ = movedB // 기록 시점 경로는 entryB에 반영됨

        let result = await store.undoBatch(batchId: batchId)
        XCTAssertEqual(result.succeeded.count, 2)
        XCTAssertTrue(result.failed.isEmpty)
        XCTAssertTrue(fm.fileExists(atPath: fileB.path), "b.md가 원위치로")
        XCTAssertTrue(fm.fileExists(atPath: folderA.path), "a가 원위치로")
        let remaining = await store.load()
        XCTAssertTrue(remaining.isEmpty, "성공분은 로그에서 제거")
    }

    func testUndoBatchKeepsFailedEntries() async throws {
        let fm = FileManager.default
        let root = dir.appendingPathComponent("fail-root")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let store = FileOpsLogStore(directory: dir)
        let batchId = UUID()
        // resultURL이 실재하지 않는 유령 엔트리 — undo 실패해야 함.
        let ghost = FileOpEntry(kind: .move, originalURL: root.appendingPathComponent("g.md"),
                                resultURL: root.appendingPathComponent("없음.md"), batchId: batchId)
        await store.appendBatch([ghost])
        let result = await store.undoBatch(batchId: batchId)
        XCTAssertEqual(result.failed.map(\.id), [ghost.id])
        let remaining = await store.load()
        XCTAssertEqual(remaining.map(\.id), [ghost.id], "실패분은 보존")
    }

    func testUndoCopyTrashesTheCopy() async throws {
        // copy 되돌리기 = 사본을 휴지통으로(영구 삭제 없음 정책) — 원본은 불변.
        let fm = FileManager.default
        let root = dir.appendingPathComponent("copy-root")
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let original = root.appendingPathComponent("원본.md")
        try Data("원본".utf8).write(to: original)
        let copyDest = root.appendingPathComponent("사본지")
        try fm.createDirectory(at: copyDest, withIntermediateDirectories: true)
        let copied = try FileOperations.copy(at: original, to: copyDest)

        let store = FileOpsLogStore(directory: dir)
        let entry = FileOpEntry(kind: .copy, originalURL: original, resultURL: copied)
        await store.append(entry)
        let ok = await store.undo(entry)
        XCTAssertTrue(ok)
        XCTAssertFalse(fm.fileExists(atPath: copied.path), "사본은 휴지통으로")
        XCTAssertTrue(fm.fileExists(atPath: original.path), "원본 불변")
        let remaining = await store.load()
        XCTAssertTrue(remaining.isEmpty)
    }
```

주의: 기존 FileOpsLogStoreTests의 임시 디렉터리 프로퍼티 이름(`dir` 가정)을 실제 파일에서 확인해 맞춘다. `load()` 등 actor 호출은 `await`.

- [ ] **Step 2: 실패 확인**

Run: `swift test --filter FileOpsLogStoreTests`
Expected: FAIL — "extra argument 'batchId'" / "no member 'appendBatch'" 컴파일 에러.

- [ ] **Step 3: 구현** — `FileOpsLogStore.swift` 전체 교체 수준 수정:

```swift
import Foundation

/// 파일 작업 종류(작업 로그용).
/// 주의: 새 케이스가 든 로그를 구버전 앱이 읽으면 배열 단위 디코드가 실패해
/// 기록 전체가 빈 것으로 보인다 — 앱은 전진만 하므로 수용(F1b 스펙 §4.2).
enum FileOpKind: String, Codable {
    case trash
    case rename
    case move
    case copy
}

/// 되돌리기 가능한 파일 작업 1건의 기록.
/// - trash: originalURL = 원위치, resultURL = 휴지통 내 실제 위치.
/// - rename: originalURL = 옛 경로, resultURL = 새 경로.
/// - move: originalURL = 옛 경로, resultURL = 새 경로(목적지 폴더 안, uniquify 반영).
/// - copy: originalURL = 원본, resultURL = 사본 — undo는 역이동이 아니라 사본을 휴지통으로.
/// 새 폴더는 기록하지 않는다 — 되돌리기가 삭제라 "영구 삭제 없음" 정책과 충돌.
struct FileOpEntry: Codable, Equatable, Identifiable {
    let id: UUID
    let kind: FileOpKind
    let originalURL: URL
    let resultURL: URL
    /// 배치 작업 묶음 id — F1a 단건은 nil(하위호환: 옛 로그 JSON에 필드 없음).
    let batchId: UUID?
    let date: Date

    init(id: UUID = UUID(), kind: FileOpKind, originalURL: URL, resultURL: URL,
         batchId: UUID? = nil, date: Date = Date()) {
        self.id = id
        self.kind = kind
        self.originalURL = originalURL
        self.resultURL = resultURL
        self.batchId = batchId
        self.date = date
    }
}

/// 파일 작업 로그를 JSON으로 영속하고 되돌리기를 수행한다(MoveLogStore 패턴).
/// 목록 = 아직 되돌릴 수 있는 작업 — 성공한 undo는 로그에서 제거, 실패는 보존.
actor FileOpsLogStore {
    private let fileURL: URL

    init(directory: URL) {
        self.fileURL = directory.appendingPathComponent("fileops-log.json")
    }

    func load() -> [FileOpEntry] {
        guard let data = try? Data(contentsOf: fileURL),
              let entries = try? JSONDecoder().decode([FileOpEntry].self, from: data) else { return [] }
        return entries
    }

    func append(_ entry: FileOpEntry) {
        appendBatch([entry])
    }

    /// 배치 기록 — 1회 load→save(건별 전체 재기록 회피).
    func appendBatch(_ newEntries: [FileOpEntry]) {
        guard !newEntries.isEmpty else { return }
        var all = load()
        all.append(contentsOf: newEntries)
        save(all)
    }

    /// 되돌리기 1건 — 성공 시 로그에서 제거, 실패 시 보존.
    func undo(_ entry: FileOpEntry) -> Bool {
        guard undoSingle(entry) else { return false }
        save(load().filter { $0.id != entry.id })
        return true
    }

    /// 배치 되돌리기 — 기록 역순으로(나중 연산부터) 복원해 순서 의존 점유 실패를 피한다
    /// (MoveExecutor.undo의 reversed() 선례). 성공분만 로그에서 제거, 실패분 보존.
    func undoBatch(batchId: UUID) -> (succeeded: [FileOpEntry], failed: [FileOpEntry]) {
        let targets = load().filter { $0.batchId == batchId }
        var succeeded: [FileOpEntry] = []
        var failed: [FileOpEntry] = []
        for entry in targets.reversed() {
            if undoSingle(entry) { succeeded.append(entry) } else { failed.append(entry) }
        }
        if !succeeded.isEmpty {
            let doneIds = Set(succeeded.map(\.id))
            save(load().filter { !doneIds.contains($0.id) })
        }
        return (succeeded, failed)
    }

    /// 실제 복원 연산(로그 조작 없음).
    /// - copy: 사본을 휴지통으로(영구 삭제 없음 정책) — 원위치 점유 검사 불필요.
    /// - 그 외: resultURL → originalURL 역이동. 결과물이 사라졌거나 원위치가 점유됐으면
    ///   실패(덮어쓰기 금지·uniquify 복원 안 함 — 이 스토어의 기존 정책 유지).
    private func undoSingle(_ entry: FileOpEntry) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: entry.resultURL.path) else { return false }
        if entry.kind == .copy {
            return (try? FileOperations.trash(at: entry.resultURL)) != nil
        }
        guard !fm.fileExists(atPath: entry.originalURL.path) else { return false }
        do {
            try fm.moveItem(at: entry.resultURL, to: entry.originalURL)
        } catch {
            return false
        }
        return true
    }

    private func save(_ entries: [FileOpEntry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: [.atomic])
    }
}
```

- [ ] **Step 4: 통과 확인**

Run: `swift test --filter FileOpsLogStoreTests && swift test --filter AppFileOpsTests`
Expected: PASS — 기존 F1a 테스트(AppFileOpsTests 포함)도 깨지지 않아야 함(batchId 기본 nil이라 호출부 불변).

- [ ] **Step 5: 커밋**

```bash
git add Sources/Services/FileOpsLogStore.swift Tests/CmdMDTests/FileOpsLogStoreTests.swift
git commit -m "기능(F1b): FileOpsLogStore 배치 — 옵셔널 batchId(하위호환)·appendBatch·undoBatch(역순)·copy undo=사본 휴지통"
```

---

### Task 3: 선택 리졸버 + 중첩 정규화 (순수 헬퍼)

**Files:**
- Create: `Sources/Services/FileSelection.swift`
- Test: `Tests/CmdMDTests/FileSelectionTests.swift` (신규)

**Interfaces:**
- Consumes: 없음(Foundation만 — 순수).
- Produces:
  - `enum SelectionModifier { case none, command, shift }`
  - `enum FileSelectionHelper` — 두 static 함수:
    - `static func resolve(current: Set<URL>, anchor: URL?, clicked: URL, modifier: SelectionModifier, ordered: [URL]) -> (selection: Set<URL>, anchor: URL?)`
    - `static func ancestorsOnly(_ urls: Set<URL>) -> [URL]` — 조상만 남기고 경로 오름차순 정렬 반환(배치 처리 결정적 순서).

- [ ] **Step 1: 실패하는 테스트 작성** — `Tests/CmdMDTests/FileSelectionTests.swift`:

```swift
import XCTest
@testable import CmdMD

final class FileSelectionTests: XCTestCase {

    private func u(_ p: String) -> URL { URL(fileURLWithPath: p) }

    // MARK: resolve — 클릭 시맨틱(스펙 §3.1)

    func testPlainClickReplacesSelection() {
        let ordered = [u("/f/a"), u("/f/b"), u("/f/c")]
        let r = FileSelectionHelper.resolve(current: [u("/f/a"), u("/f/b")], anchor: u("/f/a"),
                                            clicked: u("/f/c"), modifier: .none, ordered: ordered)
        XCTAssertEqual(r.selection, [u("/f/c")])
        XCTAssertEqual(r.anchor, u("/f/c"))
    }

    func testCommandClickToggles() {
        let ordered = [u("/f/a"), u("/f/b")]
        let added = FileSelectionHelper.resolve(current: [u("/f/a")], anchor: u("/f/a"),
                                                clicked: u("/f/b"), modifier: .command, ordered: ordered)
        XCTAssertEqual(added.selection, [u("/f/a"), u("/f/b")])
        XCTAssertEqual(added.anchor, u("/f/b"))
        let removed = FileSelectionHelper.resolve(current: added.selection, anchor: added.anchor,
                                                  clicked: u("/f/a"), modifier: .command, ordered: ordered)
        XCTAssertEqual(removed.selection, [u("/f/b")])
    }

    func testShiftClickSelectsRangeFromAnchor() {
        let ordered = [u("/f/a"), u("/f/b"), u("/f/c"), u("/f/d")]
        let r = FileSelectionHelper.resolve(current: [u("/f/b")], anchor: u("/f/b"),
                                            clicked: u("/f/d"), modifier: .shift, ordered: ordered)
        XCTAssertEqual(r.selection, [u("/f/b"), u("/f/c"), u("/f/d")])
        XCTAssertEqual(r.anchor, u("/f/b"), "⇧클릭은 앵커 유지")
        // 역방향(앵커 위쪽 클릭)도 연속 구간.
        let up = FileSelectionHelper.resolve(current: r.selection, anchor: r.anchor,
                                             clicked: u("/f/a"), modifier: .shift, ordered: ordered)
        XCTAssertEqual(up.selection, [u("/f/a"), u("/f/b")], "범위는 교체 — 이전 범위 잔존 없음")
    }

    func testShiftClickWithoutAnchorActsAsSingleSelect() {
        let ordered = [u("/f/a"), u("/f/b")]
        let r = FileSelectionHelper.resolve(current: [], anchor: nil,
                                            clicked: u("/f/b"), modifier: .shift, ordered: ordered)
        XCTAssertEqual(r.selection, [u("/f/b")])
        XCTAssertEqual(r.anchor, u("/f/b"))
    }

    func testShiftClickWithStaleAnchorFallsBackToSingle() {
        // 앵커가 ordered에 없음(재열거로 사라짐) — 단일 선택 폴백.
        let ordered = [u("/f/a"), u("/f/b")]
        let r = FileSelectionHelper.resolve(current: [u("/f/x")], anchor: u("/f/x"),
                                            clicked: u("/f/a"), modifier: .shift, ordered: ordered)
        XCTAssertEqual(r.selection, [u("/f/a")])
    }

    // MARK: ancestorsOnly — 중첩 정규화(스펙 §4.3)

    func testAncestorsOnlyDropsDescendants() {
        let input: Set<URL> = [u("/r/parent"), u("/r/parent/child.md"), u("/r/other.md")]
        let out = FileSelectionHelper.ancestorsOnly(input)
        XCTAssertEqual(Set(out), [u("/r/parent"), u("/r/other.md")])
    }

    func testAncestorsOnlyKeepsSiblingsWithPrefixNames() {
        // '/' 경계 — "/r/ab"는 "/r/a"의 하위가 아니다.
        let input: Set<URL> = [u("/r/a"), u("/r/ab")]
        let out = FileSelectionHelper.ancestorsOnly(input)
        XCTAssertEqual(Set(out), input)
    }

    func testAncestorsOnlyReturnsSortedPaths() {
        let input: Set<URL> = [u("/r/b.md"), u("/r/a.md")]
        XCTAssertEqual(FileSelectionHelper.ancestorsOnly(input).map(\.path), ["/r/a.md", "/r/b.md"])
    }
}
```

- [ ] **Step 2: 실패 확인**

Run: `swift test --filter FileSelectionTests`
Expected: FAIL — "cannot find 'FileSelectionHelper'" 컴파일 에러.

- [ ] **Step 3: 구현** — `Sources/Services/FileSelection.swift`:

```swift
import Foundation

/// 클릭에 실린 선택 수식키(F1b 스펙 §3.1). ⌘가 ⇧보다 우선.
enum SelectionModifier {
    case none
    case command
    case shift
}

/// 다중 선택 순수 헬퍼 — 상태 없음, AppState가 소유한 Set<URL>을 계산만 해준다.
enum FileSelectionHelper {

    /// 클릭 한 번의 선택 결과를 계산한다(Finder식).
    /// - none: 클릭 항목 하나로 교체, 앵커 이동.
    /// - command: 토글, 앵커 이동.
    /// - shift: 앵커~클릭 연속 구간으로 교체(ordered 순서 기준), 앵커 유지.
    ///   앵커가 없거나 ordered에서 사라졌으면(재열거) 단일 선택 폴백.
    static func resolve(current: Set<URL>, anchor: URL?, clicked: URL,
                        modifier: SelectionModifier, ordered: [URL]) -> (selection: Set<URL>, anchor: URL?) {
        switch modifier {
        case .none:
            return ([clicked], clicked)
        case .command:
            var next = current
            if next.contains(clicked) { next.remove(clicked) } else { next.insert(clicked) }
            return (next, clicked)
        case .shift:
            guard let anchor,
                  let anchorIndex = ordered.firstIndex(of: anchor),
                  let clickedIndex = ordered.firstIndex(of: clicked) else {
                return ([clicked], clicked)
            }
            let range = min(anchorIndex, clickedIndex)...max(anchorIndex, clickedIndex)
            return (Set(ordered[range]), anchor)
        }
    }

    /// 배치 대상 정규화 — 부모 폴더와 그 하위가 함께 선택됐으면 조상만 남긴다
    /// (부모가 먼저 이동/휴지통 가면 자식 연산이 경로 소실로 실패). '/' 경계 prefix로
    /// 형제("a" vs "ab") 오감지를 방지하고, 결정적 처리 순서를 위해 경로 오름차순 정렬.
    static func ancestorsOnly(_ urls: Set<URL>) -> [URL] {
        let paths = urls.map { $0.standardizedFileURL.path }
        let kept = urls.filter { url in
            let p = url.standardizedFileURL.path
            return !paths.contains { other in other != p && p.hasPrefix(other + "/") }
        }
        return kept.sorted { $0.path < $1.path }
    }
}
```

- [ ] **Step 4: 통과 확인**

Run: `swift test --filter FileSelectionTests`
Expected: PASS 9건.

- [ ] **Step 5: 커밋**

```bash
git add Sources/Services/FileSelection.swift Tests/CmdMDTests/FileSelectionTests.swift
git commit -m "기능(F1b): 선택 리졸버(클릭/⌘/⇧)·중첩 정규화 순수 헬퍼"
```

---

### Task 4: FilePasteboard (Finder 상호운용)

**Files:**
- Create: `Sources/Services/FilePasteboard.swift`
- Test: `Tests/CmdMDTests/FilePasteboardTests.swift` (신규)

**Interfaces:**
- Consumes: AppKit `NSPasteboard`.
- Produces:
  - `enum FilePasteboard`
    - `static func write(_ urls: [URL], to pasteboard: NSPasteboard = .general)`
    - `static func readFileURLs(from pasteboard: NSPasteboard = .general) -> [URL]` — 실재 파일만.

- [ ] **Step 1: 실패하는 테스트 작성** — `Tests/CmdMDTests/FilePasteboardTests.swift`:

```swift
import XCTest
@testable import CmdMD

final class FilePasteboardTests: XCTestCase {

    private var pasteboard: NSPasteboard!
    private var work: URL!

    override func setUpWithError() throws {
        // 시스템 general 페이스트보드를 오염시키지 않도록 고유 이름 인스턴스 사용.
        pasteboard = NSPasteboard(name: NSPasteboard.Name("f1b-test-\(UUID().uuidString)"))
        work = FileManager.default.temporaryDirectory
            .appendingPathComponent("pb-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
    }

    override func tearDown() {
        pasteboard.releaseGlobally()
        try? FileManager.default.removeItem(at: work)
        super.tearDown()
    }

    func testWriteThenReadRoundTrip() throws {
        let a = work.appendingPathComponent("a.md")
        let b = work.appendingPathComponent("b.md")
        try Data("a".utf8).write(to: a)
        try Data("b".utf8).write(to: b)

        FilePasteboard.write([a, b], to: pasteboard)
        let read = FilePasteboard.readFileURLs(from: pasteboard)
        XCTAssertEqual(Set(read.map(\.standardizedFileURL.path)),
                       [a.standardizedFileURL.path, b.standardizedFileURL.path])
    }

    func testReadFiltersMissingFiles() throws {
        let a = work.appendingPathComponent("a.md")
        try Data("a".utf8).write(to: a)
        let ghost = work.appendingPathComponent("없음.md")
        FilePasteboard.write([a, ghost], to: pasteboard)
        let read = FilePasteboard.readFileURLs(from: pasteboard)
        XCTAssertEqual(read.map(\.lastPathComponent), ["a.md"], "실재하지 않는 파일은 걸러냄")
    }

    func testReadFromEmptyPasteboardIsEmpty() {
        XCTAssertTrue(FilePasteboard.readFileURLs(from: pasteboard).isEmpty)
    }

    func testWriteReplacesPreviousContents() throws {
        let a = work.appendingPathComponent("a.md")
        let b = work.appendingPathComponent("b.md")
        try Data("a".utf8).write(to: a)
        try Data("b".utf8).write(to: b)
        FilePasteboard.write([a], to: pasteboard)
        FilePasteboard.write([b], to: pasteboard)
        XCTAssertEqual(FilePasteboard.readFileURLs(from: pasteboard).map(\.lastPathComponent), ["b.md"])
    }
}
```

- [ ] **Step 2: 실패 확인**

Run: `swift test --filter FilePasteboardTests`
Expected: FAIL — "cannot find 'FilePasteboard'" 컴파일 에러.

- [ ] **Step 3: 구현** — `Sources/Services/FilePasteboard.swift`:

```swift
import AppKit

/// 파일 URL 페이스트보드 헬퍼 — Finder와 양방향 상호운용(.fileURL 공용 타입).
/// 비샌드박스라 writeObjects/readObjects에 장애물 없음(드롭 경로에서 UTType 호환 기검증).
enum FilePasteboard {

    /// 파일 URL들을 페이스트보드에 쓴다(기존 내용 교체) — Finder에서 ⌘V로 받을 수 있다.
    static func write(_ urls: [URL], to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.writeObjects(urls as [NSURL])
    }

    /// 페이스트보드의 파일 URL들을 읽는다(실재 파일만) — Finder에서 ⌘C한 항목 수신.
    static func readFileURLs(from pasteboard: NSPasteboard = .general) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: options),
              let urls = objects as? [URL] else { return [] }
        return urls.filter { FileManager.default.fileExists(atPath: $0.path) }
    }
}
```

- [ ] **Step 4: 통과 확인**

Run: `swift test --filter FilePasteboardTests`
Expected: PASS 4건.

- [ ] **Step 5: 커밋**

```bash
git add Sources/Services/FilePasteboard.swift Tests/CmdMDTests/FilePasteboardTests.swift
git commit -m "기능(F1b): FilePasteboard — .fileURL 읽기/쓰기(Finder 상호운용, 실재 파일 필터)"
```

---

### Task 5: AppState 선택 상태 (fileSelection·클리어·prune)

**Files:**
- Modify: `Sources/App/AppState.swift` — ①상태 프로퍼티(`:41` selectedFolder didSet 근처) ②선택 메서드(F1a 섹션 `:1785` 뒤에 새 MARK) ③`completeFileOperation()`(`:1922`)에 prune
- Test: `Tests/CmdMDTests/AppFileSelectionTests.swift` (신규)

**Interfaces:**
- Consumes: Task 3 `FileSelectionHelper.resolve` / `SelectionModifier`.
- Produces (Task 6~10이 사용):
  - `var fileSelection: Set<URL>` / `var selectionAnchor: URL?`
  - `func handleFileClick(_ url: URL, modifier: SelectionModifier, ordered: [URL])`
  - `func toggleFileSelection(_ url: URL)` — 트리 ⌘클릭용(ordered 불필요)
  - `func clearFileSelection()`

- [ ] **Step 1: 실패하는 테스트 작성** — `Tests/CmdMDTests/AppFileSelectionTests.swift` (AppFileOpsTests 관례 복제 — TempDataDirectory 주입):

```swift
import XCTest
@testable import CmdMD

@MainActor
final class AppFileSelectionTests: XCTestCase {

    private var tempData: URL!
    private var work: URL!
    private var appState: AppState!

    override func setUpWithError() throws {
        tempData = TempDataDirectory.make()
        work = FileManager.default.temporaryDirectory
            .appendingPathComponent("selection-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        appState = AppState(dataDirectory: tempData)
    }

    override func tearDown() {
        TempDataDirectory.cleanup(tempData)
        try? FileManager.default.removeItem(at: work)
        tempData = nil; work = nil; appState = nil
        super.tearDown()
    }

    private func makeFile(_ name: String) throws -> URL {
        let url = work.appendingPathComponent(name)
        try Data("본문".utf8).write(to: url)
        return url
    }

    func testHandleFileClickReplacesAndToggles() throws {
        let a = try makeFile("a.md"); let b = try makeFile("b.md")
        appState.handleFileClick(a, modifier: .none, ordered: [a, b])
        XCTAssertEqual(appState.fileSelection, [a])
        appState.handleFileClick(b, modifier: .command, ordered: [a, b])
        XCTAssertEqual(appState.fileSelection, [a, b])
        appState.toggleFileSelection(a)
        XCTAssertEqual(appState.fileSelection, [b])
    }

    func testShiftClickUsesAnchor() throws {
        let a = try makeFile("a.md"); let b = try makeFile("b.md"); let c = try makeFile("c.md")
        appState.handleFileClick(a, modifier: .none, ordered: [a, b, c])
        appState.handleFileClick(c, modifier: .shift, ordered: [a, b, c])
        XCTAssertEqual(appState.fileSelection, [a, b, c])
    }

    func testSelectedFolderChangeClearsSelection() throws {
        let a = try makeFile("a.md")
        appState.handleFileClick(a, modifier: .none, ordered: [a])
        appState.selectedFolder = work  // 드릴인/폴더 클릭 상당
        XCTAssertTrue(appState.fileSelection.isEmpty, "폴더 이동 = 선택 해제(Finder 동일)")
        XCTAssertNil(appState.selectionAnchor)
    }

    func testFileOpPrunesVanishedSelection() async throws {
        // performRename 성공 → completeFileOperation → 옛 URL은 선택에서 제거돼야 함.
        let a = try makeFile("a.md"); let b = try makeFile("b.md")
        appState.handleFileClick(a, modifier: .none, ordered: [a, b])
        appState.handleFileClick(b, modifier: .command, ordered: [a, b])
        _ = try await appState.performRename(at: a, to: "바뀜.md")
        XCTAssertEqual(appState.fileSelection, [b], "사라진 URL prune, 남은 선택 유지")
    }
}
```

- [ ] **Step 2: 실패 확인**

Run: `swift test --filter AppFileSelectionTests`
Expected: FAIL — "no member 'handleFileClick'" 컴파일 에러.

- [ ] **Step 3: 구현** — `AppState.swift` 세 곳:

①상태(선언부, `selectedFolder` 근처 `:41`) — didSet에 클리어 추가:

```swift
    /// 라이브러리 뷰가 보여줄 폴더. 기본·리셋값은 currentFolder.
    var selectedFolder: URL? = nil {
        didSet {
            restoreLibraryLayoutForSelectedFolder()
            // 폴더 이동 = 선택 해제(Finder 동일, F1b 스펙 §2). 같은 값 재대입은 무시.
            if oldValue != selectedFolder { clearFileSelection() }
        }
    }

    // MARK: - 다중 선택 (F1b)
    /// 라이브러리·트리 공유 선택 집합. URL 키 — FileTreeItem.id는 재빌드마다 새 UUID라 못 쓴다.
    var fileSelection: Set<URL> = []
    /// ⇧범위 선택 앵커(라이브러리 전용).
    var selectionAnchor: URL? = nil
```

②선택 메서드(F1a 파일 작업 MARK 섹션 뒤에 새 MARK `// MARK: - 다중 선택 (F1b)` 추가):

```swift
    /// 라이브러리 클릭 한 번 처리 — 리졸버(순수)에 위임. ordered = 화면 표시 순서(entries).
    func handleFileClick(_ url: URL, modifier: SelectionModifier, ordered: [URL]) {
        let result = FileSelectionHelper.resolve(current: fileSelection, anchor: selectionAnchor,
                                                 clicked: url, modifier: modifier, ordered: ordered)
        fileSelection = result.selection
        selectionAnchor = result.anchor
    }

    /// 트리 ⌘클릭 토글 — 범위 선택이 없어 ordered 불필요.
    func toggleFileSelection(_ url: URL) {
        handleFileClick(url, modifier: .command, ordered: [])
    }

    func clearFileSelection() {
        fileSelection = []
        selectionAnchor = nil
    }

    /// 파일 작업 후 사라진 URL을 선택에서 제거 — 유령 선택에 배치가 실행되는 것을 방지.
    private func pruneFileSelection() {
        fileSelection = fileSelection.filter { FileManager.default.fileExists(atPath: $0.path) }
        if let anchor = selectionAnchor, !FileManager.default.fileExists(atPath: anchor.path) {
            selectionAnchor = nil
        }
    }
```

③`completeFileOperation()`(`:1922`)에 prune 삽입:

```swift
    /// 파일 작업 성공 후 공통 갱신 — 세대 토큰·트리·세션·선택 prune.
    private func completeFileOperation() {
        fileOpsGeneration += 1
        pruneFileSelection()
        loadFileTree()
        saveSession()
    }
```

- [ ] **Step 4: 통과 확인**

Run: `swift test --filter AppFileSelectionTests && swift test --filter AppLibraryStateTests && swift test --filter AppLibraryLayoutMemoryTests`
Expected: PASS — selectedFolder didSet에 로직이 늘었으므로 기존 라이브러리 상태·레이아웃 기억 테스트가 깨지지 않는지 함께 확인.

- [ ] **Step 5: 커밋**

```bash
git add Sources/App/AppState.swift Tests/CmdMDTests/AppFileSelectionTests.swift
git commit -m "기능(F1b): AppState 선택 상태 — fileSelection/앵커·폴더 이동 시 클리어·파일 작업 후 prune"
```

---

### Task 6: AppState 배치 배선 (performBatchTrash/Move/Copy·undoFileOpBatch)

**Files:**
- Modify: `Sources/App/AppState.swift` — F1a 파일 작업 섹션 뒤 새 MARK `// MARK: - 배치 파일 작업 (F1b)` + `undoFileOp`(`:1891`) 확장
- Test: `Tests/CmdMDTests/AppBatchFileOpsTests.swift` (신규)

**Interfaces:**
- Consumes: Task 1 `FileOperations.move/copy`, Task 2 `appendBatch`/`undoBatch`/`FileOpEntry(batchId:)`, Task 3 `FileSelectionHelper.ancestorsOnly`, F1a `companionNoteForOperation`/`closeTabs`/`retargetOpenTabs`/`completeFileOperation`/`hasDirtyTab`/`isDirectoryPath`/`.flushMediaCompanionNote`/`showToast`/`errorMessage`, `CompanionNote.noteURL(for:)`.
- Produces (Task 7·10·11이 사용):
  - `@discardableResult func performBatchTrash(urls: [URL]) async -> (succeeded: Int, failed: Int)`
  - `func batchTrashWithConfirmation(_ urls: [URL])` — 요약 NSAlert 1회
  - `@discardableResult func performBatchMove(urls: [URL], to destinationDir: URL) async -> (succeeded: Int, failed: Int)`
  - `@discardableResult func performBatchCopy(urls: [URL], to destinationDir: URL) async -> (succeeded: Int, failed: Int)`
  - `func undoFileOpBatch(batchId: UUID) async -> Bool`

- [ ] **Step 1: 실패하는 테스트 작성** — `Tests/CmdMDTests/AppBatchFileOpsTests.swift` (셋업은 Task 5 테스트와 동일 골격 — tempData/work/appState + makeFile + openTab 헬퍼를 AppFileOpsTests에서 복제):

```swift
import XCTest
@testable import CmdMD

@MainActor
final class AppBatchFileOpsTests: XCTestCase {

    private var tempData: URL!
    private var work: URL!
    private var appState: AppState!

    override func setUpWithError() throws {
        tempData = TempDataDirectory.make()
        work = FileManager.default.temporaryDirectory
            .appendingPathComponent("batch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        appState = AppState(dataDirectory: tempData)
    }

    override func tearDown() {
        TempDataDirectory.cleanup(tempData)
        try? FileManager.default.removeItem(at: work)
        tempData = nil; work = nil; appState = nil
        super.tearDown()
    }

    private func makeFile(_ relative: String) throws -> URL {
        let url = work.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("본문".utf8).write(to: url)
        return url
    }

    private func makeFolder(_ relative: String) throws -> URL {
        let url = work.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func openTab(at url: URL) -> EditorTab {
        appState.createNewTab()
        let index = appState.tabs.count - 1
        appState.tabs[index].fileURL = url
        appState.documents[appState.tabs[index].documentId]?.fileURL = url
        return appState.tabs[index]
    }

    // MARK: 배치 이동

    func testBatchMoveMovesAllAndLogsOneBatch() async throws {
        let a = try makeFile("a.md"); let b = try makeFile("b.md")
        let dest = try makeFolder("대상")
        let result = await appState.performBatchMove(urls: [a, b], to: dest)
        XCTAssertEqual(result.succeeded, 2)
        XCTAssertEqual(result.failed, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.appendingPathComponent("a.md").path))
        let entries = await appState.fileOpsLogStore.load()
        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(Set(entries.compactMap(\.batchId)).count, 1, "한 배치 = 한 batchId")
    }

    func testBatchMoveRetargetsOpenTabs() async throws {
        let a = try makeFile("a.md")
        let dest = try makeFolder("대상")
        let tab = openTab(at: a)
        _ = await appState.performBatchMove(urls: [a], to: dest)
        let updated = appState.tabs.first(where: { $0.id == tab.id })
        XCTAssertEqual(updated?.fileURL, dest.appendingPathComponent("a.md"))
    }

    func testBatchMoveSkipsItemsAlreadyInDestination() async throws {
        let dest = try makeFolder("대상")
        let inside = try makeFile("대상/이미.md")
        let outside = try makeFile("밖.md")
        let result = await appState.performBatchMove(urls: [inside, outside], to: dest)
        XCTAssertEqual(result.succeeded, 1, "이미 그 폴더에 있는 항목은 skip(실패 아님)")
        XCTAssertEqual(result.failed, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: inside.path), "제자리 항목 불변 — 복제 개명 없음")
        let entries = await appState.fileOpsLogStore.load()
        XCTAssertEqual(entries.count, 1)
    }

    func testBatchMoveNormalizesNestedSelection() async throws {
        // 부모 폴더와 그 자식이 함께 선택 — 조상만 이동, 자식은 따라간다(이중 이동 없음).
        let parent = try makeFolder("부모")
        let child = try makeFile("부모/자식.md")
        let dest = try makeFolder("대상")
        let result = await appState.performBatchMove(urls: [parent, child], to: dest)
        XCTAssertEqual(result.succeeded, 1)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: dest.appendingPathComponent("부모/자식.md").path))
        let entries = await appState.fileOpsLogStore.load()
        XCTAssertEqual(entries.count, 1, "자식은 별도 엔트리 없음")
    }

    func testBatchMoveCompanionNoteFollowsWithDerivedName() async throws {
        // 미디어 이동 시 짝꿍 노트 동반 + 본체 결과 이름 파생(스펙 §4.3 이름 규칙).
        let media = try makeFile("노래.mp3")
        let note = try makeFile("노래.mp3.md")
        let dest = try makeFolder("대상")
        // 목적지에 같은 이름 미디어를 미리 두어 본체가 uniquify되게 한다.
        _ = try makeFile("대상/노래.mp3")
        let result = await appState.performBatchMove(urls: [media], to: dest)
        XCTAssertEqual(result.succeeded, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: note.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: dest.appendingPathComponent("노래 (1).mp3.md").path),
            "노트는 본체 결과 이름(노래 (1).mp3)에서 파생 — 단순 uniquify(노래.mp3 (1).md) 금지")
        let entries = await appState.fileOpsLogStore.load()
        XCTAssertEqual(entries.count, 2, "본체+노트 각 1건, 같은 배치")
        XCTAssertEqual(Set(entries.compactMap(\.batchId)).count, 1)
    }

    func testBatchMoveCompanionNotDoubleProcessedWhenBothSelected() async throws {
        // 미디어와 그 짝꿍 노트가 둘 다 선택에 들어와도 노트는 한 번만 처리.
        let media = try makeFile("노래.mp3")
        let note = try makeFile("노래.mp3.md")
        let dest = try makeFolder("대상")
        _ = await appState.performBatchMove(urls: [media, note], to: dest)
        let entries = await appState.fileOpsLogStore.load()
        XCTAssertEqual(entries.count, 2, "본체 1 + 노트 1 — 노트 이중 엔트리 없음")
    }

    // MARK: 배치 복사

    func testBatchCopyKeepsOriginalsAndLogs() async throws {
        let a = try makeFile("a.md")
        let dest = try makeFolder("대상")
        let result = await appState.performBatchCopy(urls: [a], to: dest)
        XCTAssertEqual(result.succeeded, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.path), "원본 불변")
        let entries = await appState.fileOpsLogStore.load()
        XCTAssertEqual(entries.map(\.kind), [.copy])
    }

    // MARK: 배치 휴지통

    func testBatchTrashClosesTabsAndLogsOneBatch() async throws {
        let a = try makeFile("a.md"); let b = try makeFile("b.md")
        _ = openTab(at: a)
        let before = appState.tabs.count
        let result = await appState.performBatchTrash(urls: [a, b])
        XCTAssertEqual(result.succeeded, 2)
        XCTAssertEqual(appState.tabs.count, before - 1, "대상 탭 선닫기")
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.path))
        let entries = await appState.fileOpsLogStore.load()
        XCTAssertEqual(Set(entries.compactMap(\.batchId)).count, 1)
    }

    func testBatchTrashPartialFailureContinues() async throws {
        let a = try makeFile("a.md")
        let ghost = work.appendingPathComponent("없음.md")
        let result = await appState.performBatchTrash(urls: [a, ghost])
        XCTAssertEqual(result.succeeded, 1)
        XCTAssertEqual(result.failed, 1)
        XCTAssertNotNil(appState.errorMessage, "부분 실패 요약")
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.path), "실패와 무관하게 계속 진행")
    }

    // MARK: 배치 되돌리기

    func testUndoFileOpBatchRestoresAllAndRetargets() async throws {
        let a = try makeFile("a.md"); let b = try makeFile("b.md")
        let dest = try makeFolder("대상")
        _ = await appState.performBatchMove(urls: [a, b], to: dest)
        let movedA = dest.appendingPathComponent("a.md")
        let tab = openTab(at: movedA)
        let batchId = await appState.fileOpsLogStore.load().first!.batchId!

        let ok = await appState.undoFileOpBatch(batchId: batchId)
        XCTAssertTrue(ok)
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: b.path))
        let updated = appState.tabs.first(where: { $0.id == tab.id })
        XCTAssertEqual(updated?.fileURL, a, "move undo도 탭 재조준(.move 분기 필수)")
        let remaining = await appState.fileOpsLogStore.load()
        XCTAssertTrue(remaining.isEmpty)
    }

    func testUndoSingleCopyClosesCopyTab() async throws {
        let a = try makeFile("a.md")
        let dest = try makeFolder("대상")
        _ = await appState.performBatchCopy(urls: [a], to: dest)
        let copied = dest.appendingPathComponent("a.md")
        _ = openTab(at: copied)
        let entry = await appState.fileOpsLogStore.load().first!
        let before = appState.tabs.count
        let ok = await appState.undoFileOp(entry)
        XCTAssertTrue(ok)
        XCTAssertEqual(appState.tabs.count, before - 1, "사본 탭 선닫기 후 사본 휴지통")
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.path))
    }
}
```

- [ ] **Step 2: 실패 확인**

Run: `swift test --filter AppBatchFileOpsTests`
Expected: FAIL — "no member 'performBatchMove'" 컴파일 에러.

- [ ] **Step 3: 구현** — `AppState.swift`에 새 MARK 섹션 추가(F1a 섹션 뒤):

```swift
    // MARK: - 배치 파일 작업 (F1b)

    /// 배치 요약 확인(제안→확인→실행) — 항목별 모달 N회 금지, 요약 1회(Close All Tabs 관례).
    /// 단건이면 기존 trashWithConfirmation 재사용(문구 동일성).
    func batchTrashWithConfirmation(_ urls: [URL]) {
        let targets = FileSelectionHelper.ancestorsOnly(Set(urls))
        guard !targets.isEmpty else { return }
        if targets.count == 1 { trashWithConfirmation(targets[0]); return }

        let alert = NSAlert()
        alert.messageText = "\(targets.count)개 항목을 휴지통으로 이동할까요?"
        var info = "휴지통에서 복구할 수 있고, '파일 작업 기록'에서 한 번에 되돌릴 수 있습니다."
        if targets.contains(where: { Self.companionNoteForOperation(mediaURL: $0) != nil }) {
            info = "짝꿍 메모도 함께 이동합니다. " + info
        }
        if targets.contains(where: { hasDirtyTab(under: $0, isDirectory: isDirectoryPath($0)) }) {
            info = "저장 안 된 변경이 있는 탭이 닫힙니다. " + info
        }
        alert.informativeText = info
        alert.alertStyle = .warning
        alert.addButton(withTitle: "휴지통으로 이동")
        alert.addButton(withTitle: "취소")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { @MainActor in await self.performBatchTrash(urls: targets) }
    }

    /// 배치 휴지통 — 건별(flush→탭 선닫기→trash→엔트리 수집) 후 로그·갱신은 배치 끝 1회.
    /// 부분 실패는 계속 진행 + 요약. 확인은 batchTrashWithConfirmation 몫.
    @discardableResult
    func performBatchTrash(urls: [URL]) async -> (succeeded: Int, failed: Int) {
        let targets = FileSelectionHelper.ancestorsOnly(Set(urls))
        let batchId = UUID()
        var entries: [FileOpEntry] = []
        var failures: [String] = []
        var handled = Set<String>()   // 동반 처리된 짝꿍 노트(standardized path) — 이중 처리 방지

        for url in targets {
            if handled.contains(url.standardizedFileURL.path) { continue }
            let isDirectory = isDirectoryPath(url)
            let companion = isDirectory ? nil : Self.companionNoteForOperation(mediaURL: url)
            if companion != nil {
                NotificationCenter.default.post(name: .flushMediaCompanionNote, object: url)
            }
            closeTabs(under: url, isDirectory: isDirectory)
            if let companion { closeTabs(under: companion, isDirectory: false) }
            do {
                let trashed = try FileOperations.trash(at: url)
                entries.append(FileOpEntry(kind: .trash, originalURL: url,
                                           resultURL: trashed, batchId: batchId))
                if let companion {
                    do {
                        let trashedNote = try FileOperations.trash(at: companion)
                        entries.append(FileOpEntry(kind: .trash, originalURL: companion,
                                                   resultURL: trashedNote, batchId: batchId))
                        handled.insert(companion.standardizedFileURL.path)
                    } catch {
                        failures.append("짝꿍 노트: \(companion.lastPathComponent)")
                    }
                }
            } catch {
                failures.append(url.lastPathComponent)
            }
        }

        await fileOpsLogStore.appendBatch(entries)
        completeFileOperation()
        reportBatchFailures(failures, action: "휴지통 이동")
        let failedTargets = failures.filter { !$0.hasPrefix("짝꿍 노트") }.count
        return (targets.count - failedTargets, failedTargets)
    }

    /// 배치 이동 — 건별(flush→move→탭 재조준→짝꿍 동반) 후 로그·갱신은 배치 끝 1회.
    /// 이미 목적지에 있는 항목은 skip(실패 아님 — 제자리 이동은 uniquify가 복제 개명으로 둔갑).
    @discardableResult
    func performBatchMove(urls: [URL], to destinationDir: URL) async -> (succeeded: Int, failed: Int) {
        let destStd = destinationDir.standardizedFileURL
        let targets = FileSelectionHelper.ancestorsOnly(Set(urls)).filter {
            $0.standardizedFileURL.deletingLastPathComponent().path != destStd.path
        }
        let batchId = UUID()
        var entries: [FileOpEntry] = []
        var failures: [String] = []
        var handled = Set<String>()

        for url in targets {
            if handled.contains(url.standardizedFileURL.path) { continue }
            let isDirectory = isDirectoryPath(url)
            let companion = isDirectory ? nil : Self.companionNoteForOperation(mediaURL: url)
            if companion != nil {
                NotificationCenter.default.post(name: .flushMediaCompanionNote, object: url)
            }
            do {
                let moved = try FileOperations.move(at: url, to: destStd)
                entries.append(FileOpEntry(kind: .move, originalURL: url,
                                           resultURL: moved, batchId: batchId))
                retargetOpenTabs(from: url, to: moved, isDirectory: isDirectory)
                if let companion {
                    do {
                        let finalNote = try relocateCompanion(companion, mode: .move,
                                                              to: destStd, alongside: moved,
                                                              failures: &failures)
                        entries.append(FileOpEntry(kind: .move, originalURL: companion,
                                                   resultURL: finalNote, batchId: batchId))
                        retargetOpenTabs(from: companion, to: finalNote, isDirectory: false)
                        handled.insert(companion.standardizedFileURL.path)
                    } catch {
                        failures.append("짝꿍 노트: \(companion.lastPathComponent)")
                    }
                }
            } catch {
                failures.append(url.lastPathComponent)
            }
        }

        await fileOpsLogStore.appendBatch(entries)
        completeFileOperation()
        reportBatchFailures(failures, action: "이동")
        let failedTargets = failures.filter { !$0.hasPrefix("짝꿍 노트") }.count
        return (targets.count - failedTargets, failedTargets)
    }

    /// 배치 복사 — 원본·탭 불변, 로그만(undo=사본 휴지통). 같은 폴더 복사 = 사본 시맨틱.
    @discardableResult
    func performBatchCopy(urls: [URL], to destinationDir: URL) async -> (succeeded: Int, failed: Int) {
        let destStd = destinationDir.standardizedFileURL
        let targets = FileSelectionHelper.ancestorsOnly(Set(urls))
        let batchId = UUID()
        var entries: [FileOpEntry] = []
        var failures: [String] = []
        var handled = Set<String>()

        for url in targets {
            if handled.contains(url.standardizedFileURL.path) { continue }
            let isDirectory = isDirectoryPath(url)
            let companion = isDirectory ? nil : Self.companionNoteForOperation(mediaURL: url)
            if companion != nil {
                // 편집 중 버퍼를 원본 노트에 flush — 사본에 최신 내용이 담기게.
                NotificationCenter.default.post(name: .flushMediaCompanionNote, object: url)
            }
            do {
                let copied = try FileOperations.copy(at: url, to: destStd)
                entries.append(FileOpEntry(kind: .copy, originalURL: url,
                                           resultURL: copied, batchId: batchId))
                if let companion {
                    do {
                        let finalNote = try relocateCompanion(companion, mode: .copy,
                                                              to: destStd, alongside: copied,
                                                              failures: &failures)
                        entries.append(FileOpEntry(kind: .copy, originalURL: companion,
                                                   resultURL: finalNote, batchId: batchId))
                        handled.insert(companion.standardizedFileURL.path)
                    } catch {
                        failures.append("짝꿍 노트: \(companion.lastPathComponent)")
                    }
                }
            } catch {
                failures.append(url.lastPathComponent)
            }
        }

        await fileOpsLogStore.appendBatch(entries)
        completeFileOperation()
        reportBatchFailures(failures, action: "복사")
        let failedTargets = failures.filter { !$0.hasPrefix("짝꿍 노트") }.count
        return (targets.count - failedTargets, failedTargets)
    }

    private enum CompanionRelocateMode { case move, copy }

    /// 짝꿍 노트 동반 이동/복사 — 결과 이름은 본체 결과에서 파생(파일명.ext.md 규칙 유지).
    /// 본체가 uniquify로 개명됐으면(노래.mp3→노래 (1).mp3) 노트도 "노래 (1).mp3.md"로 맞춘다.
    /// 파생 이름이 점유돼 있으면 노트만 uniquify하고 연결 끊김을 failures에 기록(스펙 §4.3).
    private func relocateCompanion(_ companion: URL, mode: CompanionRelocateMode,
                                   to destinationDir: URL, alongside movedBody: URL,
                                   failures: inout [String]) throws -> URL {
        let relocated: URL
        switch mode {
        case .move: relocated = try FileOperations.move(at: companion, to: destinationDir)
        case .copy: relocated = try FileOperations.copy(at: companion, to: destinationDir)
        }
        let desiredName = CompanionNote.noteURL(for: movedBody).lastPathComponent
        guard relocated.lastPathComponent != desiredName else { return relocated }
        if let aligned = try? FileOperations.rename(at: relocated, to: desiredName) {
            return aligned
        }
        failures.append("짝꿍 노트 이름 정렬: \(relocated.lastPathComponent)")
        return relocated
    }

    /// 부분 실패 요약 — errorMessage는 단일 문자열이라 건별 나열 대신 개수+예시.
    private func reportBatchFailures(_ failures: [String], action: String) {
        guard !failures.isEmpty else { return }
        let sample = failures.prefix(3).joined(separator: ", ")
        errorMessage = "\(action) 중 \(failures.count)건을 처리하지 못했습니다: \(sample)"
    }

    /// 배치 되돌리기 — copy 사본 탭 선닫기 → 스토어 역순 undo → move/rename 성공분 탭 재조준.
    func undoFileOpBatch(batchId: UUID) async -> Bool {
        let entries = await fileOpsLogStore.load().filter { $0.batchId == batchId }
        for entry in entries where entry.kind == .copy {
            closeTabs(under: entry.resultURL, isDirectory: isDirectoryPath(entry.resultURL))
        }
        let result = await fileOpsLogStore.undoBatch(batchId: batchId)
        for entry in result.succeeded where entry.kind == .rename || entry.kind == .move {
            // 복원 = resultURL → originalURL. 그 경로를 보던 탭 재조준(F1a undo 함정의 동형 방지).
            retargetOpenTabs(from: entry.resultURL, to: entry.originalURL,
                             isDirectory: isDirectoryPath(entry.originalURL))
        }
        completeFileOperation()
        return result.failed.isEmpty
    }
```

기존 `undoFileOp`(`:1891`) 확장 — copy 선닫기 + move 재조준:

```swift
    /// 파일 작업 되돌리기 — 성공 시 갱신 트리거까지.
    func undoFileOp(_ entry: FileOpEntry) async -> Bool {
        // copy 되돌리기 = 사본이 휴지통으로 감 — 사본을 보던 탭 먼저 닫는다.
        if entry.kind == .copy {
            closeTabs(under: entry.resultURL, isDirectory: isDirectoryPath(entry.resultURL))
        }
        let ok = await fileOpsLogStore.undo(entry)
        if ok {
            // rename/move 되돌리기 = 파일이 resultURL → originalURL로 복귀. 그 경로를 보던
            // 탭도 재조준 — 안 그러면 워처가 "외부에서 삭제됨"으로 오인(F1a 최종 리뷰 함정).
            // trash 되돌리기는 대상 탭이 이미 닫혀 있어 재조준할 탭이 없다.
            if entry.kind == .rename || entry.kind == .move {
                let isDirectory = (try? entry.originalURL
                    .resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                retargetOpenTabs(from: entry.resultURL, to: entry.originalURL, isDirectory: isDirectory)
            }
            completeFileOperation()
        }
        return ok
    }
```

- [ ] **Step 4: 통과 확인**

Run: `swift test --filter AppBatchFileOpsTests && swift test --filter AppFileOpsTests`
Expected: PASS — 기존 F1a 단건 테스트 무회귀 포함.

- [ ] **Step 5: 커밋**

```bash
git add Sources/App/AppState.swift Tests/CmdMDTests/AppBatchFileOpsTests.swift
git commit -m "기능(F1b): AppState 배치 배선 — trash/move/copy·요약 확인 1회·짝꿍 동반(이름 파생)·배치 undo 탭 재조준"
```

---

### Task 7: 페이스트보드 액션 + 로컬 키 모니터 (⌘C/⌘V/⌥⌘V/⌘A/⌘⌫/⎋)

**Files:**
- Modify: `Sources/App/AppState.swift` — 배치 섹션에 액션 메서드 추가
- Modify: `Sources/App/CmdMDApp.swift` — `applicationDidFinishLaunching`(`:357`)에 로컬 모니터 설치(기존 globalMonitor 관례)
- Test: `Tests/CmdMDTests/AppPasteboardActionsTests.swift` (신규)

**Interfaces:**
- Consumes: Task 4 `FilePasteboard`, Task 5 선택 상태, Task 6 `performBatchCopy/Move`·`batchTrashWithConfirmation`, `LibraryListing.entries(of:)`·`ParaLens.sorted`(LibraryView 열거 관례).
- Produces (Task 8·10이 사용):
  - `@discardableResult func copySelectionToPasteboard(_ pasteboard: NSPasteboard = .general) -> Bool`
  - `func pasteFromPasteboard(move: Bool, into folder: URL? = nil, pasteboard: NSPasteboard = .general)` — folder nil이면 표시 폴더(`selectedFolder ?? currentFolder`)
  - `func selectAllInLibrary()`
  - `func handleFileOpsKeyEvent(_ event: NSEvent) -> Bool` — true면 소비(모니터가 nil 반환)

- [ ] **Step 1: 실패하는 테스트 작성** — `Tests/CmdMDTests/AppPasteboardActionsTests.swift` (셋업 골격은 Task 6과 동일 + 커스텀 페이스트보드):

```swift
import XCTest
@testable import CmdMD

@MainActor
final class AppPasteboardActionsTests: XCTestCase {

    private var tempData: URL!
    private var work: URL!
    private var appState: AppState!
    private var pasteboard: NSPasteboard!

    override func setUpWithError() throws {
        tempData = TempDataDirectory.make()
        work = FileManager.default.temporaryDirectory
            .appendingPathComponent("pbact-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        appState = AppState(dataDirectory: tempData)
        pasteboard = NSPasteboard(name: NSPasteboard.Name("f1b-act-\(UUID().uuidString)"))
    }

    override func tearDown() {
        pasteboard.releaseGlobally()
        TempDataDirectory.cleanup(tempData)
        try? FileManager.default.removeItem(at: work)
        tempData = nil; work = nil; appState = nil; pasteboard = nil
        super.tearDown()
    }

    private func makeFile(_ name: String) throws -> URL {
        let url = work.appendingPathComponent(name)
        try Data("본문".utf8).write(to: url)
        return url
    }

    func testCopySelectionWritesToPasteboard() throws {
        let a = try makeFile("a.md")
        appState.handleFileClick(a, modifier: .none, ordered: [a])
        XCTAssertTrue(appState.copySelectionToPasteboard(pasteboard))
        XCTAssertEqual(FilePasteboard.readFileURLs(from: pasteboard).map(\.lastPathComponent), ["a.md"])
    }

    func testCopyWithEmptySelectionReturnsFalse() {
        XCTAssertFalse(appState.copySelectionToPasteboard(pasteboard))
        XCTAssertTrue(FilePasteboard.readFileURLs(from: pasteboard).isEmpty, "빈 선택은 페이스트보드 불변")
    }

    func testPasteCopiesIntoExplicitFolder() async throws {
        let a = try makeFile("a.md")
        let dest = work.appendingPathComponent("대상")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        FilePasteboard.write([a], to: pasteboard)

        appState.pasteFromPasteboard(move: false, into: dest, pasteboard: pasteboard)
        // pasteFromPasteboard는 Task로 배치를 돌린다 — 완료 폴링(기존 async 테스트 관례).
        for _ in 0..<50 where !FileManager.default.fileExists(atPath: dest.appendingPathComponent("a.md").path) {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.appendingPathComponent("a.md").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: a.path), "복사 — 원본 불변")
    }

    func testPasteMoveMovesIntoFolder() async throws {
        let a = try makeFile("a.md")
        let dest = work.appendingPathComponent("대상")
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        FilePasteboard.write([a], to: pasteboard)

        appState.pasteFromPasteboard(move: true, into: dest, pasteboard: pasteboard)
        for _ in 0..<50 where FileManager.default.fileExists(atPath: a.path) {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.path), "이동 — 원본 사라짐")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.appendingPathComponent("a.md").path))
    }

    func testSelectAllInLibrarySelectsDisplayFolderEntries() throws {
        _ = try makeFile("a.md")
        _ = try makeFile("b.md")
        appState.currentFolder = work
        appState.mainMode = .library
        appState.selectAllInLibrary()
        XCTAssertEqual(appState.fileSelection.count, 2)
    }
}
```

- [ ] **Step 2: 실패 확인**

Run: `swift test --filter AppPasteboardActionsTests`
Expected: FAIL — "no member 'copySelectionToPasteboard'" 컴파일 에러.

- [ ] **Step 3: 구현 (1/2)** — `AppState.swift` 배치 섹션에 추가:

```swift
    // MARK: - 페이스트보드·키 액션 (F1b)

    /// 선택 항목을 페이스트보드로(⌘C) — Finder에 붙여넣기 가능. 빈 선택이면 false(이벤트 미소비).
    @discardableResult
    func copySelectionToPasteboard(_ pasteboard: NSPasteboard = .general) -> Bool {
        guard !fileSelection.isEmpty else { return false }
        FilePasteboard.write(FileSelectionHelper.ancestorsOnly(fileSelection), to: pasteboard)
        return true
    }

    /// 페이스트보드 파일을 폴더에 복사/이동 실행(⌘V/⌥⌘V) — folder nil이면 표시 폴더.
    func pasteFromPasteboard(move: Bool, into folder: URL? = nil,
                             pasteboard: NSPasteboard = .general) {
        guard let destination = folder ?? selectedFolder ?? currentFolder else { return }
        let urls = FilePasteboard.readFileURLs(from: pasteboard)
        guard !urls.isEmpty else { return }
        Task { @MainActor in
            if move {
                await self.performBatchMove(urls: urls, to: destination)
            } else {
                await self.performBatchCopy(urls: urls, to: destination)
            }
        }
    }

    /// 라이브러리 표시 폴더의 전 항목 선택(⌘A) — LibraryView 열거와 같은 규칙.
    func selectAllInLibrary() {
        guard let folder = selectedFolder ?? currentFolder else { return }
        let ordered = ParaLens.sorted(LibraryListing.entries(of: folder), under: currentFolder)
        fileSelection = Set(ordered.map(\.url))
        selectionAnchor = ordered.first?.url
    }

    /// F1b 파일 키 라우팅 — 로컬 NSEvent 모니터에서 호출. true = 소비(모니터가 nil 반환).
    /// 가드(스펙 §5): 메인 창(시트 아님) + firstResponder 비텍스트. 전역 메뉴 키 금지 원칙의 대체물.
    func handleFileOpsKeyEvent(_ event: NSEvent) -> Bool {
        guard let window = NSApp.keyWindow, window.canBecomeMain else { return false }
        if window.firstResponder is NSText { return false }   // NSTextView 포함(필드 에디터도)

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // String?를 switch 리터럴 패턴에 직접 매칭할 수 없다 — 빈 문자열로 언랩.
        let key = event.charactersIgnoringModifiers?.lowercased() ?? ""

        // ⎋ 선택 해제
        if event.keyCode == 53, flags.isEmpty, !fileSelection.isEmpty {
            clearFileSelection()
            return true
        }
        // ⌘⌫ 휴지통(요약 확인 경유)
        if event.keyCode == 51, flags == .command, !fileSelection.isEmpty {
            batchTrashWithConfirmation(Array(fileSelection))
            return true
        }
        switch (key, flags) {
        case ("c", [.command]):
            return copySelectionToPasteboard()
        case ("v", [.command]):
            guard mainMode == .library, !FilePasteboard.readFileURLs().isEmpty else { return false }
            pasteFromPasteboard(move: false)
            return true
        case ("v", [.command, .option]):
            guard mainMode == .library, !FilePasteboard.readFileURLs().isEmpty else { return false }
            pasteFromPasteboard(move: true)
            return true
        case ("a", [.command]):
            guard mainMode == .library else { return false }
            selectAllInLibrary()
            return true
        default:
            return false
        }
    }
```

- [ ] **Step 4: 구현 (2/2)** — `CmdMDApp.swift` `applicationDidFinishLaunching`(`:357`)에 모니터 설치(globalMonitor 선언 옆에 `private var fileOpsMonitor: Any?` 추가):

```swift
        // F1b 파일 작업 키(⌘C/⌘V/⌥⌘V/⌘A/⌘⌫/⎋) — 로컬 모니터 + AppState 가드.
        // 전역 메뉴 .keyboardShortcut은 에디터의 시스템 복사/붙여넣기를 강탈하므로 금지(스펙 §5).
        fileOpsMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if AppState.shared?.handleFileOpsKeyEvent(event) == true { return nil }
            return event
        }
```

- [ ] **Step 5: 통과 확인**

Run: `swift test --filter AppPasteboardActionsTests && swift build`
Expected: 테스트 PASS + 빌드 경고 0.

- [ ] **Step 6: 커밋**

```bash
git add Sources/App/AppState.swift Sources/App/CmdMDApp.swift Tests/CmdMDTests/AppPasteboardActionsTests.swift
git commit -m "기능(F1b): ⌘C/⌘V/⌥⌘V/⌘A/⌘⌫/⎋ — 페이스트보드 액션 + 로컬 키 모니터(에디터 비강탈 가드)"
```

---

### Task 8: LibraryView — Finder식 클릭·하이라이트·헤더 캡션

**Files:**
- Modify: `Sources/Views/LibraryView.swift` — `handleTap`(`:144`) 교체, 셀 제스처(`:113-137`), 헤더(`:51`), 셀 하이라이트(`:171-310`)
- Test: 없음(클릭 로직은 Task 5 리졸버 테스트가 커버 — 이 태스크는 뷰 배선만). 검증 = `swift build` + 수동 스모크(Task 12 체크리스트).

**Interfaces:**
- Consumes: Task 5 `handleFileClick`/`clearFileSelection`/`fileSelection`, `SelectionModifier`.
- Produces: 없음(뷰 내부).

- [ ] **Step 1: 클릭 배선 교체** — `handleTap`을 삭제하고 두 핸들러로:

```swift
    // MARK: - 클릭 처리 (F1b — Finder식: 클릭=선택, 더블클릭=열기/드릴인)

    private func handleClick(item: FileTreeItem) {
        let flags = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let modifier: SelectionModifier = flags.contains(.command) ? .command
            : (flags.contains(.shift) ? .shift : .none)
        appState.handleFileClick(item.url, modifier: modifier, ordered: entries.map(\.url))
    }

    private func handleDoubleClick(item: FileTreeItem) {
        if item.isDirectory {
            // 폴더 → 드릴인(selectedFolder didSet이 선택을 클리어)
            appState.selectedFolder = item.url
        } else {
            // 파일 → 리더 전환 (openDocument 내부에서 mainMode = .reader 설정)
            appState.openDocument(at: item.url, inNewTab: true)
        }
    }
```

그리드 셀(`:113-119`) — count:2를 먼저 선언(단일탭이 첫 탭에서 선택으로 발화해도 무해 — Finder도 mousedown 선택 후 열기):

```swift
                ForEach(entries, id: \.url) { item in
                    LibraryGridCell(item: item, isSelected: appState.fileSelection.contains(item.url))
                        .onTapGesture(count: 2) { handleDoubleClick(item: item) }
                        .onTapGesture { handleClick(item: item) }
                        .contextMenu { LibraryCellContextMenu(item: item) }
                }
```

리스트 셀(`:130-137`)도 동일 패턴:

```swift
                ForEach(entries, id: \.url) { item in
                    LibraryListCell(item: item, isSelected: appState.fileSelection.contains(item.url))
                        .onTapGesture(count: 2) { handleDoubleClick(item: item) }
                        .onTapGesture { handleClick(item: item) }
                        .contextMenu { LibraryCellContextMenu(item: item) }
                        .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
                }
```

- [ ] **Step 2: 배경 클릭 해제** — gridView의 ScrollView와 listView의 List에(셀 제스처가 자식이라 우선하므로 빈 영역만 잡힌다):

```swift
        // gridView: ScrollView { ... } 뒤에
        .onTapGesture { appState.clearFileSelection() }
        // listView: List { ... }.listStyle(.plain) 뒤에
        .onTapGesture { appState.clearFileSelection() }
```

- [ ] **Step 3: 셀 하이라이트** — `LibraryGridCell`·`LibraryListCell`에 `let isSelected: Bool` 프로퍼티 추가 — **`let item` 바로 다음 줄에 선언**(멤버와이즈 init 순서가 호출부 `(item:isSelected:)`와 일치해야 함). 그리드 셀 body의 `.padding(8)` 체인에:

```swift
        .padding(8)
        .frame(maxWidth: .infinity)
        // fill 뒤엔 View라 strokeBorder 체인 불가 — 배경(fill)과 테두리(overlay)를 분리한다.
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.cmdsAccent.opacity(0.15) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isSelected ? Color.cmdsAccent : Color.clear, lineWidth: 1)
        )
        .opacity(paraCategory == .archive ? 0.45 : 1.0)   // 기존 줄 유지 — 선택 배경도 함께 dim(항목 스타일 일관)
```

리스트 셀 body의 `.opacity(...)` 앞에:

```swift
        .background(isSelected ? Color.cmdsAccent.opacity(0.15) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 4))
```

- [ ] **Step 4: 헤더 캡션** — `libraryHeader`의 `Spacer()` 앞에:

```swift
            if !appState.fileSelection.isEmpty {
                Text("\(appState.fileSelection.count)개 선택됨")
                    .font(.caption)
                    .foregroundStyle(Color.cmdsAccent)
            }
```

파일 상단 doc 주석 "읽기·탐색 전용 — 파일 이동·삭제 없음."을 "F1b: 다중 선택 + 배치 파일 작업 진입점(컨텍스트 메뉴·키)."로 갱신.

- [ ] **Step 5: 빌드 확인 + 커밋**

Run: `swift build 2>&1 | tail -5` — 경고 0 확인. (클릭 동작 실검증은 Task 12 스모크.)

```bash
git add Sources/Views/LibraryView.swift
git commit -m "기능(F1b): 라이브러리 Finder식 클릭 — 클릭=선택/더블클릭=열기·⌘⇧ 수식키·하이라이트·선택 캡션·배경 해제"
```

---

### Task 9: 트리 ⌘클릭 토글 + 하이라이트

**Files:**
- Modify: `Sources/Views/SidebarView.swift` — `FileTreeItemRow`의 폴더 라벨 탭(`:390-392`)·파일 탭(`:416-418`)·`labelRow`(`:427`)
- Test: 없음(토글 로직은 Task 5가 커버). 검증 = `swift build` + 수동 스모크.

**Interfaces:**
- Consumes: Task 5 `toggleFileSelection`/`clearFileSelection`/`fileSelection`.
- Produces: 없음.

- [ ] **Step 1: 탭 핸들러 분기** — 폴더 라벨 탭(`:390-392`):

```swift
                        .onTapGesture {
                            // ⌘클릭 = 선택 토글만(모드 전환 없음, F1b 스펙 §3.2)
                            if NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command) {
                                appState.toggleFileSelection(item.url)
                            } else {
                                appState.clearFileSelection()
                                appState.selectFolderForLibrary(item.url)
                            }
                        }
```

파일 행 탭(`:416-418`):

```swift
                .onTapGesture {
                    if NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command) {
                        appState.toggleFileSelection(item.url)
                    } else {
                        appState.clearFileSelection()
                        appState.openDocument(at: item.url, inNewTab: true)
                    }
                }
```

(chevron 버튼은 그대로 — ⌘클릭이 떨어져도 펼침만, 스펙 §3.2.)

- [ ] **Step 2: 하이라이트** — `labelRow`(`:427`)의 `.opacity(...)` 뒤에(자식 행은 List 행이 아니라 수동 배경):

```swift
        .padding(.horizontal, 2)
        .background(appState.fileSelection.contains(item.url)
                    ? Color.cmdsAccent.opacity(0.18) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 4))
```

- [ ] **Step 3: 빌드 확인 + 커밋**

Run: `swift build 2>&1 | tail -5` — 경고 0.

```bash
git add Sources/Views/SidebarView.swift
git commit -m "기능(F1b): 트리 ⌘클릭 선택 토글 + 수동 하이라이트(일반 클릭은 기존 동작+선택 해제)"
```

---

### Task 10: 선택 인지 컨텍스트 메뉴 + 이동 패널

**Files:**
- Create: `Sources/Views/BatchSelectionMenu.swift`
- Modify: `Sources/Views/LibraryView.swift` — `LibraryCellContextMenu`(`:315-344`)
- Modify: `Sources/Views/SidebarView.swift` — `FileTreeContextMenu`(`:464-541`)
- Modify: `Sources/App/AppState.swift` — `promptBatchMove` 추가(배치 섹션)
- Test: 없음(메뉴는 뷰 선언 — 액션은 Task 6·7 테스트가 커버). 검증 = `swift build` + 수동 스모크.

**Interfaces:**
- Consumes: Task 5~7의 `fileSelection`/`copySelectionToPasteboard`/`pasteFromPasteboard`/`batchTrashWithConfirmation`/`performBatchMove`, Task 4 `FilePasteboard.readFileURLs`.
- Produces: `struct BatchSelectionMenu: View`, `AppState.promptBatchMove(urls: [URL]? = nil)`.

- [ ] **Step 1: AppState.promptBatchMove** — 배치 섹션에 추가(NSOpenPanel이 확인 역할 — 별도 모달 없음, 스펙 §4.3):

```swift
    /// "폴더로 이동…" — NSOpenPanel(디렉터리 선택)이 확인 역할. urls nil이면 현재 선택.
    func promptBatchMove(urls: [URL]? = nil) {
        let targets = urls ?? Array(fileSelection)
        guard !targets.isEmpty else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "이동"
        panel.message = "\(targets.count)개 항목을 이동할 폴더를 선택하세요"
        panel.directoryURL = selectedFolder ?? currentFolder
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        Task { @MainActor in await self.performBatchMove(urls: targets, to: destination) }
    }
```

- [ ] **Step 2: BatchSelectionMenu** — `Sources/Views/BatchSelectionMenu.swift` 신규:

```swift
import SwiftUI

/// 다중 선택 배치 메뉴 — 우클릭 셀이 선택 집합에 포함되고 2개 이상일 때 단건 메뉴를 대체.
/// 라이브러리 셀·트리 행 공용(F1b 스펙 §7).
struct BatchSelectionMenu: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        let count = appState.fileSelection.count
        Button {
            _ = appState.copySelectionToPasteboard()
        } label: {
            Label("\(count)개 항목 복사", systemImage: "doc.on.doc")
        }
        Button {
            appState.promptBatchMove()
        } label: {
            Label("\(count)개 항목 폴더로 이동…", systemImage: "folder")
        }
        Divider()
        Button(role: .destructive) {
            appState.batchTrashWithConfirmation(Array(appState.fileSelection))
        } label: {
            Label("\(count)개 항목 휴지통으로 이동", systemImage: "trash")
        }
    }
}
```

- [ ] **Step 3: LibraryCellContextMenu 분기** — body를 감싼다(기존 단건 항목은 그대로 두고 분기만 추가). 선택 밖 셀 우클릭은 단건 메뉴(Finder식 선택 교체는 SwiftUI contextMenu 한계로 생략 — 스펙 §7 문서화):

```swift
    var body: some View {
        if appState.fileSelection.count > 1 && appState.fileSelection.contains(item.url) {
            BatchSelectionMenu()
        } else {
            singleItemMenu
        }
    }

    @ViewBuilder
    private var singleItemMenu: some View {
        // ← 기존 body 내용 전부 이동(이름 변경…/정보 보기/이 안에 새 폴더/휴지통)
        //    그리고 폴더 분기의 "이 안에 새 폴더" 아래에 붙여넣기 항목 추가:
        if item.isDirectory && !FilePasteboard.readFileURLs().isEmpty {
            Button {
                appState.pasteFromPasteboard(move: false, into: item.url)
            } label: {
                Label("이 폴더에 붙여넣기", systemImage: "doc.on.clipboard")
            }
        }
    }
```

- [ ] **Step 4: FileTreeContextMenu 분기** — 같은 패턴(`:472` body를 분기로 감싸고 기존 내용을 `singleItemMenu`로 이동, 폴더 분기의 New Folder 아래에 같은 "이 폴더에 붙여넣기" 항목 추가).

- [ ] **Step 5: 빌드 확인 + 커밋**

Run: `swift build 2>&1 | tail -5` — 경고 0.

```bash
git add Sources/Views/BatchSelectionMenu.swift Sources/Views/LibraryView.swift Sources/Views/SidebarView.swift Sources/App/AppState.swift
git commit -m "기능(F1b): 선택 인지 컨텍스트 메뉴(배치 3종)·폴더에 붙여넣기·폴더로 이동 패널"
```

---

### Task 11: FileOpsHistoryView — 배치 그룹 행

**Files:**
- Modify: `Sources/Views/FileOpsHistoryView.swift` (93줄)
- Test: `Tests/CmdMDTests/FileOpsHistoryGroupingTests.swift` (신규 — 그룹핑 순수 함수만)

**Interfaces:**
- Consumes: Task 2 `FileOpEntry.batchId`, Task 6 `undoFileOpBatch(batchId:)`, 기존 `undoFileOp`.
- Produces: `enum FileOpsHistoryGrouping { static func rows(_ entries: [FileOpEntry]) -> [Row] }` — 뷰 파일 안에 선언(테스트 접근 가능한 internal).

- [ ] **Step 1: 실패하는 테스트 작성** — `Tests/CmdMDTests/FileOpsHistoryGroupingTests.swift`:

```swift
import XCTest
@testable import CmdMD

final class FileOpsHistoryGroupingTests: XCTestCase {

    private func entry(_ kind: FileOpKind, _ name: String, batchId: UUID? = nil) -> FileOpEntry {
        FileOpEntry(kind: kind,
                    originalURL: URL(fileURLWithPath: "/tmp/\(name)"),
                    resultURL: URL(fileURLWithPath: "/tmp/dest/\(name)"),
                    batchId: batchId)
    }

    func testSinglesStaySingle() {
        let a = entry(.rename, "a.md")
        let rows = FileOpsHistoryGrouping.rows([a])
        guard case .single(let e) = rows[0] else { return XCTFail() }
        XCTAssertEqual(e.id, a.id)
    }

    func testBatchEntriesCollapseToOneRowAtFirstPosition() {
        let batchId = UUID()
        let single = entry(.trash, "s.md")
        let b1 = entry(.move, "1.md", batchId: batchId)
        let b2 = entry(.move, "2.md", batchId: batchId)
        let rows = FileOpsHistoryGrouping.rows([b1, single, b2])
        XCTAssertEqual(rows.count, 2)
        guard case .batch(let id, let members) = rows[0] else { return XCTFail("배치가 첫 위치") }
        XCTAssertEqual(id, batchId)
        XCTAssertEqual(members.map(\.id), [b1.id, b2.id])
        guard case .single = rows[1] else { return XCTFail() }
    }

    func testDifferentBatchesStaySeparate() {
        let b1 = entry(.move, "1.md", batchId: UUID())
        let b2 = entry(.copy, "2.md", batchId: UUID())
        XCTAssertEqual(FileOpsHistoryGrouping.rows([b1, b2]).count, 2)
    }
}
```

- [ ] **Step 2: 실패 확인**

Run: `swift test --filter FileOpsHistoryGroupingTests`
Expected: FAIL — "cannot find 'FileOpsHistoryGrouping'" 컴파일 에러.

- [ ] **Step 3: 구현** — `FileOpsHistoryView.swift`에 그룹핑 타입 추가 + 뷰 개편:

```swift
/// 기록 행 그룹핑 — batchId가 같은 엔트리를 첫 등장 위치에서 한 행으로 묶는다(순수).
enum FileOpsHistoryGrouping {
    enum Row: Identifiable {
        case single(FileOpEntry)
        case batch(id: UUID, entries: [FileOpEntry])

        var id: UUID {
            switch self {
            case .single(let entry): return entry.id
            case .batch(let id, _): return id
            }
        }
    }

    static func rows(_ entries: [FileOpEntry]) -> [Row] {
        var rows: [Row] = []
        var seenBatches = Set<UUID>()
        for entry in entries {
            guard let batchId = entry.batchId else {
                rows.append(.single(entry)); continue
            }
            guard !seenBatches.contains(batchId) else { continue }
            seenBatches.insert(batchId)
            rows.append(.batch(id: batchId, entries: entries.filter { $0.batchId == batchId }))
        }
        return rows
    }
}
```

뷰 수정 — `content`의 `ForEach(entries.reversed())`를 그룹 행으로:

```swift
            List {
                // 최근 작업이 위로
                ForEach(FileOpsHistoryGrouping.rows(entries).reversed()) { row in
                    switch row {
                    case .single(let entry): singleRow(entry)
                    case .batch(let id, let members): batchRow(id: id, members: members)
                    }
                }
            }
            .listStyle(.plain)
```

기존 `row(_:)`는 `singleRow(_:)`로 개명하고, `rowTitle`·아이콘 switch에 `.move`/`.copy` 케이스 추가(exhaustive라 컴파일이 강제함):

```swift
    private func rowTitle(_ entry: FileOpEntry) -> String {
        switch entry.kind {
        case .trash:
            return "휴지통: \(entry.originalURL.lastPathComponent)"
        case .rename:
            return "이름 변경: \(entry.originalURL.lastPathComponent) → \(entry.resultURL.lastPathComponent)"
        case .move:
            return "이동: \(entry.originalURL.lastPathComponent) → \(entry.resultURL.deletingLastPathComponent().lastPathComponent)/"
        case .copy:
            return "복사: \(entry.originalURL.lastPathComponent)"
        }
    }

    private func kindIcon(_ kind: FileOpKind) -> String {
        switch kind {
        case .trash: return "trash"
        case .rename: return "pencil"
        case .move: return "folder"
        case .copy: return "doc.on.doc"
        }
    }

    private func kindLabel(_ kind: FileOpKind) -> String {
        switch kind {
        case .trash: return "휴지통"
        case .rename: return "이름 변경"
        case .move: return "이동"
        case .copy: return "복사"
        }
    }
```

(`singleRow`의 기존 아이콘 삼항 `entry.kind == .trash ? "trash" : "pencil"`도 `kindIcon(entry.kind)`으로 교체.)

배치 행 — 되돌리기 1버튼(`undoFileOpBatch`), 부분 실패 시 남은 엔트리로 재시도 가능:

```swift
    @ViewBuilder
    private func batchRow(id: UUID, members: [FileOpEntry]) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "square.stack")
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text("\(kindLabel(members.first?.kind ?? .move)) \(members.count)건")
                    .lineLimit(1)
                Text(members.first?.date.formatted(.dateTime.month().day().hour().minute()) ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if failedBatchIds.contains(id) {
                    Text("일부를 되돌리지 못했습니다 — 남은 항목으로 다시 시도할 수 있습니다.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            Spacer()
            Button("모두 되돌리기") {
                Task { @MainActor in
                    if await appState.undoFileOpBatch(batchId: id) {
                        failedBatchIds.remove(id)
                    } else {
                        failedBatchIds.insert(id)
                    }
                    await reload()
                }
            }
        }
        .padding(.vertical, 2)
    }
```

상태 추가: `@State private var failedBatchIds: Set<UUID> = []`. 파일 상단 doc 주석의 "휴지통/이름변경 목록"을 "휴지통/이름변경/이동/복사 목록(배치는 한 행)"으로 갱신.

- [ ] **Step 4: 통과 확인**

Run: `swift test --filter FileOpsHistoryGroupingTests && swift build 2>&1 | tail -3`
Expected: PASS + 경고 0.

- [ ] **Step 5: 커밋**

```bash
git add Sources/Views/FileOpsHistoryView.swift Tests/CmdMDTests/FileOpsHistoryGroupingTests.swift
git commit -m "기능(F1b): 파일 작업 기록 배치 그룹 행 — 모두 되돌리기·부분 실패 재시도·move/copy 표기"
```

---

### Task 12: 전체 게이트 + 수동 스모크 체크리스트

**Files:**
- Modify: 없음(수정은 발견된 결함만).

- [ ] **Step 1: 전체 테스트**

Run: `swift test 2>&1 | tail -5`
Expected: 전부 PASS(F1a 기준 454 + 신규 ≈30). 실패 시 원인 수정 후 재실행(수정은 별도 커밋).

- [ ] **Step 2: 릴리스 빌드 확인**

Run: `swift build 2>&1 | grep -i warning | wc -l`
Expected: `0`.

- [ ] **Step 3: 수동 스모크 체크리스트 기록** — 아래를 최종 보고에 포함(실행은 사용자/후속 세션):

1. 라이브러리 클릭=선택(하이라이트)·더블클릭=열기/드릴인·⌘토글·⇧범위·배경 클릭 해제·"N개 선택됨" 캡션.
2. 트리 ⌘클릭 토글(모드 전환 없음)·일반 클릭 기존 동작·하이라이트가 archive dim과 공존.
3. ⌘C→Finder ⌘V(앱→Finder), Finder ⌘C→앱 ⌘V(수신), ⌥⌘V 이동, ⌘A, ⌘⌫(요약 확인 1회), ⎋ 해제.
4. **키 가드**: 에디터 포커스에서 ⌘C/⌘V/⌘A/⌘⌫가 텍스트 편집으로 동작(강탈 없음), 커맨드 팔레트·시트 열림 중 무발동.
5. 선택 포함 셀 우클릭=배치 메뉴/밖 셀=단건 메뉴, 폴더 셀 "이 폴더에 붙여넣기", "폴더로 이동…" 패널.
6. 미디어+짝꿍 노트 배치 이동(노트 동반·배지 유지), 기록 시트 "모두 되돌리기"(탭 재조준 확인).
7. PDF 텍스트 선택 중 ⌘C — 트리 선택이 남아 있으면 파일 복사가 우선(문서화된 엣지) 체감 확인.

- [ ] **Step 4: 최종 커밋(잔여 수정이 있었다면)**

```bash
git status --short  # 깨끗하면 생략
```

---

## Self-Review 결과 (계획 작성 후 점검)

- 스펙 커버리지: §2 선택 모델=Task 3·5, §3 클릭=Task 8·9, §4 연산·로그·배치=Task 1·2·6, §5 키=Task 7, §6 페이스트보드=Task 4, §7 메뉴·패널=Task 10, §8 기록=Task 11, §9 정합=Task 5·6, §10 테스트=각 태스크+Task 12. 누락 없음.
- 스펙과 의도된 편차 2건(둘 다 강화): ①`undoBatch`가 Int 카운트 대신 엔트리 배열 반환(AppState 탭 재조준에 필요 — Task 2에 명시) ②copy에도 자기 하위 복사 가드(FileManager 재귀 복사 중 무한/부분 복사 위험 차단 — Task 1).
- 타입 일관성: `SelectionModifier`·`FileSelectionHelper`·`FilePasteboard`·`performBatch*` 시그니처가 Task 간 동일함을 교차 확인.


