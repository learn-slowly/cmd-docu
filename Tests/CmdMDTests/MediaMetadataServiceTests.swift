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
