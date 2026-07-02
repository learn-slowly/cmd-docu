import XCTest
@testable import CmdMD

final class RendererFeatureTests: XCTestCase {
    private func render(_ markdown: String, configure: (inout MarkdownRenderOptions) -> Void = { _ in }) -> String {
        var options = MarkdownRenderOptions()
        configure(&options)
        return MarkdownRenderer().renderToHTML(markdown: markdown, options: options)
    }

    // MARK: Callouts

    func testCalloutContentRendersMarkdown() {
        let html = render("> [!note] Title\n> Some **bold** text")
        XCTAssertTrue(html.contains("callout-note"))
        XCTAssertTrue(html.contains("<strong>bold</strong>"), "callout bodies must render markdown, not escaped text")
    }

    func testWikiLinkInsideCalloutStaysALink() {
        let html = render("> [!tip]\n> See [[Other Note]]")
        XCTAssertTrue(html.contains("class=\"wiki-link\""), "wiki links inside callouts were previously escaped to literal text")
        XCTAssertFalse(html.contains("&lt;a href"), "anchor markup must not be double-escaped")
    }

    func testCalloutsDisabledLeavesBlockquote() {
        let html = render("> [!note] Title\n> body", configure: { $0.enableCallouts = false })
        XCTAssertFalse(html.contains("class=\"callout"))
    }

    // MARK: Inline extensions

    func testStrikethroughRendersDelTag() {
        let html = render("some ~~gone~~ text")
        XCTAssertTrue(html.contains("<del>gone</del>"))
    }

    func testHighlightSyntaxRendersMark() {
        let html = render("this is ==important== stuff")
        XCTAssertTrue(html.contains("<mark>important</mark>"))
    }

    func testHighlightInsideCodeIsUntouched() {
        let html = render("`a ==b== c`")
        XCTAssertFalse(html.contains("<mark>"))
    }

    // MARK: Wiki links / tags toggle

    func testWikiLinksDisabledRendersPlainText() {
        let html = render("[[Note]]", configure: { $0.enableWikiLinks = false })
        // The .wiki-link CSS class definition is always present in the style
        // block; what matters is that no anchor was generated.
        XCTAssertFalse(html.contains("class=\"wiki-link\""))
        XCTAssertFalse(html.contains("cmdmd://open"))
    }

    // MARK: Math

    func testKaTeXMasksInlineMathFromEmphasisParsing() {
        let html = render("Euler: $a_b + c_d$", configure: { $0.enableKaTeX = true })
        XCTAssertTrue(html.contains("$a_b + c_d$"), "math must survive as literal text for in-DOM rendering")
        XCTAssertFalse(html.contains("<em>"), "underscores inside math must not become emphasis")
        XCTAssertTrue(html.contains("katex"), "KaTeX assets must be included when enabled")
    }

    func testKaTeXDisabledHasNoKatexAssets() {
        let html = render("$a_b$")
        XCTAssertFalse(html.contains("katex"))
    }

    // 인라인(번들)·CDN 폴백 양쪽 모두에 존재하는 auto-render 초기화 마커로 검증.
    func testKaTeXAutoRenderIncludedWhenEnabled() {
        let html = render("$a$", configure: { $0.enableKaTeX = true })
        XCTAssertTrue(html.contains("renderMathInElement"), "KaTeX auto-render 초기화가 포함되어야 한다(인라인·CDN 공통)")
    }

    func testKaTeXAutoRenderAbsentWhenDisabled() {
        let html = render("$a$")
        XCTAssertFalse(html.contains("renderMathInElement"))
    }

    // MARK: Code highlighting

    func testHighlightJSIncludedForCodeBlocks() {
        let html = render("```swift\nlet x = 1\n```")
        // 인라인(번들)·CDN 폴백 양쪽 모두에 존재하는 초기화 스크립트로 검증.
        XCTAssertTrue(html.contains("hljs.highlightElement"))
    }

    func testHighlightJSAbsentWhenDisabled() {
        let html = render("```swift\nlet x = 1\n```", configure: { $0.enableCodeHighlight = false })
        XCTAssertFalse(html.contains("hljs.highlightElement"))
    }

