# F1a 파일 작업 기반 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 단일 항목의 이름 변경·새 폴더·휴지통 이동(작업 로그+앱 내 되돌리기)과 파일 정보 보기(⌥⌘I 시트 + 라이브러리 리스트 크기·수정일 열)를 트리·라이브러리에 배선한다.

**Architecture:** 순수 서비스 3개(`FileOperations`·`FileOpsLogStore`·`FileInfoService`)를 먼저 TDD로 만들고, `AppState`가 오케스트레이션(로그·열린 탭 정합·짝꿍 노트 동반·세대 토큰) 후 UI(컨텍스트 메뉴·시트 3종·리스트 열)를 가산한다. 기존 `MoveLogStore`/`uniquified()`/`closeTab`/NSAlert 관례를 미러링하고, 기존 트리 우클릭의 무로그 `Move to Trash`를 확인+로그 경로로 대체한다.

**Tech Stack:** Swift/SwiftUI, AppKit(NSAlert), FileManager(trashItem), ImageIO·PDFKit·AVFoundation(정보 한 줄 — 전부 시스템), XCTest(임시 디렉터리 + `AppState(dataDirectory:)` 주입 관례).

**Spec:** `docs/superpowers/specs/2026-07-03-f1a-file-operations-design.md` (상위: `2026-07-03-finder-replacement-roadmap.md`)

## Global Constraints

- **영구 삭제 없음** — 삭제는 `FileManager.trashItem` 휴지통 이동만(로드맵 확정). 휴지통 비우기 기능 금지.
- **제안→확인→실행** — 휴지통은 NSAlert 확인 1회 후 실행. rename·새 폴더는 사용자가 직접 시작한 명시 동작이라 확인 없음.
- **덮어쓰기 금지** — rename 충돌은 에러(사용자 지정 이름 — uniquify 아님), 새 폴더는 `uniquified()`, undo 충돌은 실패+로그 보존.
- 다중 선택·배치·복사/붙여넣기·드래그는 범위 밖(F1b·F2). 리스트 열 헤더 정렬은 F3.
- 코드 주석·커밋 메시지는 한국어. '박다/박는다/박았다' 류 표현 금지. 커밋은 태스크마다.
- 새 패키지 의존성 0. 신규 기능은 별도 파일로(업스트림 머지 용이).
- Phase 게이트: 현 스위트 406개(XCTest 388+Testing 18) 유지+신규. `swift test`는 정식 Xcode 필요.
- 테스트에서 실제 휴지통을 쓰는 경우 임시 파일만 사용하고, 휴지통 접근 불가 환경이면 `XCTSkip`.

## 확인된 코드 사실 (전 태스크 공통 — 정찰로 검증됨)

- `EditorTab`(Sources/Models/Workspace.swift:40): `id: UUID`(let)·`documentId: UUID`·`fileURL: URL?`·`title: String`·`isPinned`. 커스텀 `init(from:)`이 있어 멤버와이즈 init 없음 — 테스트는 `appState.createNewTab()` 후 `tabs[0].fileURL` 직접 대입으로 구성.
- `documents: [UUID: MarkdownDocument]`(AppState.swift:17) — 키는 **documentId**. `MarkdownDocument.fileURL`도 var — rename 시 `tab.fileURL`과 둘 다 갱신 필요.
- `closeTab(_:)`(AppState.swift:1635)은 더티 체크 없이 닫고 워처·문서·미디어 플레이어 정리 후 `saveSession()` — trash 경로에서 그대로 재사용.
- 파일 워처: `startWatchingFile(at:for:)`(AppState.swift:1059, private)·`stopWatchingFile(for:)`(:1083) — rename 후 재장전 필요.
- `loadFileTree()`(AppState.swift:1311)는 백그라운드 리빌드, 주석이 이미 "이름변경 시 호출"을 상정.
- **세대 토큰류 카운터는 현재 없음** — `LibraryView.folderKey`(LibraryView.swift:16-18)는 폴더 경로 문자열뿐이라 같은 폴더 내 변경은 재열거 트리거가 없음(검증된 사실 — Task 5·6이 해결).
- `FileTreeItem`(Workspace.swift:120-167): Hashable/==는 id만 비교, 모든 init 파라미터에 기본값 — 옵셔널 필드 추가 시 기존 생성 지점 4곳(AppState.swift:1362·1368, LibraryListing.swift:29·34) 무수정 호환.
- `FileTreeContextMenu`(SidebarView.swift:464-561): 이미 "Move to Trash" 존재(`try?` trashItem, 확인·로그·탭정리 없음 — **대체 대상**). 배선은 private 메서드→`appState` 직접 호출.
- 라이브러리 셀(LibraryView.swift): 그리드 `ForEach(entries, id: \.url)`+`.onTapGesture`(:110-121), 리스트 `List(.plain)`(:126-138) — 셀 컨텍스트 메뉴 없음(신설 자리 = onTapGesture와 같은 층).
- 시트 관례: 페이로드 있는 시트는 `.sheet(item: $state.xxx)` + Identifiable request 구조체(officeFillSession 선례, AppState.swift:2544). 새 `.sheet`는 ContentView.swift :110-112(`showFolderCleanup`) 뒤, `.alert` :113 앞에 삽입.
- NSAlert 관례: `closeAllTabs()`(AppState.swift:1725-1765) — AppState 메서드 안에서 `runModal()` 동기 분기, 후속은 `Task { @MainActor in }`, 부분 실패는 `showToast`.
- `MoveLogStore`(Sources/Services/MoveLogStore.swift): actor + JSON 원자적 write — `FileOpsLogStore`가 미러링할 패턴. AppState init(:694)에서 `MoveLogStore(directory: appDir)` 주입 선례.
- `uniquified()`(AppState.swift:2571-2589): `extension URL`, 충돌 시 `" (1)"` 접미.
- `AppShortcut`(Sources/Models/Shortcuts.swift:70-92 케이스, :123-148 defaultBinding): 새 케이스 추가 시 `ShortcutDefaultsTests.testDefaultBindingsAreUnique`(allCases 전수)에 자동 포함. `KeyBinding.displayString`(:41) 존재.
- **⌥⌘I는 실바인딩 미사용**(⌘I는 Format Italic, CmdMDApp.swift:226). 단 `CommandPaletteView.swift:406` "Toggle Inspector" 항목에 **스테일 표시 문자열 "⌥⌘I"** 가 있음(실제 기본값은 ⌃⌘→) — Task 7에서 정정.
- `CompanionNote.noteURL(for:)` = `mediaURL.appendingPathExtension("md")` — rename 동반 시 새 노트 이름은 `noteURL(for: 새미디어URL)`.
- `DocumentKind`(Sources/Models/DocumentKind.swift): case markdown/image/pdf/office/media, `init(from: URL)`, `isVideo(_:)`. **한국어 라벨 없음** — Task 3에서 FileInfoService에 추가(모델 오염 없이).
- 날짜 표기 관례: `.formatted(.dateTime.month().day().hour().minute())`(InspectorView.swift:230). **ByteCountFormatter 사용처 없음** — Task 3에서 도입.
- 테스트 픽스처 관례: WAV 실생성(MediaMetadataServiceTests), PDF 실생성(ContentExtractorTests:30-39 — `PDFDocument`+`NSBitmapImageRep`). PNG 실생성 선례는 없음 — 같은 `NSBitmapImageRep`→`representation(using: .png)`로 생성.
- `TempDataDirectory`(Tests/CmdMDTests/TempDataDirectory.swift): `make()`/`cleanup(_:)` — App* 테스트 격리 관례.

---

### Task 1: `FileOperations` 서비스 + `FileOperationError`

**Files:**
- Create: `Sources/Services/FileOperations.swift`
- Test: `Tests/CmdMDTests/FileOperationsTests.swift` (신규)

**Interfaces:**
- Consumes: `URL.uniquified()`(AppState.swift:2571 — 같은 모듈이라 그대로 사용 가능).
- Produces: `FileOperations.rename(at:to:) throws -> URL`, `FileOperations.createFolder(in:name:) throws -> URL`(기본 이름 "새 폴더"), `FileOperations.trash(at:) throws -> URL`(휴지통 내 실제 위치 반환), `FileOperationError`(LocalizedError·Equatable — case emptyName/invalidName/sameName/alreadyExists(String)/sourceMissing/failed(String), 전부 한국어 errorDescription). Task 2·5·6이 사용.

- [ ] **Step 1: 실패하는 테스트 작성**

`Tests/CmdMDTests/FileOperationsTests.swift` 신규. 서비스 테스트라 AppState 불필요 — MoveLogStoreTests처럼 파일 내 private 임시 디렉터리 헬퍼 사용.

```swift
import XCTest
@testable import CmdMD

final class FileOperationsTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fileops-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        dir = nil
        super.tearDown()
    }

    private func makeFile(_ name: String, contents: String = "본문") throws -> URL {
        let url = dir.appendingPathComponent(name)
        try contents.data(using: .utf8)!.write(to: url)
        return url
    }

    // MARK: rename

    func testRenameFileSuccess() throws {
        let src = try makeFile("원본.md")
        let result = try FileOperations.rename(at: src, to: "새이름.md")
        XCTAssertEqual(result, dir.appendingPathComponent("새이름.md"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: src.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.path))
    }

    func testRenameFolderSuccess() throws {
        let src = dir.appendingPathComponent("폴더A")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        let result = try FileOperations.rename(at: src, to: "폴더B")
        XCTAssertTrue(FileManager.default.fileExists(atPath: result.path))
        XCTAssertEqual(result.lastPathComponent, "폴더B")
    }

    func testRenameRejectsEmptyOrWhitespaceName() throws {
        let src = try makeFile("a.md")
        XCTAssertThrowsError(try FileOperations.rename(at: src, to: "")) {
            XCTAssertEqual($0 as? FileOperationError, .emptyName)
        }
        XCTAssertThrowsError(try FileOperations.rename(at: src, to: "   ")) {
            XCTAssertEqual($0 as? FileOperationError, .emptyName)
        }
    }

    func testRenameRejectsSlash() throws {
        let src = try makeFile("a.md")
        XCTAssertThrowsError(try FileOperations.rename(at: src, to: "b/c.md")) {
            XCTAssertEqual($0 as? FileOperationError, .invalidName)
        }
    }

    func testRenameRejectsSameName() throws {
        let src = try makeFile("a.md")
        XCTAssertThrowsError(try FileOperations.rename(at: src, to: "a.md")) {
            XCTAssertEqual($0 as? FileOperationError, .sameName)
        }
    }

    func testRenameRejectsExistingTarget() throws {
        let src = try makeFile("a.md")
        _ = try makeFile("b.md")
        XCTAssertThrowsError(try FileOperations.rename(at: src, to: "b.md")) {
            XCTAssertEqual($0 as? FileOperationError, .alreadyExists("b.md"))
        }
        // 실패 시 원본 불변
        XCTAssertTrue(FileManager.default.fileExists(atPath: src.path))
    }

    func testRenameAllowsCaseOnlyChange() throws {
        // APFS 기본(대소문자 무시)에서 fileExists("A.md")가 true라도 대소문자만 다른 rename은 허용.
        let src = try makeFile("a.md")
        let result = try FileOperations.rename(at: src, to: "A.md")
        XCTAssertEqual(result.lastPathComponent, "A.md")
    }

    func testRenameMissingSource() {
        let ghost = dir.appendingPathComponent("없음.md")
        XCTAssertThrowsError(try FileOperations.rename(at: ghost, to: "x.md")) {
            XCTAssertEqual($0 as? FileOperationError, .sourceMissing)
        }
    }

    // MARK: createFolder

    func testCreateFolderDefaultName() throws {
        let created = try FileOperations.createFolder(in: dir)
        XCTAssertEqual(created.lastPathComponent, "새 폴더")
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: created.path, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue)
    }

    func testCreateFolderUniquifiesOnConflict() throws {
        _ = try FileOperations.createFolder(in: dir)
        let second = try FileOperations.createFolder(in: dir)
        XCTAssertEqual(second.lastPathComponent, "새 폴더 (1)")
    }

    // MARK: trash

    func testTrashMovesToTrashAndReturnsLocation() throws {
        let src = try makeFile("버릴것.md")
        let trashed: URL
        do {
            trashed = try FileOperations.trash(at: src)
        } catch {
            throw XCTSkip("휴지통 접근 불가 환경: \(error)")
        }
        defer { try? FileManager.default.removeItem(at: trashed) }   // 테스트 자체 픽스처 정리
        XCTAssertFalse(FileManager.default.fileExists(atPath: src.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: trashed.path))
    }

    func testTrashMissingSource() {
        let ghost = dir.appendingPathComponent("없음.md")
        XCTAssertThrowsError(try FileOperations.trash(at: ghost)) {
            XCTAssertEqual($0 as? FileOperationError, .sourceMissing)
        }
    }
}
```

