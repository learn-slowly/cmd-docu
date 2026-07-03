import XCTest
@testable import CmdMD

/// 파일 연결 그룹 정의가 DocumentKind 상수와 어긋나지 않게 고정한다(이중 정의 드리프트 방지).
final class FileAssociationGroupTests: XCTestCase {
    func testGroupsMatchDocumentKindConstants() {
        let byId = Dictionary(uniqueKeysWithValues: FileTypeGroup.all.map { ($0.id, $0) })
        let hangul = Set(byId["hangul"]!.extensions)
        let office = Set(byId["office"]!.extensions)
        XCTAssertEqual(hangul.union(office), DocumentKind.officeExtensions,
                       "한글+오피스 합집합이 officeExtensions와 달라졌습니다")
        XCTAssertTrue(hangul.isDisjoint(with: office))
        XCTAssertEqual(Set(byId["markdown"]!.extensions), DocumentKind.markdownExtensions)
        XCTAssertEqual(Set(byId["pdf"]!.extensions), DocumentKind.pdfExtensions)
        XCTAssertEqual(Set(byId["image"]!.extensions), DocumentKind.imageExtensions)
        XCTAssertEqual(Set(byId["media"]!.extensions), DocumentKind.mediaExtensions)
    }

    func testNoDuplicateExtensionsAcrossGroups() {
        let all = FileTypeGroup.all.flatMap(\.extensions)
        XCTAssertEqual(all.count, Set(all).count, "그룹 간 확장자 중복")
    }

    func testGroupOrderAndRepresentative() {
        XCTAssertEqual(FileTypeGroup.all.count, 6)
        XCTAssertEqual(FileTypeGroup.all.first?.id, "hangul")
        for group in FileTypeGroup.all {
            XCTAssertFalse(group.extensions.isEmpty)
            XCTAssertEqual(group.representativeExtension, group.extensions[0])
        }
    }
}
