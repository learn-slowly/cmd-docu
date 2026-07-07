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
        XCTAssertTrue(CompanionNote.isCompanionNote(note, siblingKeys: CompanionNote.siblingKeys(["a.mp3", "a.mp3.md"])))
        // 고아 노트(대응 미디어 없음)는 일반 노트로 취급 — 숨기지 않는다.
        XCTAssertFalse(CompanionNote.isCompanionNote(note, siblingKeys: CompanionNote.siblingKeys(["a.mp3.md"])))
        // 일반 md는 siblings와 무관하게 false.
        XCTAssertFalse(CompanionNote.isCompanionNote(
            URL(fileURLWithPath: "/tmp/일반.md"), siblingKeys: CompanionNote.siblingKeys(["일반.md", "a.mp3"])))
    }

    func testSiblingMatchingIsCaseInsensitive() {
        // 미디어가 Clip.MOV, 노트가 Clip.mov.md — 숨김·배지 모두 성립해야 한다
        let keys = CompanionNote.siblingKeys(["Clip.MOV", "Clip.mov.md"])
        XCTAssertTrue(CompanionNote.isCompanionNote(URL(fileURLWithPath: "/t/Clip.mov.md"), siblingKeys: keys))
        XCTAssertTrue(CompanionNote.hasCompanionNote(for: URL(fileURLWithPath: "/t/Clip.MOV"), siblingKeys: keys))
    }

    func testUppercaseMdNoteMatches() {
        // 노트 확장자가 .MD — a.mp3에 배지, a.mp3.MD 숨김
        let keys = CompanionNote.siblingKeys(["a.mp3", "a.mp3.MD"])
        XCTAssertTrue(CompanionNote.isCompanionNote(URL(fileURLWithPath: "/t/a.mp3.MD"), siblingKeys: keys))
        XCTAssertTrue(CompanionNote.hasCompanionNote(for: URL(fileURLWithPath: "/t/a.mp3"), siblingKeys: keys))
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

    func testSummaryParsesDotsClosingFence() {
        let content = "---\nsummary: 회의 메모\n...\n본문"
        XCTAssertEqual(CompanionNote.summary(fromNoteContent: content), "회의 메모")
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

    func testBodyStrippingHandlesDotsClosingFence() {
        let content = "---\nsummary: s\n...\n본문 시작"
        XCTAssertEqual(CompanionNote.bodyStrippingFrontmatter(content), "본문 시작")
    }

    func testClosingFenceToleratesTrailingSpace() {
        let content = "---\nsummary: s\n--- \n본문"
        XCTAssertEqual(CompanionNote.bodyStrippingFrontmatter(content), "본문")
    }

    // MARK: - media 필드 정합(updatingMediaField — co-rename 후 frontmatter 갱신)

    func testUpdatingMediaFieldReplacesValueAndKeepsRest() {
        let content = "---\nmedia: \"노래.mp3\"\nduration: \"3:41\"\nsummary: \"메모\"\ntags: []\n---\n\n# 노래\n\n본문\n"
        XCTAssertEqual(CompanionNote.updatingMediaField(in: content, to: "새노래.mp3"),
                       "---\nmedia: \"새노래.mp3\"\nduration: \"3:41\"\nsummary: \"메모\"\ntags: []\n---\n\n# 노래\n\n본문\n")
    }

    func testUpdatingMediaFieldNilWithoutFrontmatter() {
        // frontmatter가 없으면 본문에 media: 줄이 있어도 손대지 않는다.
        XCTAssertNil(CompanionNote.updatingMediaField(in: "# 제목\nmedia: 옛날.mp3\n", to: "새.mp3"))
        XCTAssertNil(CompanionNote.updatingMediaField(in: "", to: "새.mp3"))
    }

    func testUpdatingMediaFieldNilWithoutMediaKey() {
        XCTAssertNil(CompanionNote.updatingMediaField(in: "---\nsummary: \"s\"\n---\n본문", to: "새.mp3"))
    }

    func testUpdatingMediaFieldNilWhenBrokenFence() {
        // 닫는 펜스 없음 = 깨진 frontmatter → 불가침(splitFrontmatter와 동일 판정).
        XCTAssertNil(CompanionNote.updatingMediaField(in: "---\nmedia: \"a.mp3\"\n본문", to: "새.mp3"))
    }

    func testUpdatingMediaFieldNilWhenAlreadyCurrent() {
        XCTAssertNil(CompanionNote.updatingMediaField(in: "---\nmedia: \"a.mp3\"\n---\n본문", to: "a.mp3"))
    }

    func testUpdatingMediaFieldPreservesDotsClosingFence() {
        let content = "---\nmedia: \"a.mp3\"\nsummary: \"s\"\n...\n본문"
        XCTAssertEqual(CompanionNote.updatingMediaField(in: content, to: "b.mp3"),
                       "---\nmedia: \"b.mp3\"\nsummary: \"s\"\n...\n본문")
    }

    func testUpdatingMediaFieldQuotesAndEscapes() {
        let content = "---\nmedia: \"a.mp3\"\n---\n본문"
        XCTAssertEqual(CompanionNote.updatingMediaField(in: content, to: "인용\"쿼트\".mp3"),
                       "---\nmedia: \"인용\\\"쿼트\\\".mp3\"\n---\n본문")
    }

    func testUpdatingMediaFieldReplacesOnlyFirstTopLevelKey() {
        // 중복 키는 첫 줄만, 들여쓴 중첩 키·본문 줄은 불가침.
        let content = "---\nmedia: \"a.mp3\"\nmedia: \"b.mp3\"\nnested:\n  media: \"c.mp3\"\n---\nmedia: 본문줄\n"
        XCTAssertEqual(CompanionNote.updatingMediaField(in: content, to: "새.mp3"),
                       "---\nmedia: \"새.mp3\"\nmedia: \"b.mp3\"\nnested:\n  media: \"c.mp3\"\n---\nmedia: 본문줄\n")
    }

    func testUpdatingMediaFieldIgnoresIndentedKeyOnly() {
        // 최상위 media 키가 없고 중첩만 있으면 변경 없음.
        XCTAssertNil(CompanionNote.updatingMediaField(
            in: "---\nnested:\n  media: \"c.mp3\"\n---\n본문", to: "새.mp3"))
    }

    func testUpdatingMediaFieldPreservesBOM() {
        let content = "\u{FEFF}---\nmedia: \"a.mp3\"\n---\n본문"
        XCTAssertEqual(CompanionNote.updatingMediaField(in: content, to: "b.mp3"),
                       "\u{FEFF}---\nmedia: \"b.mp3\"\n---\n본문")
    }

    func testUpdatingMediaFieldOnInitialContentKeepsSummaryParsing() {
        let meta = MediaMetadata(durationSeconds: 222, embeddedTitle: "제목", format: "mp3", createdAt: nil)
        let content = CompanionNote.initialContent(mediaFileName: "a.mp3", metadata: meta)
            .replacingOccurrences(of: "summary: \"\"", with: "summary: \"요약\"")
        let updated = CompanionNote.updatingMediaField(in: content, to: "b.mp3")
        XCTAssertNotNil(updated)
        XCTAssertTrue(updated?.contains("media: \"b.mp3\"") == true)
        XCTAssertEqual(CompanionNote.summary(fromNoteContent: updated ?? ""), "요약")
    }

    func testUpdatingMediaFieldNeverTouchesBodyMediaLine() {
        // frontmatter는 유효하되 media 키는 본문에만 — 경계를 넘어 본문 줄을 잡으면 안 된다
        // (적대적 리뷰: 탐색 범위를 lines[1...]로 넓힌 뮤턴트가 기존 스위트를 전부 통과했음).
        XCTAssertNil(CompanionNote.updatingMediaField(
            in: "---\nsummary: \"s\"\n---\nmedia: 본문줄", to: "새.mp3"))
    }

    func testUpdatingMediaFieldNilWithoutOpeningFence() {
        // 여는 펜스 없이 본문 중간에 media: 줄 + 뒤쪽 "---" 수평선 — frontmatter 아님.
        XCTAssertNil(CompanionNote.updatingMediaField(
            in: "머리말\nmedia: a.mp3\n---\n본문", to: "새.mp3"))
    }

    func testUpdatingMediaFieldKeepsHandFormattingWhenValueUnchanged() {
        // 값이 이미 같으면 서식(무인용·인라인 주석)이 정규형과 달라도 재작성하지 않는다 —
        // 이름 불변 이동/복사·undo에서 수기 편집 노트의 주석·인용 스타일·mtime을 보존.
        XCTAssertNil(CompanionNote.updatingMediaField(
            in: "---\nmedia: a.mp3\n---\n본문", to: "a.mp3"))
        XCTAssertNil(CompanionNote.updatingMediaField(
            in: "---\nmedia: \"a.mp3\" # 원본 위치 메모\n---\n본문", to: "a.mp3"))
    }

    func testUpdatingMediaFieldRewritesCommentedLineWhenValueChanged() {
        // 값이 실제로 바뀌면 정규형으로 재작성 — 인라인 주석 소실은 문서화된 트레이드오프.
        XCTAssertEqual(CompanionNote.updatingMediaField(
            in: "---\nmedia: \"a.mp3\" # 메모\n---\n본문", to: "b.mp3"),
            "---\nmedia: \"b.mp3\"\n---\n본문")
    }

    func testUpdatingMediaFieldLeavesBlockScalarUntouched() {
        // 블록 스칼라(>-·|)는 값이 다음 줄로 이어진다 — 첫 줄만 바꾸면 고아 들여쓰기 줄이
        // 남아 invalid YAML(summary 파싱 파손). 수기 구조는 불가침(nil).
        XCTAssertNil(CompanionNote.updatingMediaField(
            in: "---\nmedia: >-\n  a.mp3\nsummary: \"s\"\n---\n본문", to: "b.mp3"))
        XCTAssertNil(CompanionNote.updatingMediaField(
            in: "---\nmedia: |\n  a.mp3\n---\n본문", to: "b.mp3"))
    }

    func testUpdatingMediaFieldLeavesNestedOrContinuedValueUntouched() {
        // 값 없는 키(중첩 매핑)·다줄 plain 스칼라도 동일 — 불가침(nil).
        XCTAssertNil(CompanionNote.updatingMediaField(
            in: "---\nmedia:\n  name: a.mp3\n---\n본문", to: "b.mp3"))
        XCTAssertNil(CompanionNote.updatingMediaField(
            in: "---\nmedia: 노래\n  이어짐.mp3\n---\n본문", to: "b.mp3"))
    }
}
