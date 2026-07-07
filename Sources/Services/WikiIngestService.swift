import Foundation

enum WikiIngestError: Error, Equatable {
    case sourceUnreadable      // 소스 본문 추출 실패(미지원 형식·kordoc 실패 포함)
    case pageUnreadable        // 기존 페이지 읽기 실패
    case pageTooLarge          // 페이지 한도 초과(출력=전문이라 타임아웃 방어)
    case invalidNewPageName    // 정제 후 빈 이름
    case badResponse           // 응답 검증 실패(빈 값·급축소)
    case autoPathInvalid           // 자동 배치 — 도달 불가 방어용(마커 없음/경로 무효는 _인박스 폴백)
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

            // 마커·경로 파싱. 유효한 위치를 냈으면 그대로, 못 냈거나 무효면 _인박스로 폴백
            // (빠른 모델이 마커를 종종 누락 — 2026-07-07 스모크 결정: 실패 대신 폴백).
            let auto = WikiIngestModels.extractAutoPage(from: stdout)
            let validated = auto.flatMap {
                WikiIngestModels.validatedAutoPageURL(relativePath: $0.relativePath,
                                                      wikiFolder: wikiFolder)
            }
            let pageURL: URL
            let rawBody: String
            if let validated {
                // Claude가 유효 경로 제안 — 점유돼 있으면 여전히 별도 에러(사용자가 .existing 선택 유도).
                guard !FileManager.default.fileExists(atPath: validated.path) else {
                    throw WikiIngestError.autoPathOccupied(auto?.relativePath ?? validated.lastPathComponent)
                }
                pageURL = validated
                rawBody = auto?.body ?? stdout
            } else {
                pageURL = WikiIngestModels.inboxFallbackURL(
                    sourceName: source.lastPathComponent, wikiFolder: wikiFolder)
                // 마커가 있었으면 그 줄은 뗀 본문, 없었으면 응답 전체. 단 마커가 10줄 창 밖(frontmatter
                // 뒤)이라 못 잡힌 경우 stdout에 마커가 남으므로 위치 무관 제거.
                rawBody = WikiIngestModels.strippingPageMarkerLines(auto?.body ?? stdout)
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
    /// 출력=페이지 전문이라 기본 120s 대신 위키 전용 한도(300s)를 호출별로 지정한다.
    private func askWithRetry(prompt: String, context: String) async throws -> String {
        let limit = WikiIngestModels.claudeTimeout
        do { return try await claude.ask(prompt: prompt, context: context, timeout: limit) }
        catch ClaudeError.timeout {
            return try await claude.ask(prompt: prompt, context: context, timeout: limit)
        }
    }
}
