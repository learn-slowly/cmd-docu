# Phase 5a — kordoc patch (편집 후 서식 보존 저장) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 한글 문서(hwp/hwpx)를 편집모드로 수정하고 `kordoc patch`로 원본 서식을 보존한 채 새 파일로 저장한다.

**Architecture:** 새 `KordocWriteService`(actor)가 편집 마크다운을 임시 .md로 쓰고 `kordoc patch`를 `Process`로 호출한다. 순수 헬퍼(출력 경로 제안·patch 가능 판별·에러 메시지)는 단위 테스트하고, 실제 CLI 호출은 통합 동작으로 둔다. UI는 기존 읽기전용 `OfficeReaderView`에 편집 토글을 더하고, 저장 전 경로 확인 시트를 띄운다.

**Tech Stack:** Swift 5.9+ / SwiftUI, SPM, macOS 14+, XCTest, `Process`로 외부 `kordoc` CLI.

## Global Constraints

- 비샌드박스 유지 — 서브프로세스 호출이 막히면 안 됨.
- kordoc은 직접 구현하지 않음 — `Process`로 호출. 경로 탐지 실패/실패/타임아웃은 throw + 한국어 안내, 크래시 금지.
- 파일 변경은 제안→확인→실행. **원본은 절대 덮어쓰거나 삭제하지 않는다.** 출력은 새 uniquified 경로.
- patch는 HWP/HWPX 전용 — 편집 토글을 그 종류로만 노출.
- Phase 게이트 — 시작·종료 시 `swift test`로 기존 112개 유지(정식 Xcode 필요).
- 신규 기능은 별도 파일로 분리(`KordocWriteService.swift`, `OfficeSaveConfirmView.swift`).
- 코드 주석·커밋 메시지 한국어. '박다/박는다' 류 표현 금지(대안: 넣는다/적는다/반영한다/저장한다 등).
- 테스트: XCTest, `@testable import CmdMD`. 순수 static 헬퍼는 직접 호출해 검증.
- 경로 탐지는 기존 `KordocService.resolveNpxPath()` 재사용(중복 금지).

## File Structure

- `Sources/Models/DocumentKind.swift` (수정) — `patchableExtensions` + `isPatchable(_:)`.
- `Sources/Services/KordocWriteService.swift` (생성) — `actor`, `KordocWriteError`, `patch(...)`.
- `Sources/App/AppState.swift` (수정) — 편집 상태/버퍼, `OfficeSaveRequest`, 메서드, 순수 헬퍼.
- `Sources/Views/OfficeReaderView.swift` (수정) — 편집 토글·에디터·저장 바.
- `Sources/Views/OfficeSaveConfirmView.swift` (생성) — 저장 경로 확인 시트.
- `Sources/Views/ContentView.swift` (수정) — `officeSaveConfirm` 시트 배선.
- `Tests/CmdMDTests/DocumentKindPatchTests.swift` (생성) — `isPatchable` 테스트.
- `Tests/CmdMDTests/AppPatchTests.swift` (생성) — `patchedOutputURL`/`kordocWriteErrorMessage`/편집 버퍼 테스트.

---

### Task 0: Phase 게이트 기준선 확인

- [ ] **Step 1: 기존 테스트 통과 확인**

Run: `swift test 2>&1 | grep -E "Executed 112|failed" | tail -2`
Expected: 112개 통과(실패 0). 실패하면 멈추고 원인 보고.

---

### Task 1: DocumentKind.isPatchable + AppState.patchedOutputURL (순수 헬퍼)

**Files:**
- Modify: `Sources/Models/DocumentKind.swift`
- Modify: `Sources/App/AppState.swift`
- Test: `Tests/CmdMDTests/DocumentKindPatchTests.swift`, `Tests/CmdMDTests/AppPatchTests.swift`

**Interfaces:**
- Produces:
  - `static func DocumentKind.isPatchable(_ url: URL) -> Bool`
  - `static func AppState.patchedOutputURL(for original: URL) -> URL`

- [ ] **Step 1: 실패하는 테스트 작성**

