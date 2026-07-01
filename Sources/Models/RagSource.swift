/// RAG 답변의 근거 1건 + 원본 위치.
struct RagSource: Equatable, Identifiable {
    let index: Int          // [n] (1-based). 프롬프트 번호와 표시에 공용.
    let path: String        // 원본 파일 절대경로
    let snippet: String     // 표시용 발췌
    let location: RagLocation
    var id: Int { index }
}

/// 근거의 원본 위치. 클릭 점프에 쓴다.
enum RagLocation: Equatable {
    case line(Int)          // text/md: 1-based 줄
    case page(Int)          // pdf: 1-based 페이지
    case unknown            // office 등 위치 매핑 불가 → 파일만 연다
}
