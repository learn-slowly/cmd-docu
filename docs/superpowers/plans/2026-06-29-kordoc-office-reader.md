# 한글·오피스 읽기 (kordoc, Phase 3) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** HWP·HWPX·오피스 파일을 탭으로 열면 kordoc CLI가 마크다운으로 변환해 읽기전용으로 렌더한다(원본 미변경, 비동기 로딩/에러 안내).

**Architecture:** 이미지/PDF에서 쓴 `DocumentKind` 분기 + 외부 CLI 비동기. `KordocService`(actor)가 npx 절대경로를 탐지해 `kordoc <file> --format json -o <tmp> --silent`를 `Process`로 실행, JSON을 `KordocResult`로 디코드한다. office 탭은 `MarkdownDocument` 없이 생성하고, 변환 결과는 `AppState.officeStates[tabID]`에 보관해 `OfficeReaderView`가 로딩/완료(기존 마크다운 프리뷰)/실패로 렌더한다.

**Tech Stack:** Swift 5.9+ / SwiftUI / Foundation `Process` / 외부 kordoc(Node 18+) / XCTest. macOS 14+, 비샌드박스.

## Global Constraints

- macOS 14+, Swift 5.9+. **비샌드박스 유지**(서브프로세스 호출 필수). Swift 외 추가 의존성 없음(kordoc은 외부 CLI).
- Phase 게이트: 각 Task 테스트 + **기존 84개 XCTest 전부 통과**. `swift test`는 정식 Xcode에서만.
- **kordoc은 직접 구현하지 않는다.** `Process`로 호출, 경로 탐지 실패·변환 실패·타임아웃은 **크래시 없이 안내 상태**로 전달.
- **원본 read-only**: office 탭은 저장/편집 경로를 거치지 않는다(이미지/PDF처럼 `documents[]`에 없음).
- 신규 로직(모델/서비스/뷰)은 별도 파일로 격리. 기존 파일은 분기 확장 위주, 마크다운·이미지·PDF 동작 불변.
- 내부 식별자 `CmdMD`·URL 스킴 `cmdmd`·원작자 고지 유지.
- 커밋 메시지 한국어. **모든 커밋 끝에**:
  ```
  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01S2QuZUALidkTNRswXFL6xM
  ```
- 작업 브랜치: `cmd-docu`.

## 검증된 kordoc 계약 (실측)
- 실행: `npx -y kordoc <파일> --format json -o <출력.json> --silent` → 종료코드 0, 출력은 **-o 파일**(stdout 아님).
- JSON: `{ success:Bool, fileType:String, markdown:String, blocks:[{type,text,pageNumber,level,style}], outline:[{level,text,pageNumber}], metadata:{version,pageCount} }`. (`style`/`metadata`는 자유형식 — 디코딩 무시.)
- node/npx: `/opt/homebrew/bin`. GUI 앱은 PATH 미상속 → 절대경로 탐지 필요.

## File Structure
| 파일 | 책임 | 변경 |
| --- | --- | --- |
| `Sources/Models/KordocResult.swift` | kordoc JSON Codable 모델 | 신규 |
| `Tests/CmdMDTests/KordocResultTests.swift` | JSON 디코딩 검증 | 신규 |
| `Sources/Models/DocumentKind.swift` | `.office` + officeExtensions | 수정 |
| `Tests/CmdMDTests/DocumentKindTests.swift` | office 매핑 | 수정 |
| `Sources/Services/KordocService.swift` | npx 탐지 + Process 변환 + 디코드 | 신규 |
| `Sources/App/AppState.swift` | officeStates·로드 분기·재시도·패널·목록·정리 | 수정 |
| `Tests/CmdMDTests/FileTreeListingTests.swift` | office 목록 | 수정 |
| `Tests/CmdMDTests/AppOfficeTabTests.swift` | office 탭 노출 프로퍼티 | 신규 |
| `Sources/Views/OfficeReaderView.swift` | loading/loaded(프리뷰)/failed | 신규 |
| `Sources/Views/MainEditorView.swift` | `.office` 분기 | 수정 |

