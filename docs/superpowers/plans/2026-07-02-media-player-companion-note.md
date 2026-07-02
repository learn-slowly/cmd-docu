# 작업 B — 미디어 플레이어 + 짝꿍 노트 구현 계획

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 미디어(음악·동영상) 파일을 열면 플레이어+짝꿍 마크다운 노트가 한 화면에 뜨고, 노트는 메타데이터 자동 채움·목록 배지·기존 검색 통합까지 지원한다.

**Architecture:** `DocumentKind.media` 신설 → 기존 이미지/PDF/오피스와 동형의 리더 디스패치로 `MediaReaderView`(AVKit 플레이어 + 임베디드 노트 편집기) 추가. 짝꿍 노트 규칙(`파일명.ext.md`)은 순수 헬퍼 `CompanionNote`가 단일 판별원. 목록(사이드바 트리·라이브러리)은 빌드 시 siblings 집합으로 짝꿍 노트를 숨기고 `hasCompanionNote` 플래그를 채워 렌더 중 FS 호출이 없다. 노트가 `.md`라 검색(FTS5·폴더검색·RAG)은 자동 통합.

**Tech Stack:** Swift 5.9+/SwiftUI, AVKit·AVFoundation(시스템, 신규 사용), Yams(기존 의존성), XCTest.

**스펙:** `docs/superpowers/specs/2026-07-02-media-player-companion-note-design.md`

## Global Constraints

- 비샌드박스 유지. 새 패키지 의존성 0 (AVKit/AVFoundation은 macOS 내장).
- **원본 미디어 파일은 어떤 경로에서도 쓰지 않는다**(읽기 전용). 앱이 쓰는 파일은 짝꿍 `.md`뿐. 기존 파일 덮어쓰기 금지.
- 노트 생성은 사용자가 "메모 만들기" 버튼을 눌렀을 때만(자동 생성 없음).
- Phase 게이트: 각 태스크 전후 `swift test`(정식 Xcode 필요)로 기존 315+ 테스트가 깨지지 않는지 확인.
- 코드 주석·커밋 메시지는 한국어. '박다/박는다' 계열 어휘 금지.
- 신규 기능은 별도 파일로(업스트림 머지 용이성). 기존 파일은 최소 가산.
- 테스트에서 AppState를 만들 때는 반드시 `AppState(dataDirectory: TempDataDirectory.make())` 주입(실제 설정 오염 금지).

---

### Task 1: DocumentKind에 media 종류 추가

**Files:**
- Modify: `Sources/Models/DocumentKind.swift`
- Test: `Tests/CmdMDTests/DocumentKindMediaTests.swift` (신규)

**Interfaces:**
- Consumes: 없음 (기존 `DocumentKind` enum).
- Produces: `DocumentKind.media` 케이스, `DocumentKind.audioExtensions: Set<String>`, `DocumentKind.videoExtensions: Set<String>`, `DocumentKind.mediaExtensions: Set<String>`, `static func isVideo(_ url: URL) -> Bool`. 이후 모든 태스크가 사용.

- [ ] **Step 1: 실패하는 테스트 작성**

`Tests/CmdMDTests/DocumentKindMediaTests.swift` 생성:

```swift
import XCTest
@testable import CmdMD

/// DocumentKind.media — 미디어(음악·동영상) 확장자 매핑.
final class DocumentKindMediaTests: XCTestCase {

    func testMediaExtensionsMapToMedia() {
        // AVFoundation 네이티브 재생 확장자 전부 + 대소문자 무시.
        for ext in ["mp3", "m4a", "aac", "wav", "aiff", "flac",
                    "mp4", "mov", "m4v", "MP3", "MOV", "Flac"] {
            let url = URL(fileURLWithPath: "/tmp/노래.\(ext)")
            XCTAssertEqual(DocumentKind(from: url), .media, "확장자 \(ext)는 media여야 한다")
        }
    }

    func testIsVideoSplitsAudioAndVideo() {
        XCTAssertTrue(DocumentKind.isVideo(URL(fileURLWithPath: "/tmp/a.mp4")))
        XCTAssertTrue(DocumentKind.isVideo(URL(fileURLWithPath: "/tmp/a.MOV")))
        XCTAssertTrue(DocumentKind.isVideo(URL(fileURLWithPath: "/tmp/a.m4v")))
        XCTAssertFalse(DocumentKind.isVideo(URL(fileURLWithPath: "/tmp/a.mp3")))
        XCTAssertFalse(DocumentKind.isVideo(URL(fileURLWithPath: "/tmp/a.wav")))
    }

    func testMediaExtensionsIsUnionOfAudioAndVideo() {
        XCTAssertEqual(DocumentKind.mediaExtensions,
                       DocumentKind.audioExtensions.union(DocumentKind.videoExtensions))
    }

    func testExistingKindsUnchanged() {
        XCTAssertEqual(DocumentKind(from: URL(fileURLWithPath: "/tmp/a.png")), .image)
        XCTAssertEqual(DocumentKind(from: URL(fileURLWithPath: "/tmp/a.pdf")), .pdf)
        XCTAssertEqual(DocumentKind(from: URL(fileURLWithPath: "/tmp/a.hwp")), .office)
        XCTAssertEqual(DocumentKind(from: URL(fileURLWithPath: "/tmp/a.md")), .markdown)
        XCTAssertEqual(DocumentKind(from: URL(fileURLWithPath: "/tmp/제목없음")), .markdown)
    }
}
```

- [ ] **Step 2: 테스트가 실패하는지 확인**

Run: `swift test --filter DocumentKindMediaTests 2>&1 | tail -5`
Expected: 컴파일 에러 — `type 'DocumentKind' has no member 'media'` 류.

- [ ] **Step 3: 최소 구현**

`Sources/Models/DocumentKind.swift`의 enum에 케이스 추가:

```swift
enum DocumentKind: String, Codable {
    case markdown
    case image
    case pdf
    case office
    case media
}
```

extension에 (officeExtensions 선언 아래) 추가:

```swift
    /// AVFoundation이 네이티브 재생하는 음악 확장자(소문자).
    static let audioExtensions: Set<String> = ["mp3", "m4a", "aac", "wav", "aiff", "flac"]

    /// AVFoundation이 네이티브 재생하는 동영상 확장자(소문자).
    static let videoExtensions: Set<String> = ["mp4", "mov", "m4v"]

    /// 미디어(음악+동영상) 확장자 합집합.
    static let mediaExtensions: Set<String> = audioExtensions.union(videoExtensions)

    /// 이 파일이 동영상인가 — 미디어 리더 레이아웃 분기용(동영상=좌우 분할, 음악=상단 바).
    static func isVideo(_ url: URL) -> Bool {
        videoExtensions.contains(url.pathExtension.lowercased())
    }
```

`init(from:)`의 office 분기와 markdown 폴백 사이에 media 분기 추가:

