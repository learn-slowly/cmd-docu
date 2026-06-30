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
