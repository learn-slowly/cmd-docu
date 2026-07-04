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

    /// 드래그 파스테보드에 내부 페이로드 시드 — 실드래그의 파스테보드 직판을 재현.
    private func seedDragPasteboard(_ urls: [URL]) {
        let pb = NSPasteboard(name: .drag)
        pb.clearContents()
        pb.declareTypes([DragPayload.pasteboardType], owner: nil)
        pb.setData(DragPayload.encode(urls), forType: DragPayload.pasteboardType)
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
        // 내부 드래그 — 전체 목록은 드래그 파스테보드로 전달(SwiftUI가 드롭 provider에서
        // 커스텀 타입을 누락하므로 provider가 아니라 파스테보드를 시드).
        seedDragPasteboard([a, b])
        let provider = DragPayload.makeProvider(for: [a, b], primary: a)
        let accepted = app.handleFileDrop([provider], into: destDir)
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
        // Finder발 재현 — 커스텀 타입 없는 순수 fileURL provider 2개.
        let providers = [NSItemProvider(object: a as NSURL), NSItemProvider(object: b as NSURL)]
        XCTAssertTrue(app.handleFileDrop(providers, into: destDir))
        waitUntil {
            FileManager.default.fileExists(atPath: self.destDir.appendingPathComponent("ext1.md").path)
                && FileManager.default.fileExists(atPath: self.destDir.appendingPathComponent("ext2.md").path)
        }
    }

    @MainActor
    func testDropGuardFiltersSelfDescendant() {
        let app = AppState(dataDirectory: tempDir)
        // dest 자신을 dest 하위로 이동 시도 — 2차 방어 필터로 무동작이어야 함.
        seedDragPasteboard([destDir])
        let provider = DragPayload.makeProvider(for: [destDir], primary: destDir)
        let sub = destDir.appendingPathComponent("sub")
        try? FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        XCTAssertTrue(app.handleFileDrop([provider], into: sub))
        // 폴링으로 "이동이 일어나지 않음"을 확인(잠깐 대기 후 원위치 확인).
        RunLoop.main.run(until: Date().addingTimeInterval(1.0))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destDir.path), "자기 하위 드롭은 무동작")
        // 2차 필터의 진짜 가치 = 실패 보고 없는 "조용한" 무동작. 필터를 지우면 performBatchMove가
        // FileOperations.move(자기 하위)로 throw → reportBatchFailures가 errorMessage를 채운다.
        // errorMessage가 nil로 남아야 필터가 살아있음을 증명한다(FileOperations 독립 거부와 구분).
        XCTAssertNil(app.errorMessage, "2차 필터가 조용히 걸러 실패 보고가 없어야 함")
    }

    /// collectDropURLs 파스테보드 시임 — 유니크 파스테보드의 내부 페이로드를 전체 회수(직판 경로).
    func testCollectDropURLsReadsPayloadFromPasteboard() {
        let a = makeFile("c1.md"), b = makeFile("c2.md")
        let pb = NSPasteboard(name: NSPasteboard.Name(rawValue: UUID().uuidString))
        pb.declareTypes([DragPayload.pasteboardType], owner: nil)
        pb.setData(DragPayload.encode([a, b]), forType: DragPayload.pasteboardType)
        let exp = expectation(description: "collect")
        // provider는 비어 있어도 파스테보드에서 전체 목록을 읽어야 한다(SwiftUI 누락 대응).
        AppState.collectDropURLs([], pasteboard: pb) { urls in
            XCTAssertEqual(urls, [a, b], "파스테보드 직판으로 전체 페이로드 회수")
            exp.fulfill()
        }
        wait(for: [exp], timeout: 2)
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
