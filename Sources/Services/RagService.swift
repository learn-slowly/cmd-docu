import Foundation

/// 자료에 묻기(RAG) 오케스트레이션: 확장→검색→패시지→컨텍스트→Claude.
/// 근거가 0건이면 Claude를 호출하지 않는다(무근거 생성 차단·크레딧 절약).
actor RagService {
    private let index: SearchIndex
    private let claude: ClaudeService
    private let kordoc: KordocService

    init(index: SearchIndex, claude: ClaudeService, kordoc: KordocService) {
        self.index = index
        self.claude = claude
        self.kordoc = kordoc
    }

    struct Answer: Equatable { let text: String; let sources: [RagSource] }
    enum RagOutcome { case answered(Answer); case noEvidence; case failed(ClaudeError) }

    func ask(question: String, expandQuery: Bool) async -> RagOutcome {
        // ① 확장(옵션). 실패해도 원질문만으로 진행.
        var expanded: [String] = []
        if expandQuery,
           let out = try? await claude.ask(prompt: RagQueryExpansion.prompt(), context: question) {
            expanded = RagQueryExpansion.parse(out)
        }

        // ② 검색.
        let paths = await RagRetriever(index: index).topFiles(question: question, expandedTerms: expanded)
        guard !paths.isEmpty else { return .noEvidence }

        // ③ 검색·하이라이트 공용 terms = 질문 토큰 + 확장.
        let terms = dedupedTerms(question: question, expanded: expanded)
        var keptPaths: [String] = []
        var passages: [RagPassageExtractor.Passage] = []
        for p in paths {
            if let passage = await RagPassageExtractor.passage(
                for: URL(fileURLWithPath: p), terms: terms, kordoc: kordoc) {
                keptPaths.append(p)
                passages.append(passage)
            }
        }
        guard !passages.isEmpty else { return .noEvidence }

        // ④ 컨텍스트 + 프롬프트 → Claude.
        let built = RagContextBuilder.build(paths: keptPaths, passages: passages)
        do {
            let text = try await claude.ask(
                prompt: RagPromptBuilder.prompt(question: question), context: built.context)
            return .answered(Answer(text: text, sources: built.sources))
        } catch let e as ClaudeError {
            return .failed(e)
        } catch {
            return .failed(.failed(error.localizedDescription))
        }
    }

    private func dedupedTerms(question: String, expanded: [String]) -> [String] {
        let tokens = question.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).map(String.init)
        var seen = Set<String>()
        var out: [String] = []
        for t in tokens + expanded {
            let k = t.lowercased()
            guard !t.isEmpty, !seen.contains(k) else { continue }
            seen.insert(k); out.append(t)
        }
        return out
    }
}