    func testHighlightJSAbsentWithoutCode() {
        let html = render("just text")
        XCTAssertFalse(html.contains("hljs.highlightElement"))
    }

    // MARK: Mermaid toggle

    func testMermaidDisabledRendersPlainCodeBlock() {
        let html = render("```mermaid\ngraph TD;\n```", configure: { $0.enableMermaid = false })
        XCTAssertFalse(html.contains("class=\"mermaid\""))
        XCTAssertTrue(html.contains("language-mermaid"))
    }

    func testMermaidEnabledRendersDiagramContainer() {
        let html = render("```mermaid\ngraph TD;\n```")
        XCTAssertTrue(html.contains("class=\"mermaid\""))
    }

    // initialize 스니펫은 인라인·CDN 폴백 양쪽에서 동일하게 붙는 공통 마커.
    func testMermaidInitializeIncludedForDiagram() {
        let html = render("```mermaid\ngraph TD;\n```")
        XCTAssertTrue(html.contains("mermaid.initialize"), "mermaid 초기화 스니펫이 포함되어야 한다(인라인·CDN 공통)")
    }

    func testMermaidInitializeAbsentWithoutDiagram() {
        let html = render("just text")
        XCTAssertFalse(html.contains("mermaid.initialize"))
    }

    // MARK: Heading slugs

    func testDuplicateHeadingSlugsAreDeduplicated() {
        let html = render("# Intro\n\ntext\n\n# Intro")
        XCTAssertTrue(html.contains("id=\"intro\""))
        XCTAssertTrue(html.contains("id=\"intro-1\""))
    }

    func testTOCSlugsMatchRendererIds() {
        let markdown = "# Intro\n\n## Setup\n\n# Intro\n\n```\n# not a heading\n```\n\n## Setup"
        let headings = TOCBuilder.extractHeadings(from: markdown)
        let html = render(markdown)

        XCTAssertEqual(headings.map(\.slug), ["intro", "setup", "intro-1", "setup-1"])
        for heading in headings {
            XCTAssertTrue(html.contains("id=\"\(heading.slug)\""), "renderer must emit anchor for TOC slug \(heading.slug)")
        }
    }

    func testKoreanHeadingGetsUsableSlug() {
        let headings = TOCBuilder.extractHeadings(from: "# 한국어 제목")
        XCTAssertEqual(headings.first?.slug, "한국어-제목")
    }

    // MARK: Settings CSS

    func testPreviewSettingsAreInjected() {
        let html = render("hello", configure: {
            $0.preview.fontSize = 19
            $0.preview.maxWidth = 750
            $0.preview.customCSS = ".x { color: red; }"
        })
        XCTAssertTrue(html.contains("font-size: 19px"))
        XCTAssertTrue(html.contains("max-width: 750px"))
        XCTAssertTrue(html.contains(".x { color: red; }"))
    }

    func testLegacyHeadingColorDefaultIsIgnored() {
        var settings = PreviewSettings()
        settings.headingColor = "#333333"
        XCTAssertNil(settings.effectiveHeadingColor)

        settings.headingColor = "#ff0000"
        XCTAssertEqual(settings.effectiveHeadingColor, "#ff0000")
    }

    // MARK: Interactive tasks

    func testTaskCheckboxCarriesSourceLine() {
        let html = render("intro\n\n- [ ] first\n- [x] second")
        XCTAssertTrue(html.contains("data-line=\"3\""))
        XCTAssertTrue(html.contains("data-line=\"4\""))
    }

    func testExportTasksAreDisabled() {
        let html = render("- [ ] item", configure: { $0.interactiveTasks = false })
        XCTAssertFalse(html.contains("data-line"))
        XCTAssertTrue(html.contains("disabled"))
    }

    func testTaskScanSkipsFencesAndCallouts() {
        let markdown = """
        - [ ] real one
        ```
        - [ ] inside fence
        ```
        > [!todo]
        > - [ ] inside callout
        - [ ] real two
        """
        XCTAssertEqual(TaskLineQueue.scan(markdown), [1, 7])
    }
}