- [ ] **Step 2: 실패 확인**

Run: `swift test --filter FileOperationsTests 2>&1 | tail -5`
Expected: 컴파일 실패 — `cannot find 'FileOperations' in scope`.

- [ ] **Step 3: 구현**

`Sources/Services/FileOperations.swift` 신규:

```swift
import Foundation

/// 파일 작업 실패 — 사용자에게 그대로 보일 한국어 메시지를 가진다.
enum FileOperationError: LocalizedError, Equatable {
    case emptyName
    case invalidName
    case sameName
    case alreadyExists(String)
    case sourceMissing
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .emptyName: return "이름을 입력하세요."
        case .invalidName: return "이름에 '/' 문자를 쓸 수 없습니다."
        case .sameName: return "기존 이름과 같습니다."
        case .alreadyExists(let name): return "같은 위치에 '\(name)'이(가) 이미 있습니다."
        case .sourceMissing: return "원본을 찾을 수 없습니다. 이동되었거나 삭제된 항목일 수 있습니다."
        case .failed(let message): return "작업에 실패했습니다: \(message)"
        }
    }
}

/// 단일 항목 파일 작업(F1a) — FileManager 기반 동기 함수. 영구 삭제 없음(휴지통 이동만).
enum FileOperations {

    /// 같은 디렉터리 안에서 이름을 바꾼다. `newName`은 확장자 포함 전체 파일명.
    /// 대상 이름이 이미 있으면 에러 — 사용자 지정 이름이므로 uniquify하지 않고 덮어쓰지도 않는다.
    static func rename(at url: URL, to newName: String) throws -> URL {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw FileOperationError.emptyName }
        guard !trimmed.contains("/") else { throw FileOperationError.invalidName }
        guard trimmed != url.lastPathComponent else { throw FileOperationError.sameName }

        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { throw FileOperationError.sourceMissing }

        let target = url.deletingLastPathComponent().appendingPathComponent(trimmed)
        // 대소문자 무시 볼륨(APFS 기본)에서 대소문자만 바꾸는 rename은 fileExists가 자기 자신을
        // 가리켜 true가 되므로, 그 경우만 존재 검사를 건너뛴다.
        let isCaseOnlyChange = trimmed.lowercased() == url.lastPathComponent.lowercased()
        guard isCaseOnlyChange || !fm.fileExists(atPath: target.path) else {
            throw FileOperationError.alreadyExists(trimmed)
        }
        do {
            try fm.moveItem(at: url, to: target)
        } catch {
            throw FileOperationError.failed(error.localizedDescription)
        }
        return target
    }

    /// parent 안에 새 폴더를 만든다. 이름이 겹치면 " (1)" 접미로 비켜 간다(uniquified 관례).
    static func createFolder(in parent: URL, name: String = "새 폴더") throws -> URL {
        let target = parent.appendingPathComponent(name).uniquified()
        do {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        } catch {
            throw FileOperationError.failed(error.localizedDescription)
        }
        return target
    }

    /// 휴지통으로 이동하고 휴지통 안의 실제 위치를 반환한다(작업 로그·되돌리기용).
    static func trash(at url: URL) throws -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { throw FileOperationError.sourceMissing }
        var resultURL: NSURL?
        do {
            try fm.trashItem(at: url, resultingItemURL: &resultURL)
        } catch {
            throw FileOperationError.failed(error.localizedDescription)
        }
        guard let trashedURL = resultURL as URL? else {
            throw FileOperationError.failed("휴지통 내 위치를 확인하지 못했습니다.")
        }
        return trashedURL
    }
}
```

- [ ] **Step 4: 통과 확인**

Run: `swift test --filter FileOperationsTests 2>&1 | tail -5`
Expected: PASS (13개).

- [ ] **Step 5: 커밋**

```bash
git add Sources/Services/FileOperations.swift Tests/CmdMDTests/FileOperationsTests.swift
git commit -m "기능(F1a): FileOperations 서비스 — rename/새폴더/휴지통, 한국어 에러"
```

---

### Task 2: `FileOpsLogStore` — 작업 로그 + 되돌리기

**Files:**
- Create: `Sources/Services/FileOpsLogStore.swift`
- Test: `Tests/CmdMDTests/FileOpsLogStoreTests.swift` (신규)

**Interfaces:**
- Consumes: `FileOperations.trash`(통합 테스트 1건에서만).
- Produces: `FileOpKind`(enum trash/rename, String Codable), `FileOpEntry`(Codable·Equatable·Identifiable — `id: UUID`·`kind`·`originalURL`·`resultURL`·`date`, init 기본값 `id = UUID()`·`date = Date()`), `actor FileOpsLogStore`(`init(directory:)` — 파일명 `fileops-log.json`, `load() -> [FileOpEntry]`, `append(_:)`, `undo(_:) -> Bool`). Task 5·8이 사용.

- [ ] **Step 1: 실패하는 테스트 작성**

`Tests/CmdMDTests/FileOpsLogStoreTests.swift` 신규 (MoveLogStoreTests 스타일 — actor라 async 테스트):

```swift
import XCTest
@testable import CmdMD

final class FileOpsLogStoreTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fileopslog-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        dir = nil
        super.tearDown()
    }

    private func makeFile(_ name: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try Data("본문".utf8).write(to: url)
        return url
    }

    func testAppendThenLoadRoundTrip() async throws {
        let store = FileOpsLogStore(directory: dir)
        let entry = FileOpEntry(kind: .rename,
                                originalURL: dir.appendingPathComponent("a.md"),
                                resultURL: dir.appendingPathComponent("b.md"))
        await store.append(entry)
        let loaded = await store.load()
        XCTAssertEqual(loaded, [entry])
    }

    func testLoadEmptyWhenNoFile() async {
        let store = FileOpsLogStore(directory: dir)
        let loaded = await store.load()
        XCTAssertTrue(loaded.isEmpty)
    }

    func testUndoRenameMovesBackAndRemovesEntry() async throws {
        // rename을 실제 수행한 상황을 재현: b.md만 존재, 로그는 a→b.
        let original = dir.appendingPathComponent("a.md")
        let renamed = try makeFile("b.md")
        let store = FileOpsLogStore(directory: dir)
        let entry = FileOpEntry(kind: .rename, originalURL: original, resultURL: renamed)
        await store.append(entry)

        let ok = await store.undo(entry)

        XCTAssertTrue(ok)
        XCTAssertTrue(FileManager.default.fileExists(atPath: original.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: renamed.path))
        let remaining = await store.load()
        XCTAssertTrue(remaining.isEmpty)   // 성공한 엔트리는 제거
    }

    func testUndoFailsWhenOriginalOccupied() async throws {
        // 원위치에 다른 항목이 생겼으면 덮어쓰지 않고 실패, 로그 보존.
        let original = try makeFile("a.md")           // 점유자
        let renamed = try makeFile("b.md")
        let store = FileOpsLogStore(directory: dir)
        let entry = FileOpEntry(kind: .rename, originalURL: original, resultURL: renamed)
        await store.append(entry)

        let ok = await store.undo(entry)

        XCTAssertFalse(ok)
        XCTAssertTrue(FileManager.default.fileExists(atPath: renamed.path))   // 결과물 불변
        let remaining = await store.load()
        XCTAssertEqual(remaining, [entry])            // 실패한 엔트리는 보존
    }

    func testUndoFailsWhenResultMissing() async {
        // 휴지통이 비워졌거나 결과물이 사라진 경우.
        let store = FileOpsLogStore(directory: dir)
        let entry = FileOpEntry(kind: .trash,
                                originalURL: dir.appendingPathComponent("a.md"),
                                resultURL: dir.appendingPathComponent("휴지통에없음.md"))
        await store.append(entry)

        let ok = await store.undo(entry)

        XCTAssertFalse(ok)
        let remaining = await store.load()
        XCTAssertEqual(remaining, [entry])
    }

    func testUndoRealTrashRoundTrip() async throws {
        // 스펙 §5: 생성→trash→undo 복귀 통합 확인. 휴지통 접근 불가 환경이면 스킵.
        let src = try makeFile("왕복.md")
        let trashed: URL
        do {
            trashed = try FileOperations.trash(at: src)
        } catch {
            throw XCTSkip("휴지통 접근 불가 환경: \(error)")
        }
        let store = FileOpsLogStore(directory: dir)
        let entry = FileOpEntry(kind: .trash, originalURL: src, resultURL: trashed)
        await store.append(entry)

        let ok = await store.undo(entry)

        XCTAssertTrue(ok)
        XCTAssertTrue(FileManager.default.fileExists(atPath: src.path))
    }
}
```

- [ ] **Step 2: 실패 확인**

Run: `swift test --filter FileOpsLogStoreTests 2>&1 | tail -5`
Expected: 컴파일 실패 — `cannot find 'FileOpsLogStore' in scope`.

- [ ] **Step 3: 구현**

`Sources/Services/FileOpsLogStore.swift` 신규:

