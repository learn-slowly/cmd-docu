# Phase 5b — kordoc fill(양식 채우기) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 한글·오피스 서식 문서의 빈칸을 kordoc `fill`로 채워 새 `.hwpx`로 저장하는 기능을 추가한다(dry-run 라벨 조회 + 수동 값 입력).

**Architecture:** Phase 5a(kordoc patch) 패턴을 그대로 따른다 — Process로 kordoc만 호출, 신규 `KordocFillService` actor가 dry-run/fill을 담당하고, `AppState`가 상태·메서드를, 신규 `OfficeFillView` 모달 시트가 UI를 맡는다. 원본은 절대 건드리지 않고 새 uniquified `.hwpx`만 만든다.

**Tech Stack:** Swift 5.9+ / SwiftUI / SPM, macOS 14+, Process로 `npx kordoc fill` 호출, XCTest.

## Global Constraints

- 비샌드박스 유지. kordoc은 직접 구현하지 않고 `Process`로만 호출한다.
- 원본 불변. 출력은 항상 새 `.hwpx`(uniquified). `KordocWriteService.isSameFile` 가드로 원본 덮어쓰기 거부. 삭제 없음.
- 제안→확인→실행. dry-run 결과를 시트로 제안하고 사용자가 값·경로 확인 후 실행.
- 코드 주석·커밋 메시지는 한국어. '박다/박는다' 류 표현 금지.
- 신규 기능은 별도 파일로 분리(업스트림 머지 용이).
- Process를 부르는 서비스는 단위테스트하지 않는다(순수 함수만 테스트). 기존 ~121개 테스트가 깨지지 않아야 한다.
- npx 경로는 `KordocService.resolveNpxPath()` 재사용. 타임아웃 120s 협조적 폴링.
- 커밋 메시지 말미에 다음 두 줄을 넣는다:
  `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`
  `Claude-Session: https://claude.ai/code/session_01S2QuZUALidkTNRswXFL6xM`

### 검증된 kordoc fill 실제 동작 (v3.5.1)
- `npx -y kordoc fill --dry-run --silent <template>` → **stdout에 JSON** `{"fields":[{"label":String,"value":String,"row":Int,"col":Int}],"confidence":Number}`, 진행 메시지는 stderr.
- `npx -y kordoc fill <template> -j <json> --silent` → **채운 hwpx를 stdout으로 스트리밍**(`-o` 무시). 출력은 hwpx-preserve(.hwp 입력도 .hwpx 출력).
- 매칭 실패는 비치명적: stderr에 `⚠️ 매칭 실패: <라벨>`, 종료코드 0(부분 채움).

---

### Task 1: FillField / FillDetection 모델

**Files:**
- Create: `Sources/Models/FillField.swift`
- Test: `Tests/CmdMDTests/FillFieldTests.swift`

**Interfaces:**
- Produces: `struct FillField: Decodable, Identifiable { let label: String; let value: String; let row: Int; let col: Int; var id: String }`, `struct FillDetection: Decodable { let fields: [FillField]; let confidence: Double? }`

- [ ] **Step 1: 실패하는 디코딩 테스트 작성**

`Tests/CmdMDTests/FillFieldTests.swift`:
```swift
import XCTest
@testable import CmdMD

final class FillFieldTests: XCTestCase {
    private let json = """
    {
      "fields": [
        {"label":"성명","value":"","row":0,"col":1},
        {"label":"전화","value":"010","row":1,"col":1}
      ],
      "confidence": 1.0
    }
    """.data(using: .utf8)!

    func testDecodesFieldsAndConfidence() throws {
        let d = try JSONDecoder().decode(FillDetection.self, from: json)
        XCTAssertEqual(d.fields.count, 2)
        XCTAssertEqual(d.fields.first?.label, "성명")
        XCTAssertEqual(d.fields.first?.value, "")
        XCTAssertEqual(d.fields[1].row, 1)
        XCTAssertEqual(d.fields[1].col, 1)
        XCTAssertEqual(d.confidence, 1.0)
    }

    func testIdDisambiguatesDuplicateLabels() throws {
        let d = try JSONDecoder().decode(FillDetection.self, from: json)
        XCTAssertNotEqual(d.fields[0].id, d.fields[1].id)
    }

    func testMissingConfidenceDecodesAsNil() throws {
        let minimal = #"{"fields":[]}"#.data(using: .utf8)!
        let d = try JSONDecoder().decode(FillDetection.self, from: minimal)
        XCTAssertTrue(d.fields.isEmpty)
        XCTAssertNil(d.confidence)
    }
}
```

- [ ] **Step 2: 테스트 실패 확인**

Run: `swift test --filter FillFieldTests`
Expected: 컴파일 실패("cannot find 'FillDetection'") 또는 FAIL.

- [ ] **Step 3: 모델 구현**

