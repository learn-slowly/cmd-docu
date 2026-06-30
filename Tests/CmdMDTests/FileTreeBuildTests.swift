import XCTest
@testable import CmdMD

/// AppState.buildFileTree(at:expanded:) 순수 함수 단위 테스트.
/// 실제 Task.detached 백그라운드 전환(loadFileTree)은 빌드+수동 확인.
final class FileTreeBuildTests: XCTestCase {

    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileTreeBuildTests_\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDown() {
        super.tearDown()
        try? FileManager.default.removeItem(at: tempDir)
    }

    // MARK: - 헬퍼

    @discardableResult
    private func makeFile(_ name: String, in dir: URL? = nil) -> URL {
        let parent = dir ?? tempDir!
        let url = parent.appendingPathComponent(name)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        return url
    }

    @discardableResult
    private func makeDir(_ name: String, in dir: URL? = nil) -> URL {
        let parent = dir ?? tempDir!
        let url = parent.appendingPathComponent(name)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    // MARK: - 기본 구조 반영

    func testListableFilesAreIncluded() {
        makeFile("note.md")
        makeFile("doc.pdf")
        makeFile("photo.png")

        let items = AppState.buildFileTree(at: tempDir, expanded: [])
        let names = items.map { $0.name }
        XCTAssertTrue(names.contains("note.md"), "md 파일이 포함되어야 한다")
        XCTAssertTrue(names.contains("doc.pdf"), "pdf 파일이 포함되어야 한다")
        XCTAssertTrue(names.contains("photo.png"), "png 파일이 포함되어야 한다")
    }

    func testNonListableFilesAreExcluded() {
        makeFile("archive.zip")
        makeFile("sound.mp3")

        let items = AppState.buildFileTree(at: tempDir, expanded: [])
        let names = items.map { $0.name }
        XCTAssertFalse(names.contains("archive.zip"), "zip 파일은 제외되어야 한다")
        XCTAssertFalse(names.contains("sound.mp3"), "mp3 파일은 제외되어야 한다")
    }

    func testDirectoriesAreIncluded() {
        makeDir("SubFolder")

        let items = AppState.buildFileTree(at: tempDir, expanded: [])
        let dirs = items.filter { $0.isDirectory }
        XCTAssertTrue(dirs.map { $0.name }.contains("SubFolder"), "디렉터리가 포함되어야 한다")
    }

    // MARK: - 펼침 동작

    func testUnexpandedFolderHasEmptyChildren() {
        let subDir = makeDir("SubFolder")
        makeFile("child.md", in: subDir)

        let items = AppState.buildFileTree(at: tempDir, expanded: [])
        let folder = items.first { $0.isDirectory }
        XCTAssertNotNil(folder, "디렉터리 항목이 있어야 한다")
        XCTAssertTrue(folder!.children.isEmpty, "펼치지 않은 폴더의 children은 비어있어야 한다")
        XCTAssertFalse(folder!.isExpanded, "펼치지 않은 폴더의 isExpanded는 false여야 한다")
    }

    func testExpandedFolderHasChildren() {
        let subDir = makeDir("SubFolder")
        makeFile("child.md", in: subDir)

        // 1단계: unexpanded 빌드로 contentsOfDirectory가 반환하는 실제 URL 획득.
        // (appendingPathComponent URL과 trailing slash 등 정규화 차이가 있을 수 있으므로
        //  buildFileTree 내부와 동일한 URL 출처를 사용해 비교 일치를 보장한다.)
        let unexpanded = AppState.buildFileTree(at: tempDir, expanded: [])
        guard let folderItem = unexpanded.first(where: { $0.isDirectory }) else {
            XCTFail("디렉터리 항목이 있어야 한다")
            return
        }

        // 2단계: 실제 URL로 expanded 구성 → 자식 채워짐
        let items = AppState.buildFileTree(at: tempDir, expanded: [folderItem.url])
        let folder = items.first { $0.isDirectory }
        XCTAssertNotNil(folder, "디렉터리 항목이 있어야 한다")
        XCTAssertFalse(folder!.children.isEmpty, "펼친 폴더의 children은 비어있지 않아야 한다")
        XCTAssertTrue(folder!.isExpanded, "펼친 폴더의 isExpanded는 true여야 한다")
        XCTAssertTrue(folder!.children.map { $0.name }.contains("child.md"),
                      "펼친 폴더의 children에 자식 파일이 있어야 한다")
    }

    // MARK: - depth 가드

    func testDepthMoreThan10ReturnsEmpty() {
        // depth=10 인자를 직접 넘겨 가드를 검증
        let items = AppState.buildFileTree(at: tempDir, expanded: [], depth: 10)
        XCTAssertTrue(items.isEmpty, "depth 10 이상은 빈 배열을 반환해야 한다")
    }

    func testDepth9IsNotBlocked() {
        makeFile("note.md")
        let items = AppState.buildFileTree(at: tempDir, expanded: [], depth: 9)
        XCTAssertFalse(items.isEmpty, "depth 9는 차단되지 않아야 한다")
    }

    // MARK: - 정렬 (디렉터리 먼저, 이름 오름차순)

    func testDirectoriesComeBeforeFiles() {
        makeFile("aaa.md")
        makeDir("ZZZFolder")

        let items = AppState.buildFileTree(at: tempDir, expanded: [])
        XCTAssertEqual(items.first?.name, "ZZZFolder", "디렉터리가 파일보다 먼저 와야 한다")
    }

    func testItemsAreSortedCaseInsensitive() {
        makeFile("beta.md")
        makeFile("Alpha.md")
        makeFile("gamma.txt")

        let items = AppState.buildFileTree(at: tempDir, expanded: [])
        let names = items.map { $0.name.lowercased() }
        XCTAssertEqual(names, names.sorted(), "항목은 대소문자 무시 오름차순 정렬되어야 한다")
    }

    // MARK: - 존재하지 않는 폴더는 빈 배열

    func testNonexistentFolderReturnsEmpty() {
        let ghost = tempDir.appendingPathComponent("ghost_folder")
        let items = AppState.buildFileTree(at: ghost, expanded: [])
        XCTAssertTrue(items.isEmpty, "존재하지 않는 폴더는 빈 배열을 반환해야 한다")
    }
}
