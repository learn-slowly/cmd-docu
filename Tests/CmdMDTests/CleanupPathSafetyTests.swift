import XCTest
@testable import CmdMD

final class CleanupPathSafetyTests: XCTestCase {
    func testDestinationWithinRoot() {
        let root = URL(fileURLWithPath: "/Users/x/Downloads")
        let bucket = CleanupBucket(id: "문서", name: "문서", hint: "", relativePath: "문서")
        let dest = CleanupPlanner.destinationDir(root: root, bucket: bucket)
        XCTAssertEqual(dest?.path, "/Users/x/Downloads/문서")
    }

    func testNestedRelativePathWithinRoot() {
        let root = URL(fileURLWithPath: "/v")
        let bucket = CleanupBucket(id: "p", name: "p", hint: "", relativePath: "10000_Projects/Living")
        let dest = CleanupPlanner.destinationDir(root: root, bucket: bucket)
        XCTAssertEqual(dest?.path, "/v/10000_Projects/Living")
    }

    func testEscapeAttemptReturnsNil() {
        let root = URL(fileURLWithPath: "/Users/x/Downloads")
        let bucket = CleanupBucket(id: "e", name: "e", hint: "", relativePath: "../../etc")
        XCTAssertNil(CleanupPlanner.destinationDir(root: root, bucket: bucket))
    }
}
