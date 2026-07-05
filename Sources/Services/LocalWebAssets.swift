import Foundation

/// Highlightr 번들에 동봉된 highlight.js 자산을 앱 번들에서 1회 로드해 캐시한다.
/// WebView baseURL을 변경하지 않고 `<script>`/`<style>`로 인라인 주입하기 위해 사용한다.
/// (baseURL을 번들 디렉터리로 바꾸면 기존 CORS·file:// 이슈가 재현될 수 있어 인라인 방식 유지.)
enum LocalWebAssets {

    // MARK: - 번들 탐색 (SyntaxHighlighter 동일 로직)

    /// Highlightr_Highlightr.bundle 위치를 반환한다.
    /// SyntaxHighlighter.highlightrResourceBundleIsPresent()와 탐색 경로를 동일하게 유지한다.
    private static func findHighlightrBundleURL() -> URL? {
        let bundleName = "Highlightr_Highlightr.bundle"
        var roots: [URL] = []
        if let resources = Bundle.main.resourceURL { roots.append(resources) }
        roots.append(Bundle.main.bundleURL)
        if let exeDir = Bundle.main.executableURL?.deletingLastPathComponent() {
            roots.append(exeDir)
        }
        let fm = FileManager.default
        for root in roots {
            let candidate = root.appendingPathComponent(bundleName)
            if fm.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    /// SPM 리소스 번들(CmdMD_CmdMD.bundle) 위치를 반환한다.
    /// `Bundle.module`은 패키지된 .app에서 trap 이력이 있어 회피하고,
    /// findHighlightrBundleURL과 동일한 3-루트 탐색에 테스트 실행용 4번째 루트를 더한다.
    private static func findAppResourceBundleURL() -> URL? {
        let bundleName = "CmdMD_CmdMD.bundle"
        var roots: [URL] = []
        if let resources = Bundle.main.resourceURL { roots.append(resources) }
        roots.append(Bundle.main.bundleURL)
        if let exeDir = Bundle.main.executableURL?.deletingLastPathComponent() {
            roots.append(exeDir)
        }
        // `swift test`(xctest CLI) 실행 시 Bundle.main은 시스템 xctest 실행파일이라 위 3-루트가 전부 빗나간다.
        // 테스트 바이너리(.xctest)와 리소스 번들은 항상 같은 빌드 산출물 디렉터리에 나란히 놓이므로,
        // 로드된 번들 중 .xctest를 찾아 그 부모 디렉터리를 추가 후보로 삼는다(프로덕션 앱 동작엔 영향 없음).
        if let xctestBundle = Bundle.allBundles.first(where: { $0.bundlePath.hasSuffix(".xctest") }) {
            roots.append(xctestBundle.bundleURL.deletingLastPathComponent())
        }
        let fm = FileManager.default
        for root in roots {
            let candidate = root.appendingPathComponent(bundleName)
            if fm.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    /// SPM 리소스 번들 내부 `web/…` 하위 파일을 UTF-8로 읽는다. 번들·파일 없으면 nil.
    private static func readWebResource(_ relativePath: String) -> String? {
        guard let base = findAppResourceBundleURL() else { return nil }
        let url = base.appendingPathComponent("web").appendingPathComponent(relativePath)
        return try? String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - 자산 캐시 (lazy static, 앱 수명 동안 1회 로드)

    /// highlight.min.js 전체 내용. 번들 없으면 nil(CDN 폴백 트리거).
    static let highlightJS: String? = {
        guard let base = findHighlightrBundleURL() else { return nil }
        return try? String(contentsOf: base.appendingPathComponent("highlight.min.js"),
                           encoding: .utf8)
    }()

    /// github 라이트 테마 CSS(github.min.css). 번들 없으면 nil.
    static let highlightCSSLight: String? = {
        guard let base = findHighlightrBundleURL() else { return nil }
        return try? String(contentsOf: base.appendingPathComponent("github.min.css"),
                           encoding: .utf8)
    }()

    /// github 다크 테마 CSS(github-dark.min.css). 번들 없으면 nil.
    static let highlightCSSDark: String? = {
        guard let base = findHighlightrBundleURL() else { return nil }
        return try? String(contentsOf: base.appendingPathComponent("github-dark.min.css"),
                           encoding: .utf8)
    }()

    // MARK: - KaTeX·Mermaid 자산 캐시 (SPM 리소스 번들, lazy static)

    /// katex.min.js. 번들 없으면 nil(CDN 폴백 트리거).
    static let katexJS: String? = readWebResource("katex/katex.min.js")

    /// contrib/auto-render.min.js. 번들 없으면 nil.
    static let katexAutoRenderJS: String? = readWebResource("katex/auto-render.min.js")

    /// contrib/mhchem.min.js. 번들 없으면 nil.
    static let katexMhchemJS: String? = readWebResource("katex/mhchem.min.js")

    /// katex.inline.min.css — 폰트를 woff2 data URI로 인라인한 전처리판. 번들 없으면 nil.
    static let katexCSS: String? = readWebResource("katex/katex.inline.min.css")

    /// mermaid.min.js(UMD). 번들 없으면 nil.
    static let mermaidJS: String? = readWebResource("mermaid/mermaid.min.js")

    /// dataviewjs용 luxon(로컬 동봉) — 스펙 §5.
    static let luxonJS: String? = readWebResource("luxon/luxon.min.js")

    /// dv API 서브셋 shim — 스펙 §3 범위, JSContext 전용.
    static let dvShimJS: String? = readWebResource("dataview/dv-shim.js")

    // MARK: - 순수 조립 함수 (테스트 가능, 입력=콘텐츠)

    /// JS·CSS 콘텐츠를 인라인 `<script>`/`<style>` 문자열로 조립한다.
    ///
    /// - Parameters:
    ///   - js: highlight.min.js 문자열.
    ///   - cssLight: 라이트 테마 CSS.
    ///   - cssDark: 다크 테마 CSS.
    /// - Returns: HTML 인라인 블록 문자열. **셋 중 하나라도 nil이면 nil 반환**(CDN 폴백 트리거).
    static func hljsBlock(js: String?, cssLight: String?, cssDark: String?) -> String? {
        // js·cssLight·cssDark 모두 있어야 로컬 인라인 주입; 하나라도 없으면 nil → CDN 폴백.
        guard let js, let cssLight, let cssDark else { return nil }

        // JS 초기화 스크립트: mermaid 블록 제외 후 hljs 적용
        let initScript = """
            <script>
                document.addEventListener('DOMContentLoaded', function() {
                    if (typeof hljs === 'undefined') return;
                    document.querySelectorAll('pre code').forEach(function(el) {
                        if (el.classList.contains('language-mermaid')) return;
                        hljs.highlightElement(el);
                    });
                });
            </script>
            """

        return """
            <style media="(prefers-color-scheme: light)">\(cssLight)</style>
            <style media="(prefers-color-scheme: dark)">\(cssDark)</style>
            <script>\(js)</script>
            \(initScript)
            """
    }

    /// KaTeX 자산(CSS·katex JS·mhchem·auto-render)을 인라인 블록으로 조립한다.
    ///
    /// - Returns: HTML 인라인 블록. **하나라도 nil이면 nil**(CDN 폴백 트리거).
    ///   delimiters 목록은 MarkdownRenderer의 CDN판과 문자 단위로 동일하게 유지한다.
    static func katexBlock(css: String?, js: String?, mhchem: String?, autoRender: String?) -> String? {
        guard let css, let js, let mhchem, let autoRender else { return nil }
        return """
            <style>\(css)</style>
            <script>\(js)</script>
            <script>\(mhchem)</script>
            <script>\(autoRender)</script>
            <script>
            document.addEventListener('DOMContentLoaded', function() {
                if (typeof renderMathInElement === 'undefined') return;
                renderMathInElement(document.body, {
                    delimiters: [
                        {left: '$$', right: '$$', display: true},
                        {left: '\\\\[', right: '\\\\]', display: true},
                        {left: '\\\\(', right: '\\\\)', display: false},
                        {left: '$', right: '$', display: false}
                    ],
                    throwOnError: false
                });
            });
            </script>
            """
    }

    /// Mermaid UMD JS를 인라인 `<script>`로 감싼다. initialize 스니펫은 렌더러가 기존 그대로 뒤에 붙인다.
    ///
    /// - Returns: `<script>…</script>` 블록. **js가 nil이면 nil**(CDN 폴백 트리거).
    static func mermaidBlock(js: String?) -> String? {
        guard let js else { return nil }
        return "<script>\(js)</script>"
    }
}
