import XCTest
@testable import CmdMD

final class DocumentKindTests: XCTestCase {
    private func kind(_ name: String) -> DocumentKind {
        DocumentKind(from: URL(fileURLWithPath: "/tmp/\(name)"))
    }

    func testImageExtensionsMapToImage() {
        for ext in ["png", "jpg", "jpeg", "heic", "webp", "gif"] {
            XCTAssertEqual(kind("file.\(ext)"), .image, "\(ext) should be image")
        }
    }

    func testUppercaseAndMixedCaseMapToImage() {
        XCTAssertEqual(kind("PHOTO.PNG"), .image)
        XCTAssertEqual(kind("Pic.Jpg"), .image)
    }

    func testMarkdownAndTextMapToMarkdown() {
        for ext in ["md", "markdown", "txt"] {
            XCTAssertEqual(kind("note.\(ext)"), .markdown, "\(ext) should be markdown")
        }
    }

    func testUnknownAndNoExtensionFallBackToMarkdown() {
        XCTAssertEqual(kind("data.xyz"), .markdown)
        XCTAssertEqual(kind("README"), .markdown)
    }

    func testImageExtensionsSetMatchesMapping() {
        for ext in DocumentKind.imageExtensions {
            XCTAssertEqual(kind("a.\(ext)"), .image)
        }
    }

    func testPdfMapsToPdf() {
        XCTAssertEqual(kind("doc.pdf"), .pdf)
        XCTAssertEqual(kind("REPORT.PDF"), .pdf)
        XCTAssertEqual(kind("Paper.Pdf"), .pdf)
    }

    func testPdfExtensionsSetMatchesMapping() {
        for ext in DocumentKind.pdfExtensions {
            XCTAssertEqual(kind("a.\(ext)"), .pdf)
        }
    }
}
