import Foundation

/// 정리 프롬프트 생성·strict JSON 파싱·경로 안전·배정 병합을 담당하는 순수 헬퍼.
/// RouteHelper와 동형(테스트 대상).
enum CleanupPlanner {

    /// 파일 메타데이터 목록을 "이름 | 확장자 | 크기" 줄로 직렬화.
    static func metadataList(_ metas: [FileMeta]) -> String {
        metas.map { m in
            "- \(m.name) | \(m.ext.isEmpty ? "(없음)" : m.ext) | \(m.size)B"
        }.joined(separator: "\n")
    }

    /// 폴더명 안전화: 경로 구분자·금지문자·`..` 제거.
    static func sanitizeBucketName(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:\\?%*|\"<>\u{0}")
        var cleaned = name.components(separatedBy: invalid).joined(separator: "-")
        cleaned = cleaned.replacingOccurrences(of: "..", with: "")
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// stdout에서 첫 `{` ~ 마지막 `}` 구간만 추출(RouteHelper 패턴).
    static func extractJSONObject(_ stdout: String) -> String? {
        guard let start = stdout.firstIndex(of: "{"),
              let end = stdout.lastIndex(of: "}"), start < end else { return nil }
        return String(stdout[start...end])
    }

    static func buildSchemePrompt(metadata metas: [FileMeta]) -> String {
        """
        아래는 한 폴더의 파일 목록(이름 | 확장자 | 크기)이다. 이 파일들을 종류·주제별로
        정리할 하위폴더 묶음(스킴)을 제안하라. 폴더는 3~8개로 적절히 묶고 한국어 폴더명을 쓴다.
        경로 구분자(/·\\)나 ..는 폴더명에 쓰지 않는다.

        \(metadataList(metas))

        답은 다른 텍스트 없이 strict JSON 한 줄로만 한다:
        {"buckets":[{"name":"<폴더명>","hint":"<무엇을 담는지 한 줄>"}]}
        """
    }

    private struct SchemeParse: Decodable { let buckets: [BucketParse] }
    private struct BucketParse: Decodable { let name: String; let hint: String? }

    /// strict JSON 추출·디코드 후 이름 sanitize·중복 제거. 결과 없으면 nil.
    static func parseScheme(_ stdout: String) -> CleanupScheme? {
        guard let json = extractJSONObject(stdout),
              let data = json.data(using: .utf8),
              let parsed = try? JSONDecoder().decode(SchemeParse.self, from: data)
        else { return nil }

        var seen = Set<String>()
        var buckets: CleanupScheme = []
        for b in parsed.buckets {
            let clean = sanitizeBucketName(b.name)
            guard !clean.isEmpty, !seen.contains(clean) else { continue }
            seen.insert(clean)
            buckets.append(CleanupBucket(id: clean, name: clean, hint: b.hint ?? "", relativePath: clean))
        }
        return buckets.isEmpty ? nil : buckets
    }
}

extension CleanupPlanner {

    static func buildAssignPrompt(scheme: CleanupScheme, metadata metas: [FileMeta]) -> String {
        let list = scheme.map { "- \($0.id) — \($0.hint)" }.joined(separator: "\n")
        return """
        아래 폴더 스킴(id — 설명)이 있다:

        \(list)

        다음 파일들을 각각 위 스킴의 id 중 하나에 배정하라. 확신이 없으면 confidence를 낮게 준다.
        어디에도 맞지 않으면 id를 빈 문자열("")로 둔다.

        \(metadataList(metas))

        답은 다른 텍스트 없이 strict JSON 한 줄로만 한다:
        {"assignments":[{"name":"<파일명>","id":"<스킴 id 또는 \\"\\">","reason":"<한 줄>","confidence":0.0}]}
        """
    }

    /// 모호 파일의 본문 발췌를 파일명 헤더와 함께 묶는다. 각 발췌는 maxCharsEach로 truncate.
    static func buildAmbiguousContext(_ items: [(name: String, excerpt: String)], maxCharsEach: Int = 1500) -> String {
        items.map { item in
            let body = item.excerpt.count > maxCharsEach
                ? String(item.excerpt.prefix(maxCharsEach)) + "\n…(생략)"
                : item.excerpt
            return "## \(item.name)\n\(body)"
        }.joined(separator: "\n\n")
    }

    private struct AssignParse: Decodable { let assignments: [AssignmentParse] }
    private struct AssignmentParse: Decodable {
        let name: String; let id: String; let reason: String?; let confidence: Double?
    }

    /// 파일명으로 메타와 매칭하고 id를 스킴 허용 목록으로 검증(밖이면 ""). confidence는 0...1 클램프.
    static func parseAssignments(_ stdout: String, scheme: CleanupScheme, metadata metas: [FileMeta]) -> [CleanupAssignment]? {
        guard let json = extractJSONObject(stdout),
              let data = json.data(using: .utf8),
              let parsed = try? JSONDecoder().decode(AssignParse.self, from: data)
        else { return nil }

        let validIds = Set(scheme.map { $0.id })
        let byName = Dictionary(metas.map { ($0.name, $0.url) }, uniquingKeysWith: { a, _ in a })

        var result: [CleanupAssignment] = []
        for a in parsed.assignments {
            guard let url = byName[a.name] else { continue }
            let validId = validIds.contains(a.id) ? a.id : ""
            let conf = min(1.0, max(0.0, a.confidence ?? 0))
            result.append(CleanupAssignment(fileURL: url, bucketId: validId, reason: a.reason ?? "", confidence: conf))
        }
        return result
    }

    /// overrides(2차 본문 재배정)를 fileURL 기준으로 base에 덮어쓴다.
    static func merge(_ base: [CleanupAssignment], with overrides: [CleanupAssignment]) -> [CleanupAssignment] {
        var byURL = Dictionary(base.map { ($0.fileURL, $0) }, uniquingKeysWith: { a, _ in a })
        for o in overrides { byURL[o.fileURL] = o }
        return base.map { byURL[$0.fileURL] ?? $0 }
    }

    /// 배정을 미리보기용 move로 변환. 분류된 것만 기본 승인.
    static func buildMoves(from assignments: [CleanupAssignment]) -> [CleanupMove] {
        assignments.map {
            CleanupMove(id: UUID(), source: $0.fileURL, bucketId: $0.bucketId,
                        reason: $0.reason, confidence: $0.confidence, approved: !$0.bucketId.isEmpty)
        }
    }
}