`Sources/Models/FillField.swift`:
```swift
import Foundation

/// kordoc `fill --dry-run` 출력의 단일 필드(서식 빈칸 후보).
/// label = 셀 텍스트(채울 라벨), value = kordoc가 추정한 인접 값(빈 서식이면 보통 빈 문자열).
struct FillField: Decodable, Identifiable {
    let label: String
    let value: String
    let row: Int
    let col: Int
    /// 중복 label을 구분하기 위한 안정 id(행·열·라벨 조합).
    var id: String { "\(row)-\(col)-\(label)" }
}

/// kordoc `fill --dry-run --silent`의 stdout JSON 모델.
struct FillDetection: Decodable {
    let fields: [FillField]
    let confidence: Double?
}
```

- [ ] **Step 4: 테스트 통과 확인**

Run: `swift test --filter FillFieldTests`
Expected: PASS (3 tests).

- [ ] **Step 5: 커밋**

```bash
git add Sources/Models/FillField.swift Tests/CmdMDTests/FillFieldTests.swift
git commit -m "기능(fill): FillField·FillDetection 모델 추가

dry-run JSON(fields/label/value/row/col/confidence) 디코딩.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01S2QuZUALidkTNRswXFL6xM"
```

---

### Task 2: DocumentKind.isFillable

**Files:**
- Modify: `Sources/Models/DocumentKind.swift` (extension에 추가, `patchableExtensions`/`isPatchable` 바로 아래)
- Test: `Tests/CmdMDTests/DocumentKindFillTests.swift`

**Interfaces:**
- Produces: `static let DocumentKind.fillableExtensions: Set<String>`, `static func DocumentKind.isFillable(_ url: URL) -> Bool`

- [ ] **Step 1: 실패하는 테스트 작성**

`Tests/CmdMDTests/DocumentKindFillTests.swift`:
```swift
import XCTest
@testable import CmdMD

final class DocumentKindFillTests: XCTestCase {
    func testHwpAndHwpxAreFillable() {
        XCTAssertTrue(DocumentKind.isFillable(URL(fileURLWithPath: "/tmp/서식.hwp")))
        XCTAssertTrue(DocumentKind.isFillable(URL(fileURLWithPath: "/tmp/서식.hwpx")))
        XCTAssertTrue(DocumentKind.isFillable(URL(fileURLWithPath: "/tmp/서식.HWP"))) // 대소문자 무시
    }

    func testOtherKindsAreNotFillable() {
        for path in ["/tmp/a.docx", "/tmp/a.xlsx", "/tmp/a.pdf", "/tmp/a.md", "/tmp/a.hwpml"] {
            XCTAssertFalse(DocumentKind.isFillable(URL(fileURLWithPath: path)), "\(path)는 fill 비대상")
        }
    }
}
```

- [ ] **Step 2: 테스트 실패 확인**

Run: `swift test --filter DocumentKindFillTests`
Expected: 컴파일 실패("cannot find 'isFillable'").

- [ ] **Step 3: 구현 추가**

`Sources/Models/DocumentKind.swift`의 `isPatchable(_:)` 아래에 추가:
```swift
    /// kordoc fill(서식 빈칸 채우기) 대상 확장자(소문자). HWP/HWPX 전용. 출력은 항상 hwpx.
    static let fillableExtensions: Set<String> = ["hwp", "hwpx"]

    /// 이 파일이 kordoc fill(양식 채우기) 대상인가.
    static func isFillable(_ url: URL) -> Bool {
        fillableExtensions.contains(url.pathExtension.lowercased())
    }
```

- [ ] **Step 4: 테스트 통과 확인**

Run: `swift test --filter DocumentKindFillTests`
Expected: PASS (2 tests).

- [ ] **Step 5: 커밋**

```bash
git add Sources/Models/DocumentKind.swift Tests/CmdMDTests/DocumentKindFillTests.swift
git commit -m "기능(fill): DocumentKind.isFillable(hwp/hwpx) 추가

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01S2QuZUALidkTNRswXFL6xM"
```

---

### Task 3: AppState.filledOutputURL + fillValuesToSend (순수 헬퍼)

**Files:**
- Modify: `Sources/App/AppState.swift` (`patchedOutputURL(for:)` 바로 아래에 두 static 추가)
- Test: `Tests/CmdMDTests/AppFillHelpersTests.swift`

**Interfaces:**
- Consumes: `FillField`(Task 1)
- Produces: `static func AppState.filledOutputURL(for original: URL) -> URL`, `static func AppState.fillValuesToSend(fields: [FillField], edited: [String: String]) -> [String: String]`

- [ ] **Step 1: 실패하는 테스트 작성**