`Tests/CmdMDTests/DocumentKindPatchTests.swift`:
```swift
import XCTest
@testable import CmdMD

final class DocumentKindPatchTests: XCTestCase {
    func testHwpAndHwpxArePatchable() {
        XCTAssertTrue(DocumentKind.isPatchable(URL(fileURLWithPath: "/tmp/문서.hwp")))
        XCTAssertTrue(DocumentKind.isPatchable(URL(fileURLWithPath: "/tmp/문서.hwpx")))
        XCTAssertTrue(DocumentKind.isPatchable(URL(fileURLWithPath: "/tmp/문서.HWPX"))) // 대소문자 무시
    }

    func testOtherKindsAreNotPatchable() {
        for path in ["/tmp/a.docx", "/tmp/a.xlsx", "/tmp/a.pdf", "/tmp/a.md", "/tmp/a.hwpml"] {
            XCTAssertFalse(DocumentKind.isPatchable(URL(fileURLWithPath: path)), "\(path)는 patch 비대상")
        }
    }
}
```

`Tests/CmdMDTests/AppPatchTests.swift`:
```swift
import XCTest
@testable import CmdMD

final class AppPatchTests: XCTestCase {
    func testPatchedOutputURLAddsSuffixAndKeepsExtension() {
        let original = URL(fileURLWithPath: "/tmp/cmddocu-test-nonexistent/평가서.hwpx")
        let out = AppState.patchedOutputURL(for: original)
        XCTAssertEqual(out.deletingLastPathComponent().path, "/tmp/cmddocu-test-nonexistent")
        XCTAssertEqual(out.pathExtension, "hwpx")
        XCTAssertEqual(out.lastPathComponent, "평가서 (편집).hwpx")
    }

    func testPatchedOutputURLPreservesHwpExtension() {
        let out = AppState.patchedOutputURL(for: URL(fileURLWithPath: "/tmp/cmddocu-test-nonexistent/문서.hwp"))
        XCTAssertEqual(out.pathExtension, "hwp")
        XCTAssertEqual(out.lastPathComponent, "문서 (편집).hwp")
    }
}
```

- [ ] **Step 2: 테스트 실패 확인**

Run: `swift test --filter DocumentKindPatchTests 2>&1 | tail -5; swift test --filter AppPatchTests 2>&1 | tail -5`
Expected: FAIL — `isPatchable`/`patchedOutputURL` 미정의.

- [ ] **Step 3: DocumentKind.isPatchable 구현**

`Sources/Models/DocumentKind.swift`의 `extension DocumentKind` 안, `officeExtensions` 선언 아래에 추가:
```swift
    /// kordoc patch가 서식 보존 라운드트립을 지원하는 확장자(소문자). HWP/HWPX 전용.
    static let patchableExtensions: Set<String> = ["hwp", "hwpx"]

    /// 이 파일이 kordoc patch(편집 후 서식 보존 저장) 대상인가.
    static func isPatchable(_ url: URL) -> Bool {
        patchableExtensions.contains(url.pathExtension.lowercased())
    }
```

- [ ] **Step 4: AppState.patchedOutputURL 구현**

`Sources/App/AppState.swift`의 `keyBinding(for:)` 함수 아래(또는 다른 `static func` 헬퍼 근처)에 추가:
```swift

    /// 편집 저장의 기본 출력 경로: 원본과 같은 폴더에 "<이름> (편집).<확장자>", 충돌 시 uniquify.
    /// 원본은 절대 건드리지 않으므로 항상 새 경로를 돌려준다.
    static func patchedOutputURL(for original: URL) -> URL {
        let ext = original.pathExtension
        let base = original.deletingPathExtension().lastPathComponent
        let folder = original.deletingLastPathComponent()
        let name = ext.isEmpty ? "\(base) (편집)" : "\(base) (편집).\(ext)"
        return folder.appendingPathComponent(name).uniquified()
    }
```
(`URL.uniquified()`는 기존 `AppState.swift` 하단 extension에 이미 있다.)

