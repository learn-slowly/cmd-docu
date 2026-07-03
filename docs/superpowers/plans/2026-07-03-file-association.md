# 파일 연결(기본 앱 등록) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 설정 → Tools 탭에서 형식 그룹별로 cmdALL을 macOS 기본 앱으로 등록해, Finder 더블클릭으로 지원 파일이 cmdALL에서 열리게 한다.

**Architecture:** 순수 그룹 모델(`FileTypeGroup`, DocumentKind 상수 재사용)과 `NSWorkspace` 래퍼(`FileAssociationService`)를 새 파일로 분리하고, 기존 ToolsSettingsView에 "파일 연결" 섹션만 더한다. 전제조건으로 package_app.sh의 Info.plist에 문서형 선언(Viewer/Alternate)을 확장한다. 파일 열기 배선은 기존 완비(`handleURL`→`openDocument`) — macOS 쪽 등록만 추가.

**Tech Stack:** Swift/SwiftUI, AppKit `NSWorkspace.setDefaultApplication(at:toOpen:)`(macOS 12+, **컴파일 검증 완료** 2026-07-03: `swiftc -typecheck`로 시그니처 실측 — `try await ws.setDefaultApplication(at: URL, toOpen: UTType)`·`ws.urlForApplication(toOpen: UTType)`), UniformTypeIdentifiers, XCTest.

**Spec:** `docs/superpowers/specs/2026-07-03-file-association-design.md`

## Global Constraints

- 그룹 6개 고정(순서 포함): 한글 문서(hwp/hwpx/hwpml) · 오피스 문서(doc/docx/xls/xlsx) · 마크다운·텍스트(md/markdown/mdown/txt) · PDF(pdf) · 이미지(png/jpg/jpeg/heic/webp/gif) · 미디어(mp3/m4a/aac/wav/aiff/flac/mp4/mov/m4v). 대표 확장자 = 첫 원소.
- 확장자 출처는 `DocumentKind` 상수 — 마크다운 그룹용 `markdownExtensions`만 신설, 나머지 이중 정의 금지(테스트로 정합 고정).
- `swift run`(비 .app 번들)에서는 기능 비활성 + 안내 문구. 등록 해제 UI 없음(Finder 안내 footer).
- 자동 등록 없음 — 사용자 버튼 클릭으로만.
- 코드 주석·커밋 메시지는 한국어. '박다/박는다/박았다' 류 표현 금지. 파일 삭제 없음. 커밋은 태스크마다.
- Phase 게이트: 현 스위트 389개(XCTest 371+Testing 18) 유지. `swift test`는 정식 Xcode 필요.
- dist/ 커밋 금지.

---

### Task 1: FileTypeGroup + FileAssociationService (+ DocumentKind.markdownExtensions)

**Files:**
- Modify: `Sources/Models/DocumentKind.swift` (markdownExtensions 상수 추가)
- Create: `Sources/Services/FileAssociationService.swift`
- Test: `Tests/CmdMDTests/FileAssociationGroupTests.swift` (신규)

**Interfaces:**
- Consumes: `DocumentKind.officeExtensions`/`pdfExtensions`/`imageExtensions`/`mediaExtensions`(전부 `Set<String>`), 신설 `markdownExtensions: Set<String>`.
- Produces(Task 2가 사용): `struct FileTypeGroup: Identifiable, Equatable`(`id: String`·`name: String`·`extensions: [String]`·`representativeExtension: String`·`static let all: [FileTypeGroup]`), `enum FileAssociationError: Error, Equatable`(`.notPackagedApp`·`.partialFailure(failed: [String])`), `@MainActor enum FileAssociationService`(`static var appBundleURL: URL?`, `static func currentDefaultAppName(for: FileTypeGroup) -> String?`, `static func setAsDefault(group: FileTypeGroup) async -> Result<Void, FileAssociationError>`).

- [ ] **Step 1: 실패하는 테스트 작성**

`Tests/CmdMDTests/FileAssociationGroupTests.swift` 신규:

