import Foundation

enum WikiRulesError: Error, Equatable {
    case noRuleSources     // CLAUDE.md·templates 어느 것도 없음 — 내장 기본 스키마로 동작
    case badResponse       // 요약이 빈 값
}

/// 위키 규칙 1회 파악(스펙 §2.1) — 위키의 CLAUDE.md·templates에서 "문서 생성에 적용할
/// 규칙만" 추출·요약한다. 요약은 설정에 저장돼 매 인제스트 프롬프트에 주입된다.
actor WikiRulesService {
    /// 규칙 소스 입력 상한 — 초과분 truncate + 프롬프트 고지.
    static let sourceInputLimit = 40_000
    /// 요약 상한 — 매 인제스트 프롬프트에 실리므로 간결해야 한다.
    static let summaryLimit = 8_000

    private let claude: any ClaudeAsking

    init(claude: any ClaudeAsking) {
        self.claude = claude
    }

    func captureRules(wikiFolder: URL) async throws -> String {
        guard let raw = Self.collectRuleSources(wikiFolder: wikiFolder) else {
            throw WikiRulesError.noRuleSources
        }
        let truncated = raw.count >= Self.sourceInputLimit
        let (prompt, context) = Self.capturePrompt(truncatedInput: truncated)
        let stdout = try await askWithRetry(prompt: prompt, context: context + raw)
        let summary = stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !summary.isEmpty else { throw WikiRulesError.badResponse }
        return summary.count > Self.summaryLimit
            ? String(summary.prefix(Self.summaryLimit)) : summary
    }

    /// 규칙 소스 수집 — CLAUDE.md + templates/*.md(이름순), 파일별 헤더로 연결.
    /// 하나도 없으면 nil. 합계가 상한을 넘으면 앞에서부터 상한까지 truncate.
    static func collectRuleSources(wikiFolder: URL) -> String? {
        var parts: [String] = []
        let claudeMd = wikiFolder.appendingPathComponent("CLAUDE.md")
        if let body = try? String(contentsOf: claudeMd, encoding: .utf8) {
            parts.append("## 파일: CLAUDE.md\n\n\(body)")
        }
        let templatesDir = wikiFolder.appendingPathComponent("templates")
        if let names = try? FileManager.default.contentsOfDirectory(atPath: templatesDir.path) {
            for name in names.sorted() where name.lowercased().hasSuffix(".md") {
                if let body = try? String(contentsOf: templatesDir.appendingPathComponent(name),
                                          encoding: .utf8) {
                    parts.append("## 파일: templates/\(name)\n\n\(body)")
                }
            }
        }
        guard !parts.isEmpty else { return nil }
        let joined = parts.joined(separator: "\n\n---\n\n")
        return joined.count > sourceInputLimit ? String(joined.prefix(sourceInputLimit)) : joined
    }

    /// 추출 프롬프트 — 문서 생성 규칙만 추리고, 도구 실행이 필요한 워크플로우 규칙은 제외.
    static func capturePrompt(truncatedInput: Bool) -> (prompt: String, context: String) {
        var prompt = """
        아래는 한 지식 위키의 운영 규칙·템플릿 문서들이다. 이 위키에 **새 문서를 생성하거나 \
        기존 문서에 병합할 때 적용해야 할 규칙만** 추려, 간결한 지시문 목록으로 요약하라.

        반드시 포함할 것(문서에 있으면): 파일 명명 규칙, 문서 유형별로 새 문서가 놓일 폴더(상대 \
        경로), frontmatter 스키마(필드·형식), 언어 정책, 섹션 구조·필수 섹션(템플릿), 서술 \
        금지사항(예: 소스에 없는 내용 금지, 빈 섹션 허용).

        제외할 것: 도구 실행이 필요한 워크플로우 규칙(웹 다운로드, 다층 검증 절차, 인덱스/로그 \
        파일 갱신, 외부 파일 조작, git 조작). 단 검증 규칙의 정신은 "문서가 소스 발췌 기반임을 \
        명시하고, 소스에 없는 내용을 쓰지 말라" 수준의 서술 지침으로 반영하라.

        출력은 요약 지시문만 쓴다(서문·설명 금지). 한국어로 쓴다.
        """
        if truncatedInput {
            prompt += "\n주의: 입력 문서는 분량 한도로 잘린 발췌본이다."
        }
        return (prompt, "")
    }

    /// 타임아웃 1회 재시도(CleanupService 전례). 입력이 40k까지 실릴 수 있어
    /// 위키 전용 한도(300s)를 호출별로 지정한다(WikiIngestModels.claudeTimeout 공유).
    private func askWithRetry(prompt: String, context: String) async throws -> String {
        let limit = WikiIngestModels.claudeTimeout
        do { return try await claude.ask(prompt: prompt, context: context, timeout: limit) }
        catch ClaudeError.timeout {
            return try await claude.ask(prompt: prompt, context: context, timeout: limit)
        }
    }
}