```swift
import Foundation

/// 파일 작업 종류(작업 로그용).
enum FileOpKind: String, Codable {
    case trash
    case rename
}

/// 되돌리기 가능한 파일 작업 1건의 기록.
/// - trash: originalURL = 원위치, resultURL = 휴지통 내 실제 위치.
/// - rename: originalURL = 옛 경로, resultURL = 새 경로.
/// 새 폴더는 기록하지 않는다 — 되돌리기가 삭제라 "영구 삭제 없음" 정책과 충돌.
struct FileOpEntry: Codable, Equatable, Identifiable {
    let id: UUID
    let kind: FileOpKind
    let originalURL: URL
    let resultURL: URL
    let date: Date

    init(id: UUID = UUID(), kind: FileOpKind, originalURL: URL, resultURL: URL, date: Date = Date()) {
        self.id = id
        self.kind = kind
        self.originalURL = originalURL
        self.resultURL = resultURL
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
        var all = load()
        all.append(entry)
        save(all)
    }

    /// 되돌리기 — resultURL을 originalURL로 역이동(휴지통 꺼내기와 rename 역방향이 같은 연산).
    /// 결과물이 사라졌거나 원위치가 점유됐으면 실패(false)하고 로그를 보존한다(덮어쓰기 금지).
    func undo(_ entry: FileOpEntry) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: entry.resultURL.path) else { return false }
        guard !fm.fileExists(atPath: entry.originalURL.path) else { return false }
        do {
            try fm.moveItem(at: entry.resultURL, to: entry.originalURL)
        } catch {
            return false
        }
        save(load().filter { $0.id != entry.id })
        return true
    }

    private func save(_ entries: [FileOpEntry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: [.atomic])
    }
}
```

- [ ] **Step 4: 통과 확인**

Run: `swift test --filter FileOpsLogStoreTests 2>&1 | tail -5`
Expected: PASS (6개).

- [ ] **Step 5: 커밋**

```bash
git add Sources/Services/FileOpsLogStore.swift Tests/CmdMDTests/FileOpsLogStoreTests.swift
git commit -m "기능(F1a): FileOpsLogStore — 작업 로그 JSON 영속 + 되돌리기(덮어쓰기 금지·실패 보존)"
```

---

### Task 3: `FileInfoService` — 정보 모델·로더·폴더 크기

**Files:**
- Create: `Sources/Services/FileInfoService.swift`
- Test: `Tests/CmdMDTests/FileInfoServiceTests.swift` (신규)

**Interfaces:**
- Consumes: `DocumentKind(from:)`·`DocumentKind.isVideo(_:)`, `MediaMetadataService.load(url:)`·`formatDuration(_:)`.
- Produces: `FileInfo`(Equatable — name/isDirectory/kindLabel/sizeBytes(`Int64?`, 폴더는 nil)/locationPath/createdAt/modifiedAt), `FileInfoService.loadBasic(url:) -> FileInfo`(동기), `loadDetail(url:isDirectory:) async -> String?`, `computeFolderSize(url:) async throws -> Int64`, `formatSize(_: Int64) -> String`, `kindLabel(for:isDirectory:) -> String`. Task 4(formatSize)·7(전부)이 사용.

- [ ] **Step 1: 실패하는 테스트 작성**

`Tests/CmdMDTests/FileInfoServiceTests.swift` 신규. 이미지=PNG 실생성(`NSBitmapImageRep`→`.png` — ContentExtractorTests의 비트맵 패턴), PDF=ContentExtractorTests 패턴, 미디어=MediaMetadataServiceTests의 WAV 헬퍼 복사.

```swift
import XCTest
import AppKit
import PDFKit
@testable import CmdMD

final class FileInfoServiceTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fileinfo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        dir = nil
        super.tearDown()
    }

    // MARK: 픽스처

    /// widthxheight 픽셀 PNG를 실제로 만든다(헤더만 읽는 해상도 검증용).
    private func makePNG(_ name: String, width: Int, height: Int) throws -> URL {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .calibratedRGB,
                                      bytesPerRow: 0, bitsPerPixel: 32)!
        let data = bitmap.representation(using: .png, properties: [:])!
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func makePDF(_ name: String, pages: Int) throws -> URL {
        let pdf = PDFDocument()
        for index in 0..<pages {
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 10, pixelsHigh: 10,
                                          bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                          isPlanar: false, colorSpaceName: .calibratedRGB,
                                          bytesPerRow: 0, bitsPerPixel: 32)!
            let image = NSImage()
            image.addRepresentation(bitmap)
            pdf.insert(PDFPage(image: image)!, at: index)
        }
        let url = dir.appendingPathComponent(name)
        XCTAssertTrue(pdf.write(to: url))
        return url
    }

    /// 1초짜리 8kHz 8-bit 모노 PCM WAV(MediaMetadataServiceTests와 동일).
    private func makeWAV(_ name: String) throws -> URL {
        let sampleRate: UInt32 = 8000
        let dataSize: UInt32 = 8000
        var data = Data()
        func append(_ s: String) { data.append(s.data(using: .ascii)!) }
        func append32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func append16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        append("RIFF"); append32(36 + dataSize); append("WAVE")
        append("fmt "); append32(16); append16(1); append16(1)
        append32(sampleRate); append32(sampleRate)
        append16(1); append16(8)
        append("data"); append32(dataSize)
        data.append(Data(repeating: 128, count: Int(dataSize)))
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    // MARK: loadBasic

    func testLoadBasicFile() throws {
        let url = dir.appendingPathComponent("문서.md")
        try Data("12345".utf8).write(to: url)
        let info = FileInfoService.loadBasic(url: url)
        XCTAssertEqual(info.name, "문서.md")
        XCTAssertFalse(info.isDirectory)
        XCTAssertEqual(info.sizeBytes, 5)
        XCTAssertEqual(info.locationPath, dir.path)
        XCTAssertNotNil(info.createdAt)
        XCTAssertNotNil(info.modifiedAt)
    }

    func testLoadBasicFolder() throws {
        let folder = dir.appendingPathComponent("하위")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let info = FileInfoService.loadBasic(url: folder)
        XCTAssertTrue(info.isDirectory)
        XCTAssertNil(info.sizeBytes)          // 폴더 크기는 별도 비동기 계산
        XCTAssertEqual(info.kindLabel, "폴더")
    }

    // MARK: kindLabel (순수)

    func testKindLabels() {
        func label(_ name: String) -> String {
            FileInfoService.kindLabel(for: URL(fileURLWithPath: "/tmp/\(name)"), isDirectory: false)
        }
        XCTAssertEqual(label("a.md"), "MD 문서")
        XCTAssertEqual(label("a.png"), "PNG 이미지")
        XCTAssertEqual(label("a.pdf"), "PDF 문서")
        XCTAssertEqual(label("a.hwp"), "HWP 오피스 문서")
        XCTAssertEqual(label("a.mp3"), "MP3 오디오")
        XCTAssertEqual(label("a.mov"), "MOV 동영상")
        XCTAssertEqual(FileInfoService.kindLabel(for: URL(fileURLWithPath: "/tmp/폴더"), isDirectory: true), "폴더")
    }

    // MARK: loadDetail (종류별 한 줄)

    func testDetailImageResolution() async throws {
        let url = try makePNG("img.png", width: 10, height: 8)
        let detail = await FileInfoService.loadDetail(url: url, isDirectory: false)
        XCTAssertEqual(detail, "10 × 8")
    }

    func testDetailPDFPageCount() async throws {
        let url = try makePDF("doc.pdf", pages: 2)
        let detail = await FileInfoService.loadDetail(url: url, isDirectory: false)
        XCTAssertEqual(detail, "2페이지")
    }

    func testDetailMediaDuration() async throws {
        let url = try makeWAV("clip.wav")
        let detail = await FileInfoService.loadDetail(url: url, isDirectory: false)
        XCTAssertEqual(detail, "길이 0:01")
    }

    func testDetailFolderItemCount() async throws {
        let folder = dir.appendingPathComponent("셈")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data().write(to: folder.appendingPathComponent("a.md"))
        try Data().write(to: folder.appendingPathComponent("b.md"))
        let detail = await FileInfoService.loadDetail(url: folder, isDirectory: true)
        XCTAssertEqual(detail, "항목 2개")
    }

    func testDetailMarkdownIsNil() async throws {
        let url = dir.appendingPathComponent("plain.md")
        try Data("x".utf8).write(to: url)
        let detail = await FileInfoService.loadDetail(url: url, isDirectory: false)
        XCTAssertNil(detail)
    }

    // MARK: computeFolderSize

    func testComputeFolderSizeSumsNestedFiles() async throws {
        let root = dir.appendingPathComponent("루트")
        let nested = root.appendingPathComponent("중첩")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data(repeating: 0, count: 100).write(to: root.appendingPathComponent("a.bin"))
        try Data(repeating: 0, count: 50).write(to: nested.appendingPathComponent("b.bin"))
        let total = try await FileInfoService.computeFolderSize(url: root)
        XCTAssertEqual(total, 150)
    }

    func testComputeFolderSizeCancellation() async throws {
        // 파일을 넉넉히 만들어 계산이 취소보다 오래 걸리게 한다(취소가 늦으면 완료돼버려 실패).
        let root = dir.appendingPathComponent("큰폴더")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for index in 0..<500 {
            try Data(repeating: 0, count: 10).write(to: root.appendingPathComponent("f\(index).bin"))
        }
        let task = Task { try await FileInfoService.computeFolderSize(url: root) }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("취소된 태스크가 값을 반환했습니다")
        } catch is CancellationError {
            // 기대 경로
        }
    }

    // MARK: formatSize

    func testFormatSize() {
        // ByteCountFormatter 출력은 로케일 의존 — 형식이 아니라 존재만 검증한다.
        XCTAssertFalse(FileInfoService.formatSize(0).isEmpty)
        XCTAssertFalse(FileInfoService.formatSize(1_500).isEmpty)
    }
}
```

- [ ] **Step 2: 실패 확인**

Run: `swift test --filter FileInfoServiceTests 2>&1 | tail -5`
Expected: 컴파일 실패 — `cannot find 'FileInfoService' in scope`.

- [ ] **Step 3: 구현**

`Sources/Services/FileInfoService.swift` 신규:

```swift
import Foundation
import ImageIO
import PDFKit

/// 정보 시트(⌥⌘I)에 보여줄 기본 정보 — 동기 1회 조회분.
struct FileInfo: Equatable {
    let name: String
    let isDirectory: Bool
    let kindLabel: String       // 한국어 종류 라벨
    let sizeBytes: Int64?       // 파일만. 폴더는 nil(시트에서 비동기 계산)
    let locationPath: String    // 부모 폴더 경로
    let createdAt: Date?
    let modifiedAt: Date?
}

/// 파일/폴더 정보 조회 — 기본 필드는 동기 1회, 종류별 한 줄·폴더 크기는 비동기.
enum FileInfoService {

    /// 기본 필드 일괄 조회(URLResourceValues 1회).
    static func loadBasic(url: URL) -> FileInfo {
        let values = try? url.resourceValues(forKeys: [
            .isDirectoryKey, .fileSizeKey, .creationDateKey, .contentModificationDateKey,
        ])
        let isDirectory = values?.isDirectory ?? false
        return FileInfo(
            name: url.lastPathComponent,
            isDirectory: isDirectory,
            kindLabel: kindLabel(for: url, isDirectory: isDirectory),
            sizeBytes: isDirectory ? nil : values?.fileSize.map(Int64.init),
            locationPath: url.deletingLastPathComponent().path,
            createdAt: values?.creationDate,
            modifiedAt: values?.contentModificationDate
        )
    }

    /// 종류 라벨 — DocumentKind 기반 한국어(+대문자 확장자). DocumentKind 모델은 건드리지 않는다.
    static func kindLabel(for url: URL, isDirectory: Bool) -> String {
        if isDirectory { return "폴더" }
        let ext = url.pathExtension.uppercased()
        switch DocumentKind(from: url) {
        case .markdown: return ext.isEmpty ? "텍스트 문서" : "\(ext) 문서"
        case .image: return "\(ext) 이미지"
        case .pdf: return "PDF 문서"
        case .office: return "\(ext) 오피스 문서"
        case .media: return DocumentKind.isVideo(url) ? "\(ext) 동영상" : "\(ext) 오디오"
        }
    }

    /// 종류별 한 줄: 이미지=해상도(헤더만), PDF=페이지 수, 미디어=길이, 폴더=직속 항목 수.
    /// 실패하면 nil — 나머지 정보 표시는 계속(MediaMetadata 관례).
    static func loadDetail(url: URL, isDirectory: Bool) async -> String? {
        if isDirectory {
            let count = (try? FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]))?.count
            return count.map { "항목 \($0)개" }
        }
        switch DocumentKind(from: url) {
        case .image:
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = props[kCGImagePropertyPixelWidth] as? Int,
                  let height = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
            return "\(width) × \(height)"
        case .pdf:
            guard let document = PDFDocument(url: url) else { return nil }
            return "\(document.pageCount)페이지"
        case .media:
            let metadata = await MediaMetadataService.load(url: url)
            let duration = MediaMetadataService.formatDuration(metadata.durationSeconds)
            return duration.isEmpty ? nil : "길이 \(duration)"
        case .markdown, .office:
            return nil
        }
    }

    /// 폴더 크기 재귀 합산. 취소 지원 — 시트가 닫히면(.task 취소) CancellationError로 중단.
    /// fileSize(논리 크기) 우선 — 파일 행 표기와 단위를 맞춘다(스펙 §7.1).
    static func computeFolderSize(url: URL) async throws -> Int64 {
        try Task.checkCancellation()
        let keys: Set<URLResourceKey> = [.fileSizeKey, .totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            try Task.checkCancellation()
            guard let values = try? fileURL.resourceValues(forKeys: keys),
                  values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? values.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    /// 사람이 읽는 크기 문자열(ByteCountFormatter .file — Finder와 같은 표기).
    static func formatSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
```

- [ ] **Step 4: 통과 확인**

Run: `swift test --filter FileInfoServiceTests 2>&1 | tail -5`
Expected: PASS (12개). `testFormatSize`가 로케일로 실패하면 존재 검증으로 완화 후 재실행.

- [ ] **Step 5: 커밋**

```bash
git add Sources/Services/FileInfoService.swift Tests/CmdMDTests/FileInfoServiceTests.swift
git commit -m "기능(F1a): FileInfoService — 기본 정보·종류별 한 줄·폴더 크기(취소 지원)"
```

---

### Task 4: 라이브러리 리스트 열 — `FileTreeItem` 메타 + 열거 + 셀 표시

**Files:**
- Modify: `Sources/Models/Workspace.swift:120-167` (`FileTreeItem`에 옵셔널 필드 2개)
- Modify: `Sources/Services/LibraryListing.swift` (열거 키 확장 + 채움)
- Modify: `Sources/Views/LibraryView.swift:239-293` (`LibraryListCell` 트레일링 열)
- Test: `Tests/CmdMDTests/LibraryListingTests.swift` (기존 파일에 테스트 추가)

**Interfaces:**
- Consumes: `FileInfoService.formatSize(_:)` (Task 3).
- Produces: `FileTreeItem.fileSize: Int64?`·`FileTreeItem.modifiedAt: Date?`(init 기본값 nil — 기존 생성 지점 4곳 무수정), `LibraryListing.entries`가 라이브러리 경로에서 두 필드를 채움(폴더는 modifiedAt만). Task 7과 무관, 이 태스크로 리스트 열 완결.

- [ ] **Step 1: 실패하는 테스트 작성**

`Tests/CmdMDTests/LibraryListingTests.swift`(기존 파일)에 추가:

```swift
    func testEntriesFillFileMetadata() throws {
        // 파일: fileSize·modifiedAt 채움 / 폴더: fileSize nil·modifiedAt 채움 (리스트 열용, 스펙 §7.3)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("listing-meta-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        try Data(repeating: 0, count: 42).write(to: dir.appendingPathComponent("파일.md"))
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("폴더"), withIntermediateDirectories: true)

        let entries = LibraryListing.entries(of: dir)
        let file = try XCTUnwrap(entries.first(where: { !$0.isDirectory }))
        let folder = try XCTUnwrap(entries.first(where: { $0.isDirectory }))

        XCTAssertEqual(file.fileSize, 42)
        XCTAssertNotNil(file.modifiedAt)
        XCTAssertNil(folder.fileSize)
        XCTAssertNotNil(folder.modifiedAt)
    }

    func testTreeScanLeavesMetadataNil() {
        // 사이드바 트리 경로(buildFileTree)는 메타를 읽지 않는다 — 비용 불변 확인.
        let item = FileTreeItem(url: URL(fileURLWithPath: "/tmp/x.md"))
        XCTAssertNil(item.fileSize)
        XCTAssertNil(item.modifiedAt)
    }
```

- [ ] **Step 2: 실패 확인**

Run: `swift test --filter LibraryListingTests 2>&1 | tail -5`
Expected: 컴파일 실패 — `value of type 'FileTreeItem' has no member 'fileSize'`.

- [ ] **Step 3: 구현**

(a) `Sources/Models/Workspace.swift`의 `FileTreeItem`에 필드·init 파라미터 추가(기존 프로퍼티 아래):

```swift
    /// 라이브러리 리스트 열용 메타 — 라이브러리 열거(LibraryListing)만 채운다.
    /// 사이드바 트리 스캔(buildFileTree)은 nil 유지 → 트리 비용 불변.
    var fileSize: Int64?
    var modifiedAt: Date?
```

init 시그니처를 다음으로 교체(마지막에 기본값 파라미터 2개 추가 — 기존 호출 4곳 무수정):

```swift
    init(url: URL, isDirectory: Bool = false, isExpanded: Bool = false,
         children: [FileTreeItem] = [], hasCompanionNote: Bool = false,
         fileSize: Int64? = nil, modifiedAt: Date? = nil) {
        self.id = UUID()
        self.url = url
        self.isDirectory = isDirectory
        self.isExpanded = isExpanded
        self.children = children
        self.hasCompanionNote = hasCompanionNote
        self.fileSize = fileSize
        self.modifiedAt = modifiedAt
    }
```

(b) `Sources/Services/LibraryListing.swift` — 열거 키와 채움(기존 본문에서 세 곳 수정):

```swift
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
```

```swift
            guard let resourceValues = try? url.resourceValues(
                forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]) else { continue }
            let isDirectory = resourceValues.isDirectory ?? false
            let modifiedAt = resourceValues.contentModificationDate
            if isDirectory {
                // 폴더 크기는 리스트에서 "--"(스펙 §7.3) — modifiedAt만 채운다.
                items.append(FileTreeItem(url: url, isDirectory: true, modifiedAt: modifiedAt))
            } else if AppState.isListableInFileTree(url) {
                if CompanionNote.isCompanionNote(url, siblingKeys: siblingKeys) { continue }
                let hasNote = CompanionNote.hasCompanionNote(for: url, siblingKeys: siblingKeys)
                items.append(FileTreeItem(url: url, isDirectory: false, hasCompanionNote: hasNote,
                                          fileSize: resourceValues.fileSize.map(Int64.init),
                                          modifiedAt: modifiedAt))
            }
```

(c) `Sources/Views/LibraryView.swift`의 `LibraryListCell` body HStack — 짝꿍 노트 배지 블록을 포함해 트레일링을 다음 구조로 재배치(이름 VStack까지는 불변):

```swift
            Spacer(minLength: 4)

            if item.hasCompanionNote {
                Image(systemName: "note.text")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help("짝꿍 노트 있음")
            }

            // 수정일·크기 열 — 표시만(정렬은 F3). 고정폭·모노 숫자로 세로 정렬 유지.
            Text(item.modifiedAt?.formatted(.dateTime.year().month().day()) ?? "--")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .frame(width: 92, alignment: .trailing)
            Text(item.isDirectory ? "--" : (item.fileSize.map(FileInfoService.formatSize) ?? "--"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .frame(width: 68, alignment: .trailing)
```

기존 `if item.hasCompanionNote { Spacer(minLength: 4); Image... }` 블록은 위 구조로 대체된다(Spacer는 항상, 배지는 조건부). 그리드 셀은 불변.

- [ ] **Step 4: 통과 확인**

Run: `swift test --filter LibraryListingTests 2>&1 | tail -5`
Expected: PASS (기존 + 신규 2개). 이어서 `swift build 2>&1 | tail -3`로 뷰 컴파일 확인.

- [ ] **Step 5: 커밋**

```bash
git add Sources/Models/Workspace.swift Sources/Services/LibraryListing.swift Sources/Views/LibraryView.swift Tests/CmdMDTests/LibraryListingTests.swift
git commit -m "기능(F1a): 라이브러리 리스트에 크기·수정일 열 — 열거 시점 일괄 조회(트리 비용 불변)"
```

---

### Task 5: AppState 배선 — 오케스트레이션·탭 정합·짝꿍 노트·세대 토큰

**Files:**
- Modify: `Sources/App/AppState.swift`
- Test: `Tests/CmdMDTests/AppFileOpsTests.swift` (신규)