```swift
import XCTest
@testable import CmdMD

/// 파일 연결 그룹 정의가 DocumentKind 상수와 어긋나지 않게 고정한다(이중 정의 드리프트 방지).
final class FileAssociationGroupTests: XCTestCase {
    func testGroupsMatchDocumentKindConstants() {
        let byId = Dictionary(uniqueKeysWithValues: FileTypeGroup.all.map { ($0.id, $0) })
        let hangul = Set(byId["hangul"]!.extensions)
        let office = Set(byId["office"]!.extensions)
        XCTAssertEqual(hangul.union(office), DocumentKind.officeExtensions,
                       "한글+오피스 합집합이 officeExtensions와 달라졌습니다")
        XCTAssertTrue(hangul.isDisjoint(with: office))
        XCTAssertEqual(Set(byId["markdown"]!.extensions), DocumentKind.markdownExtensions)
        XCTAssertEqual(Set(byId["pdf"]!.extensions), DocumentKind.pdfExtensions)
        XCTAssertEqual(Set(byId["image"]!.extensions), DocumentKind.imageExtensions)
        XCTAssertEqual(Set(byId["media"]!.extensions), DocumentKind.mediaExtensions)
    }

    func testNoDuplicateExtensionsAcrossGroups() {
        let all = FileTypeGroup.all.flatMap(\.extensions)
        XCTAssertEqual(all.count, Set(all).count, "그룹 간 확장자 중복")
    }

    func testGroupOrderAndRepresentative() {
        XCTAssertEqual(FileTypeGroup.all.count, 6)
        XCTAssertEqual(FileTypeGroup.all.first?.id, "hangul")
        for group in FileTypeGroup.all {
            XCTAssertFalse(group.extensions.isEmpty)
            XCTAssertEqual(group.representativeExtension, group.extensions[0])
        }
    }
}
```

- [ ] **Step 2: 실패 확인**

Run: `swift test --filter FileAssociationGroupTests 2>&1 | tail -5`
Expected: 컴파일 실패 — `cannot find 'FileTypeGroup' in scope`.

- [ ] **Step 3: DocumentKind.markdownExtensions 추가**

`Sources/Models/DocumentKind.swift`의 `pdfExtensions` 선언 블록 바로 아래에 추가:

```swift
    /// 기본(마크다운) 뷰로 여는 텍스트 확장자(소문자) — 파일 연결(기본 앱 등록) 그룹 정의용.
    /// Info.plist 문서형 선언(md/markdown/mdown)과 앱이 여는 txt를 포함한다.
    static let markdownExtensions: Set<String> = ["md", "markdown", "mdown", "txt"]
```

- [ ] **Step 4: FileAssociationService 구현**

`Sources/Services/FileAssociationService.swift` 신규:

