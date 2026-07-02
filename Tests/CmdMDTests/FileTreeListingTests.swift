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

    func testOfficeFilesAreListed() {
        for ext in ["hwp", "hwpx", "docx", "xlsx"] {
            XCTAssertTrue(listable("doc.\(ext)"), "\(ext) should be listed")
        }
    }

    func testUnsupportedFilesAreNotListed() {
        for ext in ["zip", "avi", "exe"] {
            XCTAssertFalse(listable("doc.\(ext)"), "\(ext) should not be listed")
        }
    }
}
