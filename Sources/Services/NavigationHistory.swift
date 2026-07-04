import Foundation

// MARK: - FolderLocation

/// 폴더 히스토리 한 항목 — (작업 폴더 루트, 표시 폴더) 쌍(스펙 §3.1, 사용자 결정 4).
struct FolderLocation: Equatable {
    let root: URL
    let display: URL

    /// standardized 경로 기준 동등성(연속 중복 병합용).
    /// 심링크(/var↔/private/var)까지는 해소하지 않는다(F1b 관례).
    func isSameLocation(as other: FolderLocation) -> Bool {
        root.standardizedFileURL.path == other.root.standardizedFileURL.path
            && display.standardizedFileURL.path == other.display.standardizedFileURL.path
    }
}

// MARK: - NavigationHistory

/// 뒤로/앞으로 폴더 히스토리 — 순수 구조체. FS 접근 없음(존재 검사는 클로저 주입 — 테스트 결정성).
/// 세션 내 휘발(영속 없음 — SessionState 무변경, 스펙 §3).
struct NavigationHistory {
    private(set) var backStack: [FolderLocation] = []
    private(set) var forwardStack: [FolderLocation] = []
    private(set) var current: FolderLocation?

    /// backStack 상한 — 무한 누적 방지.
    static let capacity = 100

    var canGoBack: Bool { !backStack.isEmpty }
    var canGoForward: Bool { !forwardStack.isEmpty }

    /// 새 위치 기록. current가 없으면 seed(스택 불변). 직전과 같은 위치면 무시(didSet 재발화 흡수).
    /// 새 위치로 이동하면 forwardStack은 버린다(브라우저 규약).
    mutating func record(_ loc: FolderLocation) {
        guard let cur = current else { current = loc; return }
        guard !cur.isSameLocation(as: loc) else { return }
        backStack.append(cur)
        if backStack.count > Self.capacity {
            backStack.removeFirst(backStack.count - Self.capacity)
        }
        forwardStack = []
        current = loc
    }

    /// 뒤로 — 죽은 항목(isValid false)은 버리며 계속 pop(skip-pop). 성공 시 current를 forward로.
    mutating func goBack(isValid: (FolderLocation) -> Bool) -> FolderLocation? {
        while let loc = backStack.popLast() {
            if isValid(loc) {
                if let cur = current { forwardStack.append(cur) }
                current = loc
                return loc
            }
        }
        return nil
    }

    /// 앞으로 — goBack의 대칭.
    mutating func goForward(isValid: (FolderLocation) -> Bool) -> FolderLocation? {
        while let loc = forwardStack.popLast() {
            if isValid(loc) {
                if let cur = current { backStack.append(cur) }
                current = loc
                return loc
            }
        }
        return nil
    }

    /// 죽은 경로 제거(파일 작업 후 호출). current는 건드리지 않는다(호출부가 재조준 담당 — 스펙 §5).
    mutating func prune(isValid: (FolderLocation) -> Bool) {
        backStack.removeAll { !isValid($0) }
        forwardStack.removeAll { !isValid($0) }
    }
}