**Interfaces:**
- Consumes: `FileOperations`(Task 1), `FileOpsLogStore`·`FileOpEntry`(Task 2), 기존 `closeTab`·`startWatchingFile`·`stopWatchingFile`·`loadFileTree`·`saveSession`·`isTabDirty`·`showToast`·`CompanionNote.noteURL(for:)`·`DocumentKind(from:)`.
- Produces (Task 6·7·8이 사용):
  - 상태: `fileOpsGeneration: Int`, `showFileOpsHistory: Bool`, `renameRequest: RenameRequest?`, `fileInfoRequest: FileInfoRequest?`, `fileOpsLogStore: FileOpsLogStore`(let, init에서 주입).
  - 구조체: `RenameRequest`·`FileInfoRequest`(Identifiable, `let id = UUID(); let url: URL`).
  - 메서드: `performRename(at:to:) async throws -> URL`(@discardableResult, 검증 실패는 FileOperationError throw — 시트 인라인 표시용), `trashWithConfirmation(_ url: URL)`(NSAlert → performTrash), `performTrash(at:) async -> Bool`(@discardableResult), `undoFileOp(_ entry: FileOpEntry) async -> Bool`, `static companionNoteForOperation(mediaURL:) -> URL?`.
  - 변경: `createNewFolder(in:)`이 `FileOperations.createFolder` 위임(폴더명 "New Folder"→"새 폴더") + 세대 토큰 증가.

- [ ] **Step 1: 실패하는 테스트 작성**

`Tests/CmdMDTests/AppFileOpsTests.swift` 신규. App* 관례(임시 데이터 디렉터리 주입 + `@MainActor`). 탭은 `createNewTab()` 후 `tabs[0].fileURL` 직접 대입(EditorTab은 커스텀 Decodable init 때문에 멤버와이즈 init 없음). NSAlert 경로(trashWithConfirmation)는 러너 모달이라 테스트하지 않는다 — closeAllTabs 관례.

```swift
import XCTest
@testable import CmdMD

@MainActor
final class AppFileOpsTests: XCTestCase {

    private var tempData: URL!
    private var work: URL!
    private var appState: AppState!

    override func setUpWithError() throws {
        tempData = TempDataDirectory.make()
        work = FileManager.default.temporaryDirectory
            .appendingPathComponent("fileops-app-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        appState = AppState(dataDirectory: tempData)
    }

    override func tearDown() {
        TempDataDirectory.cleanup(tempData)
        try? FileManager.default.removeItem(at: work)
        tempData = nil
        work = nil
        appState = nil
        super.tearDown()
    }

    private func makeFile(_ relative: String) throws -> URL {
        let url = work.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("본문".utf8).write(to: url)
        return url
    }

    /// 지정 URL을 보는 탭을 하나 만든다(createNewTab 후 fileURL 주입).
    private func openTab(at url: URL) -> EditorTab {
        appState.createNewTab()
        let index = appState.tabs.count - 1
        appState.tabs[index].fileURL = url
        appState.documents[appState.tabs[index].documentId]?.fileURL = url
        return appState.tabs[index]
    }

    // MARK: performRename

    func testPerformRenameUpdatesTabAndDocument() async throws {
        let old = try makeFile("문서.md")
        let tab = openTab(at: old)

        let newURL = try await appState.performRename(at: old, to: "바뀐이름.md")

        XCTAssertEqual(newURL.lastPathComponent, "바뀐이름.md")
        let updated = appState.tabs.first(where: { $0.id == tab.id })
        XCTAssertEqual(updated?.fileURL, newURL)
        XCTAssertEqual(appState.documents[tab.documentId]?.fileURL, newURL)
        XCTAssertTrue(FileManager.default.fileExists(atPath: newURL.path))
    }

    func testPerformRenameFolderRetargetsNestedTabsWithBoundary() async throws {
        // /work/폴더/안.md 는 재조준, 형제 /work/폴더X/밖.md 는 불변('/' 경계 — 8.5-②a 교훈)
        let inner = try makeFile("폴더/안.md")
        let sibling = try makeFile("폴더X/밖.md")
        let innerTab = openTab(at: inner)
        let siblingTab = openTab(at: sibling)

        let newFolder = try await appState.performRename(at: work.appendingPathComponent("폴더"), to: "새폴더")

        XCTAssertEqual(appState.tabs.first(where: { $0.id == innerTab.id })?.fileURL,
                       newFolder.appendingPathComponent("안.md"))
        XCTAssertEqual(appState.tabs.first(where: { $0.id == siblingTab.id })?.fileURL, sibling)
    }

    func testPerformRenameCoRenamesCompanionNote() async throws {
        let media = try makeFile("노래.mp3")
        let note = try makeFile("노래.mp3.md")

        let newURL = try await appState.performRename(at: media, to: "새노래.mp3")

        XCTAssertEqual(newURL.lastPathComponent, "새노래.mp3")
        XCTAssertFalse(FileManager.default.fileExists(atPath: note.path))
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: work.appendingPathComponent("새노래.mp3.md").path))
        // 로그에 미디어·노트 두 건 모두 기록(각각 되돌리기 가능)
        let entries = await appState.fileOpsLogStore.load()
        XCTAssertEqual(entries.count, 2)
        XCTAssertTrue(entries.allSatisfy { $0.kind == .rename })
    }

    func testPerformRenameConflictThrowsAndLeavesStateIntact() async throws {
        let src = try makeFile("a.md")
        _ = try makeFile("b.md")
        let tab = openTab(at: src)
        let generationBefore = appState.fileOpsGeneration

        do {
            _ = try await appState.performRename(at: src, to: "b.md")
            XCTFail("충돌인데 성공")
        } catch let error as FileOperationError {
            XCTAssertEqual(error, .alreadyExists("b.md"))
        }

        XCTAssertEqual(appState.tabs.first(where: { $0.id == tab.id })?.fileURL, src)
        XCTAssertEqual(appState.fileOpsGeneration, generationBefore)
        let entries = await appState.fileOpsLogStore.load()
        XCTAssertTrue(entries.isEmpty)
    }

    func testPerformRenameBumpsGeneration() async throws {
        let src = try makeFile("g.md")
        let before = appState.fileOpsGeneration
        _ = try await appState.performRename(at: src, to: "g2.md")
        XCTAssertEqual(appState.fileOpsGeneration, before + 1)
    }

    // MARK: performTrash

    func testPerformTrashClosesTabsAndLogs() async throws {
        let folder = work.appendingPathComponent("버릴폴더")
        let inner = try makeFile("버릴폴더/안.md")
        let outside = try makeFile("남는.md")
        let innerTab = openTab(at: inner)
        let outsideTab = openTab(at: outside)

        let ok = await appState.performTrash(at: folder)
        guard ok else { throw XCTSkip("휴지통 접근 불가 환경") }

        XCTAssertNil(appState.tabs.first(where: { $0.id == innerTab.id }))
        XCTAssertNotNil(appState.tabs.first(where: { $0.id == outsideTab.id }))
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        let entries = await appState.fileOpsLogStore.load()
        XCTAssertEqual(entries.map(\.kind), [.trash])
        // 테스트 픽스처 정리 — 휴지통에 들어간 사본 제거
        if let trashed = entries.first?.resultURL {
            try? FileManager.default.removeItem(at: trashed)
        }
    }

    func testPerformTrashTakesCompanionNoteAlong() async throws {
        let media = try makeFile("영상.mp4")
        _ = try makeFile("영상.mp4.md")

        let ok = await appState.performTrash(at: media)
        guard ok else { throw XCTSkip("휴지통 접근 불가 환경") }

        XCTAssertFalse(FileManager.default.fileExists(
            atPath: work.appendingPathComponent("영상.mp4.md").path))
        let entries = await appState.fileOpsLogStore.load()
        XCTAssertEqual(entries.count, 2)
        for entry in entries { try? FileManager.default.removeItem(at: entry.resultURL) }
    }

    // MARK: undo

    func testUndoFileOpRestoresAndBumpsGeneration() async throws {
        let src = try makeFile("복귀.md")
        _ = try await appState.performRename(at: src, to: "임시.md")
        // XCTUnwrap은 autoclosure라 인자 안에 await를 둘 수 없다 — 먼저 받아온다.
        let entries = await appState.fileOpsLogStore.load()
        let entry = try XCTUnwrap(entries.first)
        let before = appState.fileOpsGeneration

        let ok = await appState.undoFileOp(entry)

        XCTAssertTrue(ok)
        XCTAssertTrue(FileManager.default.fileExists(atPath: src.path))
        XCTAssertEqual(appState.fileOpsGeneration, before + 1)
    }

    // MARK: createNewFolder 위임

    func testCreateNewFolderUsesKoreanDefaultAndBumpsGeneration() {
        let before = appState.fileOpsGeneration
        appState.createNewFolder(in: work)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: work.appendingPathComponent("새 폴더").path))
        XCTAssertEqual(appState.fileOpsGeneration, before + 1)
    }

    // MARK: companion 판별

    func testCompanionNoteForOperation() throws {
        let media = try makeFile("m.mp3")
        XCTAssertNil(AppState.companionNoteForOperation(mediaURL: media))   // 노트 없음
        _ = try makeFile("m.mp3.md")
        XCTAssertEqual(AppState.companionNoteForOperation(mediaURL: media),
                       work.appendingPathComponent("m.mp3.md"))
        let plain = try makeFile("일반.md")
        XCTAssertNil(AppState.companionNoteForOperation(mediaURL: plain))   // 미디어 아님
    }
}
```

주의: `createNewTab()`이 documents 항목을 만드는지 실제 코드로 확인하고, 문서가 없으면 `openTab`의 documents 갱신 줄은 옵셔널 체이닝이라 무해 — 그 경우 `testPerformRenameUpdatesTabAndDocument`의 documents 검증은 documents에 항목이 실재하는 방식(기존 App* 테스트 참고)으로 조정하되 탭 URL 검증은 유지한다.

- [ ] **Step 2: 실패 확인**

Run: `swift test --filter AppFileOpsTests 2>&1 | tail -5`
Expected: 컴파일 실패 — `value of type 'AppState' has no member 'performRename'`.

- [ ] **Step 3: 구현**

`Sources/App/AppState.swift`에 추가·수정:

(a) 상태 프로퍼티 — `showFolderCleanup`(:136) 근처에:

```swift
    // MARK: - 파일 작업(F1a) 상태

    /// 파일작업 세대 토큰 — rename/새폴더/휴지통/되돌리기마다 증가.
    /// LibraryView.folderKey가 결합해 같은 폴더 내 변경도 재열거되게 한다.
    var fileOpsGeneration: Int = 0
    /// 파일 작업 기록 시트.
    var showFileOpsHistory: Bool = false
    /// 이름 변경 시트 요청(.sheet(item:)).
    var renameRequest: RenameRequest? = nil
    /// 정보 보기 시트 요청(.sheet(item:)).
    var fileInfoRequest: FileInfoRequest? = nil
```

(b) 스토어 — `moveLogStore` 선언 이웃에 `let fileOpsLogStore: FileOpsLogStore`, init(:694 근처)에 `fileOpsLogStore = FileOpsLogStore(directory: appDir)`.

(c) Request 구조체 — `OfficeFillRequest`(:2544) 이웃에:

```swift
/// 이름 변경 시트 요청 페이로드.
struct RenameRequest: Identifiable {
    let id = UUID()
    let url: URL
}

/// 정보 보기 시트 요청 페이로드.
struct FileInfoRequest: Identifiable {
    let id = UUID()
    let url: URL
}
```

