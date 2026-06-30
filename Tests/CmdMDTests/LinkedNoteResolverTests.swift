import XCTest
@testable import CmdMD

final class LinkedNoteResolverTests: XCTestCase {
    func testResolvesEncodedFragmentTargetFromVaultRoot() throws {
        let vaultRoot = try makeTemporaryDirectory()
        let notesFolder = vaultRoot.appendingPathComponent("Knowledge")
        try FileManager.default.createDirectory(at: notesFolder, withIntermediateDirectories: true)
        let noteURL = notesFolder.appendingPathComponent("Nested Note.md")
        try "# Nested Note\n".write(to: noteURL, atomically: true, encoding: .utf8)

        let resolver = LinkedNoteResolver(roots: [vaultRoot])

        XCTAssertEqual(
            resolver.resolve("Knowledge/Nested%20Note%23Overview"),
            noteURL.standardizedFileURL
        )
    }

    func testMalformedOrMissingTargetDoesNotResolve() throws {
        let vaultRoot = try makeTemporaryDirectory()
        let resolver = LinkedNoteResolver(roots: [vaultRoot])

        XCTAssertNil(resolver.resolve(""))
        XCTAssertNil(resolver.resolve("   "))
        XCTAssertNil(resolver.resolve("%"))
        XCTAssertNil(resolver.resolve("Missing Note"))
    }

    // 점(.)이 든 노트 이름이 NSString 확장자 처리로 깨지면 안 된다(하위폴더 → findLinkedNote 경로).
    func testResolvesDottedNameInSubfolder() throws {
        let vaultRoot = try makeTemporaryDirectory()
        let sub = vaultRoot.appendingPathComponent("Notes/Deep", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let noteURL = sub.appendingPathComponent("1.1.1_미디어_개념과_특징.md")
        try "x".write(to: noteURL, atomically: true, encoding: .utf8)

        let resolver = LinkedNoteResolver(roots: [vaultRoot])
        XCTAssertEqual(resolver.resolve("1.1.1_미디어_개념과_특징"), noteURL.standardizedFileURL)
    }

    // 점(.)이 든 노트 이름이 루트 직속이면 directCandidate가 .md를 붙여 찾아야 한다.
    func testResolvesDottedNameAtRootViaDirectCandidate() throws {
        let vaultRoot = try makeTemporaryDirectory()
        let noteURL = vaultRoot.appendingPathComponent("1.2.3_release.md")
        try "x".write(to: noteURL, atomically: true, encoding: .utf8)

        let resolver = LinkedNoteResolver(roots: [vaultRoot])
        XCTAssertEqual(resolver.resolve("1.2.3_release"), noteURL.standardizedFileURL)
    }

    // 지원 확장자가 명시된 링크([[Spec.md]])는 그 노트로 해석돼야 한다(회귀 가드).
    func testResolvesNameWithExplicitSupportedExtension() throws {
        let vaultRoot = try makeTemporaryDirectory()
        let noteURL = vaultRoot.appendingPathComponent("Spec.md")
        try "x".write(to: noteURL, atomically: true, encoding: .utf8)

        let resolver = LinkedNoteResolver(roots: [vaultRoot])
        XCTAssertEqual(resolver.resolve("Spec.md"), noteURL.standardizedFileURL)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CmdMDTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }
}
