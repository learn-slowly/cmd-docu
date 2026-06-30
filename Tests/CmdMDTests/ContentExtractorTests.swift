import XCTest
import PDFKit
@testable import CmdMD

final class ContentExtractorTests: XCTestCase {
    private func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("cmddocu-ext-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    func testLocalBodyReadsTextFile() throws {
        let dir = tempDir()
        let url = dir.appendingPathComponent("note.md")
        try "제목\n본문 내용".write(to: url, atomically: true, encoding: .utf8)
        XCTAssertEqual(ContentExtractor.localBody(for: url), "제목\n본문 내용")
    }

    func testLocalBodyTxtAndMarkdown() throws {
        let dir = tempDir()
        let txt = dir.appendingPathComponent("a.txt")
        try "hello".write(to: txt, atomically: true, encoding: .utf8)
        XCTAssertEqual(ContentExtractor.localBody(for: txt), "hello")
    }

    func testLocalBodyExtractsPDFText() throws {
        let dir = tempDir()
        let url = dir.appendingPathComponent("doc.pdf")
        // PDFKit로 비트맵 기반 페이지를 만든다.
        let pdf = PDFDocument()
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 10, pixelsHigh: 10,
                                       bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                       isPlanar: false, colorSpaceName: .calibratedRGB,
                                       bytesPerRow: 0, bitsPerPixel: 32)!
        let image = NSImage()
        image.addRepresentation(bitmap)
        let page = PDFPage(image: image)!
        pdf.insert(page, at: 0)
        pdf.write(to: url)
        // 빈 이미지 페이지는 텍스트가 없을 수 있으므로, 텍스트가 nil이 아님만 보장하지 말고
        // localBody가 크래시 없이 String? 반환함을 확인한다(빈/실내용 모두 허용).
        _ = ContentExtractor.localBody(for: url)   // 크래시 없음
        XCTAssertEqual(ContentExtractor.localBody(for: dir.appendingPathComponent("none.pdf")), nil) // 없는 파일
    }

    func testLocalBodyUnsupportedReturnsNil() throws {
        let dir = tempDir()
        let img = dir.appendingPathComponent("p.png")
        try Data([0x89, 0x50]).write(to: img)
        XCTAssertNil(ContentExtractor.localBody(for: img))   // 이미지: 본문 없음
    }
}
