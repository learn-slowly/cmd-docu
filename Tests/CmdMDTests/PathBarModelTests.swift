import XCTest
@testable import CmdMD

/// F3: PathBarModel 세그먼트 분해 테스트 — '/' 경계·루트 안/밖·홈 축약·파일 플래그.
/// 기존 SimpleBreadcrumbView의 경계 없는 hasPrefix(형제 폴더 오감지) 버그의 회귀 방지 포함.
final class PathBarModelTests: XCTestCase {

    private let home = URL(fileURLWithPath: "/Users/me")

    private func names(_ segs: [PathSegment]) -> [String] { segs.map(\.name) }

    // MARK: - 기본 분해: 홈 하위면 홈(~)부터

    func testSegmentsFromHomeForHomeRelativeTarget() {
        let segs = PathBarModel.segments(target: URL(fileURLWithPath: "/Users/me/docs/proj"),
                                         root: URL(fileURLWithPath: "/Users/me/docs"),
                                         home: home, targetIsFile: false)
        XCTAssertEqual(names(segs), ["~", "docs", "proj"])
        XCTAssertEqual(segs.map(\.isWithinRoot), [false, true, true],
                       "root(docs) 자신부터 안쪽이 isWithinRoot")
        XCTAssertEqual(segs.map(\.isFile), [false, false, false])
    }

    // MARK: - 홈 밖 target은 "/"부터

    func testSegmentsFromSlashForNonHomeTarget() {
        let segs = PathBarModel.segments(target: URL(fileURLWithPath: "/tmp/work"),
                                         root: nil, home: home, targetIsFile: false)
        XCTAssertEqual(names(segs), ["/", "tmp", "work"])
        XCTAssertEqual(segs.map(\.isWithinRoot), [false, false, false], "root nil이면 전부 루트 밖")
    }

    // MARK: - 파일 target: 마지막 세그먼트만 isFile

    func testFileTargetMarksLastSegment() {
        let segs = PathBarModel.segments(target: URL(fileURLWithPath: "/Users/me/docs/a.md"),
                                         root: URL(fileURLWithPath: "/Users/me/docs"),
                                         home: home, targetIsFile: true)
        XCTAssertEqual(segs.last?.isFile, true)
        XCTAssertEqual(segs.last?.name, "a.md")
        XCTAssertEqual(segs.dropLast().map(\.isFile), [false, false])
    }

    // MARK: - '/' 경계: 형제 폴더 오감지 회귀(a vs ab)

    func testSiblingPrefixIsNotWithinRoot() {
        let segs = PathBarModel.segments(target: URL(fileURLWithPath: "/Users/me/ab/x"),
                                         root: URL(fileURLWithPath: "/Users/me/a"),
                                         home: home, targetIsFile: false)
        XCTAssertEqual(segs.map(\.isWithinRoot), [false, false, false],
                       "'/Users/me/ab'는 root '/Users/me/a'의 하위가 아니다('/' 경계)")
    }

    // MARK: - 루트 자신 포함

    func testRootItselfIsWithinRoot() {
        let root = URL(fileURLWithPath: "/Users/me/docs")
        let segs = PathBarModel.segments(target: root, root: root, home: home, targetIsFile: false)
        XCTAssertEqual(segs.last?.isWithinRoot, true, "루트 자신도 isWithinRoot(클릭=루트 라이브러리)")
    }

    // MARK: - isWithin 헬퍼

    func testIsWithinBoundary() {
        XCTAssertTrue(PathBarModel.isWithin("/a/b", ancestor: "/a"))
        XCTAssertTrue(PathBarModel.isWithin("/a", ancestor: "/a"))
        XCTAssertFalse(PathBarModel.isWithin("/ab", ancestor: "/a"), "'/' 경계 필수")
        XCTAssertTrue(PathBarModel.isWithin("/x", ancestor: "/"), "루트 조상 특례")
    }
}