- [ ] **Step 5: 테스트 통과 확인**

Run: `swift test --filter DocumentKindPatchTests 2>&1 | tail -4; swift test --filter AppPatchTests 2>&1 | tail -4`
Expected: PASS (5 테스트). `/tmp/cmddocu-test-nonexistent`는 없는 폴더라 uniquify가 그대로 돌려준다.

- [ ] **Step 6: 커밋**

```bash
git add Sources/Models/DocumentKind.swift Sources/App/AppState.swift Tests/CmdMDTests/DocumentKindPatchTests.swift Tests/CmdMDTests/AppPatchTests.swift
git commit -m "기능(patch): isPatchable·patchedOutputURL 순수 헬퍼 추가

hwp/hwpx만 patch 대상으로 판별하고, 편집 저장의 기본 출력 경로를 원본 옆
'<이름> (편집).<확장자>'로 제안(충돌 시 uniquify, 원본 불변)한다.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01S2QuZUALidkTNRswXFL6xM"
```

---

### Task 2: KordocWriteService (patch 호출)

**Files:**
- Create: `Sources/Services/KordocWriteService.swift`

**Interfaces:**
- Consumes: `KordocService.resolveNpxPath()` (기존), `URL.uniquified()` (기존).
- Produces:
  - `enum KordocWriteError: Error { case toolNotFound, patchFailed(String), timeout }`
  - `actor KordocWriteService` with `func patch(original: URL, editedMarkdown: String, output: URL) async throws`

> 실제 CLI 호출은 외부 도구라 단위 테스트하지 않는다(KordocService와 동일). 빌드 통과로 검증.

- [ ] **Step 1: 구현 작성**

`Sources/Services/KordocWriteService.swift`:
```swift
import Foundation

enum KordocWriteError: Error {
    case toolNotFound
    case patchFailed(String)
    case timeout
}

/// kordoc patch를 Process로 호출해 편집한 마크다운을 원본 서식에 반영한다.
/// kordoc 자체는 구현하지 않는다(외부 도구). 원본은 변경하지 않고 output에만 쓴다.
actor KordocWriteService {
    private let timeout: TimeInterval = 120

    /// 편집 마크다운을 임시 .md로 적고 `kordoc patch <원본> <임시.md> -o <출력>`을 실행한다.
    func patch(original: URL, editedMarkdown: String, output: URL) async throws {
        guard let npx = KordocService.resolveNpxPath() else { throw KordocWriteError.toolNotFound }

        // kordoc patch는 편집본을 파일로 받는다 — 임시 .md로 적는다.
        let tmpMd = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("md")
        defer { try? FileManager.default.removeItem(at: tmpMd) }
        do {
            try editedMarkdown.write(to: tmpMd, atomically: true, encoding: .utf8)
        } catch {
            throw KordocWriteError.patchFailed("임시 파일을 적지 못했습니다: \(error.localizedDescription)")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: npx)
        process.arguments = ["-y", "kordoc", "patch",
                             original.path(percentEncoded: false),
                             tmpMd.path(percentEncoded: false),
                             "-o", output.path(percentEncoded: false), "--silent"]
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw KordocWriteError.toolNotFound
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            if Date() > deadline {
                process.terminate()
                throw KordocWriteError.timeout
            }
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s
        }

        if process.terminationStatus != 0 {
            let data = stderrPipe.fileHandleForReading.readDataToEndOfFile()
            let msg = String(data: data, encoding: .utf8) ?? ""
            throw KordocWriteError.patchFailed(String(msg.prefix(500)))
        }

        // 성공이라면 출력 파일이 실제로 생겼는지 확인한다.
        guard FileManager.default.fileExists(atPath: output.path(percentEncoded: false)) else {
            throw KordocWriteError.patchFailed("출력 파일이 생성되지 않았습니다.")
        }
    }
}
```

- [ ] **Step 2: 빌드 + 기존 테스트 확인**