```swift
import AppKit
import UniformTypeIdentifiers

/// 파일 연결(기본 앱 등록) 대상 형식 그룹. 확장자 출처는 DocumentKind 상수(이중 정의 금지,
/// 정합은 FileAssociationGroupTests가 고정). UI 표시 순서·대표 확장자(첫 원소) 규칙 때문에 배열로 둔다.
struct FileTypeGroup: Identifiable, Equatable {
    let id: String
    let name: String
    let extensions: [String]

    /// 현재 기본 앱 표시에 쓰는 대표 확장자(첫 원소).
    var representativeExtension: String { extensions[0] }

    static let all: [FileTypeGroup] = [
        FileTypeGroup(id: "hangul", name: "한글 문서", extensions: ["hwp", "hwpx", "hwpml"]),
        FileTypeGroup(id: "office", name: "오피스 문서", extensions: ["doc", "docx", "xls", "xlsx"]),
        FileTypeGroup(id: "markdown", name: "마크다운·텍스트", extensions: ["md", "markdown", "mdown", "txt"]),
        FileTypeGroup(id: "pdf", name: "PDF", extensions: ["pdf"]),
        FileTypeGroup(id: "image", name: "이미지", extensions: ["png", "jpg", "jpeg", "heic", "webp", "gif"]),
        FileTypeGroup(id: "media", name: "미디어", extensions: ["mp3", "m4a", "aac", "wav", "aiff", "flac", "mp4", "mov", "m4v"]),
    ]
}

enum FileAssociationError: Error, Equatable {
    /// swift run 등 .app 번들 밖 실행 — Launch Services 등록 불가.
    case notPackagedApp
    /// 일부 확장자 등록 실패(UTType 획득 실패 포함).
    case partialFailure(failed: [String])
}

/// macOS 기본 앱 등록(NSWorkspace) 래퍼. UI에서만 소비하므로 MainActor로 단순화.
/// hwp 계열처럼 시스템 선언이 없는 확장자는 UTType(filenameExtension:)이 동적 타입(dyn.*)을
/// 돌려주는데, Launch Services는 동적 타입에도 기본 핸들러를 기록한다 — 설치 앱 수동 스모크로 실측(스펙 §5).
@MainActor
enum FileAssociationService {
    /// 패키징된 .app에서 실행 중일 때만 그 번들 URL(아니면 nil — swift run 가드).
    static var appBundleURL: URL? {
        let url = Bundle.main.bundleURL
        return url.pathExtension == "app" ? url : nil
    }

    /// 그룹 대표 확장자의 현재 기본 앱 이름(연결된 앱이 없으면 nil).
    static func currentDefaultAppName(for group: FileTypeGroup) -> String? {
        guard let type = UTType(filenameExtension: group.representativeExtension),
              let appURL = NSWorkspace.shared.urlForApplication(toOpen: type) else { return nil }
        return FileManager.default.displayName(atPath: appURL.path)
    }

    /// 그룹 내 모든 확장자의 기본 앱을 이 앱으로 등록. 실패 확장자를 모아 부분 실패로 보고한다.
    static func setAsDefault(group: FileTypeGroup) async -> Result<Void, FileAssociationError> {
        guard let bundleURL = appBundleURL else { return .failure(.notPackagedApp) }
        var failed: [String] = []
        for ext in group.extensions {
            guard let type = UTType(filenameExtension: ext) else {
                failed.append(ext)
                continue
            }
            do {
                try await NSWorkspace.shared.setDefaultApplication(at: bundleURL, toOpen: type)
            } catch {
                failed.append(ext)
            }
        }
        return failed.isEmpty ? .success(()) : .failure(.partialFailure(failed: failed))
    }
}
```

- [ ] **Step 5: 테스트 통과 확인**

Run: `swift test --filter FileAssociationGroupTests 2>&1 | tail -5`
Expected: 3개 테스트 PASS.

- [ ] **Step 6: 전체 게이트 + 커밋**

Run: `swift build 2>&1 | tail -3 && swift test 2>&1 | grep -E "Executed [0-9]+ tests" | tail -1`
Expected: 경고 0, `Executed 374 tests`(371+3; Swift Testing 18은 별도 줄).

```bash
git add Sources/Models/DocumentKind.swift Sources/Services/FileAssociationService.swift Tests/CmdMDTests/FileAssociationGroupTests.swift
git commit -m "기능(파일연결): FileTypeGroup 6그룹·FileAssociationService — NSWorkspace UTType 기본 앱 등록 래퍼, DocumentKind 상수 정합 테스트로 이중 정의 드리프트 방지"
```

---

### Task 2: Tools 탭 "파일 연결" 섹션

**Files:**
- Modify: `Sources/Views/SettingsView.swift` (`ToolsSettingsView` — :678부터. 섹션 1개+상태 3개+메서드 2개 추가)

**Interfaces:**
- Consumes: Task 1의 `FileTypeGroup.all`·`FileAssociationService.appBundleURL`/`currentDefaultAppName(for:)`/`setAsDefault(group:)`·`FileAssociationError`.
- Produces: 없음 (말단 뷰).

- [ ] **Step 1: 상태 추가**

`ToolsSettingsView`의 `@State private var hasChecked = false` 아래에 추가:

```swift
    /// 파일 연결 상태(그룹 id 키): 현재 기본 앱 이름·성공 표시·부분 실패 확장자.
    @State private var defaultAppNames: [String: String] = [:]
    @State private var associatedGroups: Set<String> = []
    @State private var associationFailures: [String: [String]] = [:]
```

