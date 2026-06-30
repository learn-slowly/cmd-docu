import XCTest
@testable import CmdMD

final class ThumbnailServiceTests: XCTestCase {
    private let u = URL(fileURLWithPath: "/a/b/photo.png")

    func testCacheKeyStableForSameInputs() {
        let k1 = ThumbnailService.cacheKey(url: u, pointSize: 64, scale: 2, mtime: 100)
        let k2 = ThumbnailService.cacheKey(url: u, pointSize: 64, scale: 2, mtime: 100)
        XCTAssertEqual(k1, k2)
    }

    func testCacheKeyChangesWithMtime() {
        let k1 = ThumbnailService.cacheKey(url: u, pointSize: 64, scale: 2, mtime: 100)
        let k2 = ThumbnailService.cacheKey(url: u, pointSize: 64, scale: 2, mtime: 200)
        XCTAssertNotEqual(k1, k2)
    }

    func testCacheKeyChangesWithSizeScaleAndURL() {
        let base = ThumbnailService.cacheKey(url: u, pointSize: 64, scale: 2, mtime: 100)
        XCTAssertNotEqual(base, ThumbnailService.cacheKey(url: u, pointSize: 128, scale: 2, mtime: 100))
        XCTAssertNotEqual(base, ThumbnailService.cacheKey(url: u, pointSize: 64, scale: 1, mtime: 100))
        XCTAssertNotEqual(base, ThumbnailService.cacheKey(url: URL(fileURLWithPath: "/a/b/other.png"), pointSize: 64, scale: 2, mtime: 100))
    }
}
