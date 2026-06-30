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

    /// `url` 경로의 PARA 분류를 반환한다.
    /// 경로 컴포넌트를 앞(최상위)에서부터 스캔해 처음 매칭되는 PARA 접두사로 결정한다.
    /// 매칭 없으면 `.other`.
    static func classify(_ url: URL) -> ParaCategory {
        let components = url.pathComponents
        for component in components {
            if component.hasPrefix("10000_") { return .projects }
            if component.hasPrefix("20000_") { return .areas }
            if component.hasPrefix("30000_") { return .resources }
            if component.hasPrefix("40000_") { return .archive }
        }
        return .other
    }

    // MARK: 정렬

    /// 항목 배열을 PARA 순서로 정렬해 반환한다.
    /// 정렬키: `(category.sortRank, isDirectory ? 0 : 1, name localizedStandard)`.
    /// 기존 항목 식별자·children은 그대로 보존된다.
    static func sorted(_ items: [FileTreeItem]) -> [FileTreeItem] {
        items.sorted { lhs, rhs in
            let lhsCat = classify(lhs.url)
            let rhsCat = classify(rhs.url)

            if lhsCat.sortRank != rhsCat.sortRank {
                return lhsCat.sortRank < rhsCat.sortRank
            }
            // 같은 분류: 폴더 먼저
            let lhsDir = lhs.isDirectory ? 0 : 1
            let rhsDir = rhs.isDirectory ? 0 : 1
            if lhsDir != rhsDir {
                return lhsDir < rhsDir
            }
            // 이름 오름차순
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }
}