`Tests/CmdMDTests/AppFillHelpersTests.swift`:
```swift
import XCTest
@testable import CmdMD

final class AppFillHelpersTests: XCTestCase {
    func testFilledOutputURLForcesHwpxAndAddsSuffix() {
        let out = AppState.filledOutputURL(for: URL(fileURLWithPath: "/tmp/cmddocu-test-nonexistent/신청서.hwpx"))
        XCTAssertEqual(out.deletingLastPathComponent().path, "/tmp/cmddocu-test-nonexistent")
        XCTAssertEqual(out.pathExtension, "hwpx")
        XCTAssertEqual(out.lastPathComponent, "신청서 (채움).hwpx")
    }

    func testFilledOutputURLConvertsHwpToHwpx() {
        let out = AppState.filledOutputURL(for: URL(fileURLWithPath: "/tmp/cmddocu-test-nonexistent/서식.hwp"))
        XCTAssertEqual(out.pathExtension, "hwpx")
        XCTAssertEqual(out.lastPathComponent, "서식 (채움).hwpx")
    }

    func testFillValuesToSendIncludesOnlyChangedNonEmpty() {
        let fields = [
            FillField(label: "성명", value: "", row: 0, col: 1),   // 빈칸 → 입력
            FillField(label: "전화", value: "010", row: 1, col: 1), // 변경 안 함
            FillField(label: "주소", value: "옛값", row: 2, col: 1), // 변경
            FillField(label: "비고", value: "x", row: 3, col: 1),   // 비움(전송 안 함)
        ]
        let edited = [
            "0-1-성명": "홍길동",
            "1-1-전화": "010",
            "2-1-주소": "새값",
            "3-1-비고": "",
        ]
        let out = AppState.fillValuesToSend(fields: fields, edited: edited)
        XCTAssertEqual(out, ["성명": "홍길동", "주소": "새값"])
    }

    func testFillValuesToSendDuplicateLabelsLastWins() {
        let fields = [
            FillField(label: "값", value: "", row: 0, col: 0),
            FillField(label: "값", value: "", row: 0, col: 1),
        ]
        let edited = ["0-0-값": "첫째", "0-1-값": "둘째"]
        let out = AppState.fillValuesToSend(fields: fields, edited: edited)
        XCTAssertEqual(out, ["값": "둘째"])
    }
}
```

> 참고: `FillField`는 `Decodable`이라 메모버와이즈 이니셜라이저가 자동 생성된다(커스텀 init이 없으므로). 테스트의 `FillField(label:value:row:col:)`가 그대로 동작한다.

- [ ] **Step 2: 테스트 실패 확인**

Run: `swift test --filter AppFillHelpersTests`
Expected: 컴파일 실패("cannot find 'filledOutputURL'").

- [ ] **Step 3: 구현 추가**

`Sources/App/AppState.swift`의 `patchedOutputURL(for:)` 아래에 추가:
```swift
    /// fill 출력 기본 경로: 원본과 같은 폴더에 "<이름> (채움).hwpx". fill은 항상 hwpx로 내므로 확장자 강제.
    /// 원본은 절대 건드리지 않으므로 항상 새 경로를 돌려준다.
    static func filledOutputURL(for original: URL) -> URL {
        let base = original.deletingPathExtension().lastPathComponent
        let folder = original.deletingLastPathComponent()
        return folder.appendingPathComponent("\(base) (채움).hwpx").uniquified()
    }

    /// 시트에서 편집한 값(키=FillField.id) 중 "변경됐고 비어있지 않은" 것만 label→value로 모은다.
    /// 빈 문자열은 보내지 않는다(빈 덮어쓰기 방지). 중복 label은 마지막이 우선(kordoc 매칭 한계).
    static func fillValuesToSend(fields: [FillField], edited: [String: String]) -> [String: String] {
        var out: [String: String] = [:]
        for field in fields {
            let v = edited[field.id] ?? field.value
            if v != field.value && !v.isEmpty {
                out[field.label] = v
            }
        }
        return out
    }
```

- [ ] **Step 4: 테스트 통과 확인**

Run: `swift test --filter AppFillHelpersTests`
Expected: PASS (4 tests).

- [ ] **Step 5: 커밋**

```bash
git add Sources/App/AppState.swift Tests/CmdMDTests/AppFillHelpersTests.swift
git commit -m "기능(fill): filledOutputURL·fillValuesToSend 순수 헬퍼 추가

출력은 항상 (채움).hwpx로 uniquify. 변경·비어있지 않은 값만 label 키로 전송.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01S2QuZUALidkTNRswXFL6xM"
```

---

### Task 4: KordocFillService

**Files:**
- Create: `Sources/Services/KordocFillService.swift`
- Test: `Tests/CmdMDTests/KordocFillServiceTests.swift` (순수 헬퍼 `parseMatchWarnings`만)

**Interfaces:**
- Consumes: `FillDetection`(Task 1), `KordocService.resolveNpxPath()`, `KordocWriteService.isSameFile(_:_:)`
- Produces:
  - `enum KordocFillError: Error { case toolNotFound, dryRunFailed(String), fillFailed(String), timeout, decodeFailed }`
  - `actor KordocFillService` with `func dryRun(template: URL) async throws -> FillDetection`, `func fill(template: URL, values: [String: String], output: URL) async throws -> [String]`, `static func parseMatchWarnings(_ stderr: String) -> [String]`

- [ ] **Step 1: 실패하는 테스트 작성(순수 헬퍼만)**

`Tests/CmdMDTests/KordocFillServiceTests.swift`:
```swift
import XCTest
@testable import CmdMD

final class KordocFillServiceTests: XCTestCase {
    func testParseMatchWarningsExtractsLabels() {
        let stderr = """
        [kordoc] 신청서.hwpx 파싱 중...
        [kordoc] 2개 필드 채움
        ⚠️ 매칭 실패: 후보자명
        ⚠️ 매칭 실패: 생년월일
        """
        XCTAssertEqual(KordocFillService.parseMatchWarnings(stderr), ["후보자명", "생년월일"])
    }

    func testParseMatchWarningsEmptyWhenNoFailures() {
        XCTAssertTrue(KordocFillService.parseMatchWarnings("[kordoc] 3개 필드 채움").isEmpty)
    }
}
```

