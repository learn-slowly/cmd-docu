import XCTest
import UniformTypeIdentifiers
@testable import CmdMD

/// F2: AppState 드롭 배선 — 내부/외부 provider에서 URL 수집 → 배치 이동 실행(실파일).
/// ⌥(복사) 분기는 NSEvent 실입력이 필요해 실기 스모크 몫 — 여기선 기본(이동) 경로만.
final class AppFileDropTests: XCTestCase {

    private var tempDir: URL!
    private var root: URL!
    private var destDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = TempDataDirectory.make()
        root = TempDataDirectory.make()
        destDir = root.appendingPathComponent("dest")
        try? FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)
        // 공유 드래그 파스테보드 초기화 — 이전 테스트의 내부 페이로드 잔존이 외부 드롭 테스트를
        // 오염시키지 않게(collectDropURLs가 이 파스테보드를 직판).
        NSPasteboard(name: .drag).clearContents()
    }

    override func tearDown() {
        NSPasteboard(name: .drag).clearContents()
        TempDataDirectory.cleanup(tempDir)
        TempDataDirectory.cleanup(root)
        tempDir = nil; root = nil; destDir = nil
        super.tearDown()
    }

    /// 내부 드래그 세션 재현 — 유니크 파스테보드에 커스텀 타입 '선언'만 얹는다(데이터 없음:
    /// 실전 0바이트 반영). 페이로드는 draggingURLs로 나르므로 여기엔 데이터를 싣지 않는다.
    private func internalDragPasteboard() -> NSPasteboard {
        let pb = NSPasteboard(name: NSPasteboard.Name(rawValue: UUID().uuidString))
        pb.declareTypes([DragPayload.pasteboardType], owner: nil)
        return pb
    }

    private func makeFile(_ name: String) -> URL {
        let url = root.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: Data("x".utf8))
        return url
    }

    /// 조건 충족까지 폴링(비동기 배치 완료 대기 — 콜백 훅이 없어 파일 존재로 관찰).
    private func waitUntil(_ timeout: TimeInterval = 5, _ condition: @escaping () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertTrue(condition(), "시간 내 조건 미충족")
    }

    @MainActor
    func testInternalDropMovesAllPayloadURLs() {
        let app = AppState(dataDirectory: tempDir)
        let a = makeFile("a.md"), b = makeFile("b.md")
        // 내부 드래그 — 페이로드 채널은 draggingURLs 스냅샷(.onDrag가 시작 시 채운 것).
        // 파스테보드는 커스텀 타입 '선언'만(데이터 없음 — 실전 0바이트) → 판별 신호로만 쓰인다.
        let pb = internalDragPasteboard()
        app.draggingURLs = [a, b]
        let accepted = app.handleFileDrop([], into: destDir, pasteboard: pb)
        XCTAssertTrue(accepted)
        waitUntil {
            FileManager.default.fileExists(atPath: self.destDir.appendingPathComponent("a.md").path)
                && FileManager.default.fileExists(atPath: self.destDir.appendingPathComponent("b.md").path)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.path), "이동 — 원본 제거")
    }

    @MainActor
    func testExternalFileURLProvidersMove() {
        let app = AppState(dataDirectory: tempDir)
        let a = makeFile("ext1.md"), b = makeFile("ext2.md")
        // Finder발 재현 — 커스텀 타입 없는 순수 fileURL provider 2개. setUp이 공유 .drag를 비워
        // isInternalDrag=false → 외부 수집 경로.
        let providers = [NSItemProvider(object: a as NSURL), NSItemProvider(object: b as NSURL)]
        XCTAssertTrue(app.handleFileDrop(providers, into: destDir))
        waitUntil {
            FileManager.default.fileExists(atPath: self.destDir.appendingPathComponent("ext1.md").path)
                && FileManager.default.fileExists(atPath: self.destDir.appendingPathComponent("ext2.md").path)
        }
    }

    /// 외부 드롭은 draggingURLs 스냅샷을 참조하지 않는다(C1 불변식) — stale이 남아도 무해.
    @MainActor
    func testExternalDropIgnoresStaleDraggingURLs() {
        let app = AppState(dataDirectory: tempDir)
        let ext = makeFile("ext.md")
        let stale = makeFile("stale.md")
        app.draggingURLs = [stale]   // 이전 내부 세션 잔존 가정 — 외부 드롭은 읽지 않아야 함
        // 외부 세션 파스테보드(커스텀 타입 없음) → isInternalDrag=false.
        let pb = NSPasteboard(name: NSPasteboard.Name(rawValue: UUID().uuidString))
        pb.declareTypes([.fileURL], owner: nil)
        let providers = [NSItemProvider(object: ext as NSURL)]
        XCTAssertTrue(app.handleFileDrop(providers, into: destDir, pasteboard: pb))
        waitUntil {
            FileManager.default.fileExists(atPath: self.destDir.appendingPathComponent("ext.md").path)
        }
        // stale은 provider에 없으므로 이동되지 않아야 한다.
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        XCTAssertTrue(FileManager.default.fileExists(atPath: stale.path),
                      "stale draggingURLs 미참조 — 외부 드롭에서 이동 안 됨")
        XCTAssertFalse(FileManager.default.fileExists(atPath: self.destDir.appendingPathComponent("stale.md").path))
    }

    @MainActor
    func testDropGuardFiltersSelfDescendant() {
        let app = AppState(dataDirectory: tempDir)
        // dest 자신을 dest 하위로 이동 시도(내부 드래그) — 2차 방어 필터로 무동작이어야 함.
        let pb = internalDragPasteboard()
        app.draggingURLs = [destDir]
        let sub = destDir.appendingPathComponent("sub")
        try? FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        XCTAssertTrue(app.handleFileDrop([], into: sub, pasteboard: pb))
        // 폴링으로 "이동이 일어나지 않음"을 확인(잠깐 대기 후 원위치 확인).
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destDir.path), "자기 하위 드롭은 무동작")
        // 2차 필터의 진짜 가치 = 실패 보고 없는 "조용한" 무동작. 필터를 지우면 performBatchMove가
        // FileOperations.move(자기 하위)로 throw → reportBatchFailures가 errorMessage를 채운다.
        // errorMessage가 nil로 남아야 필터가 살아있음을 증명한다(FileOperations 독립 거부와 구분).
        XCTAssertNil(app.errorMessage, "2차 필터가 조용히 걸러 실패 보고가 없어야 함")
    }

    /// collectDropURLs는 외부(Finder) provider의 fileURL만 수집(내부 드래그는 handleFileDrop이
    /// draggingURLs로 직접 처리해 이 경로에 오지 않음).
    func testCollectDropURLsCollectsFromFileURLProviders() {
        let a = makeFile("c1.md"), b = makeFile("c2.md")
        let providers = [NSItemProvider(object: a as NSURL), NSItemProvider(object: b as NSURL)]
        let exp = expectation(description: "collect")
        AppState.collectDropURLs(providers) { urls in
            XCTAssertEqual(Set(urls), Set([a, b]), "provider fileURL 수집(순서 무관)")
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2)
    }

    // MARK: - openExternalFileDrops (리더 영역 외부 파일 드롭=열기)

    /// 리더 위 외부 파일 드롭 = 열기. provider 여러 개 → 각각 탭으로 열린다(inNewTab).
    @MainActor
    func testOpenExternalFileDropsOpensAllProvidersAsTabs() {
        let app = AppState(dataDirectory: tempDir)
        let a = makeFile("open1.md"), b = makeFile("open2.md"), c = makeFile("open3.md")
        let providers = [
            NSItemProvider(object: a as NSURL),
            NSItemProvider(object: b as NSURL),
            NSItemProvider(object: c as NSURL),
        ]
        app.openExternalFileDrops(providers)
        waitUntil {
            let names = Set(app.tabs.compactMap { $0.fileURL?.lastPathComponent })
            return names.isSuperset(of: ["open1.md", "open2.md", "open3.md"])
        }
    }

    /// 단일 드롭 — inNewTab 강제 없이 연다(창 레벨 브랜치와 동일 시맨틱). 파일이 탭으로 열린다.
    @MainActor
    func testOpenExternalFileDropsSingleProviderOpens() {
        let app = AppState(dataDirectory: tempDir)
        let a = makeFile("single.md")
        app.openExternalFileDrops([NSItemProvider(object: a as NSURL)])
        waitUntil {
            app.tabs.contains { $0.fileURL?.lastPathComponent == "single.md" }
        }
    }

    /// 파일 URL이 아닌 provider만 있으면 무동작(탭 생성 없음).
    @MainActor
    func testOpenExternalFileDropsIgnoresNonFileProviders() {
        let app = AppState(dataDirectory: tempDir)
        let before = app.tabs.count
        app.openExternalFileDrops([NSItemProvider(object: "hello" as NSString)])
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        XCTAssertEqual(app.tabs.count, before, "파일 URL provider가 없으면 탭이 생기지 않아야 함")
    }

    // MARK: - expandFolder 멱등(스프링로딩용)

    @MainActor
    func testExpandFolderIsIdempotent() {
        let app = AppState(dataDirectory: tempDir)
        let dir = root.appendingPathComponent("folder")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        app.expandFolder(dir)
        XCTAssertTrue(app.expandedFolders.contains(dir))
        app.expandFolder(dir)   // 재발화 — toggle이면 도로 접힘(회귀 지점)
        XCTAssertTrue(app.expandedFolders.contains(dir), "expandFolder는 멱등 — 재호출에도 펼침 유지")
    }
}
