import Foundation

/// kordoc `fill --dry-run` 출력의 단일 필드(서식 빈칸 후보).
/// label = 셀 텍스트(채울 라벨), value = kordoc가 추정한 인접 값(빈 서식이면 보통 빈 문자열).
struct FillField: Decodable, Identifiable {
    let label: String
    let value: String
    let row: Int
    let col: Int
    /// 중복 label을 구분하기 위한 안정 id(행·열·라벨 조합).
    var id: String { "\(row)-\(col)-\(label)" }
}

/// kordoc `fill --dry-run --silent`의 stdout JSON 모델.
struct FillDetection: Decodable {
    let fields: [FillField]
    let confidence: Double?
}
