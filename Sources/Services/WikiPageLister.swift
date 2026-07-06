import Foundation

/// 위키 루트 아래 페이지(.md) 목록 — 인제스트 대상 Picker용(스펙 §2.6).
/// 하위 폴더 포함 상대경로, 숨김(점 시작) 디렉터리·파일 제외, 이름순.
enum WikiPageLister {
    static func relativePages(under root: URL) -> [String] {
        guard let enumerator = FileManager.default.enumerator(atPath: root.path) else { return [] }
        var pages: [String] = []
        for case let rel as String in enumerator {
            let components = rel.components(separatedBy: "/")
            if components.contains(where: { $0.hasPrefix(".") }) { continue }
            guard rel.lowercased().hasSuffix(".md") else { continue }
            pages.append(rel)
        }
        return pages.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}