- [ ] **Step 2: 섹션 추가**

`body`의 "검색 인덱스" `Section`(footer가 "폴더 등록·해제는 내용 검색 창에서 합니다.…"인 블록) 바로 아래, "상태 새로고침" `Section` 앞에 추가:

```swift
            Section {
                if FileAssociationService.appBundleURL == nil {
                    Text("패키징된 앱(/Applications의 cmdALL.app)에서만 사용할 수 있습니다.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(FileTypeGroup.all) { group in
                        associationRow(for: group)
                    }
                }
            } header: {
                Text("파일 연결")
            } footer: {
                Text("다른 앱으로 되돌리려면 Finder에서 파일 정보(⌘I) → 다음으로 열기에서 바꾸세요.")
                    .font(.caption)
            }
```

- [ ] **Step 3: 행 뷰·동작 메서드 추가**

`toolStatusRows` 메서드 아래에 추가:

```swift
    /// 그룹 한 행: 그룹명+확장자 캡션 / 현재 기본 앱 이름 / "cmdALL로" 버튼(+성공 체크·부분 실패 캡션).
    @ViewBuilder
    private func associationRow(for group: FileTypeGroup) -> some View {
        LabeledContent {
            HStack(spacing: 8) {
                if associatedGroups.contains(group.id) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                Text(defaultAppNames[group.id] ?? "없음")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Button("cmdALL로") { associate(group) }
            }
        } label: {
            Text(group.name)
            Text(group.extensions.joined(separator: ", "))
        }
        if let failed = associationFailures[group.id] {
            Text("일부 실패: \(failed.joined(separator: ", "))")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    private func associate(_ group: FileTypeGroup) {
        Task { @MainActor in
            switch await FileAssociationService.setAsDefault(group: group) {
            case .success:
                associatedGroups.insert(group.id)
                associationFailures[group.id] = nil
            case .failure(.partialFailure(let failed)):
                associatedGroups.remove(group.id)
                associationFailures[group.id] = failed
            case .failure(.notPackagedApp):
                associationFailures[group.id] = group.extensions
            }
            refreshDefaultAppNames()
        }
    }

    /// 현재 기본 앱 이름 일괄 재조회 — 가벼운 LS 질의(프로세스 스폰 없음, Tools 탭 원칙 유지).
    private func refreshDefaultAppNames() {
        guard FileAssociationService.appBundleURL != nil else { return }
        var names: [String: String] = [:]
        for group in FileTypeGroup.all {
            names[group.id] = FileAssociationService.currentDefaultAppName(for: group)
        }
        defaultAppNames = names
    }
```

- [ ] **Step 4: refresh()에 이름 조회 연결**

기존 `refresh()` 메서드 첫 줄(Task.detached 앞)에 한 줄 추가:

```swift
        refreshDefaultAppNames()
```

(경로 탐지는 백그라운드 유지 — 이름 조회는 동기 LS 질의라 메인에서 즉시.)

- [ ] **Step 5: 빌드·전체 테스트** (뷰 전용 — 신규 단위 테스트 없음, 검증은 수동 스모크 몫)

Run: `swift build 2>&1 | tail -3 && swift test 2>&1 | grep -E "Executed [0-9]+ tests" | tail -1`
Expected: 경고 0, `Executed 374 tests` 통과.

- [ ] **Step 6: 커밋**

```bash
git add Sources/Views/SettingsView.swift
git commit -m "기능(파일연결): Tools 탭 파일 연결 섹션 — 그룹별 현재 기본 앱 표시·cmdALL 등록 버튼·부분 실패 캡션, swift run에선 안내 문구(LS 등록은 .app 전제)"
```

---

### Task 3: Info.plist 문서형 선언 확장 + 재패키징

**Files:**
- Modify: `scripts/package_app.sh` (Info.plist heredoc의 `CFBundleDocumentTypes`)
- Modify: `scripts/test_package_app.sh` (hwp 선언 검증 1건)

