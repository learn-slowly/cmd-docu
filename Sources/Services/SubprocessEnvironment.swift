import Foundation

/// GUI 앱(.app)은 launchd의 최소 PATH만 상속해, 절대경로로 도구를 실행해도
/// 그 도구가 다시 PATH에 기대면(npx의 `#!/usr/bin/env node`가 node를 찾는 등) 실패한다.
/// 자식 프로세스 환경의 PATH 앞에 도구 디렉터리(심링크면 실제 위치 디렉터리까지)를
/// 보태 이를 보정한다. 스모크 실측: Finder 실행 앱에서 npx가 exit 127
/// "env: node: No such file or directory"로 죽어 HWP 변환이 전부 실패했다.
enum SubprocessEnvironment {
    /// launchd가 GUI 앱에 주는 최소 PATH와 동일한 폴백.
    static let fallbackPATH = "/usr/bin:/bin:/usr/sbin:/sbin"

    /// toolPath의 디렉터리(+심링크 해석 디렉터리)를 PATH 맨 앞에 보탠 환경.
    /// PATH 외 키는 base 그대로, 이미 든 디렉터리는 중복 추가하지 않는다.
    static func environment(forTool toolPath: String,
                            base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var env = base
        let path = env["PATH"] ?? fallbackPATH
        var parts = path.split(separator: ":").map(String.init)

        let toolDir = (toolPath as NSString).deletingLastPathComponent
        let resolvedDir = (URL(fileURLWithPath: toolPath).resolvingSymlinksInPath()
            .deletingLastPathComponent().path)
        // 해석 디렉터리를 먼저 넣고 도구 디렉터리를 그 앞에 — 최종 순서는 [toolDir, resolvedDir, 기존].
        for dir in [resolvedDir, toolDir] where !dir.isEmpty && dir != "/" && !parts.contains(dir) {
            parts.insert(dir, at: 0)
        }
        env["PATH"] = parts.joined(separator: ":")
        return env
    }
}
