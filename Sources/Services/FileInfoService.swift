import Foundation
import ImageIO
import PDFKit

/// 정보 시트(⌥⌘I)에 보여줄 기본 정보 — 동기 1회 조회분.
struct FileInfo: Equatable {
    let name: String
    let isDirectory: Bool
    let kindLabel: String       // 한국어 종류 라벨
    let sizeBytes: Int64?       // 파일만. 폴더는 nil(시트에서 비동기 계산)
    let locationPath: String    // 부모 폴더 경로
    let createdAt: Date?
    let modifiedAt: Date?
}

/// 파일/폴더 정보 조회 — 기본 필드는 동기 1회, 종류별 한 줄·폴더 크기는 비동기.
enum FileInfoService {

    /// 기본 필드 일괄 조회(URLResourceValues 1회).
    static func loadBasic(url: URL) -> FileInfo {
        let values = try? url.resourceValues(forKeys: [
            .isDirectoryKey, .fileSizeKey, .creationDateKey, .contentModificationDateKey,
        ])
        let isDirectory = values?.isDirectory ?? false
        return FileInfo(
            name: url.lastPathComponent,
            isDirectory: isDirectory,
            kindLabel: kindLabel(for: url, isDirectory: isDirectory),
            sizeBytes: isDirectory ? nil : values?.fileSize.map(Int64.init),
            locationPath: url.deletingLastPathComponent().path,
            createdAt: values?.creationDate,
            modifiedAt: values?.contentModificationDate
        )
    }

    /// 종류 라벨 — DocumentKind 기반 한국어(+대문자 확장자). DocumentKind 모델은 건드리지 않는다.
    static func kindLabel(for url: URL, isDirectory: Bool) -> String {
        if isDirectory { return "폴더" }
        let ext = url.pathExtension.uppercased()
        switch DocumentKind(from: url) {
        case .markdown: return ext.isEmpty ? "텍스트 문서" : "\(ext) 문서"
        case .image: return "\(ext) 이미지"
        case .pdf: return "PDF 문서"
        case .office: return "\(ext) 오피스 문서"
        case .media: return DocumentKind.isVideo(url) ? "\(ext) 동영상" : "\(ext) 오디오"
        }
    }

    /// 종류별 한 줄: 이미지=해상도(헤더만), PDF=페이지 수, 미디어=길이, 폴더=직속 항목 수.
    /// 실패하면 nil — 나머지 정보 표시는 계속(MediaMetadata 관례).
    static func loadDetail(url: URL, isDirectory: Bool) async -> String? {
        if isDirectory {
            let count = (try? FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]))?.count
            return count.map { "항목 \($0)개" }
        }
        switch DocumentKind(from: url) {
        case .image:
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = props[kCGImagePropertyPixelWidth] as? Int,
                  let height = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
            return "\(width) × \(height)"
        case .pdf:
            guard let document = PDFDocument(url: url) else { return nil }
            return "\(document.pageCount)페이지"
        case .media:
            let metadata = await MediaMetadataService.load(url: url)
            let duration = MediaMetadataService.formatDuration(metadata.durationSeconds)
            return duration.isEmpty ? nil : "길이 \(duration)"
        case .markdown, .office:
            return nil
        }
    }

    /// 폴더 크기 재귀 합산. 취소 지원 — 시트가 닫히면(.task 취소) CancellationError로 중단.
    /// fileSize(논리 크기) 우선 — 파일 행 표기와 단위를 맞춘다(스펙 §7.1).
    static func computeFolderSize(url: URL) async throws -> Int64 {
        try Task.checkCancellation()
        return try sumRegularFileSizes(under: url)
    }

    /// 동기 열거 헬퍼 — DirectoryEnumerator 순회(makeIterator)는 async 컨텍스트에서
    /// 사용 불가(Swift 6 에러 예정)라 동기 함수로 분리한다. Task.checkCancellation은
    /// 동기 코드에서도 현재 태스크의 취소를 읽으므로 취소 시맨틱은 유지된다.
    private static func sumRegularFileSizes(under url: URL) throws -> Int64 {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: url, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles]
        ) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            try Task.checkCancellation()
            guard let values = try? fileURL.resourceValues(forKeys: keys),
                  values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? values.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    /// 사람이 읽는 크기 문자열(ByteCountFormatter .file — Finder와 같은 표기).
    static func formatSize(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