현재 코드 참고:
- `DocumentKind`: `case markdown/image/pdf`, `imageExtensions`, `pdfExtensions=["pdf"]`, `init(from:)`(image→pdf→markdown).
- `AppState`: `loadAndActivateDocument`의 비마크다운 분기 `if kind == .image || kind == .pdf { EditorTab(kind:) … placeTab … return }`; `isListableInFileTree`(md/txt+image+pdf); `openFile` 패널 `[.plainText, UTType(filenameExtension:"md")!, .png, .jpeg, .heic, .webP, .gif, .pdf]`; `placeTab`(교체 시 documents/originalContents/watcher 정리); `closeTab`; `renderOptions()`; `private let fileService`.
- `MainEditorView.body` Group: image→pdf→currentDocument→Welcome 분기, `currentTabFileURL`/`currentTabKind`/`activeTabId` 존재.
- `MarkdownPreviewView(documentID:markdown:baseURL:options:scrollSyncEnabled:)` (읽기전용 렌더 재사용 가능).

---

## Task 1: KordocResult 모델 + 디코딩 테스트

**Files:**
- Create: `Sources/Models/KordocResult.swift`
- Test: `Tests/CmdMDTests/KordocResultTests.swift`

**Interfaces:**
- Produces:
  - `struct KordocResult: Codable { let success: Bool; let fileType: String; let markdown: String; let blocks: [KordocBlock]?; let outline: [KordocOutlineItem]? }`
  - `struct KordocBlock: Codable { let type: String; let text: String?; let pageNumber: Int?; let level: Int? }`
  - `struct KordocOutlineItem: Codable { let level: Int?; let text: String?; let pageNumber: Int? }`

- [ ] **Step 1: 실패 테스트 작성**

Create `Tests/CmdMDTests/KordocResultTests.swift`:
```swift
import XCTest
@testable import CmdMD

final class KordocResultTests: XCTestCase {
    private let json = """
    {
      "success": true,
      "fileType": "hwp",
      "markdown": "# 제목\\n\\n본문",
      "blocks": [
        {"type":"heading","text":"제목","pageNumber":1,"level":1,"style":{"fontSize":20}},
        {"type":"paragraph","text":"본문","pageNumber":1,"style":{"fontSize":10}}
      ],
      "metadata": {"version":"5.0","pageCount":3},
      "outline": [{"level":1,"text":"제목","pageNumber":1}]
    }
    """.data(using: .utf8)!

    func testDecodesCoreFields() throws {
        let r = try JSONDecoder().decode(KordocResult.self, from: json)
        XCTAssertTrue(r.success)
        XCTAssertEqual(r.fileType, "hwp")
        XCTAssertEqual(r.markdown, "# 제목\n\n본문")
    }

    func testDecodesBlocksAndOutline() throws {
        let r = try JSONDecoder().decode(KordocResult.self, from: json)
        XCTAssertEqual(r.blocks?.count, 2)
        XCTAssertEqual(r.blocks?.first?.type, "heading")
        XCTAssertEqual(r.blocks?.first?.level, 1)
        XCTAssertEqual(r.blocks?[1].pageNumber, 1)
        XCTAssertEqual(r.outline?.first?.text, "제목")
        XCTAssertEqual(r.outline?.first?.level, 1)
    }

    func testMissingOptionalArraysDecodeAsNil() throws {
        let minimal = #"{"success":true,"fileType":"docx","markdown":"hi"}"#.data(using: .utf8)!
        let r = try JSONDecoder().decode(KordocResult.self, from: minimal)
        XCTAssertNil(r.blocks)
        XCTAssertNil(r.outline)
        XCTAssertEqual(r.markdown, "hi")
    }

    func testMalformedJSONThrows() {
        let bad = "not json".data(using: .utf8)!
        XCTAssertThrowsError(try JSONDecoder().decode(KordocResult.self, from: bad))
    }
}
```

- [ ] **Step 2: 실패 확인**

Run: `swift test --filter KordocResultTests`
Expected: FAIL — `cannot find 'KordocResult' in scope`

- [ ] **Step 3: 구현**

Create `Sources/Models/KordocResult.swift`:
```swift
import Foundation

/// kordoc `--format json` 출력 모델. `style`/`metadata` 등 자유형식 키는
/// 선언하지 않으면 Codable이 자동으로 무시한다(필요 시 추후 추가).
struct KordocResult: Codable {
    let success: Bool
    let fileType: String
    let markdown: String
    let blocks: [KordocBlock]?
    let outline: [KordocOutlineItem]?
}

struct KordocBlock: Codable {
    let type: String
    let text: String?
    let pageNumber: Int?
    let level: Int?
}

struct KordocOutlineItem: Codable {
    let level: Int?
    let text: String?
    let pageNumber: Int?
}
```