Run: `swift build 2>&1 | tail -5 && swift test 2>&1 | grep -E "Executed 117|Executed 112|failed" | tail -2`
Expected: 빌드 성공, 기존 테스트(112 + Task1의 5 = 117) 통과.

- [ ] **Step 3: 커밋**

```bash
git add Sources/Services/KordocWriteService.swift
git commit -m "기능(patch): KordocWriteService.patch 추가

편집 마크다운을 임시 .md로 적고 kordoc patch를 Process로 호출해 원본 서식에
반영, 새 출력 파일을 만든다. 경로 탐지는 KordocService.resolveNpxPath 재사용,
120s 타임아웃·stderr 에러·출력 존재 확인. 원본은 변경하지 않는다.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01S2QuZUALidkTNRswXFL6xM"
```

---

### Task 3: AppState — 편집 상태·OfficeSaveRequest·메서드·에러 헬퍼

**Files:**
- Modify: `Sources/App/AppState.swift`
- Test: `Tests/CmdMDTests/AppPatchTests.swift` (Task 1에서 만든 파일에 추가)

**Interfaces:**
- Consumes: `KordocWriteService.patch` (Task 2), `KordocWriteError` (Task 2), `patchedOutputURL` (Task 1), `OfficeState.loaded(KordocResult)` (기존).
- Produces:
  - 상태: `officeEditing: Set<UUID>`, `officeEditBuffers: [UUID: String]`, `officePatchInProgress: Set<UUID>`, `officeSaveConfirm: OfficeSaveRequest?`
  - `struct OfficeSaveRequest: Identifiable { let id; let tabID: UUID; let fileURL: URL; var output: URL }`
  - `beginOfficeEdit(tabID:)`, `cancelOfficeEdit(tabID:)`, `requestOfficeSave(tabID:fileURL:)`, `confirmOfficeSave(tabID:fileURL:output:)`
  - `static func kordocWriteErrorMessage(_ error: Error) -> String`

- [ ] **Step 1: 실패하는 테스트 추가**

`Tests/CmdMDTests/AppPatchTests.swift`의 클래스 안에 추가:
```swift
    func testBeginOfficeEditCopiesMarkdownIntoBuffer() {
        let app = AppState()
        let tabID = UUID()
        app.officeStates[tabID] = .loaded(KordocResult(success: true, fileType: "hwpx",
                                                       markdown: "# 제목\n본문", blocks: nil, outline: nil))
        app.beginOfficeEdit(tabID: tabID)
        XCTAssertTrue(app.officeEditing.contains(tabID))
        XCTAssertEqual(app.officeEditBuffers[tabID], "# 제목\n본문")
    }

    func testBeginOfficeEditDoesNothingWithoutLoadedState() {
        let app = AppState()
        let tabID = UUID()
        app.beginOfficeEdit(tabID: tabID)
        XCTAssertFalse(app.officeEditing.contains(tabID))
        XCTAssertNil(app.officeEditBuffers[tabID])
    }

    func testCancelOfficeEditClearsBufferAndFlag() {
        let app = AppState()
        let tabID = UUID()
        app.officeStates[tabID] = .loaded(KordocResult(success: true, fileType: "hwpx",
                                                       markdown: "내용", blocks: nil, outline: nil))
        app.beginOfficeEdit(tabID: tabID)
        app.cancelOfficeEdit(tabID: tabID)
        XCTAssertFalse(app.officeEditing.contains(tabID))
        XCTAssertNil(app.officeEditBuffers[tabID])
    }

    func testKordocWriteErrorMessages() {
        XCTAssertTrue(AppState.kordocWriteErrorMessage(KordocWriteError.toolNotFound).contains("kordoc"))
        XCTAssertTrue(AppState.kordocWriteErrorMessage(KordocWriteError.timeout).contains("중단"))
        XCTAssertTrue(AppState.kordocWriteErrorMessage(KordocWriteError.patchFailed("boom")).contains("boom"))
    }
```

- [ ] **Step 2: 테스트 실패 확인**

Run: `swift test --filter AppPatchTests 2>&1 | tail -6`
Expected: FAIL — `beginOfficeEdit`/`officeEditing`/`kordocWriteErrorMessage` 등 미정의.