- [ ] **Step 2: 테스트 실패 확인**

Run: `swift test --filter KordocFillServiceTests`
Expected: 컴파일 실패("cannot find 'KordocFillService'").

- [ ] **Step 3: 서비스 구현**

`Sources/Services/KordocFillService.swift`:
```swift
import Foundation

enum KordocFillError: Error {
    case toolNotFound
    case dryRunFailed(String)
    case fillFailed(String)
    case timeout
    case decodeFailed
}

/// kordoc fill을 Process로 호출해 서식 빈칸을 채운다. kordoc 자체는 구현하지 않는다(외부 도구).
/// fill은 -o를 무시하고 채운 hwpx를 stdout으로 내므로, stdout을 직접 파일로 받아 우리가 저장한다.
/// 원본은 변경하지 않고 새 .hwpx에만 쓴다.
actor KordocFillService {
    private let timeout: TimeInterval = 120

    /// 서식 필드 목록만 조회한다(채우지 않음). stdout JSON을 FillDetection으로 디코드.
    func dryRun(template: URL) async throws -> FillDetection {
        guard let npx = KordocService.resolveNpxPath() else { throw KordocFillError.toolNotFound }

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        FileManager.default.createFile(atPath: tmp.path(percentEncoded: false), contents: nil)
        guard let outHandle = try? FileHandle(forWritingTo: tmp) else {
            throw KordocFillError.dryRunFailed("임시 파일을 열지 못했습니다.")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: npx)
        process.arguments = ["-y", "kordoc", "fill", "--dry-run", "--silent",
                             template.path(percentEncoded: false)]
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = outHandle   // dry-run JSON을 임시 파일로 받는다.

        do { try process.run() }
        catch { try? outHandle.close(); throw KordocFillError.toolNotFound }

        try await waitOrTimeout(process)
        try? outHandle.close()

        if process.terminationStatus != 0 {
            let msg = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw KordocFillError.dryRunFailed(String(msg.prefix(500)))
        }
        guard let data = try? Data(contentsOf: tmp),
              let detection = try? JSONDecoder().decode(FillDetection.self, from: data) else {
            throw KordocFillError.decodeFailed
        }
        return detection
    }

    /// values(label→value)를 임시 JSON으로 적고 fill을 실행한다. 채운 hwpx(stdout)를 output에 저장.
    /// 반환: 비치명적 "매칭 실패" 라벨 목록.
    func fill(template: URL, values: [String: String], output: URL) async throws -> [String] {
        guard let npx = KordocService.resolveNpxPath() else { throw KordocFillError.toolNotFound }

        // 원본을 절대 덮어쓰지 않는다.
        guard !KordocWriteService.isSameFile(template, output) else {
            throw KordocFillError.fillFailed("출력 경로가 원본과 같습니다. 다른 경로를 선택하세요.")
        }

        // 채울 값 JSON 임시 파일.
        let tmpJson = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("json")
        defer { try? FileManager.default.removeItem(at: tmpJson) }
        do {
            let data = try JSONEncoder().encode(values)
            try data.write(to: tmpJson)
        } catch {
            throw KordocFillError.fillFailed("값 파일을 적지 못했습니다: \(error.localizedDescription)")
        }

        // 채운 hwpx(stdout)를 받을 임시 출력 파일.
        let tmpOut = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("hwpx")
        defer { try? FileManager.default.removeItem(at: tmpOut) }
        FileManager.default.createFile(atPath: tmpOut.path(percentEncoded: false), contents: nil)
        guard let outHandle = try? FileHandle(forWritingTo: tmpOut) else {
            throw KordocFillError.fillFailed("임시 출력 파일을 열지 못했습니다.")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: npx)
        process.arguments = ["-y", "kordoc", "fill", template.path(percentEncoded: false),
                             "-j", tmpJson.path(percentEncoded: false), "--silent"]
        let stderrPipe = Pipe()
        process.standardError = stderrPipe
        process.standardOutput = outHandle   // 채운 hwpx 바이너리를 파일로 직접 받는다(파이프 교착 회피).

        do { try process.run() }
        catch { try? outHandle.close(); throw KordocFillError.toolNotFound }

        try await waitOrTimeout(process)
        try? outHandle.close()

        let stderrText = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if process.terminationStatus != 0 {
            throw KordocFillError.fillFailed(String(stderrText.prefix(500)))
        }

        // 출력 이동(원본과 같지 않음은 위에서 확인). 기존 파일이 있으면 교체.
        if FileManager.default.fileExists(atPath: output.path(percentEncoded: false)) {
            try? FileManager.default.removeItem(at: output)
        }
        do {
            try FileManager.default.moveItem(at: tmpOut, to: output)
        } catch {
            throw KordocFillError.fillFailed("출력 파일을 저장하지 못했습니다: \(error.localizedDescription)")
        }
        guard FileManager.default.fileExists(atPath: output.path(percentEncoded: false)) else {
            throw KordocFillError.fillFailed("출력 파일이 생성되지 않았습니다.")
        }
        return Self.parseMatchWarnings(stderrText)
    }

    /// stderr에서 "매칭 실패: <라벨>" 라인을 골라 라벨 배열로 반환한다(순수 함수).
    static func parseMatchWarnings(_ stderr: String) -> [String] {
        stderr.split(separator: "\n").compactMap { line -> String? in
            guard let r = line.range(of: "매칭 실패:") else { return nil }
            let label = line[r.upperBound...].trimmingCharacters(in: .whitespaces)
            return label.isEmpty ? nil : label
        }
    }

    /// 종료까지 협조적으로 폴링하다 타임아웃이면 terminate.
    private func waitOrTimeout(_ process: Process) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            if Date() > deadline {
                process.terminate()
                throw KordocFillError.timeout
            }
            try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s
        }
    }
}
```

