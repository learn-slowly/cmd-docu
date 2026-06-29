import XCTest
@testable import CmdMD

final class FileTreeListingTests: XCTestCase {
    private func listable(_ name: String) -> Bool {
        AppState.isListableInFileTree(URL(fileURLWithPath: "/tmp/\(name)"))
    }

    func testMarkdownAndTextAreListed() {
        for ext in ["md", "markdown", "txt"] {
            XCTAssertTrue(listable("note.\(ext)"), "\(ext) should be listed")
        }
    }

    func testImagesAreListed() {
        for ext in ["png", "jpg", "jpeg", "heic", "webp", "gif"] {
            XCTAssertTrue(listable("pic.\(ext)"), "\(ext) should be listed")
        }
    }

    func testUppercaseImagesAreListed() {
        XCTAssertTrue(listable("PHOTO.PNG"))
        XCTAssertTrue(listable("Clip.GIF"))
    }

    func testPdfIsListed() {
        XCTAssertTrue(listable("paper.pdf"))
        XCTAssertTrue(listable("REPORT.PDF"))
    }

    func testUnsupportedFilesAreNotListed() {
        for ext in ["hwp", "docx", "xlsx", "zip"] {
            XCTAssertFalse(listable("doc.\(ext)"), "\(ext) should not be listed yet")
        }
    }
}
