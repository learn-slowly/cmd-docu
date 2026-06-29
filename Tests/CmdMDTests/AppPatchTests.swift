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

    func testPatchedOutputURLHandlesEmptyExtension() {
        let out = AppState.patchedOutputURL(for: URL(fileURLWithPath: "/tmp/cmddocu-test-nonexistent/노확장자"))
        XCTAssertEqual(out.lastPathComponent, "노확장자 (편집)")
        XCTAssertEqual(out.pathExtension, "")
    }

    @MainActor
    func testBeginOfficeEditCopiesMarkdownIntoBuffer() {
        let app = AppState()
        let tabID = UUID()
        app.officeStates[tabID] = .loaded(KordocResult(success: true, fileType: "hwpx",
                                                       markdown: "# 제목\n본문", blocks: nil, outline: nil))
        app.beginOfficeEdit(tabID: tabID)
        XCTAssertTrue(app.officeEditing.contains(tabID))
        XCTAssertEqual(app.officeEditBuffers[tabID], "# 제목\n본문")
    }

    @MainActor
    func testBeginOfficeEditDoesNothingWithoutLoadedState() {
        let app = AppState()
        let tabID = UUID()
        app.beginOfficeEdit(tabID: tabID)
        XCTAssertFalse(app.officeEditing.contains(tabID))
        XCTAssertNil(app.officeEditBuffers[tabID])
    }

    @MainActor
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
}
