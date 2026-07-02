import XCTest
@testable import CmdMD

/// DocumentKind.media — 미디어(음악·동영상) 확장자 매핑.
final class DocumentKindMediaTests: XCTestCase {

    func testMediaExtensionsMapToMedia() {
        // AVFoundation 네이티브 재생 확장자 전부 + 대소문자 무시.
        for ext in ["mp3", "m4a", "aac", "wav", "aiff", "flac",
                    "mp4", "mov", "m4v", "MP3", "MOV", "Flac"] {
            let url = URL(fileURLWithPath: "/tmp/노래.\(ext)")
            XCTAssertEqual(DocumentKind(from: url), .media, "확장자 \(ext)는 media여야 한다")
        }
    }

    func testIsVideoSplitsAudioAndVideo() {
        XCTAssertTrue(DocumentKind.isVideo(URL(fileURLWithPath: "/tmp/a.mp4")))
        XCTAssertTrue(DocumentKind.isVideo(URL(fileURLWithPath: "/tmp/a.MOV")))
        XCTAssertTrue(DocumentKind.isVideo(URL(fileURLWithPath: "/tmp/a.m4v")))
        XCTAssertFalse(DocumentKind.isVideo(URL(fileURLWithPath: "/tmp/a.mp3")))
        XCTAssertFalse(DocumentKind.isVideo(URL(fileURLWithPath: "/tmp/a.wav")))
    }

    func testMediaExtensionsIsUnionOfAudioAndVideo() {
        XCTAssertEqual(DocumentKind.mediaExtensions,
                       DocumentKind.audioExtensions.union(DocumentKind.videoExtensions))
    }

    func testExistingKindsUnchanged() {
        XCTAssertEqual(DocumentKind(from: URL(fileURLWithPath: "/tmp/a.png")), .image)
        XCTAssertEqual(DocumentKind(from: URL(fileURLWithPath: "/tmp/a.pdf")), .pdf)
        XCTAssertEqual(DocumentKind(from: URL(fileURLWithPath: "/tmp/a.hwp")), .office)
        XCTAssertEqual(DocumentKind(from: URL(fileURLWithPath: "/tmp/a.md")), .markdown)
        XCTAssertEqual(DocumentKind(from: URL(fileURLWithPath: "/tmp/제목없음")), .markdown)
    }
}