```swift
    init(from url: URL) {
        let ext = url.pathExtension.lowercased()
        if DocumentKind.imageExtensions.contains(ext) {
            self = .image
        } else if DocumentKind.pdfExtensions.contains(ext) {
            self = .pdf
        } else if DocumentKind.officeExtensions.contains(ext) {
            self = .office
        } else if DocumentKind.mediaExtensions.contains(ext) {
            self = .media
        } else {
            self = .markdown
        }
    }
```

- [ ] **Step 4: 테스트 통과 확인**

Run: `swift test --filter DocumentKindMediaTests 2>&1 | tail -3`
Expected: `Test Suite 'DocumentKindMediaTests' passed`, 4 tests.

- [ ] **Step 5: 커밋**

```bash
git add Sources/Models/DocumentKind.swift Tests/CmdMDTests/DocumentKindMediaTests.swift
git commit -m "기능(미디어): DocumentKind.media + 음악/동영상 확장자 집합·isVideo"
```

---

### Task 2: MediaMetadataService — 재생 없이 메타데이터 읽기

**Files:**
- Create: `Sources/Services/MediaMetadataService.swift`
- Test: `Tests/CmdMDTests/MediaMetadataServiceTests.swift` (신규)

**Interfaces:**
- Consumes: 없음 (AVFoundation·FileManager만).
- Produces:
  - `struct MediaMetadata: Equatable { var durationSeconds: Double?; var embeddedTitle: String?; var format: String; var createdAt: Date? }`
  - `enum MediaMetadataService { static func load(url: URL) async -> MediaMetadata; static func formatDuration(_ seconds: Double?) -> String }`
  - Task 3(CompanionNote.initialContent)과 Task 6(MediaReaderView)이 사용.

- [ ] **Step 1: 실패하는 테스트 작성**

`Tests/CmdMDTests/MediaMetadataServiceTests.swift` 생성:

```swift
import XCTest
@testable import CmdMD

/// MediaMetadataService — 재생 없이 길이·포맷 읽기 + 표시 포맷터.
final class MediaMetadataServiceTests: XCTestCase {

    /// 1초짜리 8kHz 8-bit 모노 PCM WAV(44바이트 헤더 + 8000바이트 무음)를 만든다.
    private func makeTestWAV(at url: URL) throws {
        let sampleRate: UInt32 = 8000
        let dataSize: UInt32 = 8000
        var data = Data()
        func append(_ s: String) { data.append(s.data(using: .ascii)!) }
        func append32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func append16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        append("RIFF"); append32(36 + dataSize); append("WAVE")
        append("fmt "); append32(16); append16(1); append16(1)   // PCM, mono
        append32(sampleRate); append32(sampleRate)               // sampleRate, byteRate(8bit mono)
        append16(1); append16(8)                                 // blockAlign, bitsPerSample
        append("data"); append32(dataSize)
        data.append(Data(repeating: 128, count: Int(dataSize)))  // 무음
        try data.write(to: url)
    }

    func testLoadReadsDurationFromRealWAV() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("media-meta-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let wav = dir.appendingPathComponent("테스트.wav")
        try makeTestWAV(at: wav)

        let meta = await MediaMetadataService.load(url: wav)
        XCTAssertEqual(meta.format, "wav")
        let duration = try XCTUnwrap(meta.durationSeconds, "WAV 길이를 읽어야 한다")
        XCTAssertEqual(duration, 1.0, accuracy: 0.1)
        XCTAssertNotNil(meta.createdAt, "파일 생성일을 읽어야 한다")
    }

    func testLoadOnMissingFileDoesNotCrash() async {
        let meta = await MediaMetadataService.load(
            url: URL(fileURLWithPath: "/tmp/없는파일-\(UUID().uuidString).mp3"))
        XCTAssertEqual(meta.format, "mp3")
        XCTAssertNil(meta.durationSeconds)
        XCTAssertNil(meta.embeddedTitle)
    }

    func testFormatDuration() {
        XCTAssertEqual(MediaMetadataService.formatDuration(222), "3:42")
        XCTAssertEqual(MediaMetadataService.formatDuration(3723), "1:02:03")
        XCTAssertEqual(MediaMetadataService.formatDuration(5), "0:05")
        XCTAssertEqual(MediaMetadataService.formatDuration(nil), "")
        XCTAssertEqual(MediaMetadataService.formatDuration(-3), "")
        XCTAssertEqual(MediaMetadataService.formatDuration(.infinity), "")
    }
}
```

- [ ] **Step 2: 테스트가 실패하는지 확인**

Run: `swift test --filter MediaMetadataServiceTests 2>&1 | tail -5`
Expected: 컴파일 에러 — `cannot find 'MediaMetadataService' in scope`.

- [ ] **Step 3: 최소 구현**

`Sources/Services/MediaMetadataService.swift` 생성:

```swift
import Foundation
import AVFoundation

/// 미디어 파일 메타데이터(재생 없이 읽음). 어느 필드든 실패하면 nil — 노트 생성을 차단하지 않는다.
struct MediaMetadata: Equatable {
    var durationSeconds: Double?
    var embeddedTitle: String?
    var format: String
    var createdAt: Date?
}

/// AVFoundation으로 미디어 메타데이터를 읽는다. 원본은 읽기 전용.
enum MediaMetadataService {

    /// 길이·내장 제목(ID3 등)·파일 생성일을 읽는다. 실패한 필드는 nil로 두고 계속 진행.
    static func load(url: URL) async -> MediaMetadata {
        let format = url.pathExtension.lowercased()
        let createdAt = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.creationDate] as? Date

        let asset = AVURLAsset(url: url)

        var durationSeconds: Double?
        if let duration = try? await asset.load(.duration) {
            let seconds = CMTimeGetSeconds(duration)
            if seconds.isFinite && seconds > 0 { durationSeconds = seconds }
        }

        var embeddedTitle: String?
        if let items = try? await asset.load(.commonMetadata),
           let titleItem = AVMetadataItem.metadataItems(from: items,
                                                        filteredByIdentifier: .commonIdentifierTitle).first,
           let title = (try? await titleItem.load(.stringValue)) ?? nil,
           !title.isEmpty {
            embeddedTitle = title
        }

        return MediaMetadata(durationSeconds: durationSeconds, embeddedTitle: embeddedTitle,
                             format: format, createdAt: createdAt)
    }

    /// 초 → "m:ss" 또는 "h:mm:ss". nil·비유한·음수는 "".
    static func formatDuration(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return "" }
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }
}
```

- [ ] **Step 4: 테스트 통과 확인**

Run: `swift test --filter MediaMetadataServiceTests 2>&1 | tail -3`
Expected: `passed`, 3 tests. (WAV duration 테스트는 AVFoundation in-process 실행 — 실패 시 `accuracy` 먼저 의심하지 말고 WAV 헤더 바이트를 확인.)

- [ ] **Step 5: 커밋**

```bash
git add Sources/Services/MediaMetadataService.swift Tests/CmdMDTests/MediaMetadataServiceTests.swift
git commit -m "기능(미디어): MediaMetadataService — AVFoundation 길이·제목·생성일 읽기 + 표시 포맷터 (WAV fixture 실검증)"
```

---

### Task 3: CompanionNote — 짝꿍 노트 규칙 순수 헬퍼