- [ ] **Step 3: 상태 변수 + OfficeSaveRequest + 서비스 인스턴스 추가**

`Sources/App/AppState.swift`의 claude 상태 블록(`var currentSelectionText` 부근) 아래에 추가:
```swift

    // kordoc patch 편집 상태
    var officeEditing: Set<UUID> = []
    var officeEditBuffers: [UUID: String] = [:]
    var officePatchInProgress: Set<UUID> = []
    var officeSaveConfirm: OfficeSaveRequest?
```

`private let claudeService = ClaudeService()` 아래에 추가:
```swift
    private let kordocWriteService = KordocWriteService()
```

`enum OfficeState { ... }`(파일 하단, AppState 클래스 밖) 근처에 추가:
```swift
/// 편집 저장 확인 시트를 구동하는 요청. output은 사용자가 위치 변경 시 갱신된다.
struct OfficeSaveRequest: Identifiable {
    let id = UUID()
    let tabID: UUID
    let fileURL: URL
    var output: URL
}
```

- [ ] **Step 4: 메서드 + 에러 헬퍼 추가**

`Sources/App/AppState.swift`의 `patchedOutputURL`(Task 1) 아래에 추가:
```swift

    // MARK: - kordoc patch 편집 저장

    /// 변환 마크다운을 편집 버퍼로 복사하고 편집모드로 들어간다(이미 버퍼가 있으면 유지).
    @MainActor
    func beginOfficeEdit(tabID: UUID) {
        guard case .loaded(let result)? = officeStates[tabID] else { return }
        if officeEditBuffers[tabID] == nil {
            officeEditBuffers[tabID] = result.markdown
        }
        officeEditing.insert(tabID)
    }

    /// 편집을 취소하고 버퍼를 버린다.
    @MainActor
    func cancelOfficeEdit(tabID: UUID) {
        officeEditing.remove(tabID)
        officeEditBuffers[tabID] = nil
    }

    /// 기본 출력 경로를 제안해 저장 확인 시트를 띄운다(아직 쓰지 않는다).
    @MainActor
    func requestOfficeSave(tabID: UUID, fileURL: URL) {
        officeSaveConfirm = OfficeSaveRequest(tabID: tabID, fileURL: fileURL,
                                              output: Self.patchedOutputURL(for: fileURL))
    }

    /// 확인된 출력 경로로 kordoc patch를 실행한다. 원본은 건드리지 않는다.
    @MainActor
    func confirmOfficeSave(tabID: UUID, fileURL: URL, output: URL) {
        guard let edited = officeEditBuffers[tabID],
              !officePatchInProgress.contains(tabID) else { return }
        officeSaveConfirm = nil
        officePatchInProgress.insert(tabID)
        Task { @MainActor in
            do {
                try await kordocWriteService.patch(original: fileURL, editedMarkdown: edited, output: output)
                toastMessage = "서식 보존 저장됨: \(output.lastPathComponent)"
                officeEditing.remove(tabID)
                officeEditBuffers[tabID] = nil
            } catch {
                errorMessage = Self.kordocWriteErrorMessage(error)
            }
            officePatchInProgress.remove(tabID)
        }
    }

    static func kordocWriteErrorMessage(_ error: Error) -> String {
        switch error {
        case KordocWriteError.toolNotFound:
            return "kordoc 실행에 필요한 Node(18+)/kordoc을 찾을 수 없습니다. 터미널에서 `npx kordoc` 또는 `npm i -g kordoc` 후 다시 시도하세요."
        case KordocWriteError.timeout:
            return "서식 보존 저장이 너무 오래 걸려 중단했습니다."
        case KordocWriteError.patchFailed(let m):
            return "서식 보존 저장에 실패했습니다.\n\(m)"
        default:
            return "저장에 실패했습니다: \(error.localizedDescription)"
        }
    }
```

- [ ] **Step 5: 테스트 통과 + 빌드 확인**

