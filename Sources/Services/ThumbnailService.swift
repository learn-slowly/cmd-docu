import AppKit
import QuickLookThumbnailing

/// 라이브러리 그리드용 썸네일 생성·캐시. QLThumbnailGenerator로 비동기 생성하고
/// NSCache로 재사용한다. 못 만드는 타입은 nil(호출부가 SF 아이콘 폴백). 읽기 전용.
@MainActor
final class ThumbnailService {
    static let shared = ThumbnailService()

    private let cache = NSCache<NSString, NSImage>()

    private init() {}

    /// url의 썸네일(pointSize·scale 기준). 캐시 히트면 즉시, 미스면 생성·캐시.
    /// 실패/미지원/접근불가면 nil.
    func thumbnail(for url: URL, pointSize: CGFloat, scale: CGFloat) async -> NSImage? {
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate?.timeIntervalSince1970 ?? 0
        let key = Self.cacheKey(url: url, pointSize: pointSize, scale: scale, mtime: mtime) as NSString

        if let cached = cache.object(forKey: key) { return cached }

        let request = QLThumbnailGenerator.Request(
            fileAt: url,
            size: CGSize(width: pointSize, height: pointSize),
            scale: scale,
            representationTypes: .thumbnail
        )

        guard let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else {
            return nil
        }
        let image = NSImage(cgImage: rep.cgImage, size: NSSize(width: pointSize, height: pointSize))
        cache.setObject(image, forKey: key)
        return image
    }

    /// 캐시 키(순수). url·크기·scale·mtime 조합 — mtime이 바뀌면(편집) 새 키.
    nonisolated static func cacheKey(url: URL, pointSize: CGFloat, scale: CGFloat, mtime: TimeInterval) -> String {
        "\(url.path)|\(pointSize)|\(scale)|\(mtime)"
    }
}