**Files:**
- Create: `Sources/Models/CompanionNote.swift`
- Test: `Tests/CmdMDTests/CompanionNoteTests.swift` (신규)

**Interfaces:**
- Consumes: `DocumentKind.mediaExtensions`(Task 1), `MediaMetadata`/`MediaMetadataService.formatDuration`(Task 2), Yams(기존 의존성).
- Produces (이후 Task 4·5·6·7이 사용):
  - `CompanionNote.noteURL(for mediaURL: URL) -> URL`
  - `CompanionNote.mediaURL(for noteURL: URL) -> URL?`
  - `CompanionNote.isCompanionNote(_ url: URL, siblings: Set<String>) -> Bool`
  - `CompanionNote.initialContent(mediaFileName: String, metadata: MediaMetadata, today: Date = Date()) -> String`
  - `CompanionNote.summary(fromNoteContent content: String) -> String?`
  - `CompanionNote.loadSummary(noteURL: URL) async -> String?`

- [ ] **Step 1: 실패하는 테스트 작성**

`Tests/CmdMDTests/CompanionNoteTests.swift` 생성:

```swift
import XCTest
@testable import CmdMD

/// CompanionNote — 짝꿍 노트(파일명.ext.md) 규칙 순수 헬퍼.
final class CompanionNoteTests: XCTestCase {

    // MARK: - 경로 규칙

    func testNoteURLAppendsMd() {
        let media = URL(fileURLWithPath: "/tmp/삐약이_데모.mp3")
        XCTAssertEqual(CompanionNote.noteURL(for: media).lastPathComponent, "삐약이_데모.mp3.md")
    }

    func testMediaURLRoundTrip() {
        let note = URL(fileURLWithPath: "/tmp/삐약이_데모.mp3.md")
        XCTAssertEqual(CompanionNote.mediaURL(for: note)?.lastPathComponent, "삐약이_데모.mp3")
    }

    func testMediaURLHandlesDottedNames() {
        // 점 든 이름: 마지막 두 확장자만 본다.
        let note = URL(fileURLWithPath: "/tmp/1.1.1_강의.mp4.md")
        XCTAssertEqual(CompanionNote.mediaURL(for: note)?.lastPathComponent, "1.1.1_강의.mp4")
    }

    func testMediaURLNilForPlainNote() {
        XCTAssertNil(CompanionNote.mediaURL(for: URL(fileURLWithPath: "/tmp/일반노트.md")))
        XCTAssertNil(CompanionNote.mediaURL(for: URL(fileURLWithPath: "/tmp/스크린샷.png.md")))  // 이미지는 미디어 아님
        XCTAssertNil(CompanionNote.mediaURL(for: URL(fileURLWithPath: "/tmp/음악.mp3")))         // md가 아님
    }

    func testMediaURLIsCaseInsensitive() {
        let note = URL(fileURLWithPath: "/tmp/노래.MP3.MD")
        XCTAssertEqual(CompanionNote.mediaURL(for: note)?.lastPathComponent, "노래.MP3")
    }

    // MARK: - siblings 기반 판별

    func testIsCompanionNoteRequiresSiblingMedia() {
        let note = URL(fileURLWithPath: "/tmp/a.mp3.md")
        XCTAssertTrue(CompanionNote.isCompanionNote(note, siblings: ["a.mp3", "a.mp3.md"]))
        // 고아 노트(대응 미디어 없음)는 일반 노트로 취급 — 숨기지 않는다.
        XCTAssertFalse(CompanionNote.isCompanionNote(note, siblings: ["a.mp3.md"]))
        // 일반 md는 siblings와 무관하게 false.
        XCTAssertFalse(CompanionNote.isCompanionNote(
            URL(fileURLWithPath: "/tmp/일반.md"), siblings: ["일반.md", "a.mp3"]))
    }

    // MARK: - 초기 내용

    func testInitialContentFillsFrontmatter() {
        // 정오 UTC — 시간대(±12h)와 무관하게 같은 날짜가 나오도록.
        let meta = MediaMetadata(durationSeconds: 222, embeddedTitle: "삐약이 추모곡",
                                 format: "mp3", createdAt: Date(timeIntervalSince1970: 43_200))
        let content = CompanionNote.initialContent(mediaFileName: "삐약이_데모.mp3", metadata: meta)
        XCTAssertTrue(content.hasPrefix("---\n"), "frontmatter로 시작해야 한다")
        XCTAssertTrue(content.contains("media: \"삐약이_데모.mp3\""))
        XCTAssertTrue(content.contains("duration: \"3:42\""))
        XCTAssertTrue(content.contains("format: \"mp3\""))
        XCTAssertTrue(content.contains("created: 1970-01-01"))
        XCTAssertTrue(content.contains("summary: \"\""))
        XCTAssertTrue(content.contains("tags: []"))
        XCTAssertTrue(content.contains("# 삐약이 추모곡"), "내장 제목이 본문 제목이 된다")
    }

    func testInitialContentFallsBackToFileNameTitle() {
        let meta = MediaMetadata(durationSeconds: nil, embeddedTitle: nil, format: "mp4", createdAt: nil)
        let today = Date(timeIntervalSince1970: 129_600)  // 1970-01-02 정오 UTC(시간대 무관)
        let content = CompanionNote.initialContent(mediaFileName: "회의녹화.mp4", metadata: meta, today: today)
        XCTAssertTrue(content.contains("duration: \"\""))
        XCTAssertTrue(content.contains("created: 1970-01-02"), "생성일 없으면 오늘 날짜")
        XCTAssertTrue(content.contains("# 회의녹화"), "내장 제목 없으면 확장자 뗀 파일명")
    }

    func testYamlQuotedEscapesQuotesAndBackslash() {
        XCTAssertEqual(CompanionNote.yamlQuoted(#"a"b\c"#), #""a\"b\\c""#)
    }

    // MARK: - summary 파싱

    func testSummaryParsing() {
        let doc = """
        ---
        media: "a.mp3"
        summary: "삐약이 추모곡 첫 데모"
        ---

        본문
        """
        XCTAssertEqual(CompanionNote.summary(fromNoteContent: doc), "삐약이 추모곡 첫 데모")
    }

    func testSummaryNilWhenEmptyOrMissing() {
        XCTAssertNil(CompanionNote.summary(fromNoteContent: "---\nsummary: \"\"\n---\n"))
        XCTAssertNil(CompanionNote.summary(fromNoteContent: "---\nmedia: \"a.mp3\"\n---\n"))
        XCTAssertNil(CompanionNote.summary(fromNoteContent: "frontmatter 없음"))
    }

    func testInitialContentSummaryRoundTrip() {
        // 초기 내용의 summary는 빈 값 → nil.
        let meta = MediaMetadata(durationSeconds: 1, embeddedTitle: nil, format: "wav", createdAt: nil)
        let content = CompanionNote.initialContent(mediaFileName: "a.wav", metadata: meta)
        XCTAssertNil(CompanionNote.summary(fromNoteContent: content))
    }
}
```

- [ ] **Step 2: 테스트가 실패하는지 확인**

