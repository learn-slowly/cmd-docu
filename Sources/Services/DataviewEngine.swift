import Foundation
import JavaScriptCore

// `JSContextGroupSetExecutionTimeLimit`는 dylib에는 남아있지만(내보내기 심볼 확인됨)
// 이 SDK의 공개 헤더(JSBase.h/JSContextRef.h)에는 선언이 빠져 있어 `import JavaScriptCore`만으로는
// Swift에서 보이지 않는다. 실제 C ABI 시그니처를 직접 선언해 심볼명으로 바인딩한다.
@_silgen_name("JSContextGroupSetExecutionTimeLimit")
private func cmdmd_JSContextGroupSetExecutionTimeLimit(
    _ group: JSContextGroupRef?,
    _ limit: Double,
    _ callback: (@convention(c) (JSContextRef?, UnsafeMutableRawPointer?) -> Bool)?,
    _ context: UnsafeMutableRawPointer?
)

enum DataviewError: Error, Equatable {
    case assetsMissing
    case timeout
    case script(String)
}

struct DataviewRunContext {
    let noteURL: URL
    let rootURL: URL
}

/// dataviewjs 블록을 JSContext에서 실행한다(스펙 §4~5 — C안).
/// 컨텍스트는 실행 단위로 생성·폐기(블록 간 전역 오염 방지), 시간 제한은
/// JSContextGroupSetExecutionTimeLimit(무한루프도 강제 종료). fetch/DOM이 없는
/// 환경이라 블록이 읽은 메타데이터를 밖으로 보낼 방법이 없다(스펙 §4).
final class DataviewEngine {

    static func run(code: String, context runCtx: DataviewRunContext,
                    timeLimit: Double = 3.0) -> Result<[DataviewOutputItem], DataviewError> {
        guard let luxon = LocalWebAssets.luxonJS, let shim = LocalWebAssets.dvShimJS,
              let ctx = JSContext() else { return .failure(.assetsMissing) }

        // 시간 제한 — 콜백이 true를 돌려주면 실행을 끊는다(캡처 없는 C 함수 포인터).
        let group = JSContextGetGroup(ctx.jsGlobalContextRef)
        cmdmd_JSContextGroupSetExecutionTimeLimit(group, timeLimit, { _, _ in true }, nil)

        let index = DataviewPageIndex.shared(for: runCtx.rootURL)
        installBridge(in: ctx, index: index, runCtx: runCtx)

        ctx.evaluateScript(luxon)
        ctx.evaluateScript(shim)
        guard ctx.exception == nil else { return .failure(.assetsMissing) }

        let started = Date()
        ctx.evaluateScript(code)
        if let exception = ctx.exception {
            // 시간 제한 종료도 예외로 나온다 — 경과 시간으로 판별.
            if Date().timeIntervalSince(started) >= timeLimit { return .failure(.timeout) }
            return .failure(.script(exception.toString() ?? "알 수 없는 오류"))
        }

        guard let json = ctx.evaluateScript("JSON.stringify(__dvOutput)")?.toString(),
              let data = json.data(using: .utf8),
              let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return .failure(.script("출력을 해석하지 못했습니다")) }
        return .success(raw.compactMap(Self.outputItem(from:)))
    }

    // MARK: 동기 브릿지

    private static func installBridge(in ctx: JSContext, index: DataviewPageIndex,
                                      runCtx: DataviewRunContext) {
        let encoder = JSONEncoder()
        func jsonString<T: Encodable>(_ value: T) -> String {
            (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "null"
        }
        // 오류 메시지 안 임의 문자열(따옴표 포함 가능)을 JSON 문자열로 안전 인코드.
        func jsonErrorPayload(_ message: String) -> String {
            let escaped = (try? encoder.encode(message)).flatMap { String(data: $0, encoding: .utf8) } ?? "\"\(message)\""
            return "{\"error\":\(escaped)}"
        }
        // "/Calendar/" 같은 폴더 소스의 선행/후행 슬래시를 떼 "Calendar"로 정규화(Task 3 리뷰 지적).
        func normalizeFolder(_ s: String) -> String {
            var t = s
            if t.hasPrefix("/") { t.removeFirst() }
            if t.hasSuffix("/") { t.removeLast() }
            return t
        }

        let native = JSValue(newObjectIn: ctx)!

        let currentPage: @convention(block) () -> String = {
            guard let meta = index.meta(forFileURL: runCtx.noteURL) else {
                return jsonErrorPayload("현재 노트를 읽지 못했습니다")
            }
            return jsonString(meta)
        }
        native.setObject(currentPage, forKeyedSubscript: "currentPage" as NSString)

        let pages: @convention(block) (String) -> String = { source in
            let s = source.trimmingCharacters(in: .whitespaces)
            if s.lowercased().contains(" or ") || s.lowercased().contains(" and ") || s.hasPrefix("-") {
                return jsonErrorPayload("cmdALL은 복합 소스를 지원하지 않습니다(폴더·태그 단일 소스만)")
            }
            if s.isEmpty { return jsonString(index.allPages()) }
            if s.hasPrefix("#") { return jsonString(index.pages(withTag: s)) }
            if s.hasPrefix("\""), s.hasSuffix("\""), s.count >= 2 {
                let folder = normalizeFolder(String(s.dropFirst().dropLast()))
                return jsonString(index.pages(inFolder: folder))
            }
            return jsonErrorPayload("지원하지 않는 dv.pages 소스입니다: " + s)
        }
        native.setObject(pages, forKeyedSubscript: "pages" as NSString)

        // shim의 dv.page가 `j ? wrapPage(parsed(j)) : null`로 null 체크하므로
        // 문자열 "null"이 아니라 실제 JSValue null을 돌려줘야 한다(구현 주의 ①).
        let page: @convention(block) (String) -> JSValue = { pathOrName in
            guard let meta = index.page(at: pathOrName) else { return JSValue(nullIn: ctx) }
            return JSValue(object: jsonString(meta), in: ctx)
        }
        native.setObject(page, forKeyedSubscript: "page" as NSString)

        ctx.setObject(native, forKeyedSubscript: "__dvNative" as NSString)
    }

    // MARK: 출력 디코드

    private static func outputItem(from dict: [String: Any]) -> DataviewOutputItem? {
        switch dict["type"] as? String {
        case "table":
            let headers = (dict["headers"] as? [Any] ?? []).map(cellValue(from:))
            let rows = (dict["rows"] as? [[Any]] ?? []).map { $0.map(cellValue(from:)) }
            return .table(headers: headers, rows: rows)
        case "list": return .list((dict["items"] as? [Any] ?? []).map(cellValue(from:)))
        case "paragraph": return .paragraph(cellValue(from: dict["text"] ?? ""))
        case "header": return .header(level: dict["level"] as? Int ?? 1, cellValue(from: dict["text"] ?? ""))
        case "span": return .span(cellValue(from: dict["text"] ?? ""))
        default: return nil
        }
    }

    private static func cellValue(from any: Any) -> DataviewCellValue {
        if let link = any as? [String: Any], link["__dvLink"] as? Bool == true {
            return .link(path: link["path"] as? String ?? "", display: link["display"] as? String)
        }
        if let arr = any as? [Any] { return .nested(arr.map(cellValue(from:))) }
        return .text(any as? String ?? String(describing: any))
    }
}