- [ ] **Step 4: 통과 확인**

Run: `swift test --filter KordocResultTests`
Expected: PASS (4)

- [ ] **Step 5: 커밋**
```bash
git add Sources/Models/KordocResult.swift Tests/CmdMDTests/KordocResultTests.swift
git commit -m "$(cat <<'EOF'
kordoc 읽기(Phase 3): KordocResult JSON 모델 추가

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01S2QuZUALidkTNRswXFL6xM
EOF
)"
```

---

## Task 2: DocumentKind.office + 목록 + 패널

**Files:**
- Modify: `Sources/Models/DocumentKind.swift`
- Modify: `Sources/App/AppState.swift` (`isListableInFileTree`, `openFile` 패널)
- Test: `Tests/CmdMDTests/DocumentKindTests.swift`, `Tests/CmdMDTests/FileTreeListingTests.swift`

**Interfaces:**
- Consumes: 기존 DocumentKind
- Produces: `DocumentKind.office`, `DocumentKind.officeExtensions: Set<String>`, `init(from:)`가 office 확장자→`.office`; `isListableInFileTree`·패널에 office 포함

- [ ] **Step 1: 실패 테스트 작성**

`Tests/CmdMDTests/DocumentKindTests.swift`의 클래스 안에 추가:
```swift
    func testOfficeExtensionsMapToOffice() {
        for ext in ["hwp", "hwpx", "hwpml", "doc", "docx", "xls", "xlsx"] {
            XCTAssertEqual(kind("file.\(ext)"), .office, "\(ext) should be office")
        }
    }

    func testOfficeUppercaseMapsToOffice() {
        XCTAssertEqual(kind("문서.HWP"), .office)
        XCTAssertEqual(kind("Sheet.XLSX"), .office)
    }

    func testPdfStillPdfAndImageUnchanged() {
        XCTAssertEqual(kind("a.pdf"), .pdf)
        XCTAssertEqual(kind("a.png"), .image)
        XCTAssertEqual(kind("a.md"), .markdown)
    }
```
`Tests/CmdMDTests/FileTreeListingTests.swift`의 클래스 안에 추가:
```swift
    func testOfficeFilesAreListed() {
        for ext in ["hwp", "hwpx", "docx", "xlsx"] {
            XCTAssertTrue(listable("doc.\(ext)"), "\(ext) should be listed")
        }
    }
```
그리고 같은 파일의 `testUnsupportedFilesAreNotListed`에서 office 확장자를 제거(이제 지원). 해당 메서드를 아래로 교체:
```swift
    func testUnsupportedFilesAreNotListed() {
        for ext in ["zip", "mp3", "exe"] {
            XCTAssertFalse(listable("doc.\(ext)"), "\(ext) should not be listed")
        }
    }
```

- [ ] **Step 2: 실패 확인**

Run: `swift test --filter DocumentKindTests` 및 `--filter FileTreeListingTests`
Expected: FAIL — `type 'DocumentKind' has no member 'office'`

- [ ] **Step 3: DocumentKind 구현**

`Sources/Models/DocumentKind.swift` — enum에 `case office` 추가:
```swift
enum DocumentKind: String, Codable {
    case markdown
    case image
    case pdf
    case office
}
```
extension에 officeExtensions 추가, `init(from:)`를 아래로 교체:
```swift
    /// kordoc으로 마크다운 변환해 보는 한글·오피스 확장자(소문자).
    static let officeExtensions: Set<String> = ["hwp", "hwpx", "hwpml", "doc", "docx", "xls", "xlsx"]

    /// 확장자(대소문자 무시): 이미지 → PDF → 오피스 → 마크다운(기본).
    init(from url: URL) {
        let ext = url.pathExtension.lowercased()
        if DocumentKind.imageExtensions.contains(ext) {
            self = .image
        } else if DocumentKind.pdfExtensions.contains(ext) {
            self = .pdf
        } else if DocumentKind.officeExtensions.contains(ext) {
            self = .office
        } else {
            self = .markdown
        }
    }
```

- [ ] **Step 4: isListableInFileTree + 패널**

