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

    /// 이 드롭 세션이 앱 내부 드래그인지 — 세션의 아이템 타입으로 판별(draggingURLs 스냅샷
    /// 미참조). 외부(Finder) 세션이 stale 스냅샷을 읽어 오판하던 C1을 원천 차단한다.
    private func isInternal(_ info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.cmdDocuDrag])
    }

    func validateDrop(info: DropInfo) -> Bool {
        // 타입 게이트만 — 통과하면 언제나 수락(소비). 무효 내부 드롭도 소비해 상위 타깃으로
        // 폴스루하지 않게 하고(I2), 실제 유효성은 handleFileDrop의 2차 필터가 가린다.
        // 외부 세션은 draggingURLs를 읽지 않는다(C1 차단) — dropDecision 진리표 참조.
        guard info.hasItemsConforming(to: Self.acceptedTypes) else { return false }
        return DropGuard.dropDecision(isInternal: isInternal(info),
                                      sources: appState.draggingURLs,
                                      destination: destination).accept
    }

    func dropEntered(info: DropInfo) {
        // 하이라이트·스프링로딩은 hover 경로에서 게이팅 — 무효 내부 대상은 켜지지 않는다.
        let highlight = DropGuard.dropDecision(isInternal: isInternal(info),
                                               sources: appState.draggingURLs,
                                               destination: destination).highlight
        if highlight { onHoverChange?(true) }
    }

    /// 이탈은 항상 하이라이트 해제(스프링로딩 타이머도 취소) — 잔류 하이라이트 방지.
    func dropExited(info: DropInfo) { onHoverChange?(false) }

    func performDrop(info: DropInfo) -> Bool {
        onHoverChange?(false)
        let providers = info.itemProviders(for: Self.acceptedTypes)
        return appState.handleFileDrop(providers, into: destination)
    }
}
