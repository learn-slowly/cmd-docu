import XCTest
@testable import CmdMD

final class AppIndexSearchTests: XCTestCase {
    func testNormalizedDropsDuplicate() {
        let out = AppState.normalizedIndexFolders(["/a", "/b"], adding: "/a")
        XCTAssertEqual(out, ["/a", "/b"])
    }

    func testNormalizedDropsChildOfExisting() {
        // 이미 /a가 등록돼 있으면 그 하위 /a/sub는 추가하지 않는다(중복 인덱싱 방지).
        let out = AppState.normalizedIndexFolders(["/a"], adding: "/a/sub")
        XCTAssertEqual(out, ["/a"])
    }

    func testNormalizedReplacesParentWhenAddingAncestor() {
        // 새로 추가하는 /a가 기존 /a/sub의 상위면, 하위를 흡수해 /a만 남긴다.
        let out = AppState.normalizedIndexFolders(["/a/sub", "/b"], adding: "/a")
        XCTAssertEqual(Set(out), Set(["/a", "/b"]))
    }

    func testNormalizedAppendsUnrelated() {
        let out = AppState.normalizedIndexFolders(["/a"], adding: "/b")
        XCTAssertEqual(out, ["/a", "/b"])
    }

    func testNormalizedPreservesPrivatePrefixedCanonicalPath() {
        // canonical 경로(/private/var/...)를 그대로 저장해야 한다. standardizingPath가 /private를 떼면 안 된다.
        let out = AppState.normalizedIndexFolders([], adding: "/private/var/folders/abc/Docs")
        XCTAssertEqual(out, ["/private/var/folders/abc/Docs"])
    }

    @MainActor
    func testIndexSearchStateDefaults() {
        let app = AppState()
        XCTAssertFalse(app.showIndexSearch)
        XCTAssertTrue(app.indexSearchResults.isEmpty)
        XCTAssertFalse(app.indexInProgress)
    }
}
