import AppKit
import UniformTypeIdentifiers

/// 파일 연결(기본 앱 등록) 대상 형식 그룹. 확장자 출처는 DocumentKind 상수(이중 정의 금지,
/// 정합은 FileAssociationGroupTests가 고정). UI 표시 순서·대표 확장자(첫 원소) 규칙 때문에 배열로 둔다.
struct FileTypeGroup: Identifiable, Equatable {
    let id: String
    let name: String
    let extensions: [String]

    /// 현재 기본 앱 표시에 쓰는 대표 확장자(첫 원소).
    var representativeExtension: String { extensions[0] }

    static let all: [FileTypeGroup] = [
        FileTypeGroup(id: "hangul", name: "한글 문서", extensions: ["hwp", "hwpx", "hwpml"]),
        FileTypeGroup(id: "office", name: "오피스 문서", extensions: ["doc", "docx", "xls", "xlsx"]),
        FileTypeGroup(id: "markdown", name: "마크다운·텍스트", extensions: ["md", "markdown", "mdown", "txt"]),
        FileTypeGroup(id: "pdf", name: "PDF", extensions: ["pdf"]),
        FileTypeGroup(id: "image", name: "이미지", extensions: ["png", "jpg", "jpeg", "heic", "webp", "gif"]),
        FileTypeGroup(id: "media", name: "미디어", extensions: ["mp3", "m4a", "aac", "wav", "aiff", "flac", "mp4", "mov", "m4v"]),
    ]
}

enum FileAssociationError: Error, Equatable {
    /// swift run 등 .app 번들 밖 실행 — Launch Services 등록 불가.
    case notPackagedApp
    /// 일부 확장자 등록 실패(UTType 획득 실패 포함).
    case partialFailure(failed: [String])
}

/// macOS 기본 앱 등록(NSWorkspace) 래퍼. UI에서만 소비하므로 MainActor로 단순화.
/// hwp 계열처럼 시스템 선언이 없는 확장자는 UTType(filenameExtension:)이 동적 타입(dyn.*)을
/// 돌려주는데, Launch Services는 동적 타입에도 기본 핸들러를 기록한다 — 설치 앱 수동 스모크로 실측(스펙 §5).
@MainActor
enum FileAssociationService {
    /// 패키징된 .app에서 실행 중일 때만 그 번들 URL(아니면 nil — swift run 가드).
    static var appBundleURL: URL? {
        let url = Bundle.main.bundleURL
        return url.pathExtension == "app" ? url : nil
    }

    /// 그룹 대표 확장자의 현재 기본 앱 이름(연결된 앱이 없으면 nil).
    static func currentDefaultAppName(for group: FileTypeGroup) -> String? {
        guard let type = UTType(filenameExtension: group.representativeExtension),
              let appURL = NSWorkspace.shared.urlForApplication(toOpen: type) else { return nil }
        return FileManager.default.displayName(atPath: appURL.path)
    }

    /// 그룹 내 모든 확장자의 기본 앱을 이 앱으로 등록. 실패 확장자를 모아 부분 실패로 보고한다.
    static func setAsDefault(group: FileTypeGroup) async -> Result<Void, FileAssociationError> {
        guard let bundleURL = appBundleURL else { return .failure(.notPackagedApp) }
        var failed: [String] = []
        for ext in group.extensions {
            guard let type = UTType(filenameExtension: ext) else {
                failed.append(ext)
                continue
            }
            do {
                try await NSWorkspace.shared.setDefaultApplication(at: bundleURL, toOpen: type)
            } catch {
                failed.append(ext)
            }
        }
        return failed.isEmpty ? .success(()) : .failure(.partialFailure(failed: failed))
    }
}
