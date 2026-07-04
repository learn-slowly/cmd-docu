import Foundation

// MARK: - LibrarySorting

/// 라이브러리·트리 공용 정렬 — 순수 헬퍼(스펙 §2.2).
/// para(기본)는 기존 ParaLens.sorted에 완전 위임(원본 불변 — ParaLensTests 보호).
/// 그 외 키: ①폴더 먼저(방향 무관) → ②선택 키(방향 반영) → ③이름 오름차순 tie-break(방향 무관).
enum LibrarySorting {

    static func sorted(_ items: [FileTreeItem], by sort: LibrarySort, under root: URL?) -> [FileTreeItem] {
        guard sort.key != .para else { return ParaLens.sorted(items, under: root) }

        return items.sorted { lhs, rhs in
            // 폴더 먼저 — 방향과 무관하게 항상.
            let ld = lhs.isDirectory ? 0 : 1, rd = rhs.isDirectory ? 0 : 1
            if ld != rd { return ld < rd }

            var primary = ComparisonResult.orderedSame
            switch sort.key {
            case .para:
                break // 도달 불가(위에서 선분기)
            case .name:
                primary = lhs.name.localizedStandardCompare(rhs.name)
            case .date:
                primary = compare(lhs.modifiedAt ?? .distantPast, rhs.modifiedAt ?? .distantPast)
            case .size:
                // 폴더는 크기 미계산(리스트 표기 "--") — 폴더 구간은 키 동률로 두어
                // 이름 tie-break이 정렬한다(방향 반전 비적용).
                if !(lhs.isDirectory && rhs.isDirectory) {
                    primary = compare(lhs.fileSize ?? 0, rhs.fileSize ?? 0)
                }
            case .kind:
                if !lhs.isDirectory {  // 폴더 구간은 동률 → 이름순
                    primary = compare(DocumentKind(from: lhs.url).sortRank,
                                      DocumentKind(from: rhs.url).sortRank)
                    if primary == .orderedSame {
                        primary = compare(lhs.url.pathExtension.lowercased(),
                                          rhs.url.pathExtension.lowercased())
                    }
                }
            }

            if primary != .orderedSame {
                return sort.ascending ? primary == .orderedAscending
                                      : primary == .orderedDescending
            }
            // 키 동률 — 이름 오름차순 고정(안정된 2차 질서).
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private static func compare<T: Comparable>(_ l: T, _ r: T) -> ComparisonResult {
        if l == r { return .orderedSame }
        return l < r ? .orderedAscending : .orderedDescending
    }
}
