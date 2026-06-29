import Foundation

/// 파일 확장자 → 문서 종류 단일 판별원. PDF·오피스는 이후 Phase에서 케이스만 추가한다.
enum DocumentKind: String, Codable {
    case markdown
    case image
    case pdf
}

extension DocumentKind {
    /// 보기를 네이티브 이미지 뷰로 가르는 확장자 집합(소문자).
    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "webp", "gif"]

    /// 보기를 네이티브 PDF 뷰로 가르는 확장자 집합(소문자).
    static let pdfExtensions: Set<String> = ["pdf"]

    /// 확장자(대소문자 무시)로 종류를 정한다. 이미지·PDF가 아니면 마크다운(현행 기본 동작).
    init(from url: URL) {
        let ext = url.pathExtension.lowercased()
        if DocumentKind.imageExtensions.contains(ext) {
            self = .image
        } else if DocumentKind.pdfExtensions.contains(ext) {
            self = .pdf
        } else {
            self = .markdown
        }
    }
}
