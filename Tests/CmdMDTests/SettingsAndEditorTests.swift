import XCTest
@testable import CmdMD

final class SettingsAndEditorTests: XCTestCase {
    // MARK: Resilient settings decoding

    func testSettingsDecodeFromEmptyObjectUsesDefaults() throws {
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(settings, AppSettings())
    }

    func testSettingsDecodePreservesKnownAndIgnoresUnknownKeys() throws {
        // Simulates a settings.json written by an older or newer app version:
        // one known key, one removed key. Decoding must not reset everything.
        let json = """
        { "fontSize": 18, "showInvisibles": true, "cloudSyncEnabled": true }
        """
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8))
        XCTAssertEqual(settings.fontSize, 18)
        XCTAssertEqual(settings.softWrap, AppSettings().softWrap)
    }

    func testSettingsRoundTrip() throws {
        var settings = AppSettings()
        settings.editorTheme = .nord
        settings.previewSettings.maxWidth = 720
        settings.enableKaTeX = true

        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertEqual(decoded, settings)
    }

    // MARK: Session state

    func testSessionStateRoundTrip() throws {
        var session = SessionState()
        session.openFiles = [URL(fileURLWithPath: "/tmp/a.md"), URL(fileURLWithPath: "/tmp/b.md")]
        session.activeFileIndex = 1
        session.viewMode = .split
        session.sidebarVisible = true

        let data = try JSONEncoder().encode(session)
        let decoded = try JSONDecoder().decode(SessionState.self, from: data)
        XCTAssertEqual(decoded, session)
    }

    // MARK: Line index

    func testLineIndexNumbersAndColumns() {
        let index = LineIndex()
        let text = "first\nsecond\n\nfourth" as NSString
        index.rebuild(from: text)

        XCTAssertEqual(index.lineCount, 4)
        XCTAssertEqual(index.lineNumber(at: 0), 1)
        XCTAssertEqual(index.lineNumber(at: 6), 2)   // 's' of second
        XCTAssertEqual(index.startLocation(ofLine: 2), 6)
        XCTAssertEqual(index.startLocation(ofLine: 4), 14)

        let (line, column) = index.lineAndColumn(at: 8)
        XCTAssertEqual(line, 2)
        XCTAssertEqual(column, 3)
    }

    func testLineIndexHandlesEmojiInUTF16() {
        let index = LineIndex()
        let text = "a😀b\nsecond" as NSString // 😀 is 2 UTF-16 units
        index.rebuild(from: text)

        XCTAssertEqual(index.lineCount, 2)
        XCTAssertEqual(index.startLocation(ofLine: 2), 5)
        XCTAssertEqual(index.lineNumber(at: 5), 2)
    }

    // MARK: Completion context detection (UTF-16)

    func testWikiLinkContextDetection() {
        let text = "see [[My No" as NSString
        let context = CompletionService.detectContext(in: text, cursorLocation: text.length)

        XCTAssertEqual(context?.type, .wikiLink)
        XCTAssertEqual(context?.query, "My No")
        XCTAssertEqual(context?.range, NSRange(location: 4, length: 7))
    }

    func testClosedWikiLinkYieldsNoContext() {
        let text = "see [[Done]] after" as NSString
        XCTAssertNil(CompletionService.detectContext(in: text, cursorLocation: text.length))
    }

    func testTagContextDetectionAfterEmoji() {
        let text = "fun 😀 #pro" as NSString
        let context = CompletionService.detectContext(in: text, cursorLocation: text.length)

        XCTAssertEqual(context?.type, .tag)
        XCTAssertEqual(context?.query, "pro")
        // 😀 occupies 2 UTF-16 units: "fun " (4) + emoji (2) + " " (1) = 7.
        XCTAssertEqual(context?.range, NSRange(location: 7, length: 4))
    }

    func testHashInsideWordIsNotATag() {
        let text = "c#sharp" as NSString
        XCTAssertNil(CompletionService.detectContext(in: text, cursorLocation: text.length))
    }

    func testReplacementStrings() {
        let wiki = CompletionContext(type: .wikiLink, query: "x", range: NSRange(location: 0, length: 3))
        let item = CompletionItem(text: "Target Note", displayText: "Target Note", detail: nil, type: .wikiLink)
        XCTAssertEqual(wiki.replacement(for: item), "[[Target Note]]")

        let tag = CompletionContext(type: .tag, query: "p", range: NSRange(location: 0, length: 2))
        let tagItem = CompletionItem(text: "project", displayText: "#project", detail: nil, type: .tag)
        XCTAssertEqual(tag.replacement(for: tagItem), "#project ")
    }

    func testWikiCompletionPrefersPrefixThenRecency() {
        let old = Date(timeIntervalSince1970: 100)
        let new = Date(timeIntervalSince1970: 200)
        let notes = [
            VaultNote(path: "a/Alpha.md", title: "Alpha", modifiedAt: old),
            VaultNote(path: "b/Beta Alpha.md", title: "Beta Alpha", modifiedAt: new),
            VaultNote(path: "c/Alphabet.md", title: "Alphabet", modifiedAt: new)
        ]
        let context = CompletionContext(type: .wikiLink, query: "alpha", range: NSRange(location: 0, length: 7))
        let items = CompletionService.completions(for: context, notes: notes, tags: [])

        XCTAssertEqual(items.first?.text, "Alphabet", "prefix matches sort first, newest first within them")
        XCTAssertEqual(items.map(\.text).contains("Beta Alpha"), true)
    }
}
