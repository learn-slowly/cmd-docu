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
    /// 분류 키는 항목당 1회 사전계산(Schwartzian) — classify가 비교마다 URL 표준화·
    /// pathComponents 배열을 할당해 n log n번 반복되던 비용 제거(2026-07-05 리뷰 백로그.
    /// 트리 평탄화 후 펼쳐진 전체 트리가 렌더마다 정렬되므로 체감 비용이 됐다).
    static func sorted(_ items: [FileTreeItem], under root: URL?) -> [FileTreeItem] {
        let keyed = items.map { item in
            (item: item,
             rank: classify(item.url, under: root).sortRank,
             dir: item.isDirectory ? 0 : 1)
        }
        return keyed.sorted { lhs, rhs in
            if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
            // 같은 분류: 폴더 먼저
            if lhs.dir != rhs.dir { return lhs.dir < rhs.dir }
            // 이름 오름차순
            return lhs.item.name.localizedStandardCompare(rhs.item.name) == .orderedAscending
        }.map(\.item)
    }
}