Run: `swift build 2>&1 | tail -5 && swift test --filter AppPatchTests 2>&1 | tail -6`
Expected: 빌드 성공, AppPatchTests 통과(Task1 2개 + 신규 4개 = 6개).

- [ ] **Step 6: 커밋**

```bash
git add Sources/App/AppState.swift Tests/CmdMDTests/AppPatchTests.swift
git commit -m "기능(patch): AppState 편집 상태·저장 메서드·에러 헬퍼 추가

officeEditing/Buffers, OfficeSaveRequest, begin/cancel/requestSave/confirmSave.
confirmOfficeSave는 KordocWriteService.patch를 비동기 호출(메인 액터)하고
성공 토스트/실패 안내. 원본 불변·새 출력 경로.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01S2QuZUALidkTNRswXFL6xM"
```

---

### Task 4: OfficeReaderView — 편집 토글·에디터·저장 바

**Files:**
- Modify: `Sources/Views/OfficeReaderView.swift`

**Interfaces:**
- Consumes: `appState.officeEditing`, `officeEditBuffers`, `officePatchInProgress`, `beginOfficeEdit`, `cancelOfficeEdit`, `requestOfficeSave` (Task 3), `DocumentKind.isPatchable` (Task 1), `MarkdownTextEditor` (기존).

> SwiftUI 뷰라 빌드로 검증.

- [ ] **Step 1: `.loaded` 케이스를 편집 토글 포함으로 교체 + 에디터 패널 추가**

`Sources/Views/OfficeReaderView.swift`를 아래로 교체:
```swift
import SwiftUI

/// 한글·오피스 문서를 kordoc 변환 결과(마크다운)로 표시한다.
/// hwp/hwpx는 편집모드(편집 → kordoc patch로 서식 보존 저장)를 지원한다.
/// 상태: 변환 중 / 완료(읽기 프리뷰 또는 편집) / 실패(안내+재시도).
struct OfficeReaderView: View {
    @Environment(AppState.self) private var appState
    let tabID: UUID
    let fileURL: URL

    var body: some View {
        switch appState.officeStates[tabID] {
        case .loaded(let result):
            let isEditing = appState.officeEditing.contains(tabID)
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Spacer()
                    if isEditing {
                        if appState.officePatchInProgress.contains(tabID) {
                            ProgressView().controlSize(.small)
                        }
                        Button("취소") { appState.cancelOfficeEdit(tabID: tabID) }
                            .disabled(appState.officePatchInProgress.contains(tabID))
                        Button("서식 보존 저장") {
                            appState.requestOfficeSave(tabID: tabID, fileURL: fileURL)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(appState.officePatchInProgress.contains(tabID))
                    } else if DocumentKind.isPatchable(fileURL) {
                        Button {
                            appState.beginOfficeEdit(tabID: tabID)
                        } label: {
                            Label("편집", systemImage: "pencil")
                        }
                    }
                }
                .padding(8)
                Divider()
                if isEditing {
                    OfficeEditorPane(tabID: tabID)
                } else {
                    MarkdownPreviewView(
                        documentID: tabID,
                        markdown: result.markdown,
                        baseURL: fileURL.deletingLastPathComponent(),
                        options: appState.renderOptions(),
                        scrollSyncEnabled: false
                    )
                }
            }
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

/// 편집 버퍼(officeEditBuffers[tabID])를 마크다운 에디터로 보여준다. 위키링크 자동완성은 끈다.
private struct OfficeEditorPane: View {
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme
    let tabID: UUID

    private func editorFont() -> NSFont {
        let size = appState.settings.fontSize
        let name = appState.settings.fontName
        if !name.isEmpty, let custom = NSFont(name: name, size: size) { return custom }
        return .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    var body: some View {
        @Bindable var state = appState
        let settings = appState.settings
        let theme = settings.editorTheme.resolved(forDark: colorScheme == .dark)
        MarkdownTextEditor(
            documentID: tabID,
            text: Binding(
                get: { appState.officeEditBuffers[tabID] ?? "" },
                set: { appState.officeEditBuffers[tabID] = $0 }
            ),
            font: editorFont(),
            editorTheme: theme,
            softWrap: settings.softWrap,
            showLineNumbers: settings.showLineNumbers,
            highlightCurrentLine: settings.highlightCurrentLine,
            tabSize: settings.tabSize,
            insertSpacesForTab: settings.insertSpacesInsteadOfTabs,
            enableCompletion: false,
            scrollSyncEnabled: false
        )
    }
}
```

