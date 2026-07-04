import SwiftUI
import UniformTypeIdentifiers

// MARK: - FileDropDelegate

/// 폴더 드롭 타깃 공용 델리게이트(F2 스펙 §3) — 검증(사전 차단)·hover 콜백·수행 위임.
/// 하이라이트 렌더는 표면마다 다르므로(셀 테두리·행 배경) onHoverChange로 뷰에 위임한다.
struct FileDropDelegate: DropDelegate {
    let destination: URL
    let appState: AppState
    /// hover 진입/이탈 — 하이라이트 및 트리 스프링로딩 타이머(스펙 §5)가 구독.
    var onHoverChange: ((Bool) -> Void)? = nil

    /// F2가 받는 타입 — 내부(커스텀) 우선, 외부(Finder) fileURL 겸용.
    static let acceptedTypes: [UTType] = [.cmdDocuDrag, .fileURL]

    func validateDrop(info: DropInfo) -> Bool {
        guard info.hasItemsConforming(to: Self.acceptedTypes) else { return false }
        // 1차 사전 차단 — 내부 드래그는 시작 시점 스냅샷(draggingURLs)으로 자기/하위 거부.
        // 외부 드래그는 소스를 모름 → 허용(2차 방어 = handleFileDrop 필터).
        return DropGuard.canAcceptAny(sources: appState.draggingURLs, destination: destination)
    }

    func dropEntered(info: DropInfo) { onHoverChange?(true) }
    func dropExited(info: DropInfo) { onHoverChange?(false) }

    func performDrop(info: DropInfo) -> Bool {
        onHoverChange?(false)
        let providers = info.itemProviders(for: Self.acceptedTypes)
        return appState.handleFileDrop(providers, into: destination)
    }
}
