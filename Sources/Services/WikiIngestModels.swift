import Foundation

/// 위키 인제스트 병합 대상 — 기존 페이지 또는 새 페이지 이름(스펙 §2.1).
enum WikiIngestTarget: Equatable {
    case existing(URL)
    case new(name: String)
}

/// Claude 병합 제안 — 승인 전까지 디스크에 닿지 않는 순수 값(제안→확인→실행).
struct WikiMergeProposal: Equatable {
    let pageURL: URL        // 최종 쓰기 대상(existing 경로 또는 new의 uniquified 경로)
    let isNewPage: Bool
    let oldBody: String     // 기존 전문(새 페이지면 "")
    let newBody: String     // Claude 갱신 전문
    let sourceURL: URL
}

/// 위키 인제스트 순수 헬퍼 — 대상 URL·병합 프롬프트(페이지 스키마 내장)·응답 검증·크기 한도.
enum WikiIngestModels {
    /// 소스 발췌 한도 — 출력이 아니라 입력 절단(RagContextBuilder 12k 전례).
    static let sourceExcerptLimit = 12_000
    /// 대상 페이지 한도 — 출력=페이지 전문이라 이 값이 곧 출력 상한(타임아웃 방어, 폴더 정리 교훈).
    static let pageBodyLimit = 24_000

    /// 새 페이지 파일 URL. 이름 정제(구분자·".." 제거)는 CleanupPlanner 정책 재사용,
    /// 충돌은 uniquified(). 정제 결과가 비거나 의미 있는 문자가 없으면 nil — 항상 wikiFolder 직속(경로탈출 불가).
    static func newPageURL(name: String, wikiFolder: URL) -> URL? {
        let cleaned = CleanupPlanner.sanitizeBucketName(name)
        // 정제 후 의미 있는 문자가 남아있는지 확인 (구분자만 남은 경우도 거부)
        let meaningful = cleaned.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        guard !meaningful.isEmpty else { return nil }
        return wikiFolder.appendingPathComponent(cleaned + ".md").uniquified()
    }

    static func truncatedExcerpt(_ body: String) -> (text: String, truncated: Bool) {
        guard body.count > sourceExcerptLimit else { return (body, false) }
        return (String(body.prefix(sourceExcerptLimit)), true)
    }

    /// 병합 프롬프트 — 규칙(=앱 안의 페이지 스키마)은 prompt에, 본문들은 context(stdin)에.
    static func mergePrompt(pageTitle: String, pageBody: String,
                            sourceName: String, sourceExcerpt: String,
                            excerptTruncated: Bool, isNewPage: Bool,
                            today: String) -> (prompt: String, context: String) {
        var rules = """
        당신은 개인 지식 위키의 사서다. 아래 [위키 페이지]에 [새 자료]의 내용을 병합해, \
        갱신된 페이지 전문을 출력하라.

        규칙:
        1. 출력은 갱신된 페이지의 마크다운 전문만 쓴다. 서문·설명·코드펜스로 감싸기 금지.
        2. 페이지 맨 위 YAML frontmatter를 유지·갱신한다(없으면 만든다). updated: \(today), \
        sources 목록에는 기존 항목을 전부 보존하고 "- \(sourceName) (\(today))" 항목을 추가한다.
        3. 기존 페이지의 정보를 유실하지 말 것 — 재구성·중복 제거는 허용, 내용 삭제는 금지.
        4. 새 자료의 핵심(요약·개념·근거)을 페이지 구조에 녹여 넣고, 필요하면 섹션을 신설한다.
        5. sources에 이미 있는 자료가 다시 오면 중복 서술을 만들지 말고 해당 부분을 갱신만 한다.
        6. 위키 본문은 한국어로 쓴다(자료가 외국어여도).
        """
        if isNewPage {
            rules += "\n7. 이 페이지는 새 페이지다. \"# \(pageTitle)\" 헤딩으로 시작해 새 자료의 요약으로 구성하라."
        }
        if excerptTruncated {
            rules += "\n주의: [새 자료]는 앞부분 발췌본이다."
        }
        let context = """
        [위키 페이지: \(pageTitle)]
        \(pageBody.isEmpty ? "(새 페이지 — 본문 없음)" : pageBody)

        [새 자료: \(sourceName)]
        \(sourceExcerpt)
        """
        return (rules, context)
    }

    /// 응답에서 페이지 전문을 추출·검증한다. 실패(빈 값·기존 대비 40% 미만 급축소)는 nil —
    /// 유실 방어 1차(최종 방어는 diff 승인). 새 페이지(oldBodyLength 0)엔 축소 검증 미적용.
    static func extractMarkdown(from stdout: String, oldBodyLength: Int) -> String? {
        var text = stdout.trimmingCharacters(in: .whitespacesAndNewlines)

        // 전체가 코드펜스로 감싸인 응답 벗기기(```markdown … ```).
        let lines = text.components(separatedBy: "\n")
        if lines.count >= 2, lines[0].hasPrefix("```"),
           lines[lines.count - 1].trimmingCharacters(in: .whitespaces) == "```" {
            text = lines.dropFirst().dropLast().joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // 서문 제거 — frontmatter("---") 또는 첫 헤딩("#") 시작 전 잡담을 걷어낸다.
        if !text.hasPrefix("---") && !text.hasPrefix("#") {
            if let r = text.range(of: "\n---\n") {
                text = String(text[text.index(after: r.lowerBound)...])
            } else if let r = text.range(of: "\n#") {
                text = String(text[text.index(after: r.lowerBound)...])
            }
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !text.isEmpty else { return nil }
        if oldBodyLength > 0, text.count < oldBodyLength * 40 / 100 { return nil }
        return text
    }
}