`Sources/App/AppState.swift` `isListableInFileTree`에 office 포함:
```swift
    static func isListableInFileTree(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == "md" || ext == "markdown" || ext == "txt"
            || DocumentKind.imageExtensions.contains(ext)
            || DocumentKind.pdfExtensions.contains(ext)
            || DocumentKind.officeExtensions.contains(ext)
    }
```
`openFile()`의 패널 `allowedContentTypes` 줄을 교체(office UTType 보강 — 시스템 타입 없는 확장자 대비 compactMap):
```swift
        var types: [UTType] = [.plainText, UTType(filenameExtension: "md")!,
                               .png, .jpeg, .heic, .webP, .gif, .pdf]
        types += DocumentKind.officeExtensions.compactMap { UTType(filenameExtension: $0) }
        panel.allowedContentTypes = types
```

- [ ] **Step 5: 통과 + 회귀**

Run: `swift test`
Expected: 기존 84 + 신규 모두 PASS

- [ ] **Step 6: 커밋**
```bash
git add Sources/Models/DocumentKind.swift Sources/App/AppState.swift Tests/CmdMDTests/DocumentKindTests.swift Tests/CmdMDTests/FileTreeListingTests.swift
git commit -m "$(cat <<'EOF'
kordoc 읽기(Phase 3): DocumentKind.office + 목록·패널 포함

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01S2QuZUALidkTNRswXFL6xM
EOF
)"
```

---

## Task 3: KordocService (npx 탐지 + Process 변환)

**Files:**
- Create: `Sources/Services/KordocService.swift`

**Interfaces:**
- Consumes: `KordocResult`(Task 1)
- Produces:
  - `enum KordocError: Error { case toolNotFound; case conversionFailed(String); case timeout; case decodeFailed }`
  - `actor KordocService { func convert(fileURL: URL) async throws -> KordocResult }`
  - `static func KordocService.resolveNpxPath() -> String?`

서브프로세스라 자동 단위테스트 없음. 산출물 = 컴파일 통과(+ 전체 테스트 유지). 동작은 Task 6 실제 HWP로 수동 검증.

- [ ] **Step 1: 구현**

Create `Sources/Services/KordocService.swift`:
```swift
import Foundation

enum KordocError: Error {
    case toolNotFound
    case conversionFailed(String)
    case timeout
    case decodeFailed
}

/// kordoc CLI를 Process로 호출해 한글·오피스 문서를 KordocResult로 변환한다.
/// kordoc 자체는 구현하지 않는다(외부 도구). 실패는 throw로만 — 크래시 금지.
actor KordocService {
    private let timeout: TimeInterval = 120

    func convert(fileURL: URL) async throws -> KordocResult {
        guard let npx = Self.resolveNpxPath() else { throw KordocError.toolNotFound }

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("json")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: npx)
        process.arguments = ["-y", "kordoc", fileURL.path,
                             "--format", "json", "-o", tmp.path, "--silent"]
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = FileHandle.nullDevice   // -o로 출력, stdout 불필요

        do {
            try process.run()
        } catch {
            throw KordocError.toolNotFound
        }

        // 타임아웃 감시(협조적 폴링; --silent라 stderr 버퍼 넘침 위험 낮음).
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            if Date() > deadline {
                process.terminate()
                throw KordocError.timeout
            }
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s
        }

        if process.terminationStatus != 0 {
            let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw KordocError.conversionFailed(String(msg.prefix(500)))
        }

        guard let data = try? Data(contentsOf: tmp) else {
            throw KordocError.conversionFailed("출력 파일이 생성되지 않았습니다.")
        }
        guard let result = try? JSONDecoder().decode(KordocResult.self, from: data) else {
            throw KordocError.decodeFailed
        }
        return result
    }

    /// GUI 앱(.app)은 로그인 셸 PATH를 상속하지 않으므로 npx 절대경로를 탐지한다.
    /// 흔한 설치 경로 → 그래도 없으면 로그인 셸의 `which npx`.
    static func resolveNpxPath() -> String? {
        let candidates = ["/opt/homebrew/bin/npx", "/usr/local/bin/npx", "/usr/bin/npx"]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/bin/zsh")
        probe.arguments = ["-lc", "which npx"]
        let pipe = Pipe()
        probe.standardOutput = pipe
        probe.standardError = FileHandle.nullDevice
        do {
            try probe.run()
            probe.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let out = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !out.isEmpty, FileManager.default.isExecutableFile(atPath: out) {
                return out
            }
        } catch { }
        return nil
    }
}
```