> 참고: `MarkdownPreviewView`/`appState.renderOptions()`/`MarkdownTextEditor`/`EditorTheme.resolved(forDark:)`는 기존 코드. 시그니처가 다르면 STOP하고 NEEDS_CONTEXT로 보고.

- [ ] **Step 2: 빌드 + 기존 테스트 확인**

Run: `swift build 2>&1 | tail -8 && swift test 2>&1 | grep -E "Executed 12|failed" | tail -2`
Expected: 빌드 성공, 전체 테스트 통과.

- [ ] **Step 3: 커밋**

```bash
git add Sources/Views/OfficeReaderView.swift
git commit -m "기능(patch): 오피스 프리뷰에 편집모드 토글·에디터·저장 바 추가

hwp/hwpx에서만 '편집' 노출. 편집 시 변환 마크다운을 MarkdownTextEditor로
수정하고 '서식 보존 저장'이 확인 시트를 띄운다. 위키링크 자동완성은 끈다.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01S2QuZUALidkTNRswXFL6xM"
```

---

### Task 5: OfficeSaveConfirmView + ContentView 시트 배선

**Files:**
- Create: `Sources/Views/OfficeSaveConfirmView.swift`
- Modify: `Sources/Views/ContentView.swift`

**Interfaces:**
- Consumes: `OfficeSaveRequest` (Task 3), `appState.officeSaveConfirm`, `confirmOfficeSave` (Task 3).

> SwiftUI 뷰/시트라 빌드로 검증.

- [ ] **Step 1: 확인 시트 뷰 작성**

`Sources/Views/OfficeSaveConfirmView.swift`:
```swift
import SwiftUI
import AppKit

/// 서식 보존 저장 전 출력 경로를 제안·확인한다. 원본은 건드리지 않고 새 파일로 저장한다.
struct OfficeSaveConfirmView: View {
    @Environment(AppState.self) private var appState
    let request: OfficeSaveRequest
    @State private var output: URL

    init(request: OfficeSaveRequest) {
        self.request = request
        _output = State(initialValue: request.output)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("서식 보존 저장")
                .font(.headline)
            Text("원본은 그대로 두고 새 파일로 저장합니다.")
                .font(.callout)
                .foregroundStyle(.secondary)

            GroupBox {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(output.lastPathComponent)
                            .font(.callout.weight(.medium))
                        Text(output.deletingLastPathComponent().path)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    Button("위치 변경…") { chooseLocation() }
                }
                .padding(4)
            }

            HStack {
                Spacer()
                Button("취소") { appState.officeSaveConfirm = nil }
                Button("저장") {
                    appState.confirmOfficeSave(tabID: request.tabID,
                                               fileURL: request.fileURL,
                                               output: output)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }

    private func chooseLocation() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = output.lastPathComponent
        panel.directoryURL = output.deletingLastPathComponent()
        if panel.runModal() == .OK, let url = panel.url {
            output = url
        }
    }
}
```

- [ ] **Step 2: ContentView에 시트 배선**

`Sources/Views/ContentView.swift`의 기존 `.sheet(isPresented: $state.showAbout) { AboutView() }` 아래에 추가:
```swift
        .sheet(item: $state.officeSaveConfirm) { request in
            OfficeSaveConfirmView(request: request)
        }
```

- [ ] **Step 3: 빌드 + 전체 테스트 확인**

Run: `swift build 2>&1 | tail -8 && swift test 2>&1 | grep -E "Executed 12|failed" | tail -2`
Expected: 빌드 성공, 전체 테스트 통과.

- [ ] **Step 4: 커밋**

