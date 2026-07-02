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

    // MARK: - 미리보기용 frontmatter 제거

    func testBodyStrippingFrontmatterRemovesBlock() {
        let doc = "---\nmedia: \"a.mp3\"\nsummary: \"흐머\"\n---\n\n# 제목\n\n본문\n"
        XCTAssertEqual(CompanionNote.bodyStrippingFrontmatter(doc), "# 제목\n\n본문\n")
    }

    func testBodyStrippingFrontmatterKeepsPlainContent() {
        XCTAssertEqual(CompanionNote.bodyStrippingFrontmatter("# 그냥 본문\n"), "# 그냥 본문\n")
        // 닫는 펜스가 없으면 원문 유지(깨진 frontmatter를 지우지 않는다).
        XCTAssertEqual(CompanionNote.bodyStrippingFrontmatter("---\nmedia: x\n본문"),
                       "---\nmedia: x\n본문")
    }

    func testBodyStrippingFrontmatterOnInitialContent() {
        let meta = MediaMetadata(durationSeconds: 222, embeddedTitle: "제목", format: "mp3", createdAt: nil)
        let content = CompanionNote.initialContent(mediaFileName: "a.mp3", metadata: meta)
        let body = CompanionNote.bodyStrippingFrontmatter(content)
        XCTAssertFalse(body.contains("media:"), "frontmatter가 남으면 안 된다")
        XCTAssertTrue(body.hasPrefix("# 제목"), "본문은 제목부터 시작")
    }
}