- [ ] **Step 2: 빌드 + 전체 테스트**

Run: `swift build && swift test`
Expected: Build complete! + 기존 테스트 PASS(서비스는 아직 미배선)

- [ ] **Step 3: 커밋**
```bash
git add Sources/Services/KordocService.swift
git commit -m "$(cat <<'EOF'
kordoc 읽기(Phase 3): KordocService(npx 탐지+Process 변환) 추가

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01S2QuZUALidkTNRswXFL6xM
EOF
)"
```

---

## Task 4: AppState 오피스 로드 분기 + 상태

**Files:**
- Modify: `Sources/App/AppState.swift`
- Test: `Tests/CmdMDTests/AppOfficeTabTests.swift`

**Interfaces:**
- Consumes: `DocumentKind.office`, `KordocService`, `KordocResult`, `EditorTab(kind:)`, `placeTab`
- Produces:
  - `enum OfficeState { case loading; case loaded(KordocResult); case failed(String) }`
  - `AppState.officeStates: [UUID: OfficeState]`
  - `AppState.retryOfficeConversion(tabID:fileURL:)`
  - `loadAndActivateDocument`가 office 탭 생성 + 변환 트리거

- [ ] **Step 1: 실패 테스트 작성**

Create `Tests/CmdMDTests/AppOfficeTabTests.swift`:
```swift
import XCTest
@testable import CmdMD

final class AppOfficeTabTests: XCTestCase {
    func testCurrentTabKindReflectsActiveOfficeTab() {
        let appState = AppState()
        let tab = EditorTab(fileURL: URL(fileURLWithPath: "/tmp/report.hwp"),
                            title: "report", kind: .office)
        appState.tabs = [tab]
        appState.activeTabId = tab.id

        XCTAssertEqual(appState.currentTabKind, .office)
        XCTAssertEqual(appState.currentTabFileURL, URL(fileURLWithPath: "/tmp/report.hwp"))
    }

    func testWindowTitleUsesFilenameForOfficeTab() {
        let appState = AppState()
        let tab = EditorTab(fileURL: URL(fileURLWithPath: "/tmp/평가서.hwp"),
                            title: "평가서", kind: .office)
        appState.tabs = [tab]
        appState.activeTabId = tab.id
        XCTAssertEqual(appState.windowTitle, "평가서")
    }
}
```

- [ ] **Step 2: 실패 확인**

Run: `swift test --filter AppOfficeTabTests`
Expected: 컴파일은 되나(현 kind 기반 프로퍼티), `.office` 미정의면 FAIL → Task 2 후이므로 통과할 수도. 최소 빌드 확인 후 다음. (이 테스트는 회귀 가드용)

- [ ] **Step 3: officeStates + retry 추가**

`Sources/App/AppState.swift` — 서비스 보관(기존 `private let fileService` 옆):
```swift
    private let kordocService = KordocService()
```
office 상태 타입과 저장소 추가(파일 상단 다른 `var` 선언 근처, 예: documents 근처):
```swift
    /// kordoc 오피스 변환 상태(키 = EditorTab.id). office 탭은 MarkdownDocument가 없다.
    var officeStates: [UUID: OfficeState] = [:]
```
그리고 같은 파일 안(클래스 밖, 파일 하단 등)에 enum 추가:
```swift
enum OfficeState {
    case loading
    case loaded(KordocResult)
    case failed(String)
}
```
재시도/변환 트리거 + 에러 메시지 헬퍼 추가(클래스 안, Folder Search 등 다른 MARK 근처):
```swift
    /// office 탭 변환을 시작/재시도한다(로딩 표시 후 비동기 변환).
    func retryOfficeConversion(tabID: UUID, fileURL: URL) {
        officeStates[tabID] = .loading
        Task { @MainActor in
            do {
                let result = try await kordocService.convert(fileURL: fileURL)
                officeStates[tabID] = .loaded(result)
            } catch {
                officeStates[tabID] = .failed(Self.officeErrorMessage(error))
            }
        }
    }

    static func officeErrorMessage(_ error: Error) -> String {
        switch error {
        case KordocError.toolNotFound:
            return "kordoc 실행에 필요한 Node(18+)/kordoc을 찾을 수 없습니다. 터미널에서 `npx kordoc` 또는 `npm i -g kordoc` 후 다시 시도하세요."
        case KordocError.timeout:
            return "문서 변환 시간이 초과됐습니다. 다시 시도해 주세요."
        case KordocError.decodeFailed:
            return "변환 결과를 해석하지 못했습니다."
        case KordocError.conversionFailed(let m):
            return "문서 변환에 실패했습니다.\n\(m)"
        default:
            return "문서를 열 수 없습니다: \(error.localizedDescription)"
        }
    }
```