- [ ] **Step 4: 테스트 통과 + 빌드 확인**

Run: `swift test --filter KordocFillServiceTests`
Expected: PASS (2 tests).
Run: `swift build`
Expected: 빌드 성공(서비스가 컴파일됨).

- [ ] **Step 5: 커밋**

```bash
git add Sources/Services/KordocFillService.swift Tests/CmdMDTests/KordocFillServiceTests.swift
git commit -m "기능(fill): KordocFillService(dry-run·fill) 추가

fill은 -o 무시·stdout 스트리밍이라 stdout을 파일로 직접 받아 저장. 매칭실패 경고 파싱.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01S2QuZUALidkTNRswXFL6xM"
```

---

### Task 5: AppState fill 상태·메서드

**Files:**
- Modify: `Sources/App/AppState.swift`
  - 상태 필드 추가(`officeSaveConfirm` 근처, line ~65)
  - 서비스 인스턴스 추가(line ~103, `kordocWriteService` 옆)
  - 메서드 추가(`confirmOfficeSave`/`kordocWriteErrorMessage` 아래, line ~267 근처)
  - `OfficeFillRequest` 구조체 추가(`OfficeSaveRequest` 옆, line ~1773 근처)
- Test: `Tests/CmdMDTests/AppFillStateTests.swift`

**Interfaces:**
- Consumes: `KordocFillService`(Task 4), `FillDetection`/`FillField`(Task 1), `AppState.filledOutputURL`/`fillValuesToSend`(Task 3), `DocumentKind.isFillable`(Task 2)
- Produces:
  - `var AppState.officeFillSession: OfficeFillRequest?`
  - `var AppState.officeFillInProgress: Set<UUID>`
  - `func AppState.beginOfficeFill(tabID: UUID, fileURL: URL)` (@MainActor)
  - `func AppState.confirmOfficeFill(tabID: UUID, fileURL: URL, values: [String: String], output: URL)` (@MainActor)
  - `static func AppState.kordocFillErrorMessage(_ error: Error) -> String`
  - `struct OfficeFillRequest: Identifiable { let id: UUID; let tabID: UUID; let fileURL: URL; let detection: FillDetection; var output: URL }`

- [ ] **Step 1: 실패하는 테스트 작성**

`Tests/CmdMDTests/AppFillStateTests.swift`:
```swift
import XCTest
@testable import CmdMD

final class AppFillStateTests: XCTestCase {
    func testKordocFillErrorMessages() {
        XCTAssertTrue(AppState.kordocFillErrorMessage(KordocFillError.toolNotFound).contains("kordoc"))
        XCTAssertTrue(AppState.kordocFillErrorMessage(KordocFillError.timeout).contains("중단"))
        XCTAssertTrue(AppState.kordocFillErrorMessage(KordocFillError.fillFailed("boom")).contains("boom"))
        XCTAssertTrue(AppState.kordocFillErrorMessage(KordocFillError.dryRunFailed("nope")).contains("nope"))
    }

    @MainActor
    func testBeginOfficeFillIgnoresNonFillable() {
        let app = AppState()
        let tabID = UUID()
        app.beginOfficeFill(tabID: tabID, fileURL: URL(fileURLWithPath: "/tmp/a.docx"))
        XCTAssertNil(app.officeFillSession)
        XCTAssertFalse(app.officeFillInProgress.contains(tabID))
    }

    @MainActor
    func testOfficeFillRequestHoldsDetection() {
        let detection = FillDetection(fields: [], confidence: nil)  // 메모버와이즈 init
        let req = OfficeFillRequest(tabID: UUID(),
                                    fileURL: URL(fileURLWithPath: "/tmp/서식.hwpx"),
                                    detection: detection,
                                    output: URL(fileURLWithPath: "/tmp/서식 (채움).hwpx"))
        XCTAssertEqual(req.output.lastPathComponent, "서식 (채움).hwpx")
        XCTAssertTrue(req.detection.fields.isEmpty)
    }
}
```

> 참고: `FillDetection`은 `Decodable`이고 커스텀 init이 없으므로 메모버와이즈 `FillDetection(fields:confidence:)`가 자동 생성된다.

- [ ] **Step 2: 테스트 실패 확인**

