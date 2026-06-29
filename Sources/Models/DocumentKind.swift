import Foundation

/// 파일 확장자 → 문서 종류 단일 판별원.
enum DocumentKind: String, Codable {
    case markdown
    case image
    case pdf
    case office
}

extension DocumentKind {
    /// 보기를 네이티브 이미지 뷰로 가르는 확장자 집합(소문자).
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "webp", "gif"]

    /// 보기를 네이티브 PDF 뷰로 가르는 확장자 집합(소문자).
    static let pdfExtensions: Set<String> = ["pdf"]

    /// kordoc으로 마크다운 변환해 보는 한글·오피스 확장자(소문자).
    static let officeExtensions: Set<String> = ["hwp", "hwpx", "hwpml", "doc", "docx", "xls", "xlsx"]

    /// kordoc patch가 서식 보존 라운드트립을 지원하는 확장자(소문자). HWP/HWPX 전용.
    static let patchableExtensions: Set<String> = ["hwp", "hwpx"]

    /// 이 파일이 kordoc patch(편집 후 서식 보존 저장) 대상인가.
    static func isPatchable(_ url: URL) -> Bool {
        patchableExtensions.contains(url.pathExtension.lowercased())
    }

    /// 확장자(대소문자 무시): 이미지 → PDF → 오피스 → 마크다운(기본).
    init(from url: URL) {
        let ext = url.pathExtension.lowercased()
        if DocumentKind.imageExtensions.contains(ext) {
            self = .image
        } else if DocumentKind.pdfExtensions.contains(ext) {
            self = .pdf
        } else if DocumentKind.officeExtensions.contains(ext) {
            self = .office
        } else {
            self = .markdown
        }
    }
}