(d) 파일 작업 메서드 — `closeAllTabs` 아래 새 MARK 섹션:

```swift
    // MARK: - 파일 작업 (F1a — 이름변경·휴지통·되돌리기)

    /// 짝꿍 노트 동반 대상 — url이 미디어 파일이고 노트(파일명.ext.md)가 실재할 때만.
    static func companionNoteForOperation(mediaURL: URL) -> URL? {
        guard DocumentKind(from: mediaURL) == .media else { return nil }
        let note = CompanionNote.noteURL(for: mediaURL)
        guard FileManager.default.fileExists(atPath: note.path) else { return nil }
        return note
    }

    /// 이름 변경 + 로그 + 열린 탭·짝꿍 노트 정합. 성공 시 새 URL 반환.
    /// 검증 실패는 FileOperationError로 던진다 — 시트가 인라인 표시(전역 errorMessage 미사용).
    @discardableResult
    func performRename(at url: URL, to newName: String) async throws -> URL {
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        let companion = isDirectory ? nil : Self.companionNoteForOperation(mediaURL: url)

        let newURL = try FileOperations.rename(at: url, to: newName)
        await fileOpsLogStore.append(FileOpEntry(kind: .rename, originalURL: url, resultURL: newURL))
        retargetOpenTabs(from: url, to: newURL, isDirectory: isDirectory)

        // 짝꿍 노트 동반 rename(파일명.ext.md 규칙 유지). 실패해도 본체 rename은 유지 — 토스트로 알림.
        if let companion {
            let newNoteName = CompanionNote.noteURL(for: newURL).lastPathComponent
            do {
                let movedNote = try FileOperations.rename(at: companion, to: newNoteName)
                await fileOpsLogStore.append(
                    FileOpEntry(kind: .rename, originalURL: companion, resultURL: movedNote))
                retargetOpenTabs(from: companion, to: movedNote, isDirectory: false)
            } catch {
                showToast("짝꿍 노트 이름은 바꾸지 못했습니다")
            }
        }

        completeFileOperation()
        return newURL
    }

    /// 휴지통 확인 대화상자(제안→확인→실행) — 확인 시 performTrash. NSAlert 관례는 closeAllTabs와 동일.
    func trashWithConfirmation(_ url: URL) {
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        let companion = isDirectory ? nil : Self.companionNoteForOperation(mediaURL: url)

        let alert = NSAlert()
        alert.messageText = "'\(url.lastPathComponent)'을(를) 휴지통으로 이동할까요?"
        var info = "휴지통에서 복구할 수 있고, '파일 작업 기록'에서 되돌릴 수 있습니다."
        if let companion {
            info = "짝꿍 메모('\(companion.lastPathComponent)')도 함께 이동합니다. " + info
        }
        if hasDirtyTab(under: url, isDirectory: isDirectory) {
            info = "저장 안 된 변경이 있는 탭이 닫힙니다. " + info
        }
        alert.informativeText = info
        alert.alertStyle = .warning
        alert.addButton(withTitle: "휴지통으로 이동")
        alert.addButton(withTitle: "취소")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { @MainActor in await performTrash(at: url) }
    }

    /// 휴지통 이동 + 로그 + 관련 탭 닫기(+짝꿍 노트 동반). 확인은 trashWithConfirmation 몫.
    @discardableResult
    func performTrash(at url: URL) async -> Bool {
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        let companion = isDirectory ? nil : Self.companionNoteForOperation(mediaURL: url)

        // 대상(하위 포함)·짝꿍 노트를 보는 탭 먼저 닫는다 — 워처·플레이어 정리는 closeTab이 담당.
        closeTabs(under: url, isDirectory: isDirectory)
        if let companion { closeTabs(under: companion, isDirectory: false) }

        do {
            let trashedURL = try FileOperations.trash(at: url)
            await fileOpsLogStore.append(
                FileOpEntry(kind: .trash, originalURL: url, resultURL: trashedURL))
            if let companion {
                do {
                    let trashedNote = try FileOperations.trash(at: companion)
                    await fileOpsLogStore.append(
                        FileOpEntry(kind: .trash, originalURL: companion, resultURL: trashedNote))
                } catch {
                    showToast("짝꿍 노트는 휴지통으로 옮기지 못했습니다")
                }
            }
            completeFileOperation()
            return true
        } catch {
            errorMessage = (error as? FileOperationError)?.errorDescription
                ?? error.localizedDescription
            return false
        }
    }

    /// 파일 작업 되돌리기 — 성공 시 갱신 트리거까지.
    func undoFileOp(_ entry: FileOpEntry) async -> Bool {
        let ok = await fileOpsLogStore.undo(entry)
        if ok { completeFileOperation() }
        return ok
    }

    /// 파일 작업 성공 후 공통 갱신 — 세대 토큰·트리·세션.
    private func completeFileOperation() {
        fileOpsGeneration += 1
        loadFileTree()
        saveSession()
    }

    /// rename된 경로를 보는 열린 탭들의 URL·제목·문서·파일워처를 새 경로로 옮긴다.
    /// 폴더 rename이면 하위 경로 탭 전부 — '/' 경계 prefix 비교(형제 폴더 오매칭 방지).
    private func retargetOpenTabs(from oldURL: URL, to newURL: URL, isDirectory: Bool) {
        let oldPath = oldURL.standardizedFileURL.path
        for index in tabs.indices {
            guard let tabURL = tabs[index].fileURL else { continue }
            let tabPath = tabURL.standardizedFileURL.path
            let target: URL?
            if tabPath == oldPath {
                target = newURL
            } else if isDirectory, tabPath.hasPrefix(oldPath + "/") {
                target = newURL.appendingPathComponent(String(tabPath.dropFirst(oldPath.count + 1)))
            } else {
                target = nil
            }
            guard let target else { continue }
            let tab = tabs[index]
            tabs[index].fileURL = target
            tabs[index].title = target.lastPathComponent
            documents[tab.documentId]?.fileURL = target
            // 파일 워처 재장전 — 옛 경로 디스크립터를 닫고 새 경로로.
            stopWatchingFile(for: tab.id)
            if !isDirectoryPath(target) {
                startWatchingFile(at: target, for: tab.id)
            }
        }
    }

    /// url(폴더면 하위 포함)을 보는 열린 탭들을 닫는다.
    private func closeTabs(under url: URL, isDirectory: Bool) {
        let basePath = url.standardizedFileURL.path
        let affected = tabs.filter { tab in
            guard let tabURL = tab.fileURL else { return false }
            let tabPath = tabURL.standardizedFileURL.path
            return tabPath == basePath || (isDirectory && tabPath.hasPrefix(basePath + "/"))
        }
        affected.forEach { closeTab($0) }
    }

    /// url 하위(또는 자신)에 더티 탭이 있는가 — 휴지통 확인 문구용.
    private func hasDirtyTab(under url: URL, isDirectory: Bool) -> Bool {
        let basePath = url.standardizedFileURL.path
        return tabs.contains { tab in
            guard let tabURL = tab.fileURL else { return false }
            let tabPath = tabURL.standardizedFileURL.path
            let affected = tabPath == basePath || (isDirectory && tabPath.hasPrefix(basePath + "/"))
            return affected && isTabDirty(tab)
        }
    }

    /// 경로가 디렉터리인가(워처 재장전 가드용 — 탭은 파일만 보지만 방어적으로).
    private func isDirectoryPath(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
    }
```

주의: `tabs[index].title` 대입 규칙은 탭 생성부(`loadAndActivateDocument`)가 title을 어떻게 채우는지 실제 코드로 확인해 미러링한다(확장자 포함/제외). `EditorTab.displayTitle`이 fileURL을 우선하므로 title은 보수적 동기화다.

(e) `createNewFolder(in:)`(:1405-1413) 교체:

```swift
    /// parent 안에 새 폴더 생성 — FileOperations 위임(기본 이름 "새 폴더"·uniquify).
    /// 새 폴더는 작업 로그에 기록하지 않는다(되돌리기=삭제라 정책 충돌 — 스펙 §2).
    func createNewFolder(in parent: URL) {
        do {
            _ = try FileOperations.createFolder(in: parent)
            fileOpsGeneration += 1
            loadFileTree()
        } catch {
            errorMessage = (error as? FileOperationError)?.errorDescription
                ?? error.localizedDescription
        }
    }
```

- [ ] **Step 4: 통과 확인**

Run: `swift test --filter AppFileOpsTests 2>&1 | tail -5`
Expected: PASS (11개). 이어서 `swift test --filter "MoveLogStoreTests|AppCloseAllTabsTests" 2>&1 | tail -3`로 이웃 회귀 확인.

- [ ] **Step 5: 커밋**

```bash
git add Sources/App/AppState.swift Tests/CmdMDTests/AppFileOpsTests.swift
git commit -m "기능(F1a): AppState 파일작업 배선 — rename/trash 오케스트레이션·탭 정합·짝꿍 노트 동반·세대 토큰"
```

---

### Task 6: 이름 변경 시트 + 컨텍스트 메뉴(트리·라이브러리) + folderKey 토큰

**Files:**
- Create: `Sources/Views/RenameSheetView.swift`
- Modify: `Sources/Views/SidebarView.swift:464-561` (`FileTreeContextMenu` — 이름 변경 추가·Move to Trash 대체·private moveToTrash 제거)
- Modify: `Sources/Views/LibraryView.swift` (folderKey에 세대 토큰 + 그리드/리스트 셀 `.contextMenu` + `LibraryCellContextMenu` 신설)
- Modify: `Sources/Views/ContentView.swift:110-113` (`.sheet(item: $state.renameRequest)` 삽입)

**Interfaces:**
- Consumes: `appState.performRename(at:to:)`·`trashWithConfirmation(_:)`·`createNewFolder(in:)`·`renameRequest`·`fileOpsGeneration`(Task 5), `FileOperationError`(Task 1).
- Produces: `RenameSheetView(request:)`, `LibraryCellContextMenu(item:)`(그리드·리스트 공통 — Task 7이 "정보 보기" 항목을 여기 추가). UI 태스크 — 검증은 수동 스모크(로직은 Task 5 테스트가 커버).

- [ ] **Step 1: RenameSheetView 작성**

`Sources/Views/RenameSheetView.swift` 신규:

```swift
import SwiftUI

/// 이름 변경 시트 — 현재 이름 프리필, Return 확정, Esc 취소, 에러 인라인 표시.
struct RenameSheetView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    let request: RenameRequest

    @State private var newName: String = ""
    @State private var errorText: String?
    @FocusState private var nameFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("이름 변경").font(.headline)
            TextField("새 이름", text: $newName)
                .textFieldStyle(.roundedBorder)
                .focused($nameFieldFocused)
                .onSubmit { confirm() }
                .frame(width: 320)
            if let errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("취소") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("이름 변경") { confirm() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .onAppear {
            newName = request.url.lastPathComponent
            nameFieldFocused = true
        }
    }

    private func confirm() {
        Task { @MainActor in
            do {
                try await appState.performRename(at: request.url, to: newName)
                dismiss()
            } catch {
                errorText = (error as? FileOperationError)?.errorDescription
                    ?? error.localizedDescription
            }
        }
    }
}
```

