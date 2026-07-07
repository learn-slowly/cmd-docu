import Foundation

/// 위키 루트 아래 페이지(.md) 목록 — 인제스트 대상 Picker용(스펙 §2.6).
/// 하위 폴더 포함 상대경로, 숨김(점 시작) 디렉터리·파일 제외, 이름순.
/// 루트 직속 CLAUDE.md·templates/는 "규칙 소스"(규칙 파악이 읽는 파일)라 병합 대상에서 제외 —
/// Picker에 노출되면 규칙 파일에 실수로 병합하는 사고를 유인한다(하위 폴더의 동명은 일반 취급).
enum WikiPageLister {
    static func relativePages(under root: URL) -> [String] {
        guard let enumerator = FileManager.default.enumerator(atPath: root.path) else { return [] }
        var pages: [String] = []
        while let rel = enumerator.nextObject() as? String {
            let last = (rel as NSString).lastPathComponent
            if last.hasPrefix(".") {
                // 숨김 "디렉터리"만 하강 차단 — 숨김 파일에서 skipDescendants()를 부르면
                // 가장 최근 서브디렉터리(=그 파일을 담은 보이는 폴더)의 하강이 취소돼
                // 페이지가 무증상 누락된다(.DS_Store 실측 — 리뷰 확정 Critical).
                if (enumerator.fileAttributes?[.type] as? FileAttributeType) == .typeDirectory {
                    enumerator.skipDescendants()
                }
                continue
            }
            // 대소문자 무시 비교 — collectRuleSources는 파일시스템 경로 해석(macOS APFS 기본=
            // case-insensitive)으로 규칙 소스를 읽으므로, 제외도 같은 시맨틱이어야 소문자
            // claude.md·대문자 Templates/ 가 규칙 소스이면서 대상 Picker에 새지 않는다(리뷰 확증).
            if rel.caseInsensitiveCompare("CLAUDE.md") == .orderedSame { continue }
            if rel.caseInsensitiveCompare("templates") == .orderedSame {
                if (enumerator.fileAttributes?[.type] as? FileAttributeType) == .typeDirectory {
                    enumerator.skipDescendants()
                    continue
                }
            }
            guard rel.lowercased().hasSuffix(".md") else { continue }
            pages.append(rel)
        }
        return pages.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}