- [ ] **Step 4: 로드 분기에 office 통합**

`loadAndActivateDocument`의 비마크다운 분기(`if kind == .image || kind == .pdf { … }`)를 아래로 교체(image/pdf/office 공통 탭 생성 + office는 변환 트리거):
```swift
        // 이미지·PDF·오피스: MarkdownDocument/워처/originalContents 없이 탭만.
        let kind = DocumentKind(from: url)
        if kind != .markdown {
            let tab = EditorTab(
                fileURL: url,
                title: url.deletingPathExtension().lastPathComponent,
                kind: kind
            )
            placeTab(tab, inNewTab: inNewTab)
            addToRecentFiles(url)
            if kind == .office {
                retryOfficeConversion(tabID: tab.id, fileURL: url)
            }
            saveSession()
            return
        }
```
(주의: 기존 코드가 `if DocumentKind(from: url) == .image || ... == .pdf {`로 시작하면 위 형태로 합치고, 그 아래 마크다운 do/catch는 그대로 둔다. `let kind`를 이미 위에서 선언했다면 중복 선언 피할 것.)

- [ ] **Step 5: closeTab / placeTab 정리**

office 탭이 닫히거나 교체될 때 상태 누수 방지:
- `closeTab(...)`에서 탭 제거 직전/직후에 `officeStates.removeValue(forKey: <닫는 탭 id>)` 추가.
- `placeTab`의 활성탭 교체 분기(기존 `let oldTab = tabs[activeIndex]` 블록)에 `officeStates.removeValue(forKey: oldTab.id)` 한 줄 추가.

- [ ] **Step 6: 빌드 + 전체 테스트**

Run: `swift build && swift test`
Expected: Build complete! + AppOfficeTabTests + 기존 모두 PASS

- [ ] **Step 7: 커밋**
```bash
git add Sources/App/AppState.swift Tests/CmdMDTests/AppOfficeTabTests.swift
git commit -m "$(cat <<'EOF'
kordoc 읽기(Phase 3): AppState 오피스 로드 분기·officeStates·재시도

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01S2QuZUALidkTNRswXFL6xM
EOF
)"
```

---

## Task 5: OfficeReaderView + MainEditorView 배선

**Files:**
- Create: `Sources/Views/OfficeReaderView.swift`
- Modify: `Sources/Views/MainEditorView.swift`

**Interfaces:**
- Consumes: `AppState.officeStates`, `OfficeState`, `retryOfficeConversion`, `MarkdownPreviewView`, `currentTabKind`/`currentTabFileURL`/`activeTabId`
- Produces: `OfficeReaderView(tabID:fileURL:)`; office 탭이면 표시

빌드 + 수동 검증.

- [ ] **Step 1: OfficeReaderView 구현**

Create `Sources/Views/OfficeReaderView.swift`:
```swift
import SwiftUI

/// 한글·오피스 문서를 kordoc 변환 결과(마크다운)로 읽기전용 표시.
/// 상태: 변환 중 / 완료(기존 마크다운 프리뷰) / 실패(안내+재시도).
struct OfficeReaderView: View {
    @Environment(AppState.self) private var appState
    let tabID: UUID
    let fileURL: URL

    var body: some View {
        switch appState.officeStates[tabID] {
        case .loaded(let result):
            MarkdownPreviewView(
                documentID: tabID,
                markdown: result.markdown,
                baseURL: fileURL.deletingLastPathComponent(),
                options: appState.renderOptions(),
                scrollSyncEnabled: false
            )
        case .failed(let message):
            VStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 420)
                Button("다시 시도") {
                    appState.retryOfficeConversion(tabID: tabID, fileURL: fileURL)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
        case .loading, .none:
            VStack(spacing: 12) {
                ProgressView()
                Text("변환 중… (첫 실행은 kordoc 다운로드로 느릴 수 있어요)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
```

- [ ] **Step 2: 빌드 확인**