```bash
git add Sources/Views/OfficeSaveConfirmView.swift Sources/Views/ContentView.swift
git commit -m "기능(patch): 저장 경로 확인 시트 추가·배선

OfficeSaveConfirmView가 제안 경로를 보여주고 '위치 변경…'(NSSavePanel)·
'저장'(confirmOfficeSave). ContentView에 officeSaveConfirm 시트 연결.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01S2QuZUALidkTNRswXFL6xM"
```

---

### Task 6: Phase 게이트 마감 — 전체 테스트 + CLAUDE.md

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: 전체 테스트 통과 확인**

Run: `swift test 2>&1 | grep -E "Executed 12|failed" | tail -2`
Expected: 전체 통과(실패 0). 신규 ~9개 포함 약 121개.

- [ ] **Step 2: CLAUDE.md "현재 상태"에 Phase 5a 줄 추가 + 다음 액션 갱신**

`CLAUDE.md`의 Phase 4 완료 줄 아래에 추가:
```markdown
- Phase 5a 완료(2026-06-29). kordoc patch(편집 후 서식 보존 저장) — kordoc 실제 API 검증(generate 부재 확인, patch/fill만 실재). `KordocWriteService`(actor: 편집 마크다운을 임시 .md로 적고 `kordoc patch <원본> <편집.md> -o <출력> --silent`, 120s 타임아웃, 출력 존재 확인) + `OfficeReaderView` 편집모드 토글(hwp/hwpx만, `MarkdownTextEditor` 재사용) + `OfficeSaveConfirmView`(제안 경로 확인·위치 변경 NSSavePanel). 원본 불변, 새 uniquified 출력. 약 121개 테스트 통과. 다음: fill(양식 채우기).
```

`다음 액션` 줄을 갱신:
```markdown
- 다음 액션: Phase 5b kordoc fill(양식 채우기, --dry-run 라벨 조회+수동 값) → Phase 6 PARA 라우팅.
```

- [ ] **Step 3: 커밋**

```bash
git add CLAUDE.md
git commit -m "문서: Phase 5a kordoc patch 완료 상태 기록

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01S2QuZUALidkTNRswXFL6xM"
```

---

## Self-Review

**1. Spec coverage:**
- 편집모드 토글(hwp/hwpx) → Task 1(isPatchable) + Task 4(토글). ✓
- 변환 마크다운 편집 → Task 3(버퍼) + Task 4(에디터). ✓
- kordoc patch 호출 → Task 2(KordocWriteService) + Task 3(confirmOfficeSave). ✓
- 원본 옆 새 파일 + 경로 확인 → Task 1(patchedOutputURL) + Task 3(requestOfficeSave) + Task 5(확인 시트). ✓
- 비파괴·에러 안내 → Task 2(출력 확인) + Task 3(kordocWriteErrorMessage). ✓
- Phase 게이트 → Task 0, Task 6. ✓

**2. Placeholder scan:** 모든 코드 스텝에 실제 코드 포함. TBD/TODO 없음. ✓

**3. Type consistency:** `KordocWriteError`(toolNotFound/patchFailed/timeout) Task 2 정의→Task 3 사용 일관. `OfficeSaveRequest`(tabID/fileURL/output) Task 3 정의→Task 5 사용 일관. `patchedOutputURL`/`isPatchable`/`kordocWriteErrorMessage`/편집 상태 변수명 Task 간 일관. `MarkdownTextEditor` 파라미터는 기존 시그니처와 대조 완료. ✓

## 미해결 가정 (실행 중 확인)

- `kordoc patch <원본> <편집.md> -o <출력>` 인자 순서/플래그가 help대로 동작한다는 전제. 실제 동작이 다르면 Task 2의 `arguments`를 조정(예: `--no-verify` 추가 필요 여부)하고 사용자에게 보고.
- `EditorTheme.resolved(forDark:)`·`MarkdownPreviewView`·`appState.renderOptions()` 시그니처는 기존 코드 기준 — 실제와 다르면 Task 4에서 NEEDS_CONTEXT.
