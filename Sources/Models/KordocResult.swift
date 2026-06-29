import Foundation

/// kordoc `--format json` 출력 모델. `style`/`metadata` 등 자유형식 키는
/// 선언하지 않으면 Codable이 자동으로 무시한다(필요 시 추후 추가).
struct KordocResult: Codable {
    let success: Bool
    let fileType: String
    let markdown: String
    let blocks: [KordocBlock]?
    let outline: [KordocOutlineItem]?
}

struct KordocBlock: Codable {
    let type: String
    let text: String?
    let pageNumber: Int?
    let level: Int?
}

struct KordocOutlineItem: Codable {
    let level: Int?
    let text: String?
    let pageNumber: Int?
}