Run: `swift test --filter CompanionNoteTests 2>&1 | tail -5`
Expected: 컴파일 에러 — `cannot find 'CompanionNote' in scope`.

- [ ] **Step 3: 최소 구현**

`Sources/Models/CompanionNote.swift` 생성:

```swift
import Foundation
import Yams

/// 미디어 파일의 짝꿍 노트(파일명.ext.md) 규칙 — 단일 판별원.
/// 경로 계산·판별·초기 내용 생성은 순수. 파일시스템 접근은 loadSummary뿐.
enum CompanionNote {

    /// 미디어 URL → 짝꿍 노트 URL. 예: a.mp3 → a.mp3.md
    static func noteURL(for mediaURL: URL) -> URL {
        mediaURL.appendingPathExtension("md")
    }

    /// 노트 URL → 대응 미디어 URL. `.md`를 벗긴 결과가 미디어 확장자일 때만.
    /// 예: a.mp3.md → a.mp3 / 일반노트.md → nil
    static func mediaURL(for noteURL: URL) -> URL? {
        guard noteURL.pathExtension.lowercased() == "md" else { return nil }
        let stripped = noteURL.deletingPathExtension()
        guard DocumentKind.mediaExtensions.contains(stripped.pathExtension.lowercased()) else { return nil }
        return stripped
    }

    /// 같은 폴더 열거 목록(siblings: 파일명 집합) 기준으로 짝꿍 노트인지 판별.
    /// 대응 미디어가 실재할 때만 true — 고아 노트는 일반 노트로 취급(숨기지 않음).
    /// 렌더·빌드 중 추가 FS 호출을 피하려고 siblings를 인자로 받는다.
    static func isCompanionNote(_ url: URL, siblings: Set<String>) -> Bool {
        guard let media = mediaURL(for: url) else { return false }
        return siblings.contains(media.lastPathComponent)
    }

    /// 노트 초기 내용 — frontmatter 자동 채움(§스펙 3.2) + 제목 본문.
    static func initialContent(mediaFileName: String, metadata: MediaMetadata, today: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        let created = formatter.string(from: metadata.createdAt ?? today)
        let duration = MediaMetadataService.formatDuration(metadata.durationSeconds)
        let title = metadata.embeddedTitle ?? (mediaFileName as NSString).deletingPathExtension
        return """
        ---
        media: \(yamlQuoted(mediaFileName))
        duration: \(yamlQuoted(duration))
        format: \(yamlQuoted(metadata.format))
        created: \(created)
        summary: ""
        tags: []
        ---

        # \(title)

        """
    }

    /// YAML 더블쿼트 스칼라 — 역슬래시·따옴표 이스케이프.
    static func yamlQuoted(_ value: String) -> String {
        "\"" + value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    /// 노트 내용에서 frontmatter의 summary를 읽는다(순수). 없거나 빈 값이면 nil.
    static func summary(fromNoteContent content: String) -> String? {
        guard content.hasPrefix("---\n") else { return nil }
        let afterOpen = content.dropFirst(4)
        guard let close = afterOpen.range(of: "\n---") else { return nil }
        let yamlString = String(afterOpen[..<close.lowerBound])
        guard let yaml = (try? Yams.load(yaml: yamlString)) as? [String: Any],
              let summary = yaml["summary"] as? String,
              !summary.isEmpty else { return nil }
        return summary
    }

    /// 짝꿍 노트 파일에서 summary를 비동기로 읽는다(라이브러리 리스트 셀 lazy 표시용).
    static func loadSummary(noteURL: URL) async -> String? {
        let task = Task.detached(priority: .utility) { () -> String? in
            guard let content = try? String(contentsOf: noteURL, encoding: .utf8) else { return nil }
            return summary(fromNoteContent: content)
        }
        return await task.value
    }
}
```

- [ ] **Step 4: 테스트 통과 확인**

Run: `swift test --filter CompanionNoteTests 2>&1 | tail -3`
Expected: `passed`, 11 tests.

- [ ] **Step 5: 커밋**

```bash
git add Sources/Models/CompanionNote.swift Tests/CmdMDTests/CompanionNoteTests.swift
git commit -m "기능(미디어): CompanionNote 순수 헬퍼 — 노트 경로 규칙·siblings 판별·frontmatter 초기내용·summary 파싱"
```

---

### Task 4: 목록 — 짝꿍 노트 숨김 + hasCompanionNote 배지 플래그

**Files:**
- Modify: `Sources/Models/Workspace.swift` (`FileTreeItem`: 120~160행 부근)
- Modify: `Sources/App/AppState.swift` (`isListableInFileTree` 1207행 부근, `buildFileTree` 1220행 부근)
- Modify: `Sources/Services/LibraryListing.swift`
- Test: `Tests/CmdMDTests/MediaListingTests.swift` (신규)

**Interfaces:**
- Consumes: `DocumentKind.mediaExtensions`·`audioExtensions`·`videoExtensions`(Task 1), `CompanionNote.isCompanionNote(_:siblings:)`·`noteURL(for:)`(Task 3).
- Produces: `FileTreeItem.hasCompanionNote: Bool`(기본 false), 미디어 아이콘(`music.note`/`film`), 사이드바·라이브러리에 미디어 표시 + 짝꿍 노트 숨김. Task 7(배지 UI)이 `hasCompanionNote`를 사용.
- 참고: 폴더 검색의 파일명 매칭은 `isListableInFileTree`를 게이트로 쓰므로(AppState `searchInFolder`), 이 태스크로 미디어 파일명 검색이 자동 활성화된다 — 별도 코드 불필요.

- [ ] **Step 1: 실패하는 테스트 작성**

`Tests/CmdMDTests/MediaListingTests.swift` 생성:

```swift
import XCTest
@testable import CmdMD

/// 목록(사이드바 트리·라이브러리) — 미디어 표시·짝꿍 노트 숨김·배지 플래그.
final class MediaListingTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("media-listing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // fixture: 노트 있는 미디어 / 노트 없는 미디어 / 고아 노트 / 일반 노트
        for name in ["a.mp3", "a.mp3.md", "b.mp4", "c.mov.md", "일반.md"] {
            FileManager.default.createFile(
                atPath: dir.appendingPathComponent(name).path,
                contents: Data("x".utf8))
        }
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        dir = nil
        super.tearDown()
    }

    func testMediaIsListableInFileTree() {
        XCTAssertTrue(AppState.isListableInFileTree(URL(fileURLWithPath: "/tmp/a.mp3")))
        XCTAssertTrue(AppState.isListableInFileTree(URL(fileURLWithPath: "/tmp/a.MOV")))
        XCTAssertFalse(AppState.isListableInFileTree(URL(fileURLWithPath: "/tmp/a.exe")))
    }

    func testBuildFileTreeHidesCompanionNoteAndFlagsMedia() {
        let items = AppState.buildFileTree(at: dir, expanded: [])
        let names = items.map(\.name)
        XCTAssertTrue(names.contains("a.mp3"))
        XCTAssertFalse(names.contains("a.mp3.md"), "짝꿍 노트는 숨긴다")
        XCTAssertTrue(names.contains("b.mp4"))
        XCTAssertTrue(names.contains("c.mov.md"), "고아 노트는 일반 노트로 표시")
        XCTAssertTrue(names.contains("일반.md"))

        let a = items.first { $0.name == "a.mp3" }
        let b = items.first { $0.name == "b.mp4" }
        XCTAssertEqual(a?.hasCompanionNote, true, "노트 있는 미디어는 배지 플래그 true")
        XCTAssertEqual(b?.hasCompanionNote, false)
    }

    func testLibraryListingMatchesTreeBehavior() {
        let items = LibraryListing.entries(of: dir)
        let names = items.map(\.name)
        XCTAssertTrue(names.contains("a.mp3"))
        XCTAssertFalse(names.contains("a.mp3.md"))
        XCTAssertEqual(items.first { $0.name == "a.mp3" }?.hasCompanionNote, true)
        XCTAssertEqual(items.first { $0.name == "b.mp4" }?.hasCompanionNote, false)
    }

    func testMediaIcons() {
        XCTAssertEqual(FileTreeItem(url: URL(fileURLWithPath: "/tmp/a.mp3")).icon, "music.note")
        XCTAssertEqual(FileTreeItem(url: URL(fileURLWithPath: "/tmp/a.mp4")).icon, "film")
    }
}
```

