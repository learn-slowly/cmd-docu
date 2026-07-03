import XCTest
@testable import CmdMD

/// GUI 앱(.app)이 launchd의 최소 PATH만 상속해 npx(`#!/usr/bin/env node`)가
/// node를 못 찾고 exit 127로 죽던 버그(스모크 실측)의 회귀 방지 테스트.
final class SubprocessEnvironmentTests: XCTestCase {

    func testMissingPATH_prependsToolDirAndKeepsFallback() {
        let env = SubprocessEnvironment.environment(
            forTool: "/opt/homebrew/bin/npx",
            base: ["HOME": "/Users/tester"]
        )
        guard let path = env["PATH"] else {
            return XCTFail("PATH가 없습니다.")
        }
        XCTAssertTrue(path.hasPrefix("/opt/homebrew/bin"), "PATH가 도구 디렉터리로 시작해야 합니다: \(path)")
        XCTAssertTrue(path.contains(SubprocessEnvironment.fallbackPATH),
                      "폴백 PATH(launchd 최소 PATH)가 보존돼야 합니다: \(path)")
    }

    func testExistingPATH_prependsToolDirAndPreservesExisting() {
        let base = ["PATH": "/usr/bin:/bin", "HOME": "/Users/tester"]
        let env = SubprocessEnvironment.environment(forTool: "/opt/homebrew/bin/npx", base: base)

        guard let path = env["PATH"] else {
            return XCTFail("PATH가 없습니다.")
        }
        XCTAssertTrue(path.hasPrefix("/opt/homebrew/bin"), "도구 디렉터리가 앞에 붙어야 합니다: \(path)")
        XCTAssertTrue(path.contains("/usr/bin:/bin"), "기존 PATH가 보존돼야 합니다: \(path)")
        XCTAssertEqual(env["HOME"], "/Users/tester", "PATH 외 키는 그대로여야 합니다.")
    }

    func testToolDirAlreadyInPATH_noDuplicate() throws {
        // 심링크가 아닌 실제 파일로 고정해야 한다 — 이 개발 머신의 실제 /opt/homebrew/bin/npx는
        // npm 패키지 내부(node_modules/npm/bin)로 가는 심링크라 resolvedDir이 달라져
        // (의도된 동작으로) 그 디렉터리가 별도로 보태진다. 여기서는 toolDir 중복 방지만 검증한다.
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? fm.removeItem(at: dir) }
        let tool = dir.appendingPathComponent("npx")
        fm.createFile(atPath: tool.path, contents: Data())

        let base = ["PATH": "\(dir.path):/usr/bin:/bin"]
        let env = SubprocessEnvironment.environment(forTool: tool.path, base: base)

        XCTAssertEqual(env["PATH"], "\(dir.path):/usr/bin:/bin", "이미 있으면 중복 추가하지 않아야 합니다.")
    }

    func testSymlinkedTool_includesBothLinkAndResolvedDirs() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let realDir = root.appendingPathComponent("A/bin")
        let linkDir = root.appendingPathComponent("B/bin")
        try fm.createDirectory(at: realDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: linkDir, withIntermediateDirectories: true)
        addTeardownBlock { try? fm.removeItem(at: root) }

        let realTool = realDir.appendingPathComponent("tool")
        fm.createFile(atPath: realTool.path, contents: Data())
        let linkedTool = linkDir.appendingPathComponent("tool")
        try fm.createSymbolicLink(at: linkedTool, withDestinationURL: realTool)

        let env = SubprocessEnvironment.environment(forTool: linkedTool.path, base: [:])
        guard let path = env["PATH"] else {
            return XCTFail("PATH가 없습니다.")
        }
        XCTAssertTrue(path.contains(linkDir.path), "심링크 디렉터리가 PATH에 있어야 합니다: \(path)")
        XCTAssertTrue(path.contains(realDir.path), "심링크 해석 디렉터리도 PATH에 있어야 합니다: \(path)")
    }

    /// 실환경 재현 스모크 — /opt/homebrew/bin/npx가 있는 머신에서만 실행.
    func testRealNpxPath_includesHomebrewBin() throws {
        let npxPath = "/opt/homebrew/bin/npx"
        guard FileManager.default.isExecutableFile(atPath: npxPath) else {
            throw XCTSkip("이 머신에 \(npxPath)가 없습니다.")
        }
        let env = SubprocessEnvironment.environment(forTool: npxPath, base: [:])
        XCTAssertTrue(env["PATH"]?.contains("/opt/homebrew/bin") ?? false)
    }
}