- [ ] **Step 2: 트리 컨텍스트 메뉴 수정**

`Sources/Views/SidebarView.swift`의 `FileTreeContextMenu`:

(a) 즐겨찾기 분기 앞(공통 영역 시작)에 추가:

```swift
        Button {
            appState.renameRequest = RenameRequest(url: item.url)
        } label: {
            Label("이름 변경…", systemImage: "pencil")
        }
        Divider()
```

(b) 기존 "Move to Trash" 버튼(:524-528)의 액션을 확인+로그 경로로 교체하고 라벨을 한국어로:

```swift
        Button(role: .destructive) {
            appState.trashWithConfirmation(item.url)
        } label: {
            Label("휴지통으로 이동", systemImage: "trash")
        }
```

(c) 더는 안 쓰는 private `moveToTrash(_:)`(:543-546)를 제거한다(무확인·무로그 경로 잔존 금지).

- [ ] **Step 3: 라이브러리 셀 컨텍스트 메뉴 + folderKey 토큰**

`Sources/Views/LibraryView.swift`:

(a) folderKey(:16-18)에 세대 토큰 결합:

```swift
    /// 폴더(또는 정렬 기준 currentFolder)가 바뀔 때, 그리고 파일 작업 후 재계산하기 위한 키.
    private var folderKey: String {
        "\(displayFolder?.path ?? "∅")|\(appState.currentFolder?.path ?? "∅")|\(appState.fileOpsGeneration)"
    }
```

(b) 그리드 ForEach(:110-121)와 리스트 ForEach(:126-138)의 셀에 `.contextMenu` 추가 — `.onTapGesture`와 같은 층:

```swift
                LibraryGridCell(item: item)
                    .onTapGesture { handleTap(item: item) }
                    .contextMenu { LibraryCellContextMenu(item: item) }
```

```swift
                LibraryListCell(item: item)
                    .onTapGesture { handleTap(item: item) }
                    .contextMenu { LibraryCellContextMenu(item: item) }
                    .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
```

(c) 같은 파일 하단에 공용 메뉴 신설:

```swift
/// 라이브러리 셀 우클릭 메뉴 — 그리드·리스트 공통(스펙 §3). 빈 영역 우클릭은 범위 밖.
struct LibraryCellContextMenu: View {
    @Environment(AppState.self) private var appState
    let item: FileTreeItem

    var body: some View {
        Button {
            appState.renameRequest = RenameRequest(url: item.url)
        } label: {
            Label("이름 변경…", systemImage: "pencil")
        }
        if item.isDirectory {
            Button {
                appState.createNewFolder(in: item.url)
            } label: {
                Label("이 안에 새 폴더", systemImage: "folder.badge.plus")
            }
        }
        Divider()
        Button(role: .destructive) {
            appState.trashWithConfirmation(item.url)
        } label: {
            Label("휴지통으로 이동", systemImage: "trash")
        }
    }
}
```

- [ ] **Step 4: ContentView 시트 배선**

`Sources/Views/ContentView.swift` — `.sheet(isPresented: $state.showFolderCleanup)`(:110-112) 뒤, `.alert`(:113) 앞에:

```swift
        .sheet(item: $state.renameRequest) { request in
            RenameSheetView(request: request)
        }
```

- [ ] **Step 5: 빌드·회귀 확인**

Run: `swift build 2>&1 | tail -3` → Expected: Build complete, 경고 0.
Run: `swift test --filter "AppFileOpsTests|LibraryListingTests" 2>&1 | tail -3` → Expected: PASS.

- [ ] **Step 6: 커밋**

```bash
git add Sources/Views/RenameSheetView.swift Sources/Views/SidebarView.swift Sources/Views/LibraryView.swift Sources/Views/ContentView.swift
git commit -m "기능(F1a): 이름 변경 시트·트리/라이브러리 컨텍스트 메뉴·휴지통 확인 경로 — 무로그 trash 대체"
```

---

### Task 7: 정보 보기 — `FileInfoView` + ⌥⌘I + 팔레트 + 메뉴 항목

**Files:**
- Create: `Sources/Views/FileInfoView.swift`
- Modify: `Sources/Models/Shortcuts.swift` (case `fileInfo` + title + defaultBinding)
- Modify: `Sources/App/AppState.swift` (`showFileInfoForCurrentContext()`)
- Modify: `Sources/App/CmdMDApp.swift:113-170` (View 메뉴 항목)
- Modify: `Sources/Views/ContentView.swift` (`.sheet(item: $state.fileInfoRequest)`)
- Modify: `Sources/Views/CommandPaletteView.swift` (팔레트 항목 신설 + :406 스테일 "⌥⌘I" 정정)
- Modify: `Sources/Views/SidebarView.swift`·`Sources/Views/LibraryView.swift` (컨텍스트 메뉴에 "정보 보기")
- Test: `Tests/CmdMDTests/ShortcutDefaultsTests.swift` (기본값 1줄 추가), `Tests/CmdMDTests/AppFileOpsTests.swift` (대상 규칙 테스트 추가)

**Interfaces:**
- Consumes: `FileInfoService`·`FileInfo`(Task 3), `fileInfoRequest`·`FileInfoRequest`(Task 5), `LibraryCellContextMenu`(Task 6), `KeyBinding.displayString`, `appShortcut(_:)`.
- Produces: `FileInfoView(request:)`, `AppShortcut.fileInfo`(⌥⌘I), `AppState.showFileInfoForCurrentContext()`.

- [ ] **Step 1: 실패하는 테스트 작성**

(a) `Tests/CmdMDTests/ShortcutDefaultsTests.swift`의 `testPhase10ShortcutDefaults` 아래에 추가:

```swift
    func testFileInfoShortcutDefault() {
        // F1a 정보 보기 — ⌘I는 Format Italic 선점(마크다운 에디터 관례)이라 ⌥⌘I.
        XCTAssertEqual(AppShortcut.fileInfo.defaultBinding,
                       KeyBinding(key: "i", command: true, option: true))
    }
```

(유일성은 기존 `testDefaultBindingsAreUnique`가 allCases 전수라 자동 포함.)

(b) `Tests/CmdMDTests/AppFileOpsTests.swift`에 추가:

```swift
    // MARK: 정보 보기 대상 규칙 (스펙 §7.2)

    func testShowFileInfoTargetInReaderMode() throws {
        let file = try makeFile("정보대상.md")
        appState.mainMode = .reader
        appState.fileInfoRequest = nil
        appState.showFileInfoForCurrentContext()
        XCTAssertNil(appState.fileInfoRequest)          // 탭 없음 → 비활성(무동작)

        _ = openTab(at: file)
        appState.activeTabId = appState.tabs.last?.id
        appState.showFileInfoForCurrentContext()
        XCTAssertEqual(appState.fileInfoRequest?.url, file)
    }

    func testShowFileInfoTargetInLibraryMode() {
        appState.mainMode = .library
        appState.currentFolder = work
        appState.selectedFolder = nil
        appState.showFileInfoForCurrentContext()
        XCTAssertEqual(appState.fileInfoRequest?.url, work)   // selectedFolder 없으면 currentFolder

        let sub = work.appendingPathComponent("하위")
        try? FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        appState.selectedFolder = sub
        appState.showFileInfoForCurrentContext()
        XCTAssertEqual(appState.fileInfoRequest?.url, sub)
    }
```

- [ ] **Step 2: 실패 확인**

Run: `swift test --filter "ShortcutDefaultsTests|AppFileOpsTests" 2>&1 | tail -5`
Expected: 컴파일 실패 — `type 'AppShortcut' has no member 'fileInfo'`.

- [ ] **Step 3: 구현**

(a) `Sources/Models/Shortcuts.swift`:
- enum에 `case fileInfo` 추가(`folderCleanup` 아래).
- `title`에 `case .fileInfo: return "File Info (정보 보기)"` 추가.
- `defaultBinding`에 `case .fileInfo: return KeyBinding(key: "i", command: true, option: true)  // ⌥⌘I` 추가.

(b) `Sources/App/AppState.swift` — Task 5의 파일작업 MARK 섹션에:

```swift
    /// 현재 컨텍스트의 정보 보기 대상 — 리더=활성 탭 파일(없으면 무동작),
    /// 라이브러리=표시 중 폴더(selectedFolder ?? currentFolder). 스펙 §7.2.
    func showFileInfoForCurrentContext() {
        switch mainMode {
        case .reader:
            guard let url = activeTab?.fileURL else { return }
            fileInfoRequest = FileInfoRequest(url: url)
        case .library:
            guard let folder = selectedFolder ?? currentFolder else { return }
            fileInfoRequest = FileInfoRequest(url: folder)
        }
    }
```

(c) `Sources/Views/FileInfoView.swift` 신규:

```swift
import SwiftUI

/// 파일/폴더 정보 시트(⌥⌘I) — 기본 필드 즉시 + 종류별 한 줄·폴더 크기 비동기.
/// 시트가 닫히면 .task가 취소돼 폴더 크기 계산도 중단된다.
struct FileInfoView: View {
    @Environment(\.dismiss) private var dismiss
    let request: FileInfoRequest

    @State private var info: FileInfo?
    @State private var detail: String?
    @State private var folderSizeText: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("정보").font(.headline)
            if let info {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 6) {
                    row("이름", info.name)
                    row("종류", info.kindLabel)
                    row("크기", sizeText(info))
                    row("위치", info.locationPath)
                    row("생성일", formatted(info.createdAt))
                    row("수정일", formatted(info.modifiedAt))
                    // 종류별 한 줄 — 도착 전에도 자리 예약(리플로우 방지, 리스트 셀 summary 관례)
                    row("정보", detail ?? " ")
                }
            }
            HStack {
                Spacer()
                Button("닫기") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
        .task(id: request.url) {
            let basic = FileInfoService.loadBasic(url: request.url)
            info = basic
            detail = await FileInfoService.loadDetail(url: request.url, isDirectory: basic.isDirectory)
            if basic.isDirectory {
                folderSizeText = "계산 중…"
                if let bytes = try? await FileInfoService.computeFolderSize(url: request.url) {
                    folderSizeText = FileInfoService.formatSize(bytes)
                } else {
                    folderSizeText = "--"   // 취소·실패
                }
            }
        }
    }

    private func sizeText(_ info: FileInfo) -> String {
        if info.isDirectory { return folderSizeText ?? "계산 중…" }
        return info.sizeBytes.map(FileInfoService.formatSize) ?? "--"
    }

    private func formatted(_ date: Date?) -> String {
        date?.formatted(.dateTime.year().month().day().hour().minute()) ?? "--"
    }

    @ViewBuilder
    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label)
                .foregroundStyle(.secondary)
                .gridColumnAlignment(.trailing)
            Text(value)
                .textSelection(.enabled)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
```