Run: `swift test --filter AppFillStateTests`
Expected: 컴파일 실패("cannot find 'kordocFillErrorMessage'" 등).

- [ ] **Step 3: 상태 필드 추가**

`Sources/App/AppState.swift`의 `var officeSaveConfirm: OfficeSaveRequest?`(line ~65) 아래에 추가:
```swift
    /// 양식 채우기 시트 구동(키 = 활성 office 탭). nil이면 시트 닫힘.
    var officeFillSession: OfficeFillRequest?
    /// 양식 채우기(dry-run·fill) 진행 중인 탭. 스피너·중복 실행 방지.
    var officeFillInProgress: Set<UUID> = []
```

- [ ] **Step 4: 서비스 인스턴스 추가**

`private let kordocWriteService = KordocWriteService()`(line ~103) 아래에 추가:
```swift
    private let kordocFillService = KordocFillService()
```

- [ ] **Step 5: 메서드 추가**

`kordocWriteErrorMessage(_:)` 정의 끝(line ~267) 아래에 추가:
```swift
    // MARK: - kordoc fill 양식 채우기

    /// dry-run으로 서식 필드를 조회해 양식 채우기 시트를 띄운다(아직 채우지 않는다).
    @MainActor
    func beginOfficeFill(tabID: UUID, fileURL: URL) {
        guard DocumentKind.isFillable(fileURL),
              !officeFillInProgress.contains(tabID) else { return }
        officeFillInProgress.insert(tabID)
        Task { @MainActor in
            do {
                let detection = try await kordocFillService.dryRun(template: fileURL)
                officeFillSession = OfficeFillRequest(tabID: tabID, fileURL: fileURL,
                                                      detection: detection,
                                                      output: Self.filledOutputURL(for: fileURL))
            } catch {
                errorMessage = Self.kordocFillErrorMessage(error)
            }
            officeFillInProgress.remove(tabID)
        }
    }

    /// 확인된 값·출력 경로로 kordoc fill을 실행한다. 원본은 건드리지 않는다.
    @MainActor
    func confirmOfficeFill(tabID: UUID, fileURL: URL,
                           values: [String: String], output: URL) {
        guard !officeFillInProgress.contains(tabID) else { return }
        officeFillSession = nil
        officeFillInProgress.insert(tabID)
        Task { @MainActor in
            do {
                let warnings = try await kordocFillService.fill(template: fileURL,
                                                                values: values, output: output)
                if warnings.isEmpty {
                    toastMessage = "양식 채움: \(output.lastPathComponent)"
                } else {
                    toastMessage = "양식 채움: \(output.lastPathComponent) · 매칭 실패 \(warnings.count)개"
                }
            } catch {
                errorMessage = Self.kordocFillErrorMessage(error)
            }
            officeFillInProgress.remove(tabID)
        }
    }

    static func kordocFillErrorMessage(_ error: Error) -> String {
        switch error {
        case KordocFillError.toolNotFound:
            return "kordoc 실행에 필요한 Node(18+)/kordoc을 찾을 수 없습니다. 터미널에서 `npx kordoc` 또는 `npm i -g kordoc` 후 다시 시도하세요."
        case KordocFillError.timeout:
            return "양식 채우기가 너무 오래 걸려 중단했습니다."
        case KordocFillError.dryRunFailed(let m):
            return "서식 필드를 읽지 못했습니다.\n\(m)"
        case KordocFillError.fillFailed(let m):
            return "양식 채우기에 실패했습니다.\n\(m)"
        case KordocFillError.decodeFailed:
            return "서식 필드 정보를 해석하지 못했습니다."
        default:
            return "양식 채우기에 실패했습니다: \(error.localizedDescription)"
        }
    }
```

- [ ] **Step 6: OfficeFillRequest 구조체 추가**

`struct OfficeSaveRequest: Identifiable { … }`(line ~1773) 아래에 추가:
```swift
/// 양식 채우기 시트를 구동하는 요청. detection = dry-run 결과, output = 제안 기본 경로(시드).
struct OfficeFillRequest: Identifiable {
    let id = UUID()
    let tabID: UUID
    let fileURL: URL
    let detection: FillDetection
    var output: URL
}
```

- [ ] **Step 7: 테스트 통과 + 빌드 확인**

Run: `swift test --filter AppFillStateTests`
Expected: PASS (3 tests).
Run: `swift build`
Expected: 빌드 성공.

- [ ] **Step 8: 커밋**

```bash
git add Sources/App/AppState.swift Tests/CmdMDTests/AppFillStateTests.swift
git commit -m "기능(fill): AppState 양식채우기 상태·메서드·OfficeFillRequest 추가

beginOfficeFill(dry-run→시트)·confirmOfficeFill(fill→토스트/경고)·에러 분류.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01S2QuZUALidkTNRswXFL6xM"
```

---

### Task 6: OfficeFillView UI + 진입점 배선

**Files:**
- Create: `Sources/Views/OfficeFillView.swift`
- Modify: `Sources/Views/OfficeReaderView.swift` (툴바에 "양식 채우기" 버튼 추가)
- Modify: `Sources/Views/ContentView.swift` (`.sheet(item: $state.officeFillSession)` 추가, line ~93 저장확인 시트 옆)

