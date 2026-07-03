import Foundation

/// 클릭에 실린 선택 수식키(F1b 스펙 §3.1). ⌘가 ⇧보다 우선.
enum SelectionModifier {
    case none
    case command
    case shift
}

/// 다중 선택 순수 헬퍼 — 상태 없음, AppState가 소유한 Set<URL>을 계산만 해준다.
enum FileSelectionHelper {

    /// 클릭 한 번의 선택 결과를 계산한다(Finder식).
    /// - none: 클릭 항목 하나로 교체, 앵커 이동.
    /// - command: 토글, 앵커 이동.
    /// - shift: 앵커~클릭 연속 구간으로 교체(ordered 순서 기준), 앵커 유지.
    ///   앵커가 없거나 ordered에서 사라졌으면(재열거) 단일 선택 폴백.
    static func resolve(current: Set<URL>, anchor: URL?, clicked: URL,
                        modifier: SelectionModifier, ordered: [URL]) -> (selection: Set<URL>, anchor: URL?) {
        switch modifier {
        case .none:
            return ([clicked], clicked)
        case .command:
            var next = current
            if next.contains(clicked) { next.remove(clicked) } else { next.insert(clicked) }
            return (next, clicked)
        case .shift:
            guard let anchor,
                  let anchorIndex = ordered.firstIndex(of: anchor),
                  let clickedIndex = ordered.firstIndex(of: clicked) else {
                return ([clicked], clicked)
            }
            let range = min(anchorIndex, clickedIndex)...max(anchorIndex, clickedIndex)
            return (Set(ordered[range]), anchor)
        }
    }

    /// 배치 대상 정규화 — 부모 폴더와 그 하위가 함께 선택됐으면 조상만 남긴다
    /// (부모가 먼저 이동/휴지통 가면 자식 연산이 경로 소실로 실패). '/' 경계 prefix로
    /// 형제("a" vs "ab") 오감지를 방지하고, 결정적 처리 순서를 위해 경로 오름차순 정렬.
    static func ancestorsOnly(_ urls: Set<URL>) -> [URL] {
        let paths = urls.map { $0.standardizedFileURL.path }
        let kept = urls.filter { url in
            let p = url.standardizedFileURL.path
            return !paths.contains { other in other != p && p.hasPrefix(other + "/") }
        }
        return kept.sorted { $0.path < $1.path }
    }
}
