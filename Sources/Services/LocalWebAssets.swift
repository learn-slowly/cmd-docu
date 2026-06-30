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
}
