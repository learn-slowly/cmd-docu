import Foundation

/// dataviewjs 렌더 호출(dv.table/dv.list/dv.paragraph/dv.header/dv.span 등)의
/// 결과를 표현하는 값 모델. Task 6의 JS 엔진이 dv-shim.js 출력을 이 값으로
/// 변환해 넘긴다(변환 로직은 Task 6 몫 — 여기는 값 정의+직렬화만 담당).
enum DataviewCellValue: Equatable {
    case text(String)                          // 이스케이프 후 <br>만 복원(cellHTML 참조)
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
/// 텍스트 셀 처리: 이스케이프 후 `<br>` 계열만 복원하는 화이트리스트(cellHTML 참조).
/// 실사용 dataviewjs 블록이 여러 줄을 한 셀에 넣을 때 쓰는 `<br>` join만 살리고,
/// 그 밖의 태그는 전부 이스케이프한다 — raw 통과는 dv.pages()로 읽은 볼트
/// 메타데이터를 `<img src="https://…">` 셀로 내보내는 유출 채널이 된다(최종 리뷰 확증).
/// 오류 카드의 코드도 이스케이프한다(원본 소스 노출이라 실행될 이유가 없다).
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
        case .text(let s):
            // 이스케이프 후 <br>만 복원 — 실사용 셀 HTML은 <br> join뿐(스펙 §3).
            // raw 통과는 dv.pages()로 읽은 볼트 전체 메타데이터를 <img src="https://…"> 셀로
            // 내보내는 유출 채널이 된다(최종 리뷰 확증) — JSContext 격리(§4)를 직렬화 경계까지 연장.
            return escape(s)
                .replacingOccurrences(of: "&lt;br&gt;", with: "<br>")
                .replacingOccurrences(of: "&lt;br/&gt;", with: "<br>")
                .replacingOccurrences(of: "&lt;br /&gt;", with: "<br>")
        case .link(let path, let display):
            // 지원 확장자(md/markdown/txt)일 때만 제거 — 무조건 deletingPathExtension이면
            // 점 든 이름("1.1.1_노트")을 "1.1"로 오절단한다(LinkedNoteResolver 점-이름 버그 전례).
            let ext = (path as NSString).pathExtension.lowercased()
            let target = ["md", "markdown", "txt"].contains(ext)
                ? (path as NSString).deletingPathExtension : path
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
