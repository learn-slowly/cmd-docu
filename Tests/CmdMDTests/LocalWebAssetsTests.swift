import XCTest
@testable import CmdMD

/// hljsBlock 순수 조립 함수 단위 테스트.
/// 실제 번들 읽기(highlightJS 비-nil)는 환경의존이라 빌드+수동 확인.
final class LocalWebAssetsTests: XCTestCase {

    // MARK: - nil 인자 → nil 반환 (CDN 폴백 트리거)

    func testNilJsReturnsNil() {
        XCTAssertNil(LocalWebAssets.hljsBlock(js: nil, cssLight: nil, cssDark: nil))
    }

    func testNilJsWithCSSReturnsNil() {
        XCTAssertNil(LocalWebAssets.hljsBlock(js: nil, cssLight: "body{}", cssDark: ".dark{}"))
    }

    /// cssDark가 nil이면 CDN 폴백 — 부분 입력도 nil.
    func testPartialCSSMissingDarkReturnsNil() {
        XCTAssertNil(
            LocalWebAssets.hljsBlock(js: "var x=1;", cssLight: "body{color:red;}", cssDark: nil),
            "cssDark 없이는 nil을 반환해야 한다(CDN 폴백 트리거)"
        )
    }

    /// JS만 있고 CSS가 없으면 nil — 이전 동작(JS만 있어도 반환)은 더 이상 지원하지 않는다.
    func testJSOnlyWithoutCSSReturnsNil() {
        XCTAssertNil(
            LocalWebAssets.hljsBlock(js: "var hljs={};", cssLight: nil, cssDark: nil),
            "CSS 없이 JS만 있으면 nil을 반환해야 한다(CDN 폴백)"
        )
    }

    // MARK: - 셋 모두 있을 때 블록 조립 확인

    func testJSIsWrappedInScriptTag() {
        let block = LocalWebAssets.hljsBlock(js: "var x=1;", cssLight: ".light{}", cssDark: ".dark{}")
        XCTAssertNotNil(block)
        XCTAssertTrue(block!.contains("var x=1;"), "JS 내용이 포함되어야 한다")
        XCTAssertTrue(block!.contains("<script>"), "<script> 태그가 있어야 한다")
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
        let block = LocalWebAssets.hljsBlock(js: "var x=1;", cssLight: ".light{}", cssDark: ".dark{}")
        XCTAssertNotNil(block)
        XCTAssertTrue(block!.contains("hljs.highlightElement"), "hljs 초기화 코드가 포함되어야 한다")
    }

    func testBlockSkipsMermaidClass() {
        let block = LocalWebAssets.hljsBlock(js: "var x=1;", cssLight: ".light{}", cssDark: ".dark{}")
        XCTAssertNotNil(block)
        XCTAssertTrue(block!.contains("language-mermaid"), "mermaid 클래스 제외 로직이 포함되어야 한다")
    }
}
