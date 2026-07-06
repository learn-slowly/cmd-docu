import Foundation

enum WikiIngestError: Error, Equatable {
    case sourceUnreadable      // 소스 본문 추출 실패(미지원 형식·kordoc 실패 포함)
    case pageUnreadable        // 기존 페이지 읽기 실패
    case pageTooLarge          // 페이지 한도 초과(출력=전문이라 타임아웃 방어)
    case invalidNewPageName    // 정제 후 빈 이름
    case badResponse           // 응답 검증 실패(빈 값·급축소)
    case autoPathInvalid           // 자동 배치 — 마커 없음/경로 검증 실패
    case autoPathOccupied(String)  // 자동 배치 — 제안 경로에 이미 페이지 존재(상대경로)
}

/// 병합 제안 생성만 담당 — 디스크에 쓰지 않는다(적용은 AppState+WikiBackupStore,
/// 제안→확인→실행). 의존은 ClaudeAsking으로 좁혀 가짜 주입 테스트(스펙 §2.3).
actor WikiIngestService {
    private let claude: any ClaudeAsking
    private let kordoc: KordocService

    init(claude: any ClaudeAsking, kordoc: KordocService) {
        self.claude = claude
        self.kordoc = kordoc
    }

    func propose(source: URL, target: WikiIngestTarget,
                 wikiFolder: URL, rulesSummary: String?,
                 today: String) async throws -> WikiMergeProposal {
        guard let sourceBody = await ContentExtractor.body(for: source, kordoc: kordoc) else {
            throw WikiIngestError.sourceUnreadable
        }
        let (excerpt, truncated) = WikiIngestModels.truncatedExcerpt(sourceBody)

        // 자동 배치 — Claude가 위치·파일명을 마커로 제안(스펙 §2.4).
        if case .auto = target {
            let title = source.deletingPathExtension().lastPathComponent
            let (prompt, context) = WikiIngestModels.mergePrompt(
                pageTitle: title, pageBody: "",
                sourceName: source.lastPathComponent, sourceExcerpt: excerpt,
                excerptTruncated: truncated, isNewPage: true,
                autoPlacement: true, rulesSummary: rulesSummary, today: today)
            let stdout = try await askWithRetry(prompt: prompt, context: context)
            guard let (relPath, rawBody) = WikiIngestModels.extractAutoPage(from: stdout),
                  let pageURL = WikiIngestModels.validatedAutoPageURL(
                      relativePath: relPath, wikiFolder: wikiFolder) else {
                throw WikiIngestError.autoPathInvalid
            }
            guard !FileManager.default.fileExists(atPath: pageURL.path) else {
                throw WikiIngestError.autoPathOccupied(relPath)
            }
            guard let newBody = WikiIngestModels.extractMarkdown(from: rawBody,
                                                                 oldBodyLength: 0) else {
                throw WikiIngestError.badResponse
            }
            return WikiMergeProposal(pageURL: pageURL, isNewPage: true,
                                     oldBody: "", newBody: newBody, sourceURL: source)
        }

        let pageURL: URL
        let oldBody: String
        let isNewPage: Bool
        switch target {
        case .existing(let url):
            guard let body = try? String(contentsOf: url, encoding: .utf8) else {
                throw WikiIngestError.pageUnreadable
            }
            guard body.count <= WikiIngestModels.pageBodyLimit else {
                throw WikiIngestError.pageTooLarge
            }
            pageURL = url; oldBody = body; isNewPage = false
        case .new(let name):
            guard let url = WikiIngestModels.newPageURL(name: name, wikiFolder: wikiFolder) else {
                throw WikiIngestError.invalidNewPageName
            }
            pageURL = url; oldBody = ""; isNewPage = true
        case .auto:
            // 도달 불가(위에서 조기 반환) — switch 전수성용. 크래시 대신 안전한 에러.
            throw WikiIngestError.autoPathInvalid
        }

        let title = pageURL.deletingPathExtension().lastPathComponent
        let (prompt, context) = WikiIngestModels.mergePrompt(
            pageTitle: title, pageBody: oldBody,
            sourceName: source.lastPathComponent, sourceExcerpt: excerpt,
            excerptTruncated: truncated, isNewPage: isNewPage,
            rulesSummary: rulesSummary, today: today)

        let stdout = try await askWithRetry(prompt: prompt, context: context)
        guard let newBody = WikiIngestModels.extractMarkdown(from: stdout,
                                                             oldBodyLength: oldBody.count) else {
            throw WikiIngestError.badResponse
        }
        return WikiMergeProposal(pageURL: pageURL, isNewPage: isNewPage,
                                 oldBody: oldBody, newBody: newBody, sourceURL: source)
    }

    /// 타임아웃 1회 재시도 — 경계선 방어(CleanupService 전례). 다른 에러는 전파.
    private func askWithRetry(prompt: String, context: String) async throws -> String {
        do { return try await claude.ask(prompt: prompt, context: context) }
        catch ClaudeError.timeout { return try await claude.ask(prompt: prompt, context: context) }
    }
}
