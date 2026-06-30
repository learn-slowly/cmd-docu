import Foundation

/// 폴더를 워킹하며 변경분만 (재)인덱싱하고 사라진 파일을 인덱스에서 제거한다.
/// 인덱싱은 읽기 전용 — 원본 파일을 건드리지 않는다.
actor SearchIndexer {
    private let index: SearchIndex
    private let kordoc: KordocService

    init(index: SearchIndex, kordoc: KordocService) {
        self.index = index
        self.kordoc = kordoc
    }

    /// URL을 정규 경로로 변환한다(예: /var → /private/var).
    /// 파일이 없으면 부모 디렉터리를 기준으로 해소한다.
    /// Task 6(AppState 배선)에서 등록 폴더 경로를 동일 방식으로 정규화할 수 있도록 static으로 공개.
    static func canonicalURL(_ url: URL) -> URL {
        // 존재하는 경우 직접 canonicalPath를 얻는다.
        if let c = try? url.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath {
            return URL(fileURLWithPath: c, isDirectory: false)
        }
        // 삭제된 파일처럼 존재하지 않는 경우 부모 기준으로 해소한다.
        let parent = url.deletingLastPathComponent()
        if let pc = try? parent.resourceValues(forKeys: [.canonicalPathKey]).canonicalPath {
            return URL(fileURLWithPath: pc, isDirectory: true)
                .appendingPathComponent(url.lastPathComponent)
        }
        return url  // 폴백: 원본 그대로
    }

    func indexFolder(_ folder: URL, progress: ((Int, Int) -> Void)?) async {
        // 폴더의 정규 경로를 구한다. enumerator도 동일 정규 경로를 반환하므로
        // indexedPaths prefix와 일치한다.
        let canonicalFolder = Self.canonicalURL(folder)
        let fm = FileManager.default
        guard let en = fm.enumerator(at: canonicalFolder,
                                     includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                                     options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return }
        let urls = en.allObjects.compactMap { $0 as? URL }.filter { AppState.isListableInFileTree($0) }
        let total = urls.count
        var done = 0
        var seen = Set<String>()
        for url in urls {
            seen.insert(url.path)
            let mtime = ((try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? Date()).timeIntervalSince1970
            if await index.needsIndex(path: url.path, mtime: mtime) {
                let body = await ContentExtractor.body(for: url, kordoc: kordoc) ?? ""
                await index.upsert(path: url.path, filename: url.lastPathComponent,
                                   body: body, mtime: mtime, ext: url.pathExtension.lowercased())
            }
            done += 1
            progress?(done, total)
        }
        // 인덱스에는 있으나 디스크에서 사라진 파일 제거.
        for indexed in await index.indexedPaths(under: canonicalFolder.path) where !seen.contains(indexed) {
            await index.remove(path: indexed)
        }
    }

    /// 단일 경로 (재)인덱싱. 파일이 없으면 인덱스에서 제거.
    func reindex(path: String) async {
        // 정규 경로로 변환(예: /var → /private/var). 파일이 없어도 부모 기준 해소.
        let canonicalURL = Self.canonicalURL(URL(fileURLWithPath: path))
        let canonicalPath = canonicalURL.path
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: canonicalPath, isDirectory: &isDir), !isDir.boolValue,
              AppState.isListableInFileTree(canonicalURL) else {
            await index.remove(path: canonicalPath)
            return
        }
        let mtime = ((try? canonicalURL.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? Date()).timeIntervalSince1970
        guard await index.needsIndex(path: canonicalPath, mtime: mtime) else { return }
        let body = await ContentExtractor.body(for: canonicalURL, kordoc: kordoc) ?? ""
        await index.upsert(path: canonicalPath, filename: canonicalURL.lastPathComponent,
                           body: body, mtime: mtime, ext: canonicalURL.pathExtension.lowercased())
    }
}