**Interfaces:**
- Produces: 재패키징된 `dist/cmdALL.app`·`dist/cmdALL-0.9.0.dmg`(LS가 cmdALL을 각 형식 후보 앱으로 등록 — 사용자 재설치 후 스모크).

- [ ] **Step 1: 기존 Markdown dict에 txt 추가**

`scripts/package_app.sh` heredoc의 `CFBundleDocumentTypes` 안 Markdown dict `CFBundleTypeExtensions` 배열에 `<string>txt</string>` 추가(mdown 아래):

```xml
      <key>CFBundleTypeExtensions</key>
      <array>
        <string>md</string>
        <string>markdown</string>
        <string>mdown</string>
        <string>txt</string>
      </array>
```

- [ ] **Step 2: 신규 문서형 dict 5개 추가**

같은 `CFBundleDocumentTypes` 배열 안, Markdown dict를 닫는 `</dict>` 바로 뒤에 추가:

```xml
    <dict>
      <key>CFBundleTypeExtensions</key>
      <array>
        <string>hwp</string>
        <string>hwpx</string>
        <string>hwpml</string>
      </array>
      <key>CFBundleTypeName</key>
      <string>Hangul Document</string>
      <key>CFBundleTypeRole</key>
      <string>Viewer</string>
      <key>LSHandlerRank</key>
      <string>Alternate</string>
    </dict>
    <dict>
      <key>CFBundleTypeExtensions</key>
      <array>
        <string>doc</string>
        <string>docx</string>
        <string>xls</string>
        <string>xlsx</string>
      </array>
      <key>CFBundleTypeName</key>
      <string>Office Document</string>
      <key>CFBundleTypeRole</key>
      <string>Viewer</string>
      <key>LSHandlerRank</key>
      <string>Alternate</string>
    </dict>
    <dict>
      <key>CFBundleTypeExtensions</key>
      <array>
        <string>pdf</string>
      </array>
      <key>CFBundleTypeName</key>
      <string>PDF Document</string>
      <key>CFBundleTypeRole</key>
      <string>Viewer</string>
      <key>LSHandlerRank</key>
      <string>Alternate</string>
      <key>LSItemContentTypes</key>
      <array>
        <string>com.adobe.pdf</string>
      </array>
    </dict>
    <dict>
      <key>CFBundleTypeExtensions</key>
      <array>
        <string>png</string>
        <string>jpg</string>
        <string>jpeg</string>
        <string>heic</string>
        <string>webp</string>
        <string>gif</string>
      </array>
      <key>CFBundleTypeName</key>
      <string>Image</string>
      <key>CFBundleTypeRole</key>
      <string>Viewer</string>
      <key>LSHandlerRank</key>
      <string>Alternate</string>
    </dict>
    <dict>
      <key>CFBundleTypeExtensions</key>
      <array>
        <string>mp3</string>
        <string>m4a</string>
        <string>aac</string>
        <string>wav</string>
        <string>aiff</string>
        <string>flac</string>
        <string>mp4</string>
        <string>mov</string>
        <string>m4v</string>
      </array>
      <key>CFBundleTypeName</key>
      <string>Media</string>
      <key>CFBundleTypeRole</key>
      <string>Viewer</string>
      <key>LSHandlerRank</key>
      <string>Alternate</string>
    </dict>
```

- [ ] **Step 3: test_package_app.sh 검증 추가**

`cmdmd` URL 스킴 검증 블록 앞에 추가:

```bash
/usr/libexec/PlistBuddy -c "Print :CFBundleDocumentTypes" "$PLIST" | grep -q "hwp" \
  || fail "Info.plist does not declare hwp in CFBundleDocumentTypes (file association would not register)"
```

- [ ] **Step 4: 재패키징 실행 검증** (릴리스 빌드 포함 — 수 분 소요)

Run: `bash scripts/test_package_app.sh 2>&1 | tail -3`
Expected: `PASS: package app artifact checks passed`

