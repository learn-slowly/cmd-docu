import XCTest
import AppKit
import PDFKit
@testable import CmdMD

final class FileInfoServiceTests: XCTestCase {

    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("fileinfo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        dir = nil
        super.tearDown()
    }

    // MARK: 픽스처

    /// widthxheight 픽셀 PNG를 실제로 만든다(헤더만 읽는 해상도 검증용).
    private func makePNG(_ name: String, width: Int, height: Int) throws -> URL {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
                                      bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                      isPlanar: false, colorSpaceName: .calibratedRGB,
                                      bytesPerRow: 0, bitsPerPixel: 32)!
        let data = bitmap.representation(using: .png, properties: [:])!
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private func makePDF(_ name: String, pages: Int) throws -> URL {
        let pdf = PDFDocument()
        for index in 0..<pages {
            let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 10, pixelsHigh: 10,
                                          bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                          isPlanar: false, colorSpaceName: .calibratedRGB,
                                          bytesPerRow: 0, bitsPerPixel: 32)!
            let image = NSImage()
            image.addRepresentation(bitmap)
            pdf.insert(PDFPage(image: image)!, at: index)
        }
        let url = dir.appendingPathComponent(name)
        XCTAssertTrue(pdf.write(to: url))
        return url
    }

    /// 1초짜리 8kHz 8-bit 모노 PCM WAV(MediaMetadataServiceTests와 동일).
    private func makeWAV(_ name: String) throws -> URL {
        let sampleRate: UInt32 = 8000
        let dataSize: UInt32 = 8000
        var data = Data()
        func append(_ s: String) { data.append(s.data(using: .ascii)!) }
        func append32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        func append16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { data.append(contentsOf: $0) } }
        append("RIFF"); append32(36 + dataSize); append("WAVE")
        append("fmt "); append32(16); append16(1); append16(1)
        append32(sampleRate); append32(sampleRate)
        append16(1); append16(8)
        append("data"); append32(dataSize)
        data.append(Data(repeating: 128, count: Int(dataSize)))
        let url = dir.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    // MARK: loadBasic

    func testLoadBasicFile() throws {
        let url = dir.appendingPathComponent("문서.md")
        try Data("12345".utf8).write(to: url)
        let info = FileInfoService.loadBasic(url: url)
        XCTAssertEqual(info.name, "문서.md")
        XCTAssertFalse(info.isDirectory)
        XCTAssertEqual(info.sizeBytes, 5)
        XCTAssertEqual(info.locationPath, dir.path)
        XCTAssertNotNil(info.createdAt)
        XCTAssertNotNil(info.modifiedAt)
    }

    func testLoadBasicFolder() throws {
        let folder = dir.appendingPathComponent("하위")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let info = FileInfoService.loadBasic(url: folder)
        XCTAssertTrue(info.isDirectory)
        XCTAssertNil(info.sizeBytes)          // 폴더 크기는 별도 비동기 계산
        XCTAssertEqual(info.kindLabel, "폴더")
    }

    // MARK: kindLabel (순수)

    func testKindLabels() {
        func label(_ name: String) -> String {
            FileInfoService.kindLabel(for: URL(fileURLWithPath: "/tmp/\(name)"), isDirectory: false)
        }
        XCTAssertEqual(label("a.md"), "MD 문서")
        XCTAssertEqual(label("a.png"), "PNG 이미지")
        XCTAssertEqual(label("a.pdf"), "PDF 문서")
        XCTAssertEqual(label("a.hwp"), "HWP 오피스 문서")
        XCTAssertEqual(label("a.mp3"), "MP3 오디오")
        XCTAssertEqual(label("a.mov"), "MOV 동영상")
        XCTAssertEqual(FileInfoService.kindLabel(for: URL(fileURLWithPath: "/tmp/폴더"), isDirectory: true), "폴더")
    }

    // MARK: loadDetail (종류별 한 줄)

    func testDetailImageResolution() async throws {
        let url = try makePNG("img.png", width: 10, height: 8)
        let detail = await FileInfoService.loadDetail(url: url, isDirectory: false)
        XCTAssertEqual(detail, "10 × 8")
    }

    func testDetailPDFPageCount() async throws {
        let url = try makePDF("doc.pdf", pages: 2)
        let detail = await FileInfoService.loadDetail(url: url, isDirectory: false)
        XCTAssertEqual(detail, "2페이지")
    }

    func testDetailMediaDuration() async throws {
        let url = try makeWAV("clip.wav")
        let detail = await FileInfoService.loadDetail(url: url, isDirectory: false)
        XCTAssertEqual(detail, "길이 0:01")
    }

    func testDetailFolderItemCount() async throws {
        let folder = dir.appendingPathComponent("셈")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data().write(to: folder.appendingPathComponent("a.md"))
        try Data().write(to: folder.appendingPathComponent("b.md"))
        let detail = await FileInfoService.loadDetail(url: folder, isDirectory: true)
        XCTAssertEqual(detail, "항목 2개")
    }

    func testDetailMarkdownIsNil() async throws {
        let url = dir.appendingPathComponent("plain.md")
        try Data("x".utf8).write(to: url)
        let detail = await FileInfoService.loadDetail(url: url, isDirectory: false)
        XCTAssertNil(detail)
    }

    // MARK: computeFolderSize

    func testComputeFolderSizeSumsNestedFiles() async throws {
        let root = dir.appendingPathComponent("루트")
        let nested = root.appendingPathComponent("중첩")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data(repeating: 0, count: 100).write(to: root.appendingPathComponent("a.bin"))
        try Data(repeating: 0, count: 50).write(to: nested.appendingPathComponent("b.bin"))
        let total = try await FileInfoService.computeFolderSize(url: root)
        XCTAssertEqual(total, 150)
    }

    func testComputeFolderSizeCancellation() async throws {
        // 파일을 넉넉히 만들어 계산이 취소보다 오래 걸리게 한다(취소가 늦으면 완료돼버려 실패).
        let root = dir.appendingPathComponent("큰폴더")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for index in 0..<500 {
            try Data(repeating: 0, count: 10).write(to: root.appendingPathComponent("f\(index).bin"))
        }
        let task = Task { try await FileInfoService.computeFolderSize(url: root) }
        task.cancel()
        do {
            _ = try await task.value
            XCTFail("취소된 태스크가 값을 반환했습니다")
        } catch is CancellationError {
            // 기대 경로
        }
    }

    // MARK: formatSize

    func testFormatSize() {
        // ByteCountFormatter 출력은 로케일 의존 — 형식이 아니라 존재만 검증한다.
        XCTAssertFalse(FileInfoService.formatSize(0).isEmpty)
        XCTAssertFalse(FileInfoService.formatSize(1_500).isEmpty)
    }
}