(d) `Sources/Views/ContentView.swift` — Task 6의 renameRequest 시트 뒤에:

```swift
        .sheet(item: $state.fileInfoRequest) { request in
            FileInfoView(request: request)
        }
```

(e) `Sources/App/CmdMDApp.swift` View 메뉴 — "폴더 정리 (배치)" 버튼 아래:

```swift
                Button("정보 보기") {
                    appState.showFileInfoForCurrentContext()
                }
                .appShortcut(appState.keyBinding(for: .fileInfo))
```

(f) `Sources/Views/CommandPaletteView.swift`:
- "폴더 정리 (배치)" Command 항목 뒤에 신설:

```swift
            Command(
                title: "정보 보기",
                subtitle: "현재 파일 또는 폴더의 종류·크기·날짜",
                icon: "info.circle",
                shortcut: appState.keyBinding(for: .fileInfo).displayString,
                keywords: ["정보", "info", "크기", "size", "날짜", "get info", "파일 정보"]
            ) {
                appState.showFileInfoForCurrentContext()
            },
```

- :406 "Toggle Inspector" 항목의 스테일 `shortcut: "⌥⌘I"`를 실제 바인딩으로 정정(정보 보기 ⌥⌘I와의 표기 충돌 방지):

```swift
                shortcut: appState.keyBinding(for: .toggleInspector).displayString,
```

(g) 컨텍스트 메뉴 "정보 보기" 항목 — `FileTreeContextMenu`(Task 6에서 넣은 "이름 변경…" 아래)와 `LibraryCellContextMenu`("이름 변경…" 아래) 양쪽에:

```swift
        Button {
            appState.fileInfoRequest = FileInfoRequest(url: item.url)
        } label: {
            Label("정보 보기", systemImage: "info.circle")
        }
```

- [ ] **Step 4: 통과 확인**

Run: `swift test --filter "ShortcutDefaultsTests|AppFileOpsTests" 2>&1 | tail -5`
Expected: PASS. 이어서 `swift build 2>&1 | tail -3` — 경고 0.

- [ ] **Step 5: 커밋**

```bash
git add Sources/Views/FileInfoView.swift Sources/Models/Shortcuts.swift Sources/App/AppState.swift Sources/App/CmdMDApp.swift Sources/Views/ContentView.swift Sources/Views/CommandPaletteView.swift Sources/Views/SidebarView.swift Sources/Views/LibraryView.swift Tests/CmdMDTests/ShortcutDefaultsTests.swift Tests/CmdMDTests/AppFileOpsTests.swift
git commit -m "기능(F1a): 정보 보기 — FileInfoView 시트·⌥⌘I(fileInfo)·팔레트·컨텍스트 메뉴, 스테일 ⌥⌘I 라벨 정정"
```

---

### Task 8: 파일 작업 기록 시트 (`FileOpsHistoryView`) + 진입점

**Files:**
- Create: `Sources/Views/FileOpsHistoryView.swift`
- Modify: `Sources/Views/ContentView.swift` (`.sheet(isPresented: $state.showFileOpsHistory)`)
- Modify: `Sources/App/CmdMDApp.swift` (View 메뉴 "파일 작업 기록")
- Modify: `Sources/Views/CommandPaletteView.swift` (팔레트 항목)

**Interfaces:**
- Consumes: `appState.fileOpsLogStore.load()`·`appState.undoFileOp(_:)`(Task 5), `FileOpEntry`(Task 2), `showFileOpsHistory`(Task 5).
- Produces: `FileOpsHistoryView()`. 로직은 Task 2·5 테스트가 커버 — 뷰는 수동 스모크.

- [ ] **Step 1: FileOpsHistoryView 작성**

`Sources/Views/FileOpsHistoryView.swift` 신규:

```swift
import SwiftUI

/// 파일 작업 기록 시트 — 아직 되돌릴 수 있는 휴지통/이름변경 목록 + 행별 되돌리기.
/// 되돌리기 성공 시 목록에서 사라지고(스토어가 제거), 실패 시 행에 사유 캡션.
struct FileOpsHistoryView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var entries: [FileOpEntry] = []
    @State private var failedIds: Set<UUID> = []
    @State private var isLoading = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("파일 작업 기록").font(.headline)
            content
            HStack {
                Spacer()
                Button("닫기") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480, height: 360)
        .task { await reload() }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        } else if entries.isEmpty {
            Text("되돌릴 수 있는 작업이 없습니다.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        } else {
            List {
                // 최근 작업이 위로
                ForEach(entries.reversed()) { entry in
                    row(entry)
                }
            }
            .listStyle(.plain)
        }
    }

    private func reload() async {
        entries = await appState.fileOpsLogStore.load()
        isLoading = false
    }

    @ViewBuilder
    private func row(_ entry: FileOpEntry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: entry.kind == .trash ? "trash" : "pencil")
                .foregroundStyle(.secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(rowTitle(entry)).lineLimit(1)
                Text(entry.date.formatted(.dateTime.month().day().hour().minute()))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if failedIds.contains(entry.id) {
                    Text("되돌리지 못했습니다 — 원위치가 사용 중이거나 항목이 사라졌습니다.")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            Spacer()
            Button("되돌리기") {
                Task { @MainActor in
                    if await appState.undoFileOp(entry) {
                        failedIds.remove(entry.id)
                        await reload()
                    } else {
                        failedIds.insert(entry.id)
                    }
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func rowTitle(_ entry: FileOpEntry) -> String {
        switch entry.kind {
        case .trash:
            return "휴지통: \(entry.originalURL.lastPathComponent)"
        case .rename:
            return "이름 변경: \(entry.originalURL.lastPathComponent) → \(entry.resultURL.lastPathComponent)"
        }
    }
}
```

- [ ] **Step 2: 진입점 배선**

(a) `Sources/Views/ContentView.swift` — fileInfoRequest 시트 뒤에:

```swift
        .sheet(isPresented: $state.showFileOpsHistory) {
            FileOpsHistoryView()
        }
```

(b) `Sources/App/CmdMDApp.swift` View 메뉴 — "정보 보기" 버튼 아래(단축키 없음):

```swift
                Button("파일 작업 기록") {
                    appState.showFileOpsHistory = true
                }
```

(c) `Sources/Views/CommandPaletteView.swift` — "정보 보기" Command 뒤에:

```swift
            Command(
                title: "파일 작업 기록",
                subtitle: "휴지통·이름 변경 기록을 보고 되돌리기",
                icon: "clock.arrow.circlepath",
                shortcut: nil,
                keywords: ["기록", "되돌리기", "undo", "휴지통", "history", "파일 작업"]
            ) {
                appState.showFileOpsHistory = true
            },
```

- [ ] **Step 3: 빌드·회귀 확인**

Run: `swift build 2>&1 | tail -3` → Build complete, 경고 0.
Run: `swift test --filter "FileOpsLogStoreTests|AppFileOpsTests" 2>&1 | tail -3` → PASS.

- [ ] **Step 4: 커밋**

```bash
git add Sources/Views/FileOpsHistoryView.swift Sources/Views/ContentView.swift Sources/App/CmdMDApp.swift Sources/Views/CommandPaletteView.swift
git commit -m "기능(F1a): 파일 작업 기록 시트 — 행별 되돌리기·실패 캡션, View 메뉴·팔레트 진입점"
```

---

### Task 9: README 갱신 + 전체 게이트

**Files:**
- Modify: `README.md` (:72-84 기능 목록, :115 테스트 수, :127-135 단축키 표)

**Interfaces:**
- Consumes: 전체 스위트 실행 결과(테스트 수).
- Produces: 문서 정합. 코드 변경 없음.

- [ ] **Step 1: 전체 테스트 게이트**

Run: `swift test 2>&1 | tail -5`
Expected: 전부 통과. `Executed N tests` 수를 기록한다(기준 406 + 이 계획 신규 ≈ 40+ → 약 446 안팎, 실측값 사용).

- [ ] **Step 2: README 수정**

(a) 기능 목록(:84 "PARA 라이브러리 뷰" 다음)에 추가:

```markdown
- **파일 관리(F1a)** — 트리·라이브러리 우클릭으로 이름 변경·새 폴더·휴지통 이동(확인 후 실행, 영구 삭제 없음). 모든 작업은 **작업 로그에 남아 앱 안에서 되돌리기** 가능. `⌥⌘I` 정보 보기(크기·날짜·해상도/페이지/길이, 폴더 크기 비동기 계산)와 라이브러리 리스트의 크기·수정일 열까지 — 이름 하나 바꾸려고 Finder를 열 일이 없습니다.
```

(b) 테스트 수(:115)를 실측값으로 갱신:

```bash
swift test                          # <실측 N> tests (XCTest <N-18> + Swift Testing 18, 정식 Xcode 필요)
```

(c) 단축키 표(:127-135)에 Phase 10 이후 누락분과 신규를 추가(표 행):

```markdown
| Search index (내용 검색) | `⌥⌘F` | | Ask corpus (자료에 묻기) | `⌥⌘A` |
| Reader ⇄ Library | `⇧⌘L` | | Folder cleanup (폴더 정리) | `⌥⌘K` |
| File info (정보 보기) | `⌥⌘I` | | Close all tabs | `⌥⌘W` |
```

- [ ] **Step 3: 커밋**

```bash
git add README.md
git commit -m "문서: README — F1a 파일 관리 기능·단축키 표(⌥⌘I 등)·테스트 수 갱신"
```

---

## 수동 스모크 체크리스트 (구현 완료 후 실앱)

스펙 §5·§7.4 통합:

1. 트리 우클릭 이름 변경 — 열린 탭 제목·URL 추종, 충돌 이름 인라인 에러
2. 라이브러리 그리드·리스트 셀 우클릭 — 같은 메뉴, 폴더 셀 "이 안에 새 폴더"(이름 "새 폴더")
3. 휴지통 — 확인 문구(짝꿍 노트·더티 탭 경고 포함), Finder 휴지통에서 실물 확인, 관련 탭 닫힘
4. 파일 작업 기록 — 행별 되돌리기(성공=목록에서 제거), 원위치 점유 시 실패 캡션
5. 미디어+짝꿍 노트 — rename·trash 동반, 로그 2건
6. 정보 보기 — 트리/라이브러리 우클릭, ⌥⌘I 리더(활성 탭)/라이브러리(표시 폴더) 대상 규칙, 큰 폴더 "계산 중…" 중 시트 닫기(크래시 없음), 이미지 해상도·PDF 페이지·미디어 길이
7. 리스트 열 — 크기·수정일 표시, 파일 작업 직후 리스트·트리 갱신(세대 토큰)
8. ⌘I는 여전히 에디터 이탤릭(선점 유지), 팔레트 Toggle Inspector 표기가 ⌃⌘→로 정정됐는지
