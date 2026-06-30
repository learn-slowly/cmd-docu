import Foundation

enum CleanupError: Error {
    case parseFailed
}

/// 스캔 → (subfolder)스킴 제안 → 배정 → 모호 파일 본문 재배정을 오케스트레이션한다.
/// Claude·kordoc 호출만 담당하고, 프롬프트·파싱·병합은 CleanupPlanner(순수)에 위임한다.
actor CleanupService {
    private let claude: ClaudeService
    private let kordoc: KordocService
    private let confidenceThreshold: Double

    init(claude: ClaudeService, kordoc: KordocService, confidenceThreshold: Double = 0.6) {
        self.claude = claude
        self.kordoc = kordoc
        self.confidenceThreshold = confidenceThreshold
    }

    /// subfolder 모드: Claude가 스킴 제안. (PARA 모드는 호출하지 않고 설정 폴더를 스킴으로 쓴다.)
    func proposeScheme(metas: [FileMeta]) async throws -> CleanupScheme {
        let prompt = CleanupPlanner.buildSchemePrompt(metadata: metas)
        let out = try await claude.ask(prompt: prompt, context: CleanupPlanner.metadataList(metas))
        guard let scheme = CleanupPlanner.parseScheme(out) else { throw CleanupError.parseFailed }
        return scheme
    }

    /// 1차 메타데이터 배정 → confidence 낮은 파일만 본문 발췌로 2차 재배정 후 병합.
    func assign(scheme: CleanupScheme, metas: [FileMeta]) async throws -> [CleanupAssignment] {
        let prompt = CleanupPlanner.buildAssignPrompt(scheme: scheme, metadata: metas)
        let out = try await claude.ask(prompt: prompt, context: CleanupPlanner.metadataList(metas))
        guard let base = CleanupPlanner.parseAssignments(out, scheme: scheme, metadata: metas) else {
            throw CleanupError.parseFailed
        }

        // 모호 파일만 본문 발췌해 재배정.
        let ambiguousURLs = Set(base.filter { $0.confidence < confidenceThreshold }.map { $0.fileURL })
        guard !ambiguousURLs.isEmpty else { return base }

        let ambiguousMetas = metas.filter { ambiguousURLs.contains($0.url) }
        var excerpts: [(name: String, excerpt: String)] = []
        for meta in ambiguousMetas {
            if let body = await ContentExtractor.body(for: meta.url, kordoc: kordoc), !body.isEmpty {
                excerpts.append((meta.name, body))
            }
        }
        guard !excerpts.isEmpty else { return base }

        let reassignPrompt = CleanupPlanner.buildAssignPrompt(scheme: scheme, metadata: ambiguousMetas)
        let context = CleanupPlanner.buildAmbiguousContext(excerpts)
        let out2 = try await claude.ask(prompt: reassignPrompt, context: context)
        guard let overrides = CleanupPlanner.parseAssignments(out2, scheme: scheme, metadata: ambiguousMetas) else {
            return base // 2차 실패 시 1차 결과 유지
        }
        return CleanupPlanner.merge(base, with: overrides)
    }
}