Run: `/usr/libexec/PlistBuddy -c "Print :CFBundleDocumentTypes" dist/cmdALL.app/Contents/Info.plist | grep -c "CFBundleTypeName"`
Expected: `6` (Markdown + 신규 5)

Run: `bash scripts/make_dmg.sh && ls -lh dist/cmdALL-0.9.0.dmg`
Expected: DMG 재생성.

- [ ] **Step 5: 커밋** (dist/ 제외)

```bash
git add scripts/package_app.sh scripts/test_package_app.sh
git commit -m "배포(파일연결): Info.plist 문서형 선언 확장 — 한글·오피스·PDF·이미지·미디어 Viewer/Alternate + Markdown에 txt, LS가 cmdALL을 후보 앱으로 등록하는 전제조건"
```

---

### Task 4: 문서 기록 (CLAUDE.md)

**Files:**
- Modify: `CLAUDE.md` (「현재 상태」끝 항목 추가 + 「다음 액션」갱신)

**Interfaces:** 없음 (문서).

- [ ] **Step 1: CLAUDE.md 갱신**

「현재 상태」끝에 한 문단 추가(기존 항목 문체·밀도) — 담을 사실:
- Phase 10 수동 스모크 완료(2026-07-03) 및 **스모크 발견 Critical 수정**: 설치 앱에서 HWP·엑셀 등 오피스 변환 전멸 — launchd 최소 PATH에서 npx 셔뱅(`#!/usr/bin/env node`)이 node 탐색 실패(exit 127 실측). `SubprocessEnvironment`(순수 헬퍼: 도구 디렉터리+심링크 해석 디렉터리를 자식 PATH 앞에 보정) + 스폰 7곳 배선(zsh 프로브 2곳 제외), 신규 테스트 5(389개). 재설치 후 HWP·xlsx 사용자 실측 통과. 부산물: kordoc --help 공식 목록은 HWP/HWPX/PDF/XLSX/DOCX이나 레거시 .xls도 실측 변환(.doc·.hwpml 미실측).
- 파일 연결(기본 앱 등록) 완료: `FileTypeGroup` 6그룹(DocumentKind 정합 테스트)·`FileAssociationService`(NSWorkspace UTType 등록, swift run 가드)·Tools 탭 "파일 연결" 섹션(현재 기본 앱 표시·그룹별 버튼·부분 실패 캡션·Finder 복원 안내)·Info.plist 문서형 선언 확장(재설치 필요). 테스트 수치는 실측(예상 392=XCTest 374+Testing 18).
- 수동 스모크(대기): 재설치 → Tools 탭 한글 문서 연결 → Finder에서 .hwp 더블클릭 → cmdALL로 열림(hwp 동적 UTType 실측 — 스펙 §5, 실패 시 UTImportedTypeDeclarations 대안).

「다음 액션」의 수동 스모크 문구를 이번 기능 스모크로 갱신.

- [ ] **Step 2: 최종 게이트 + 커밋**

Run: `swift test 2>&1 | grep -E "Executed [0-9]+ tests" | tail -1`
Expected: `Executed 374 tests` 통과.

```bash
git add CLAUDE.md
git commit -m "문서: PATH 수정 스모크 통과·파일 연결 완료 기록 — CLAUDE.md 상태·다음 액션(파일 연결 스모크 대기)"
```

---

## 수동 스모크 (구현 완료 후 사용자, 재설치 필수)

1. 새 DMG 설치(Info.plist 변경 반영) → 앱 실행
2. 설정 → Tools → "파일 연결" 섹션: 그룹 6개·현재 기본 앱 이름 표시(예: PDF=미리보기)
3. "한글 문서 → cmdALL로" 클릭 → 체크 표시+이름이 cmdALL로 갱신 → **Finder에서 .hwp 더블클릭 → cmdALL로 열림**(핵심: hwp 동적 UTType 실측)
4. PDF 또는 이미지 그룹 1개 더 연결·더블클릭 확인
5. (선택) `swift run` 실행 시 섹션이 안내 문구로 대체되는지
6. 실패 시: 스펙 §2 대안(UTImportedTypeDeclarations) 경로로 후속
