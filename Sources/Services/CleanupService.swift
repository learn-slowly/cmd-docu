import Foundation

enum CleanupError: Error {
    case parseFailed
}

/// 스캔 → (subfolder)스킴 제안 → 배정 → 모호 파일 본문 재배정을 오케스트레이션한다.
/// Claude·kordoc 호출만 담당하고, 프롬프트·파싱·병합은 CleanupPlanner(순수)에 위임한다.
actor CleanupService {
    private let claude: any ClaudeAsking
    private let kordoc: KordocService
    private let confidenceThreshold: Double

    /// 배정 응답은 파일당 JSON 1엔트리 — 출력이 파일 수에 비례해 대형 폴더에서
    /// claude CLI 120s 타임아웃을 넘는다(2026-07-05 Downloads 789개 실증). 청크로 상한.
    static let assignChunkSize = 80
    /// 2차 재배정은 파일당 본문 발췌(~1500자)가 입력에 실리므로 더 작게.
    static let reassignChunkSize = 20

    init(claude: any ClaudeAsking, kordoc: KordocService, confidenceThreshold: Double = 0.6) {
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

    /// 타임아웃 1회 재시도 — 실데이터에서 청크 하나가 경계선(120s)에 걸려 전체 배정이
    /// 무산되는 것을 방어한다(2026-07-05 Downloads 실측). 다른 에러는 그대로 전파.
    private func askWithRetry(prompt: String, context: String) async throws -> String {
        do { return try await claude.ask(prompt: prompt, context: context) }
        catch ClaudeError.timeout { return try await claude.ask(prompt: prompt, context: context) }
    }

    /// 1차 메타데이터 배정(청크 분할·onProgress는 1차 청크 단위) → confidence 낮은
    /// 파일만 본문 발췌로 2차 재배정(역시 청크) 후 병합.
    func assign(scheme: CleanupScheme, metas: [FileMeta],
                onProgress: (@Sendable (_ done: Int, _ total: Int) -> Void)? = nil)
    async throws -> [CleanupAssignment] {
        // 1차: 메타데이터만으로 청크별 배정 — 청크당 출력(파일 수)이 상한된다.
        // 컨텍스트는 인덱스 목록(응답이 i만 돌려줘 긴 파일명 반복 제거 — 프롬프트와 일치).
        let chunks = CleanupPlanner.chunked(metas, size: Self.assignChunkSize)
        var base: [CleanupAssignment] = []
        for (index, chunk) in chunks.enumerated() {
            onProgress?(index + 1, chunks.count)
            let prompt = CleanupPlanner.buildAssignPrompt(scheme: scheme, metadata: chunk)
            let out = try await askWithRetry(prompt: prompt, context: CleanupPlanner.indexedMetadataList(chunk))
            guard let part = CleanupPlanner.parseAssignments(out, scheme: scheme, metadata: chunk) else {
                throw CleanupError.parseFailed
            }
            base.append(contentsOf: part)
        }

        // 모호 파일만 본문 발췌해 재배정.
        let ambiguousURLs = Set(base.filter { $0.confidence < confidenceThreshold }.map { $0.fileURL })
        guard !ambiguousURLs.isEmpty else { return base }
        let ambiguousMetas = metas.filter { ambiguousURLs.contains($0.url) }

        var overrides: [CleanupAssignment] = []
        for chunk in CleanupPlanner.chunked(ambiguousMetas, size: Self.reassignChunkSize) {
            var excerpts: [(name: String, excerpt: String)] = []
            for meta in chunk {
                if let body = await ContentExtractor.body(for: meta.url, kordoc: kordoc), !body.isEmpty {
                    excerpts.append((meta.name, body))
                }
            }
            guard !excerpts.isEmpty else { continue }

            let reassignPrompt = CleanupPlanner.buildAssignPrompt(scheme: scheme, metadata: chunk)
            let context = CleanupPlanner.buildAmbiguousContext(excerpts)
            let out2 = try await askWithRetry(prompt: reassignPrompt, context: context)
            if let part = CleanupPlanner.parseAssignments(out2, scheme: scheme, metadata: chunk) {
                overrides.append(contentsOf: part)
            }
            // 청크 파싱 실패는 그 청크만 1차 결과 유지(기존 "2차 실패 시 1차 유지" 시맨틱의 청크판).
        }
        guard !overrides.isEmpty else { return base }
        return CleanupPlanner.merge(base, with: overrides)
    }
}
