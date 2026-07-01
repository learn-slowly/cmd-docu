import Foundation

/// 근거 패시지들을 번호([1]..[N])가 붙은 Claude 컨텍스트 문자열과 출처 목록으로 만든다(순수).
enum RagContextBuilder {
    struct Built: Equatable { let context: String; let sources: [RagSource] }

    static func build(paths: [String], passages: [RagPassageExtractor.Passage], budget: Int = 12000) -> Built {
        let n = min(paths.count, passages.count)
        var context = ""
        var sources: [RagSource] = []
        for i in 0..<n {
            let idx = i + 1
            let filename = URL(fileURLWithPath: paths[i]).lastPathComponent
            let block = "[\(idx)] \(filename)\(locationLabel(passages[i].location))\n\(passages[i].text)\n---\n"
            // 예산 초과 & 이미 1건 이상이면 중단(최소 1건은 넣는다).
            if !context.isEmpty, context.count + block.count > budget { break }
            context += block
            sources.append(RagSource(
                index: idx,
                path: paths[i],
                snippet: String(passages[i].text.prefix(160)),
                location: passages[i].location))
        }
        return Built(context: context, sources: sources)
    }

    private static func locationLabel(_ loc: RagLocation) -> String {
        switch loc {
        case .line(let n): return " (줄 \(n))"
        case .page(let p): return " (p.\(p))"
        case .unknown: return ""
        }
    }
}
