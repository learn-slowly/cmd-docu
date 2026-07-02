import Foundation
import AVFoundation

/// 미디어 파일 메타데이터(재생 없이 읽음). 어느 필드든 실패하면 nil — 노트 생성을 차단하지 않는다.
struct MediaMetadata: Equatable {
    var durationSeconds: Double?
    var embeddedTitle: String?
    var format: String
    var createdAt: Date?
}

/// AVFoundation으로 미디어 메타데이터를 읽는다. 원본은 읽기 전용.
enum MediaMetadataService {

    /// 길이·내장 제목(ID3 등)·파일 생성일을 읽는다. 실패한 필드는 nil로 두고 계속 진행.
    static func load(url: URL) async -> MediaMetadata {
        let format = url.pathExtension.lowercased()
        let createdAt = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.creationDate] as? Date

        let asset = AVURLAsset(url: url)

        var durationSeconds: Double?
        if let duration = try? await asset.load(.duration) {
            let seconds = CMTimeGetSeconds(duration)
            if seconds.isFinite && seconds > 0 { durationSeconds = seconds }
        }

        var embeddedTitle: String?
        if let items = try? await asset.load(.commonMetadata),
           let titleItem = AVMetadataItem.metadataItems(from: items,
                                                        filteredByIdentifier: .commonIdentifierTitle).first,
           let title = (try? await titleItem.load(.stringValue)) ?? nil,
           !title.isEmpty {
            embeddedTitle = title
        }

        return MediaMetadata(durationSeconds: durationSeconds, embeddedTitle: embeddedTitle,
                             format: format, createdAt: createdAt)
    }

    /// 초 → "m:ss" 또는 "h:mm:ss". nil·비유한·음수는 "".
    static func formatDuration(_ seconds: Double?) -> String {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return "" }
        let total = Int(seconds.rounded())
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }
}
