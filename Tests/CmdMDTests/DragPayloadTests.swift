import XCTest
import UniformTypeIdentifiers
@testable import CmdMD

/// F2: DragPayload(페이로드 규칙·직렬화·내부 판별)·DropGuard(수락 판정) 순수 헬퍼 테스트.
final class DragPayloadTests: XCTestCase {

    private func url(_ path: String) -> URL { URL(fileURLWithPath: path) }

    // MARK: - 페이로드 규칙 (Finder 관례)

    func testDraggedItemInSelectionCarriesWholeSelection() {
        let selection: Set<URL> = [url("/v/a.md"), url("/v/b.md")]
        let urls = DragPayload.urls(for: url("/v/a.md"), selection: selection)
        XCTAssertEqual(Set(urls), selection, "선택에 포함된 항목 드래그 = 선택 전체")
    }

    func testDraggedItemOutsideSelectionCarriesItselfOnly() {
        let selection: Set<URL> = [url("/v/a.md"), url("/v/b.md")]
        let urls = DragPayload.urls(for: url("/v/c.md"), selection: selection)
        XCTAssertEqual(urls, [url("/v/c.md")], "선택 밖 항목 드래그 = 그 항목만(선택 불변)")
    }

    func testPayloadNormalizesNestedSelection() {
        // 폴더와 그 하위 파일이 함께 선택된 경우 조상만 남긴다(ancestorsOnly 결합).
        let selection: Set<URL> = [url("/v/dir"), url("/v/dir/child.md")]
        let urls = DragPayload.urls(for: url("/v/dir"), selection: selection)
        XCTAssertEqual(urls, [url("/v/dir")], "중첩 선택은 조상만 — 하위 중복 이동 방지")
    }

    // MARK: - 직렬화 라운드트립

    func testEncodeDecodeRoundTrip() {
        let urls = [url("/v/한글 폴더/노트.md"), url("/v/b.pdf")]
        XCTAssertEqual(DragPayload.decode(DragPayload.encode(urls)), urls,
                       "한글 경로 포함 라운드트립")
    }

    func testDecodeGarbageReturnsEmpty() {
        XCTAssertEqual(DragPayload.decode(Data([0x00, 0x01])), [],
                       "손상 데이터는 빈 배열(크래시 없음)")
    }

    // MARK: - 내부 드래그 판별

    func testIsInternalDragDetectsCustomType() {
        let provider = DragPayload.makeProvider(for: [url("/v/a.md")], primary: url("/v/a.md"))
        XCTAssertTrue(DragPayload.isInternalDrag([provider]))
    }

    func testIsInternalDragFalseForPlainFileURL() {
        let provider = NSItemProvider(object: url("/v/a.md") as NSURL)
        XCTAssertFalse(DragPayload.isInternalDrag([provider]),
                       "Finder발 fileURL provider는 내부 드래그가 아니다")
    }

    func testMakeProviderCarriesFileURLForFinder() {
        let provider = DragPayload.makeProvider(for: [url("/v/a.md"), url("/v/b.md")],
                                                primary: url("/v/a.md"))
        XCTAssertTrue(provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
                      "아웃바운드(Finder) 복사용 fileURL 표현 병행 탑재")
    }

    func testProviderPayloadRoundTrip() {
        let urls = [url("/v/a.md"), url("/v/b.md")]
        let provider = DragPayload.makeProvider(for: urls, primary: urls[0])
        let exp = expectation(description: "load custom payload")
        provider.loadDataRepresentation(forTypeIdentifier: UTType.cmdDocuDrag.identifier) { data, error in
            XCTAssertNil(error)
            XCTAssertEqual(DragPayload.decode(data ?? Data()), urls)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2)
    }
}

/// F2: DropGuard — 자기 자신/하위 드롭 거부('/' 경계).
final class DropGuardTests: XCTestCase {

    private func url(_ path: String) -> URL { URL(fileURLWithPath: path) }

    func testRejectsDropOntoSelf() {
        XCTAssertFalse(DropGuard.canAccept(source: url("/v/dir"), destination: url("/v/dir")))
    }

    func testRejectsDropIntoOwnDescendant() {
        XCTAssertFalse(DropGuard.canAccept(source: url("/v/dir"), destination: url("/v/dir/sub")))
    }

    func testAcceptsSiblingWithSharedPrefix() {
        // '/' 경계 — /v/dir vs /v/dir2 는 하위가 아니다(형제 오감지 회귀).
        XCTAssertTrue(DropGuard.canAccept(source: url("/v/dir"), destination: url("/v/dir2")))
    }

    func testAcceptsNormalMove() {
        XCTAssertTrue(DropGuard.canAccept(source: url("/v/a.md"), destination: url("/v/dir")))
    }

    func testCanAcceptAnyEmptySourcesAllows() {
        // 외부(Finder) 드래그는 hover 시점에 소스 목록을 모름 — 허용하고 2차 방어(수행 시 필터)에 맡긴다.
        XCTAssertTrue(DropGuard.canAcceptAny(sources: [], destination: url("/v/dir")))
    }

    func testCanAcceptAnyAllInvalidRejects() {
        XCTAssertFalse(DropGuard.canAcceptAny(sources: [url("/v/dir")], destination: url("/v/dir/sub")),
                       "전부 거부 대상이면 타깃 비활성(사전 차단)")
    }
}
