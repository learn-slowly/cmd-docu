import XCTest
@testable import CmdMD

/// Phase 10 신규 단축키 4종의 기본값과, 리맵 기본값끼리의 중복 부재를 고정한다.
/// (하드코딩 단축키와의 충돌은 enum 밖이라 설계 단계 수동 검증으로 갈음 — 스펙 §2·§5)
final class ShortcutDefaultsTests: XCTestCase {
    func testPhase10ShortcutDefaults() {
        XCTAssertEqual(AppShortcut.indexSearch.defaultBinding,
                       KeyBinding(key: "f", command: true, option: true))
        XCTAssertEqual(AppShortcut.askCorpus.defaultBinding,
                       KeyBinding(key: "a", command: true, option: true))
        XCTAssertEqual(AppShortcut.toggleLibraryMode.defaultBinding,
                       KeyBinding(key: "l", command: true, shift: true))
        XCTAssertEqual(AppShortcut.folderCleanup.defaultBinding,
                       KeyBinding(key: "k", command: true, option: true))
    }

    func testDefaultBindingsAreUnique() {
        let bindings = AppShortcut.allCases.map(\.defaultBinding)
        XCTAssertEqual(Set(bindings).count, bindings.count,
                       "AppShortcut 기본 바인딩이 서로 겹칩니다")
    }
}
