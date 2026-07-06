import Foundation

/// 위키 루트 아래 페이지(.md) 목록 — 인제스트 대상 Picker용(스펙 §2.6).
/// 하위 폴더 포함 상대경로, 숨김(점 시작) 디렉터리·파일 제외, 이름순.
enum WikiPageLister {
    static func relativePages(under root: URL) -> [String] {
        guard let enumerator = FileManager.default.enumerator(atPath: root.path) else { return [] }
        var pages: [String] = []
        while let rel = enumerator.nextObject() as? String {
            let last = (rel as NSString).lastPathComponent
            if last.hasPrefix(".") {
                enumerator.skipDescendants()   // .git 등 숨김 디렉터리 하위 진입 차단(성능)
                continue
            }
            guard rel.lowercased().hasSuffix(".md") else { continue }
            pages.append(rel)
        }
        return pages.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}
