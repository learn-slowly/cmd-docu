import Foundation

// MARK: - LibrarySortKey

/// 라이브러리·트리 정렬 키. para = 기존 PARA 렌즈 정렬(기본값).
enum LibrarySortKey: String, Codable, CaseIterable {
    case para, name, date, size, kind

    /// 정렬 메뉴 표시명.
    var title: String {
        switch self {
        case .para: return "PARA (기본)"
        case .name: return "이름"
        case .date: return "수정일"
        case .size: return "크기"
        case .kind: return "종류"
        }
    }
}

// MARK: - LibrarySort

/// 정렬 상태(키+방향). 폴더별로 settings.librarySorts에 기억된다(스펙 §2.3).
struct LibrarySort: Codable, Equatable, Hashable {
    var key: LibrarySortKey
    var ascending: Bool

    static let `default` = LibrarySort(key: .para, ascending: true)

    /// 키별 기본 방향 — 이름·종류는 오름차순, 날짜·크기는 내림차순(최신·큰 것 먼저).
    static func defaultAscending(for key: LibrarySortKey) -> Bool {
        switch key {
        case .date, .size: return false
        case .para, .name, .kind: return true
        }
    }

    /// 키 선택 전이 — 새 키면 그 키의 기본 방향, 같은 키 재선택이면 방향 토글(para는 방향 없음).
    /// 툴바 메뉴·리스트 열 헤더가 공유한다.
    func selecting(_ newKey: LibrarySortKey) -> LibrarySort {
        if newKey == key, newKey != .para {
            return LibrarySort(key: key, ascending: !ascending)
        }
        return LibrarySort(key: newKey, ascending: Self.defaultAscending(for: newKey))
    }
}