- [ ] **Step 2: 테스트가 실패하는지 확인**

Run: `swift test --filter MediaListingTests 2>&1 | tail -5`
Expected: 컴파일 에러 — `FileTreeItem`에 `hasCompanionNote` 없음.

- [ ] **Step 3: 구현**

(a) `Sources/Models/Workspace.swift`의 `FileTreeItem`에 프로퍼티·init 파라미터 추가(맨 끝, 기본값 false — 기존 호출부 무변경):

```swift
struct FileTreeItem: Identifiable, Hashable {
    let id: UUID
    let url: URL
    let isDirectory: Bool
    var isExpanded: Bool
    var children: [FileTreeItem]
    /// 이 미디어 파일에 짝꿍 노트(파일명.ext.md)가 있는가 — 목록 배지용(빌드 시 채움).
    var hasCompanionNote: Bool

    init(url: URL, isDirectory: Bool = false, isExpanded: Bool = false,
         children: [FileTreeItem] = [], hasCompanionNote: Bool = false) {
        self.id = UUID()
        self.url = url
        self.isDirectory = isDirectory
        self.isExpanded = isExpanded
        self.children = children
        self.hasCompanionNote = hasCompanionNote
    }
```

같은 struct의 `icon` computed property에서 `default: return "doc"`를 다음으로 교체:

```swift
        default:
            if DocumentKind.audioExtensions.contains(ext) { return "music.note" }
            if DocumentKind.videoExtensions.contains(ext) { return "film" }
            return "doc"
```

(b) `Sources/App/AppState.swift`의 `isListableInFileTree` — 문서주석과 본문에 미디어 추가:

```swift
    /// 사이드바 파일 트리에 표시할 파일인지 — 마크다운류(md/markdown/txt) + 이미지 + PDF + 오피스 + 미디어.
    /// 각 확장자 집합은 DocumentKind(단일 판별원)를 따른다.
    static func isListableInFileTree(_ url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return ext == "md" || ext == "markdown" || ext == "txt"
            || DocumentKind.imageExtensions.contains(ext)
            || DocumentKind.pdfExtensions.contains(ext)
            || DocumentKind.officeExtensions.contains(ext)
            || DocumentKind.mediaExtensions.contains(ext)
    }
```

(c) 같은 파일 `buildFileTree` — `contents` 확보 직후 siblings 집합을 만들고, 파일 분기를 교체:

```swift
        var items: [FileTreeItem] = []
        // 같은 폴더 파일명 집합 — 짝꿍 노트 숨김·배지 판별용(추가 FS 호출 없음).
        let siblingNames = Set(contents.map { $0.lastPathComponent })
```

파일 분기(`if isListableInFileTree(itemURL) { items.append(...) }`)를:

```swift
                if isListableInFileTree(itemURL) {
                    // 짝꿍 노트는 목록에서 숨긴다 — 미디어 행이 대표(배지로 존재 표시).
                    if CompanionNote.isCompanionNote(itemURL, siblings: siblingNames) { continue }
                    let hasNote = DocumentKind(from: itemURL) == .media
                        && siblingNames.contains(CompanionNote.noteURL(for: itemURL).lastPathComponent)
                    items.append(FileTreeItem(url: itemURL, isDirectory: false, hasCompanionNote: hasNote))
                }
```

(d) `Sources/Services/LibraryListing.swift`의 `entries(of:)` 루프를 동일 논리로 교체:

```swift
        var items: [FileTreeItem] = []
        // 같은 폴더 파일명 집합 — 짝꿍 노트 숨김·배지 판별용(추가 FS 호출 없음).
        let siblingNames = Set(contents.map { $0.lastPathComponent })
        for url in contents {
            guard let resourceValues = try? url.resourceValues(forKeys: [.isDirectoryKey]) else { continue }
            let isDirectory = resourceValues.isDirectory ?? false
            if isDirectory {
                items.append(FileTreeItem(url: url, isDirectory: true))
            } else if AppState.isListableInFileTree(url) {
                // 짝꿍 노트는 숨긴다 — 미디어 행이 대표(배지로 존재 표시).
                if CompanionNote.isCompanionNote(url, siblings: siblingNames) { continue }
                let hasNote = DocumentKind(from: url) == .media
                    && siblingNames.contains(CompanionNote.noteURL(for: url).lastPathComponent)
                items.append(FileTreeItem(url: url, isDirectory: false, hasCompanionNote: hasNote))
            }
        }
        return items
```

- [ ] **Step 4: 테스트 통과 + 전체 회귀 확인**

Run: `swift test --filter MediaListingTests 2>&1 | tail -3` → Expected: `passed`, 4 tests.
Run: `swift test 2>&1 | tail -3` → Expected: 전체 통과(기존 FileTreeBuildTests·LibraryListingTests 포함).

- [ ] **Step 5: 커밋**

```bash
git add Sources/Models/Workspace.swift Sources/App/AppState.swift Sources/Services/LibraryListing.swift Tests/CmdMDTests/MediaListingTests.swift
git commit -m "기능(미디어): 목록에 미디어 표시 + 짝꿍 노트 숨김·hasCompanionNote 배지 플래그(siblings 판별, 렌더 중 FS 호출 없음)"
```

---

### Task 5: 열기 리다이렉트 — 짝꿍 노트를 열면 미디어 뷰로

**Files:**
- Modify: `Sources/App/AppState.swift` (`loadAndActivateDocument` 813행 부근)
- Test: `Tests/CmdMDTests/AppMediaOpenTests.swift` (신규)