Run: `swift build`
Expected: Build complete!

- [ ] **Step 3: MainEditorView 분기**

`MainEditorView.body`의 `Group { … }` 내부를 아래로 교체(.office 분기 추가):
```swift
            Group {
                if appState.currentTabKind == .image, let url = appState.currentTabFileURL {
                    ImageReaderView(url: url)
                } else if appState.currentTabKind == .pdf, let url = appState.currentTabFileURL {
                    PDFReaderView(url: url)
                } else if appState.currentTabKind == .office,
                          let url = appState.currentTabFileURL,
                          let tabID = appState.activeTabId {
                    OfficeReaderView(tabID: tabID, fileURL: url)
                } else if let document = appState.currentDocument {
                    // 탭 전환 시 NSTextView / WKWebView를 재생성하지 않도록 패널을 유지 — 성능 최적화.
                    DocumentEditorView(document: document)
                } else {
                    WelcomeView()
                }
            }
```

- [ ] **Step 4: 빌드 + 전체 테스트**

Run: `swift build && swift test`
Expected: Build complete! + 모든 테스트 PASS

- [ ] **Step 5: 커밋**
```bash
git add Sources/Views/OfficeReaderView.swift Sources/Views/MainEditorView.swift
git commit -m "$(cat <<'EOF'
kordoc 읽기(Phase 3): OfficeReaderView + MainEditorView .office 분기

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01S2QuZUALidkTNRswXFL6xM
EOF
)"
```

---

## Task 6: 수동 검증 (실제 HWP)

코드 변경 없음. 실제 파일로 확인.

- [ ] **Step 1: 앱 실행**
```bash
pkill -f ".build/arm64-apple-macosx/debug/CmdMD" 2>/dev/null; true
swift run CmdMD
```

- [ ] **Step 2: 체크리스트**
- [ ] `/Users/ahbaik/Downloads/제9회_전국동시지방선거_정의당_평가서.hwp`를 ⌘O 또는 드래그로 열기
- [ ] "변환 중…" 표시 후 마크다운 본문이 **읽기전용**으로 렌더(편집 불가)
- [ ] 창 제목 = 파일명, 탭으로 열림, 사이드바 목록에 .hwp 보임
- [ ] 원본 .hwp 파일 **변경/저장 안 됨**(수정시각 그대로)
- [ ] 손상/비office 파일 또는 kordoc 실패 → 안내 플레이스홀더 + "다시 시도"(크래시 없음)
- [ ] (가능하면) Node를 못 찾는 상황 시뮬레이션 시 toolNotFound 안내
- [ ] 마크다운·이미지·PDF 열기 회귀 없음

- [ ] **Step 3: 결과 기록** — 문제 없으면 Phase 3 완료. 이슈는 후속 Task로.

---

## Self-Review (계획 점검)
- **스펙 커버리지:** §3.1(KordocResult)→Task1; §3.3(DocumentKind.office)+§3.4(목록·패널)→Task2; §3.2(KordocService)→Task3; §3.4(officeStates·로드·재시도·정리)→Task4; §3.5(OfficeReaderView)+§3.6(MainEditorView)→Task5; §6(테스트)→Task1·2·4 + Task6 수동. 누락 없음.
- **플레이스홀더 스캔:** 모든 코드 단계 실제 코드. 에러 메시지·타임아웃 값 구체.
- **타입 일관성:** `KordocResult`/`KordocBlock`/`KordocOutlineItem`·`KordocError`·`KordocService.convert`/`resolveNpxPath`·`DocumentKind.office`/`officeExtensions`·`OfficeState`·`officeStates`·`retryOfficeConversion`·`officeErrorMessage`·`OfficeReaderView(tabID:fileURL:)`·`MarkdownPreviewView(documentID:markdown:baseURL:options:scrollSyncEnabled:)`가 정의/소비 Task에서 동일.
- **회귀 주의:** Task2가 FileTreeListingTests의 `testUnsupportedFilesAreNotListed`에서 office 확장자 제거를 명시. Task4의 `kind != .markdown` 분기는 image/pdf 기존 동작 보존(탭 생성 동일, office만 변환 추가). office 탭은 documents[]에 없어 저장 경로 무동작(원본 read-only).
- **범위:** 단일 계획 적합(오피스 읽기 한 기능). 쓰기/패치/양식은 Phase 5.
