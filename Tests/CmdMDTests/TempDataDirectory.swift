import Foundation

/// 테스트 격리용 임시 데이터 디렉터리 헬퍼.
///
/// AppState는 기본적으로 실제 `~/Library/Application Support/CmdMD/`에 settings·session을
/// 읽고 쓰므로, 테스트가 그대로 `AppState()`를 쓰면 (a) 사용자 설정 파일을 오염시키고
/// (b) 세션 복원이 디스크 상태에 의존해 비결정적이 된다.
/// 각 테스트가 빈 UUID 디렉터리를 만들어 `AppState(dataDirectory:)`에 주입하면
/// 깨끗한 기본값으로 시작(세션 복원 없음)하고 종료 시 통째로 정리된다.
enum TempDataDirectory {
    /// 새 빈 임시 디렉터리를 만들어 URL을 돌려준다.
    static func make() -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cmddocu-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// 임시 디렉터리를 제거한다(teardown용).
    static func cleanup(_ url: URL?) {
        guard let url else { return }
        try? FileManager.default.removeItem(at: url)
    }
}
