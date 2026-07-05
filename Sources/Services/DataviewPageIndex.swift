import Foundation

/// 페이지 메타 공급자 — 폴더 재귀 열거 + 파일별 mtime 캐시.
/// JSContext의 동기 브릿지에서 불리므로 actor가 아니라 NSLock으로 지킨다(스펙 §5 정정).
final class DataviewPageIndex {
    private let root: URL
    private let lock = NSLock()
    private var cache: [String: (mtime: Double, meta: DataviewPageMeta)] = [:]

    private static let registryLock = NSLock()
    private static var registry: [String: DataviewPageIndex] = [:]

    init(root: URL) { self.root = root.standardizedFileURL }

    /// 루트별 공유 인스턴스 — mtime 캐시가 렌더를 넘어 살아남는다.
    static func shared(for root: URL) -> DataviewPageIndex {
        let key = root.standardizedFileURL.path
        registryLock.lock(); defer { registryLock.unlock() }
        if let existing = registry[key] { return existing }
        let created = DataviewPageIndex(root: root)
        registry[key] = created
        return created
    }

    func allPages() -> [DataviewPageMeta] {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys:
            [.contentModificationDateKey, .creationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]) else { return [] }
        var result: [DataviewPageMeta] = []
        for case let url as URL in enumerator {
            let ext = url.pathExtension.lowercased()
            guard ext == "md" || ext == "markdown" else { continue }
            if let meta = meta(forFileURL: url) { result.append(meta) }
        }
        return result.sorted { $0.path < $1.path }
    }

    func pages(inFolder relativeFolder: String) -> [DataviewPageMeta] {
        let prefix = relativeFolder.hasSuffix("/") ? relativeFolder : relativeFolder + "/"
        return allPages().filter { $0.path.hasPrefix(prefix) || $0.folder == relativeFolder }
    }

    func pages(withTag tag: String) -> [DataviewPageMeta] {
        let normalized = tag.hasPrefix("#") ? tag : "#\(tag)"
        return allPages().filter { $0.tags.contains(normalized) }
    }

    func page(at pathOrName: String) -> DataviewPageMeta? {
        let all = allPages()
        if let exact = all.first(where: { $0.path == pathOrName }) { return exact }
        if let noExt = all.first(where: { ($0.path as NSString).deletingPathExtension == pathOrName }) { return noExt }
        return all.first(where: { $0.name == pathOrName })
    }

    func meta(forFileURL url: URL) -> DataviewPageMeta? {
        let std = url.standardizedFileURL
        let rootPath = root.path
        guard std.path == rootPath || std.path.hasPrefix(rootPath + "/") else {
            return parseUncached(std, relativePath: std.lastPathComponent)   // 루트 밖(클릭-투-런 현재 파일)
        }
        let rel = String(std.path.dropFirst(rootPath.count + 1))
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: std.path),
              let mdate = attrs[.modificationDate] as? Date else { return nil }
        let mtime = mdate.timeIntervalSince1970 * 1000

        lock.lock()
        if let cached = cache[rel], cached.mtime == mtime { lock.unlock(); return cached.meta }
        lock.unlock()

        guard let meta = parseUncached(std, relativePath: rel, mtimeMs: mtime,
                                       ctimeMs: ((attrs[.creationDate] as? Date)?.timeIntervalSince1970 ?? 0) * 1000)
        else { return nil }
        lock.lock(); cache[rel] = (mtime, meta); lock.unlock()
        return meta
    }

    private func parseUncached(_ url: URL, relativePath: String,
                               mtimeMs: Double = 0, ctimeMs: Double = 0) -> DataviewPageMeta? {
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return nil }   // 깨진 파일은 건너뜀(스펙 §8)
        let name = url.deletingPathExtension().lastPathComponent
        let folder = (relativePath as NSString).deletingLastPathComponent
        return DataviewPageMeta.parse(content: content, name: name, folder: folder,
                                      path: relativePath, mtime: mtimeMs, ctime: ctimeMs)
    }
}
