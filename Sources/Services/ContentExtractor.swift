import Foundation
import PDFKit

/// 파일 URL → 인덱싱 본문. 없으면 nil(파일명만 인덱싱).
/// office는 kordoc(Process) 비동기 추출, 그 외(text/pdf)는 동기 로컬 추출.
enum ContentExtractor {
    private static let textExtensions: Set<String> = ["md", "markdown", "txt"]

    /// kordoc 없이 즉시 추출 가능한 종류(text/pdf)만. 미지원/없는 파일은 nil.
    static func localBody(for url: URL) -> String? {
        let ext = url.pathExtension.lowercased()
        if textExtensions.contains(ext) {
            return try? String(contentsOf: url, encoding: .utf8)
        }
        if DocumentKind.pdfExtensions.contains(ext) {
            guard let pdf = PDFDocument(url: url) else { return nil }
            var parts: [String] = []
            for i in 0..<pdf.pageCount {
                if let s = pdf.page(at: i)?.string { parts.append(s) }
            }
            return parts.isEmpty ? nil : parts.joined(separator: "\n")
        }
        return nil
    }

    /// 종류별 본문. office면 kordoc 분기, 그 외는 localBody.
    static func body(for url: URL, kordoc: KordocService) async -> String? {
        let ext = url.pathExtension.lowercased()
        if DocumentKind.officeExtensions.contains(ext) {
            return try? await kordoc.markdown(for: url)
        }
        return localBody(for: url)
    }
}
