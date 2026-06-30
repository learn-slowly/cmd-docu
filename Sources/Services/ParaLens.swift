import Foundation

// MARK: - ParaCategory

/// PARA 분류 열거형. sortRank: archive를 맨 끝(4)으로 배치.
enum ParaCategory: Equatable {
    case projects
    case areas
    case resources
    case archive
    case other

    /// 정렬 기준값. projects(0) → areas(1) → resources(2) → other(3) → archive(4).
    var sortRank: Int {
        switch self {
        case .projects:  return 0
        case .areas:     return 1
        case .resources: return 2
        case .other:     return 3
        case .archive:   return 4
        }
    }
}

// MARK: - ParaLens

/// 사이드바 PARA 렌즈 — 순수 헬퍼. 데이터 모델·AppState 불변.
/// 정렬·분류는 렌더 시점에만 적용한다.
enum ParaLens {

    // MARK: 분류

    /// `url`의 PARA 분류. `root`(현재 폴더) 기준 상대 경로만 스캔해 조상의 PARA 접두사는 무시한다.
    /// (root 자신의 이름은 포함 — Archive 폴더로 직접 진입하면 그 안을 archive로 본다.)
    /// root가 nil이면 전체 경로 스캔(기존 동작).
    static func classify(_ url: URL, under root: URL?) -> ParaCategory {
        let urlComps = url.standardizedFileURL.pathComponents
        let start: Int
        if let root {
            let rootComps = root.standardizedFileURL.pathComponents
            guard urlComps.count >= rootComps.count,
                  Array(urlComps.prefix(rootComps.count)) == rootComps else { return .other }
            // root 자신의 lastPathComponent(index: rootComps.count - 1)부터 스캔
            start = max(0, rootComps.count - 1)
        } else {
            start = 0
        }
        for component in urlComps[start...] {
            if component.hasPrefix("10000_") { return .projects }
            if component.hasPrefix("20000_") { return .areas }
            if component.hasPrefix("30000_") { return .resources }
            if component.hasPrefix("40000_") { return .archive }
        }
        return .other
    }

    // MARK: 정렬

    /// 항목 배열을 PARA 순서로 정렬해 반환한다. 분류는 `root`(현재 폴더) 기준.
    /// 정렬키: `(category.sortRank, isDirectory ? 0 : 1, name localizedStandard)`.
    /// 기존 항목 식별자·children은 그대로 보존된다.
    static func sorted(_ items: [FileTreeItem], under root: URL?) -> [FileTreeItem] {
        items.sorted { lhs, rhs in
            let l = classify(lhs.url, under: root).sortRank
            let r = classify(rhs.url, under: root).sortRank
            if l != r { return l < r }
            // 같은 분류: 폴더 먼저
            let ld = lhs.isDirectory ? 0 : 1, rd = rhs.isDirectory ? 0 : 1
            if ld != rd { return ld < rd }
            // 이름 오름차순
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }
}
