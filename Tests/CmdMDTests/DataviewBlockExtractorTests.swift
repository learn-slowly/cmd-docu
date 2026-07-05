import XCTest
@testable import CmdMD

final class DataviewBlockExtractorTests: XCTestCase {

    private func placeholder(_ id: Int) -> String { "<div id=\"dv-b\(id)\">PH\(id)</div>" }

    func testExtractsSingleBlock() {
        let md = """
        # 제목

        ```dataviewjs
        dv.paragraph("hi");
        ```

        본문
        """
        let r = DataviewBlockExtractor.extract(md, placeholderHTML: placeholder)
        XCTAssertEqual(r.blocks.count, 1)
        XCTAssertEqual(r.blocks[0].id, 0)
        XCTAssertEqual(r.blocks[0].code, "dv.paragraph(\"hi\");")
        XCTAssertTrue(r.markdown.contains("<div id=\"dv-b0\">PH0</div>"))
        XCTAssertFalse(r.markdown.contains("```dataviewjs"))
        XCTAssertTrue(r.markdown.contains("본문"), "블록 밖 본문 보존")
    }

    func testMultipleBlocksGetSequentialIds() {
        let md = "```dataviewjs\na\n```\n중간\n```dataviewjs\nb\n```"
        let r = DataviewBlockExtractor.extract(md, placeholderHTML: placeholder)
        XCTAssertEqual(r.blocks.map(\.id), [0, 1])
        XCTAssertEqual(r.blocks.map(\.code), ["a", "b"])
        XCTAssertTrue(r.markdown.contains("PH0") && r.markdown.contains("PH1"))
    }

    func testIgnoresDataviewjsInsideOtherFence() {
        // 다른 펜스 안 예시 코드는 추출하면 안 된다.
        let md = "````markdown\n```dataviewjs\nx\n```\n````"
        let r = DataviewBlockExtractor.extract(md, placeholderHTML: placeholder)
        XCTAssertTrue(r.blocks.isEmpty)
        XCTAssertEqual(r.markdown, md, "변경 없음")
    }

    func testUnclosedFenceLeftAsIs() {
        let md = "```dataviewjs\ndv.paragraph(1);"
        let r = DataviewBlockExtractor.extract(md, placeholderHTML: placeholder)
        XCTAssertTrue(r.blocks.isEmpty)
        XCTAssertEqual(r.markdown, md)
    }

    func testPlainDataviewFenceNotExtracted() {
        // DQL(```dataview)은 비지원 — 손대지 않고 일반 코드블록으로 남긴다(스펙 §3).
        let md = "```dataview\nLIST\n```"
        let r = DataviewBlockExtractor.extract(md, placeholderHTML: placeholder)
        XCTAssertTrue(r.blocks.isEmpty)
        XCTAssertEqual(r.markdown, md)
    }

    func testCRLFNewlinesExtracted() {
        // 회귀(리뷰 확증): CRLF 문서에서 \r 잔존으로 펜스 매치가 전량 실패하고
        // insideOtherFence가 파일 끝까지 안 풀려 뒤 블록까지 연쇄 무동작하던 결함.
        let md = "```dataviewjs\r\na\r\n```\r\n본문\r\n```dataviewjs\r\nb\r\n```"
        let r = DataviewBlockExtractor.extract(md, placeholderHTML: placeholder)
        XCTAssertEqual(r.blocks.map(\.code), ["a", "b"])
        XCTAssertTrue(r.markdown.contains("PH0") && r.markdown.contains("PH1"))
    }
}
