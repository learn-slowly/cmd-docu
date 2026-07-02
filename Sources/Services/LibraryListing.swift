import Foundation

// MARK: - LibraryListing

/// 라이브러리 뷰용 폴더 항목 열거 — 순수 헬퍼. 데이터 모델·AppState 불변.
enum LibraryListing {

    /// `folder`의 직속 children(파일+1단계 하위폴더)을 `FileTreeItem` 배열로 반환한다.
    ///
    /// - 숨김 파일(.으로 시작)은 제외한다.
    /// - 하위 폴더는 `isDirectory == true`, 파일은 `isDirectory == false`.
    /// - 파일은 `AppState.isListableInFileTree`를 통과한 것만 포함한다.
    /// - 접근 불가·존재하지 않는 폴더는 빈 배열을 반환한다(크래시 없음).
    /// - 정렬은 호출부에서 `ParaLens.sorted(_:under:)`로 처리한다.
    static func entries(of folder: URL) -> [FileTreeItem] {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var items: [FileTreeItem] = []
        // 같은 폴더 파일명 집합 — 짝꿍 노트 숨김·배지 판별용(추가 FS 호출 없음).
        let siblingNames = Set(contents.map { $0.lastPathComponent })
        for url in contents {
            guard let resourceValues = try? url.resourceValues(forKeys: [.isDirectoryKey]) else { continue }
            let isDirectory = resourceValues.isDirectory ?? false
            if isDirectory {
                items.append(FileTreeItem(url: url, isDirectory: true))
            } else if AppState.isListableInFileTree(url) {
                // 짝꿍 노트는 숨긴다 — 미디어 행이 대표(배지로 존재 표시).
                if CompanionNote.isCompanionNote(url, siblings: siblingNames) { continue }
                let hasNote = DocumentKind(from: url) == .media
                    && siblingNames.contains(CompanionNote.noteURL(for: url).lastPathComponent)
                items.append(FileTreeItem(url: url, isDirectory: false, hasCompanionNote: hasNote))
            }
        }
        return items
    }
}
