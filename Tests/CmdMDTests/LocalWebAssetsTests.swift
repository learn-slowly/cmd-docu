import XCTest
@testable import CmdMD

/// hljsBlock 순수 조립 함수 단위 테스트.
/// 실제 번들 읽기(highlightJS 비-nil)는 환경의존이라 빌드+수동 확인.
final class LocalWebAssetsTests: XCTestCase {

    // MARK: - nil JS → nil 반환

    func testNilJsReturnsNil() {
        XCTAssertNil(LocalWebAssets.hljsBlock(js: nil, cssLight: nil, cssDark: nil))
    }

    func testNilJsWithCSSReturnsNil() {
        XCTAssertNil(LocalWebAssets.hljsBlock(js: nil, cssLight: "body{}", cssDark: ".dark{}"))
    }

    // MARK: - JS 래핑 확인

    func testJSIsWrappedInScriptTag() {
        let block = LocalWebAssets.hljsBlock(js: "var x=1;", cssLight: nil, cssDark: nil)
        XCTAssertNotNil(block)
        XCTAssertTrue(block!.contains("var x=1;"), "JS 내용이 포함되어야 한다")
        XCTAssertTrue(block!.contains("<script>"), "<script> 태그가 있어야 한다")
    }

    // MARK: - CSS 래핑 확인

    func testSingleCSSIsWrappedInStyleTag() {
        let block = LocalWebAssets.hljsBlock(js: "var x=1;", cssLight: "body{color:red;}", cssDark: nil)
        XCTAssertNotNil(block)
        XCTAssertTrue(block!.contains("<style>"), "단일 CSS는 <style> 태그로 감싸야 한다")
        XCTAssertTrue(block!.contains("body{color:red;}"), "CSS 내용이 포함되어야 한다")
    }

    func testLightDarkCSSUsesMediaQuery() {
        let block = LocalWebAssets.hljsBlock(js: "var x=1;", cssLight: ".light{}", cssDark: ".dark{}")
        XCTAssertNotNil(block)
        XCTAssertTrue(block!.contains("prefers-color-scheme: light"), "라이트 미디어쿼리가 있어야 한다")
        XCTAssertTrue(block!.contains("prefers-color-scheme: dark"), "다크 미디어쿼리가 있어야 한다")
        XCTAssertTrue(block!.contains(".light{}"), "라이트 CSS 내용이 포함되어야 한다")
        XCTAssertTrue(block!.contains(".dark{}"), "다크 CSS 내용이 포함되어야 한다")
    }

    // MARK: - 초기화 스크립트 포함 확인

    func testBlockContainsHljsHighlightCall() {
        let block = LocalWebAssets.hljsBlock(js: "var x=1;", cssLight: nil, cssDark: nil)
        XCTAssertNotNil(block)
        XCTAssertTrue(block!.contains("hljs.highlightElement"), "hljs 초기화 코드가 포함되어야 한다")
    }

    func testBlockSkipsMermaidClass() {
        let block = LocalWebAssets.hljsBlock(js: "var x=1;", cssLight: nil, cssDark: nil)
        XCTAssertNotNil(block)
        XCTAssertTrue(block!.contains("language-mermaid"), "mermaid 클래스 제외 로직이 포함되어야 한다")
    }

    // MARK: - nil CSS도 JS만 있으면 반환

    func testJSOnlyWithoutCSSReturnsBlock() {
        let block = LocalWebAssets.hljsBlock(js: "var hljs={};", cssLight: nil, cssDark: nil)
        XCTAssertNotNil(block, "CSS 없이 JS만 있어도 블록을 반환해야 한다")
    }
}