**Interfaces:**
- Consumes: `CompanionNote.mediaURL(for:)`(Task 3), `DocumentKind.media`(Task 1), 기존 `openDocument(at:inNewTab:...)`·`EditorTab`.
- Produces: `AppState.mediaRedirectTarget(for url: URL) -> URL?` (static, 테스트 가능한 판별원). 미디어 URL을 열면 `kind == .media`인 탭이 생긴다(기존 비마크다운 탭 경로 재사용 — 추가 구현 없음).

- [ ] **Step 1: 실패하는 테스트 작성**

`Tests/CmdMDTests/AppMediaOpenTests.swift` 생성:

```swift
import XCTest
@testable import CmdMD

/// 미디어 열기 — 짝꿍 노트 리다이렉트 + media 탭 생성.
final class AppMediaOpenTests: XCTestCase {

    private var tempDir: URL!   // AppState 데이터 디렉터리(설정 격리)
    private var filesDir: URL!  // 콘텐츠 파일 폴더

    override func setUpWithError() throws {
        tempDir = TempDataDirectory.make()
        filesDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("media-open-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: filesDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        TempDataDirectory.cleanup(tempDir)
        try? FileManager.default.removeItem(at: filesDir)
        tempDir = nil; filesDir = nil
        super.tearDown()
    }

    private func makeFile(_ name: String) -> URL {
        let url = filesDir.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: Data("x".utf8))
        return url
    }

    // MARK: - 판별원(동기·결정적)

    func testRedirectTargetForCompanionNote() {
        let media = makeFile("a.mp3")
        let note = makeFile("a.mp3.md")
        XCTAssertEqual(AppState.mediaRedirectTarget(for: note), media)
    }

    func testRedirectTargetNilForOrphanAndPlainNotes() {
        let orphan = makeFile("c.mov.md")          // 대응 미디어 없음
        let plain = makeFile("일반.md")
        XCTAssertNil(AppState.mediaRedirectTarget(for: orphan), "고아 노트는 일반 마크다운으로 연다")
        XCTAssertNil(AppState.mediaRedirectTarget(for: plain))
        XCTAssertNil(AppState.mediaRedirectTarget(for: makeFile("b.mp4")), "미디어 자신은 리다이렉트 없음")
    }

    // MARK: - 배선(비동기 폴링)

    @MainActor
    func testOpeningCompanionNoteActivatesMediaTab() async throws {
        let media = makeFile("a.mp3")
        let note = makeFile("a.mp3.md")
        let app = AppState(dataDirectory: tempDir)

        app.openDocument(at: note, inNewTab: true)
        // openDocument는 내부 Task로 비동기 — 탭 생성을 폴링 대기(최대 2초).
        for _ in 0..<200 where !app.tabs.contains(where: { $0.fileURL == media }) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        let tab = try XCTUnwrap(app.tabs.first { $0.fileURL == media }, "미디어 탭이 열려야 한다")
        XCTAssertEqual(tab.kind, .media)
        XCTAssertFalse(app.tabs.contains { $0.fileURL == note }, "노트 자체 탭은 만들지 않는다")
    }

    @MainActor
    func testOpeningMediaCreatesMediaTab() async throws {
        let media = makeFile("b.mp4")
        let app = AppState(dataDirectory: tempDir)

        app.openDocument(at: media, inNewTab: true)
        for _ in 0..<200 where !app.tabs.contains(where: { $0.fileURL == media }) {
            try await Task.sleep(nanoseconds: 10_000_000)
        }

        let tab = try XCTUnwrap(app.tabs.first { $0.fileURL == media })
        XCTAssertEqual(tab.kind, .media)
    }
}
```

- [ ] **Step 2: 테스트가 실패하는지 확인**

Run: `swift test --filter AppMediaOpenTests 2>&1 | tail -5`
Expected: 컴파일 에러 — `mediaRedirectTarget` 없음.

- [ ] **Step 3: 구현**

`Sources/App/AppState.swift` — `loadAndActivateDocument` 바로 위에 판별원 추가:

```swift
    /// 짝꿍 노트 URL이면 대응 미디어 URL을 반환(미디어 실재 시). 아니면 nil.
    /// 검색·위키링크 등 모든 열기 진입로에서 노트 대신 미디어 뷰를 열기 위한 판별원.
    static func mediaRedirectTarget(for url: URL) -> URL? {
        guard let mediaURL = CompanionNote.mediaURL(for: url),
              FileManager.default.fileExists(atPath: mediaURL.path) else { return nil }
        return mediaURL
    }
```

`loadAndActivateDocument(at:inNewTab:)` 본문 맨 앞(기존 existingTab 체크보다 먼저)에 추가:

```swift
        // 짝꿍 노트를 직접 열면 대응 미디어로 리다이렉트 — 노트는 미디어 뷰 안에서 열람·편집한다.
        if let mediaURL = Self.mediaRedirectTarget(for: url) {
            await loadAndActivateDocument(at: mediaURL, inNewTab: inNewTab)
            return
        }
```

(재귀는 1단 — `mediaURL`은 media kind라 다시 리다이렉트되지 않는다. media 탭 생성은 기존 `kind != .markdown` 분기가 그대로 처리한다.)

- [ ] **Step 4: 테스트 통과 + 전체 회귀 확인**

Run: `swift test --filter AppMediaOpenTests 2>&1 | tail -3` → Expected: `passed`, 4 tests.
Run: `swift test 2>&1 | tail -3` → Expected: 전체 통과.

- [ ] **Step 5: 커밋**

```bash
git add Sources/App/AppState.swift Tests/CmdMDTests/AppMediaOpenTests.swift
git commit -m "기능(미디어): 짝꿍 노트 열기 → 대응 미디어 리다이렉트(mediaRedirectTarget) + media 탭 생성"
```

---

### Task 6: MediaReaderView — 플레이어 + 짝꿍 노트 한 화면

**Files:**
- Create: `Sources/Views/MediaReaderView.swift`
- Modify: `Sources/Views/MainEditorView.swift` (readerLayout의 Group 분기, 27~40행 부근)

**Interfaces:**
- Consumes: `DocumentKind.isVideo`(T1), `MediaMetadataService.load`(T2), `CompanionNote.noteURL/initialContent`(T3), `appState.loadFileTree()`(배지 갱신), 기존 `MarkdownPreviewView(documentID:markdown:baseURL:options:scrollSyncEnabled:)`·`MarkdownTextEditor`(OfficeReaderView와 동일 파라미터)·`appState.renderOptions()`.
- Produces: `MediaReaderView(tabID: UUID, url: URL)`. UI라 자동 테스트 없음 — 빌드 + 전체 회귀 + 수동 스모크(Task 8).

- [ ] **Step 1: MediaReaderView 구현**

`Sources/Views/MediaReaderView.swift` 생성:

```swift
import SwiftUI
import AVKit

/// 미디어(음악·동영상) 리더 — 플레이어 + 짝꿍 노트 한 화면.
/// 핵심은 "재생하지 않고도 그 파일이 뭔지 아는 것": 노트가 항상 곁에 보인다.
/// 원본 미디어는 읽기 전용 — 앱이 쓰는 파일은 짝꿍 .md뿐.
struct MediaReaderView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme
    let tabID: UUID
    let url: URL

    @State private var player: AVPlayer?
    @State private var playerFailed = false
    @State private var noteState: NoteState = .checking
    @State private var editBuffer = ""
    @State private var isEditing = false
    @State private var errorText: String?

    private enum NoteState: Equatable {
        case checking          // 노트 존재 확인 중
        case missing           // 노트 없음 → "메모 만들기"
        case creating          // 메타데이터 읽고 생성 중
        case loaded(String)    // 노트 본문(디스크 기준)
    }

    private var noteURL: URL { CompanionNote.noteURL(for: url) }

    var body: some View {
        Group {
            if DocumentKind.isVideo(url) {
                // 동영상: 좌 플레이어 / 우 노트
                HSplitView {
                    playerArea
                        .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
                    notePane
                        .frame(minWidth: 280, maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                // 음악: 상단 컴팩트 재생 바 / 아래 노트 전체
                VStack(spacing: 0) {
                    playerArea
                        .frame(height: 72)
                    Divider()
                    notePane
                }
            }
        }
        .task(id: url) {
            await setUpPlayer()
            loadNote()
        }
        .onDisappear {
            player?.pause()
            saveIfEditing()
        }
    }

    // MARK: - 플레이어

    @ViewBuilder
    private var playerArea: some View {
        if playerFailed {
            VStack(spacing: 8) {
                Image(systemName: "play.slash")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("이 파일은 재생할 수 없습니다 (지원하지 않는 코덱일 수 있어요)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let player {
            VideoPlayer(player: player)
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// 재생 가능 여부를 먼저 확인해 실패 시 플레이스홀더로(PDF 실패 패턴).
    private func setUpPlayer() async {
        player?.pause()
        player = nil
        playerFailed = false
        let asset = AVURLAsset(url: url)
        let playable = (try? await asset.load(.isPlayable)) ?? false
        if playable {
            player = AVPlayer(url: url)
        } else {
            playerFailed = true
        }
    }

    // MARK: - 노트 패널

    @ViewBuilder
    private var notePane: some View {
        VStack(spacing: 0) {
            noteToolbar
            Divider()
            if let errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(6)
            }
            switch noteState {
            case .checking, .creating:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .missing:
                ContentUnavailableView {
                    Label("짝꿍 노트가 없습니다", systemImage: "note.text.badge.plus")
                } description: {
                    Text("메모를 만들면 길이·제목 같은 정보가 자동으로 채워집니다.")
                } actions: {
                    Button("메모 만들기") { createNote() }
                        .buttonStyle(.borderedProminent)
                }
            case .loaded(let content):
                if isEditing {
                    noteEditor
                } else {
                    MarkdownPreviewView(
                        documentID: tabID,
                        markdown: content,
                        baseURL: url.deletingLastPathComponent(),
                        options: appState.renderOptions(),
                        scrollSyncEnabled: false
                    )
                }
            }
        }
    }

    private var noteToolbar: some View {
        HStack(spacing: 8) {
            Label("짝꿍 노트", systemImage: "note.text")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            switch noteState {
            case .loaded:
                if isEditing {
                    Button("취소") {
                        // 편집 내용 파기 — 디스크 기준으로 되돌린다.
                        isEditing = false
                        errorText = nil
                    }
                    Button("저장") { save() }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button {
                        if case .loaded(let content) = noteState { editBuffer = content }
                        isEditing = true
                    } label: {
                        Label("편집", systemImage: "pencil")
                    }
                }
            default:
                EmptyView()
            }
        }
        .padding(8)
    }

    private var noteEditor: some View {
        let settings = appState.settings
        let theme = settings.editorTheme.resolved(forDark: colorScheme == .dark)
        return MarkdownTextEditor(
            documentID: tabID,
            text: $editBuffer,
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

    private func editorFont() -> NSFont {
        let size = appState.settings.fontSize
        let name = appState.settings.fontName
        if !name.isEmpty, let custom = NSFont(name: name, size: size) { return custom }
        return .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    // MARK: - 노트 IO

    private func loadNote() {
        if let content = try? String(contentsOf: noteURL, encoding: .utf8) {
            noteState = .loaded(content)
        } else {
            noteState = .missing
        }
    }

    /// "메모 만들기" — 메타데이터 자동 채움. 기존 파일이 있으면(레이스) 덮어쓰지 않고 그 파일을 연다.
    private func createNote() {
        noteState = .creating
        errorText = nil
        Task {
            let meta = await MediaMetadataService.load(url: url)
            let content = CompanionNote.initialContent(mediaFileName: url.lastPathComponent, metadata: meta)
            if !FileManager.default.fileExists(atPath: noteURL.path) {
                do {
                    try Data(content.utf8).write(to: noteURL, options: [.withoutOverwriting])
                } catch {
                    // 레이스로 이미 생겼으면 아래 loadNote가 그 파일을 연다. 그 외 실패는 안내.
                    if !FileManager.default.fileExists(atPath: noteURL.path) {
                        errorText = "메모 생성 실패: \(error.localizedDescription)"
                        noteState = .missing
                        return
                    }
                }
            }
            loadNote()
            if case .loaded(let loaded) = noteState {
                editBuffer = loaded
                isEditing = true
            }
            appState.loadFileTree()   // 사이드바 배지 갱신
        }
    }

    private func save() {
        do {
            try editBuffer.write(to: noteURL, atomically: true, encoding: .utf8)
            noteState = .loaded(editBuffer)
            isEditing = false
            errorText = nil
        } catch {
            errorText = "저장 실패: \(error.localizedDescription)"
        }
    }

    /// 탭 전환·닫기 시 편집 중이던 내용을 잃지 않도록 저장.
    private func saveIfEditing() {
        guard isEditing, case .loaded(let content) = noteState, editBuffer != content else { return }
        try? editBuffer.write(to: noteURL, atomically: true, encoding: .utf8)
    }
}
```

- [ ] **Step 2: MainEditorView 분기 추가**

`Sources/Views/MainEditorView.swift`의 `readerLayout` Group에서 `.office` 분기 다음, `currentDocument` 분기 앞에 추가:

```swift
            } else if appState.currentTabKind == .media,
                      let url = appState.currentTabFileURL,
                      let tabID = appState.activeTabId {
                MediaReaderView(tabID: tabID, url: url)
                    // 파일이 바뀌면 뷰 상태(편집 버퍼·플레이어)를 리셋 — onDisappear가 먼저 저장한다.
                    .id(url)
```

- [ ] **Step 3: 빌드 + 전체 회귀 확인**

Run: `swift build 2>&1 | tail -3` → Expected: `Build complete!`
Run: `swift test 2>&1 | tail -3` → Expected: 전체 통과.

- [ ] **Step 4: 커밋**

```bash
git add Sources/Views/MediaReaderView.swift Sources/Views/MainEditorView.swift
git commit -m "기능(미디어): MediaReaderView — AVKit 플레이어+짝꿍 노트(미리보기⇄편집·메모 만들기·재생불가 플레이스홀더) + 리더 분기"
```

---

### Task 7: 배지·요약 UI — 사이드바 행·라이브러리 셀

