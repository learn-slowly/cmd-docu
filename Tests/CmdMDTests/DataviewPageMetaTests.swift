import XCTest
@testable import CmdMD

final class DataviewPageMetaTests: XCTestCase {

    /// 실제 데일리 노트 축약 픽스처(notebox Calendar 형식).
    private let daily = """
    ---
    date: '2026-07-05'
    day: "일요일"
    tags: [daily, log]
    ---
    # 2026-07-05 일요일

    ## 🌡️ 컨디션 #daily_condition
    - 전반적: 좀 우울함
    - 식사: 아침 프로틴쉐이크

    ## 📋 할 일
    - [ ] 산책
    - [x] 상담

    ## 💭 메모 #daily_memo
    - 종일 잤다

    ```bash
    - 코드펜스 안 리스트는 무시
    ```
    """

    private func parse(_ content: String, name: String = "2026-07-05") -> DataviewPageMeta {
        DataviewPageMeta.parse(content: content, name: name, folder: "Calendar",
                               path: "Calendar/\(name).md", mtime: 1000, ctime: 500)
    }

    func testDayFromFilename() {
        XCTAssertEqual(parse(daily).day, "2026-07-05")
    }

    func testDayFallsBackToFrontmatterDate() {
        let meta = parse(daily, name: "메모없는이름")
        XCTAssertEqual(meta.day, "2026-07-05", "파일명에 날짜 없으면 frontmatter date")
    }

    func testFrontmatterScalarsAndArray() {
        let m = parse(daily)
        XCTAssertEqual(m.frontmatter["date"], .string("2026-07-05"), "따옴표 벗김")
        XCTAssertEqual(m.frontmatter["day"], .string("일요일"))
        XCTAssertEqual(m.frontmatter["tags"], .array([.string("daily"), .string("log")]))
        XCTAssertTrue(m.tags.contains("#daily"), "frontmatter tags는 # 붙여 정규화")
    }

    func testListsWithHeaderSubpathAndInlineTags() {
        let m = parse(daily)
        let condition = m.lists.filter { $0.headerSubpath.contains("컨디션") }
        XCTAssertEqual(condition.count, 2)
        XCTAssertEqual(condition[0].text, "전반적: 좀 우울함")
        XCTAssertTrue(condition[0].headerSubpath.contains("컨디션"),
                      "subpath는 헤딩 텍스트 포함 — 정확 포맷은 계약 아님, 실사용은 includes 매칭")
        // 인라인 태그는 헤딩이 아니라 항목의 것만: 컨디션 항목엔 태그 없음
        XCTAssertTrue(condition[0].tags.isEmpty)
    }

    func testTaskItems() {
        let m = parse(daily)
        let tasks = m.lists.filter { $0.task }
        XCTAssertEqual(tasks.count, 2)
        XCTAssertEqual(tasks.filter { $0.completed }.map(\.text), ["상담"])
        XCTAssertEqual(tasks.filter { !$0.completed }.map(\.text), ["산책"])
    }

    func testCodeFenceListsIgnored() {
        let m = parse(daily)
        XCTAssertFalse(m.lists.contains { $0.text.contains("코드펜스") })
    }

    func testNoFrontmatterOK() {
        let m = parse("# 그냥 노트\n- 항목", name: "노트")
        XCTAssertNil(m.day)
        XCTAssertTrue(m.frontmatter.isEmpty)
        XCTAssertEqual(m.lists.count, 1)
    }
}
