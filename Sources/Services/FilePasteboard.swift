import AppKit

/// 파일 URL 페이스트보드 헬퍼 — Finder와 양방향 상호운용(.fileURL 공용 타입).
/// 비샌드박스라 writeObjects/readObjects에 장애물 없음(드롭 경로에서 UTType 호환 기검증).
enum FilePasteboard {

    /// 파일 URL들을 페이스트보드에 쓴다(기존 내용 교체) — Finder에서 ⌘V로 받을 수 있다.
    static func write(_ urls: [URL], to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.writeObjects(urls as [NSURL])
    }

    /// 페이스트보드의 파일 URL들을 읽는다(실재 파일만) — Finder에서 ⌘C한 항목 수신.
    static func readFileURLs(from pasteboard: NSPasteboard = .general) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: options),
              let urls = objects as? [URL] else { return [] }
        return urls.filter { FileManager.default.fileExists(atPath: $0.path) }
    }
}