**Files:**
- Modify: `Sources/Views/SidebarView.swift` (`FileTreeItemRow.labelRow`, 424행 부근)
- Modify: `Sources/Views/LibraryView.swift` (`LibraryGridCell`·`LibraryListCell`)

**Interfaces:**
- Consumes: `FileTreeItem.hasCompanionNote`(T4), `CompanionNote.loadSummary(noteURL:)`·`noteURL(for:)`(T3).
- Produces: UI 변경만 — 빌드 + 전체 회귀 + 수동 확인(Task 8).

- [ ] **Step 1: 사이드바 행 배지**

`Sources/Views/SidebarView.swift`의 `FileTreeItemRow.labelRow`에서 즐겨찾기 별 다음에 추가:

```swift
    private var labelRow: some View {
        HStack(spacing: 4) {
            rowLabel
            if isFavorited {
                Image(systemName: "star.fill")
                    .font(.caption2)
                    .foregroundColor(.yellow)
            }
            if item.hasCompanionNote {
                Image(systemName: "note.text")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help("짝꿍 노트 있음")
            }
        }
        .opacity(paraCategory == .archive ? 0.45 : 1.0)
    }
```

- [ ] **Step 2: 라이브러리 격자 셀 배지**

`Sources/Views/LibraryView.swift`의 `LibraryGridCell.body`에서 `imageArea.frame(width: 64, height: 64)`를 다음으로 교체:

```swift
            imageArea
                .frame(width: 64, height: 64)
                .overlay(alignment: .topTrailing) {
                    if item.hasCompanionNote {
                        Image(systemName: "note.text")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(2)
                            .background(.thinMaterial, in: .rect(cornerRadius: 3))
                            .help("짝꿍 노트 있음")
                    }
                }
```

- [ ] **Step 3: 라이브러리 리스트 셀 배지 + 요약 부제(lazy)**

`LibraryListCell`을 다음으로 교체:

```swift
struct LibraryListCell: View {
    @Environment(AppState.self) private var appState
    let item: FileTreeItem

    /// 짝꿍 노트의 summary — 셀이 보일 때만 lazy 로드(썸네일 패턴, 셀 사라지면 취소).
    @State private var summary: String?

    private var paraCategory: ParaCategory {
        ParaLens.classify(item.url, under: appState.currentFolder)
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: item.isDirectory ? "folder" : item.icon)
                .font(.system(size: 14))
                .foregroundStyle(iconColor)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.name)
                    .lineLimit(1)
                    .font(paraCategory == .projects && item.isDirectory ? .body.weight(.medium) : .body)
                if let summary {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            if item.hasCompanionNote {
                Spacer(minLength: 4)
                Image(systemName: "note.text")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help("짝꿍 노트 있음")
            }
        }
        .opacity(paraCategory == .archive ? 0.45 : 1.0)
        .contentShape(Rectangle())
        .padding(.vertical, 2)
        .task(id: item.url) {
            guard item.hasCompanionNote else { summary = nil; return }
            summary = await CompanionNote.loadSummary(noteURL: CompanionNote.noteURL(for: item.url))
        }
    }

    private var iconColor: Color {
        if item.isDirectory && paraCategory == .projects {
            return .cmdsAccent
        }
        return .secondary
    }
}
```

- [ ] **Step 4: 빌드 + 전체 회귀 확인**

Run: `swift build 2>&1 | tail -3` → Expected: `Build complete!`
Run: `swift test 2>&1 | tail -3` → Expected: 전체 통과.

- [ ] **Step 5: 커밋**

```bash
git add Sources/Views/SidebarView.swift Sources/Views/LibraryView.swift
git commit -m "기능(미디어): 목록 배지(사이드바·라이브러리) + 리스트 셀 summary 부제 lazy 표시"
```

---

### Task 8: 마무리 — 전체 게이트·문서 갱신·수동 스모크 체크리스트

**Files:**
- Modify: `CLAUDE.md` (현재 상태 절)
- Modify: `README.md` (포크 기능 목록)

**Interfaces:**
- Consumes: Task 1~7 전부 완료 상태.
- Produces: 문서 갱신 + 수동 스모크 체크리스트(사용자 실행).

- [ ] **Step 1: 전체 테스트 게이트**

Run: `swift test 2>&1 | tail -5`
Expected: 전체 통과(기존 315 + 신규 22 내외). 실패가 있으면 이 태스크를 멈추고 원인부터 잡는다.

- [ ] **Step 2: CLAUDE.md 현재 상태에 한 줄 추가**

`CLAUDE.md`의 `## 현재 상태` 절 끝("다음 액션" 항목 앞)에 완료 기록을 추가한다. 형식은 기존 항목과 동일하게 — 무엇을(플레이어+짝꿍 노트), 어떻게(DocumentKind.media·CompanionNote·MediaMetadataService·MediaReaderView·목록 숨김+배지·열기 리다이렉트), 테스트 수, 남은 수동 스모크를 적는다. "다음 액션" 항목에서 작업 B를 완료로 옮긴다.

- [ ] **Step 3: README 포크 기능 목록에 항목 추가**

`README.md`의 "cmd‑docu 포크가 더한 것" 목록 중 "PARA 라이브러리 뷰" 항목 앞에 추가:

```markdown
- **미디어 플레이어 + 짝꿍 노트** — 음악(mp3·m4a·aac·wav·aiff·flac)·동영상(mp4·mov·m4v)을 열면 플레이어와 짝꿍 마크다운 노트(`파일명.ext.md`)가 한 화면에. 길이·제목은 자동으로 채워지고, 메모는 기존 검색·RAG에 그대로 걸립니다(재생하지 않고도 그 파일이 뭔지 아는 것).
```

- [ ] **Step 4: 커밋**

```bash
git add CLAUDE.md README.md
git commit -m "문서: 작업 B(미디어 플레이어+짝꿍 노트) 완료 기록 — CLAUDE.md 현재 상태·README 기능 목록"
```

- [ ] **Step 5: 수동 스모크 체크리스트 (사용자·실파일 필요)**

앱을 `swift run`으로 띄우고:

1. mp3 열기 → 상단 재생 바 + 아래 노트 패널. **오디오에서 `VideoPlayer` 컨트롤이 쓸 만한지 확인**(스펙 §2 실확인 항목) — 불편하면 후속으로 커스텀 바.
2. mp4 열기 → 좌 플레이어 / 우 노트. 재생·일시정지·시크.
3. "메모 만들기" → frontmatter(duration·format·created) 자동 채움 확인 → summary에 한 줄 적고 저장.
4. 사이드바·라이브러리에서 해당 미디어에 배지 표시 + 짝꿍 노트가 목록에 안 보이는지 확인. 리스트 뷰에서 summary 부제 확인.
5. 인덱스 검색(또는 폴더 검색)에서 노트에 적은 문구로 검색 → 결과 클릭 → **미디어 뷰로** 열리는지 확인.
6. 탭 전환 중 편집 → 돌아와서 내용이 저장돼 있는지 확인.
7. 재생 불가 파일(예: 확장자만 mp4인 텍스트) → 플레이스홀더 확인.
