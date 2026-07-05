import Foundation

/// dataviewjs 렌더 호출(dv.table/dv.list/dv.paragraph/dv.header/dv.span 등)의
/// 결과를 표현하는 값 모델. Task 6의 JS 엔진이 dv-shim.js 출력을 이 값으로
/// 변환해 넘긴다(변환 로직은 Task 6 몫 — 여기는 값 정의+직렬화만 담당).
enum DataviewCellValue: Equatable {
    case text(String)                          // 원문 HTML 허용(아래 근거 주석 참조)
    case link(path: String, display: String?)
    case nested([DataviewCellValue])
}

enum DataviewOutputItem: Equatable {
    case table(headers: [DataviewCellValue], rows: [[DataviewCellValue]])
    case list([DataviewCellValue])
    case paragraph(DataviewCellValue)
    case header(level: Int, DataviewCellValue)
    case span(DataviewCellValue)
}

/// dv 렌더 호출 결과를 프리뷰 HTML로 직렬화한다(순수).
///
/// 텍스트 셀 HTML 통과 근거: 실사용 dataviewjs 블록이 `<br>` join(여러 줄을
/// 한 셀에 넣는 관용구)을 쓴다. 프리뷰는 어차피 노트 마크다운의 raw HTML
/// 블록을 그대로 렌더하므로, 자기 노트가 넣는 HTML은 기존 표면과 동위험 —
/// 여기서 추가로 이스케이프하면 그 실사용 패턴만 깨진다.
/// 오류 카드의 코드만은 이스케이프한다(사용자 코드가 아니라 오류 표시 안의
/// 원본 소스 노출이라 실행될 이유가 없다).
enum DataviewHTMLSerializer {

    static func html(for items: [DataviewOutputItem]) -> String {
        items.map { item in
            switch item {
            case .table(let headers, let rows):
                let head = headers.map { "<th>\(cellHTML($0))</th>" }.joined()
                let body = rows.map { row in
                    "<tr>" + row.map { "<td>\(cellHTML($0))</td>" }.joined() + "</tr>"
                }.joined()
                return "<table class=\"dataview\"><thead><tr>\(head)</tr></thead><tbody>\(body)</tbody></table>"
            case .list(let items):
                return "<ul class=\"dataview\">" + items.map { "<li>\(cellHTML($0))</li>" }.joined() + "</ul>"
            case .paragraph(let t): return "<p class=\"dataview\">\(cellHTML(t))</p>"
            case .header(let level, let t):
                let l = min(max(level, 1), 6)
                return "<h\(l) class=\"dataview\">\(cellHTML(t))</h\(l)>"
            case .span(let t): return "<span class=\"dataview\">\(cellHTML(t))</span>"
            }
        }.joined(separator: "\n")
    }

    private static func cellHTML(_ cell: DataviewCellValue) -> String {
        switch cell {
        case .text(let s): return s
        case .link(let path, let display):
            let target = (path as NSString).deletingPathExtension
            let label = escape(display ?? (target as NSString).lastPathComponent)
            return "<a href=\"\(escape(MarkdownRenderer.wikiLinkHref(target: target)))\" class=\"wiki-link\">\(label)</a>"
        case .nested(let cells): return cells.map(cellHTML).joined(separator: "<br>")
        }
    }

    static func errorCard(message: String, code: String) -> String {
        """
        <div class="dataview-error"><p>⚠️ dataviewjs: \(escape(message))</p>\
        <details><summary>원본 코드</summary><pre><code>\(escape(code))</code></pre></details></div>
        """
    }

    static func runButtonCard(blockId: Int, code: String) -> String {
        """
        <div class="dataview-block" id="dv-b\(blockId)">\
        <button onclick='window.webkit.messageHandlers.cmdmd.postMessage({"type":"dataviewRun","id":\(blockId)})'>▶ 이 블록 실행</button>\
        <details><summary>dataviewjs 코드</summary><pre><code>\(escape(code))</code></pre></details></div>
        """
    }

    static func pendingCard() -> String {
        "<p class=\"dataview-pending\">dataviewjs 실행 중…</p>"
    }

    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
         .replacingOccurrences(of: "<", with: "&lt;")
         .replacingOccurrences(of: ">", with: "&gt;")
         .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