**Interfaces:**
- Consumes: `OfficeFillRequest`/`FillField`(Task 1·5), `AppState.fillValuesToSend`/`confirmOfficeFill`(Task 3·5), `AppState.beginOfficeFill`/`officeFillInProgress`(Task 5), `DocumentKind.isFillable`(Task 2), `KordocWriteService.isSameFile`, `URL.uniquified()`
- Produces: `struct OfficeFillView: View` (init `init(request: OfficeFillRequest)`)

- [ ] **Step 1: OfficeFillView 작성**

`Sources/Views/OfficeFillView.swift`:
```swift
import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// 양식 채우기 시트. dry-run으로 감지한 서식 필드를 보여주고 값을 입력받아 새 .hwpx로 저장한다.
/// 원본은 건드리지 않는다(제안→확인→실행).
struct OfficeFillView: View {
    @Environment(AppState.self) private var appState
    let request: OfficeFillRequest
    @State private var values: [String: String]   // 키 = FillField.id
    @State private var output: URL

    init(request: OfficeFillRequest) {
        self.request = request
        // 감지된 현재값으로 프리필.
        var seed: [String: String] = [:]
        for field in request.detection.fields { seed[field.id] = field.value }
        _values = State(initialValue: seed)
        _output = State(initialValue: request.output)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("양식 채우기")
                .font(.headline)
            VStack(alignment: .leading, spacing: 2) {
                Text("원본은 그대로 두고 새 .hwpx로 저장합니다.")
                if let c = request.detection.confidence {
                    Text("감지 확신도 \(Int((c * 100).rounded()))%")
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)

            if request.detection.fields.isEmpty {
                Text("감지된 서식 필드가 없습니다.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 80)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(request.detection.fields) { field in
                            HStack(alignment: .firstTextBaseline, spacing: 12) {
                                Text(field.label.isEmpty ? "(빈 라벨)" : field.label)
                                    .font(.callout)
                                    .frame(width: 160, alignment: .leading)
                                    .lineLimit(2)
                                TextField("값", text: Binding(
                                    get: { values[field.id] ?? "" },
                                    set: { values[field.id] = $0 }
                                ))
                                .textFieldStyle(.roundedBorder)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(maxHeight: 420)
            }

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
                Button("취소") { appState.officeFillSession = nil }
                Button("채우기") {
                    let toSend = AppState.fillValuesToSend(fields: request.detection.fields, edited: values)
                    appState.confirmOfficeFill(tabID: request.tabID, fileURL: request.fileURL,
                                               values: toSend, output: output)
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func chooseLocation() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = output.lastPathComponent
        panel.directoryURL = output.deletingLastPathComponent()
        if let type = UTType(filenameExtension: "hwpx") {
            panel.allowedContentTypes = [type]
        }
        if panel.runModal() == .OK, let url = panel.url {
            // 원본 자체를 고르면 옆 새 경로로 바꿔 원본 보호.
            output = KordocWriteService.isSameFile(url, request.fileURL) ? url.uniquified() : url
        }
    }
}
```

- [ ] **Step 2: OfficeReaderView 툴바에 버튼 추가**

`Sources/Views/OfficeReaderView.swift`의 `.loaded` 케이스 툴바 `HStack` 안, "편집" 버튼 블록(line ~29-35) 바로 다음에 추가(같은 `else if`/`if` 레벨, 비편집 상태에서만 보이도록 `if !isEditing` 블록 안):

기존:
```swift
                    } else if DocumentKind.isPatchable(fileURL) {
                        Button {
                            appState.beginOfficeEdit(tabID: tabID)
                        } label: {
                            Label("편집", systemImage: "pencil")
                        }
                    }
```
다음으로 교체:
```swift
                    } else {
                        if DocumentKind.isPatchable(fileURL) {
                            Button {
                                appState.beginOfficeEdit(tabID: tabID)
                            } label: {
                                Label("편집", systemImage: "pencil")
                            }
                        }
                        if DocumentKind.isFillable(fileURL) {
                            if appState.officeFillInProgress.contains(tabID) {
                                ProgressView().controlSize(.small)
                            }
                            Button {
                                appState.beginOfficeFill(tabID: tabID, fileURL: fileURL)
                            } label: {
                                Label("양식 채우기", systemImage: "square.and.pencil")
                            }
                            .disabled(appState.officeFillInProgress.contains(tabID))
                        }
                    }
```

- [ ] **Step 3: ContentView에 시트 추가**

`Sources/Views/ContentView.swift`의 `.sheet(item: $state.officeSaveConfirm)`(line ~93-95) 블록 바로 아래에 추가:
```swift
        .sheet(item: $state.officeFillSession) { request in
            OfficeFillView(request: request)
        }
```

> `$state`는 해당 파일에서 이미 쓰는 바인딩 패턴을 따른다(저장확인 시트와 동일하게 `$state.officeFillSession`).

- [ ] **Step 4: 빌드 확인**

Run: `swift build`
Expected: 빌드 성공.
Run: `swift test`
Expected: 기존 + 신규 모든 테스트 PASS(UI는 단위테스트 없음, 회귀만 확인).

