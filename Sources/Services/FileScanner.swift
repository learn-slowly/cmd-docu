import Foundation

/// 폴더 1단계(top-level) 파일만 메타데이터로 수집한다. 숨김파일·하위폴더 제외.
enum FileScanner {
    static func scan(_ folder: URL) -> [FileMeta] {
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .creationDateKey, .contentModificationDateKey]
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else { return [] }

        var result: [FileMeta] = []
        for url in items {
            let rv = try? url.resourceValues(forKeys: Set(keys))
            if rv?.isDirectory == true { continue }
            result.append(FileMeta(
                url: url,
                name: url.lastPathComponent,
                ext: url.pathExtension.lowercased(),
                size: Int64(rv?.fileSize ?? 0),
                createdAt: rv?.creationDate ?? Date(),
                modifiedAt: rv?.contentModificationDate ?? Date()
            ))
        }
        return result.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
