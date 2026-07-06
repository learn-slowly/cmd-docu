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
                // 숨김 "디렉터리"만 하강 차단 — 숨김 파일에서 skipDescendants()를 부르면
                // 가장 최근 서브디렉터리(=그 파일을 담은 보이는 폴더)의 하강이 취소돼
                // 페이지가 무증상 누락된다(.DS_Store 실측 — 리뷰 확정 Critical).
                if (enumerator.fileAttributes?[.type] as? FileAttributeType) == .typeDirectory {
                    enumerator.skipDescendants()
                }
                continue
            }
            guard rel.lowercased().hasSuffix(".md") else { continue }
            pages.append(rel)
        }
        return pages.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }
}