- [ ] **Step 5: 커밋**

```bash
git add Sources/Views/OfficeFillView.swift Sources/Views/OfficeReaderView.swift Sources/Views/ContentView.swift
git commit -m "기능(fill): OfficeFillView 시트·툴바 진입점·ContentView 배선

dry-run 필드 입력 폼 + 저장경로 확인. isFillable일 때 오피스 프리뷰 툴바에 버튼.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01S2QuZUALidkTNRswXFL6xM"
```

---

### Task 7: Phase 게이트 — 전체 테스트·수동 검증·문서

**Files:**
- Modify: `CLAUDE.md` (현재 상태에 Phase 5b 완료 줄 추가)

**Interfaces:** 없음(통합 검증·문서).

- [ ] **Step 1: 전체 테스트**

Run: `swift test`
Expected: 모든 테스트 PASS(기존 ~121개 + 신규 약 14개). 실패 0.
(swift test는 정식 Xcode 필요. CLT만 있으면 `swift build`로 대체하고 그 사실을 보고한다.)

- [ ] **Step 2: 수동 검증(샘플 문서)**

검증 샘플로 dry-run·fill 동작을 사람이 확인(앱 실행 또는 CLI 대조):
```bash
npx -y kordoc fill --dry-run --silent "/Users/ahbaik/Downloads/제9회_전국동시지방선거_정의당_평가서.hwp" | head -20
```
Expected: `{"fields":[…],"confidence":…}` JSON. 앱에서 .hwp/.hwpx 열고 "양식 채우기" → 필드 목록 표시 → 값 입력 → 새 `(채움).hwpx` 생성·원본 불변 확인.

- [ ] **Step 3: CLAUDE.md 상태 갱신**

`## 현재 상태` 섹션의 Phase 5a 줄 아래에 한 줄 추가(실제 결과 수치로 채움):
```markdown
- Phase 5b 완료(2026-06-30). kordoc fill(양식 채우기) — `KordocFillService`(actor: dry-run으로 서식 필드 JSON 조회 + `kordoc fill -j <values.json>`로 채움, **fill은 -o 무시·stdout 스트리밍이라 stdout을 파일로 직접 받아 저장**, 매칭실패 경고 파싱, 120s) + `FillField`/`FillDetection` 모델 + `DocumentKind.isFillable`(hwp/hwpx) + `OfficeFillView`(모달 시트: 필드 입력 폼·confidence·저장경로 확인). 출력 항상 `(채움).hwpx`(uniquify), 원본 불변, 제안→확인→실행. 변경·비어있지 않은 값만 label 키로 전송. 약 NN개 테스트 통과.
```
그리고 `다음 액션:` 줄을 Phase 6(PARA 라우팅)로 갱신.

- [ ] **Step 4: 커밋**

```bash
git add CLAUDE.md
git commit -m "문서: Phase 5b kordoc fill 양식 채우기 완료 상태 기록

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01S2QuZUALidkTNRswXFL6xM"
```

---

## Self-Review

**Spec coverage:**
- 2.1 dry-run 조회 → Task 4 `dryRun` + Task 1 모델 ✓
- 2.2 fill 실행(-o 무시·stdout) → Task 4 `fill`(stdout→파일) ✓
- 2.3 출력 항상 .hwpx → Task 3 `filledOutputURL` + Task 6 NSSavePanel hwpx ✓
- 2.4 매칭 실패 비치명적 경고 → Task 4 `parseMatchWarnings` + Task 5 토스트 ✓
- 3.1 모델 → Task 1 ✓ / 3.2 서비스 → Task 4 ✓ / 3.3 isFillable → Task 2 ✓
- 4 상태·메서드·OfficeFillRequest → Task 5 ✓
- 5.1 OfficeFillView(필드 폼·confidence·저장경로·변경분만 전송) → Task 6 + Task 3 `fillValuesToSend` ✓
- 5.2 진입점(툴바 버튼·시트) → Task 6 ✓ (커맨드 팔레트는 Phase 5a 편집과 동일하게 툴바 전용 → 범위 밖)
- 6 원본 불변·에러 분류·제안→확인→실행 → Task 4 isSameFile, Task 5 errorMessage, Task 6 시트 ✓
- 7 테스트(isFillable·filledOutputURL·디코딩·전송 빌더·parseMatchWarnings) → Task 1·2·3·4 ✓

**Placeholder scan:** NN(테스트 수)·실제 결과 수치만 실행 시 채움 — 코드/명령은 모두 구체값. 그 외 TBD 없음.

**Type consistency:** `FillField(label:value:row:col:)`·`FillDetection(fields:confidence:)`(메모버와이즈), `FillField.id` = `"\(row)-\(col)-\(label)"`(Task 1·3·5 일치), `KordocFillError` 케이스(Task 4·5 일치), `beginOfficeFill(tabID:fileURL:)`/`confirmOfficeFill(tabID:fileURL:values:output:)`/`fillValuesToSend(fields:edited:)`/`filledOutputURL(for:)`(Task 3·5·6 일치), `officeFillSession`/`officeFillInProgress`(Task 5·6 일치). 일관성 확인됨.
