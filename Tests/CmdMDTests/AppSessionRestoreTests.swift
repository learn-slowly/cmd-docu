import XCTest
@testable import CmdMD

/// 콜드런치 세션 복원 — 마지막 활성 탭 재지정 판정(순수 헬퍼).
/// 복원 루프 도중 Finder 더블클릭 같은 외부 열기가 activeTabId를 가져갔으면 존중하고
/// 세션의 activeFileIndex 재지정을 건너뛰어야 한다(AppState.restoreSessionIfNeeded).
final class AppSessionRestoreTests: XCTestCase {

    func testCurrentNilAllowsRestore() {
        // 외부 개입 없음(activeTabId가 아직 nil) — 기존 성공 경로는 그대로 재지정 허용.
        XCTAssertTrue(AppState.shouldRestoreActiveTab(current: nil, restoredTabIds: []))
    }

    func testCurrentInRestoredSetAllowsRestore() {
        // 복원 루프가 마지막으로 활성화한 탭이 곧 current — 정상 종료 경로.
        let restoredId = UUID()
        let otherId = UUID()
        XCTAssertTrue(
            AppState.shouldRestoreActiveTab(current: restoredId, restoredTabIds: [restoredId, otherId])
        )
    }

    func testCurrentOutsideRestoredSetSkipsRestore() {
        // 외부 열기가 만든 탭이 current — 복원이 이를 덮어쓰면 안 된다.
        let externalId = UUID()
        let restoredId = UUID()
        XCTAssertFalse(
            AppState.shouldRestoreActiveTab(current: externalId, restoredTabIds: [restoredId])
        )
    }

    func testCurrentOutsideEmptyRestoredSetSkipsRestore() {
        // 복원 대상 파일이 전부 없어졌거나(0건) 외부 열기만 있었던 극단 케이스.
        let externalId = UUID()
        XCTAssertFalse(AppState.shouldRestoreActiveTab(current: externalId, restoredTabIds: []))
    }
}
