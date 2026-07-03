import Foundation

/// 파일 작업 실패 — 사용자에게 그대로 보일 한국어 메시지를 가진다.
enum FileOperationError: LocalizedError, Equatable {
    case emptyName
    case invalidName
    case sameName
    case alreadyExists(String)
    case sourceMissing
    case failed(String)
    case invalidDestination(String)

    var errorDescription: String? {
        switch self {
        case .emptyName: return "이름을 입력하세요."
        case .invalidName: return "이름에 '/' 문자를 쓸 수 없습니다."
        case .sameName: return "기존 이름과 같습니다."
        case .alreadyExists(let name): return "같은 위치에 '\(name)'이(가) 이미 있습니다."
        case .sourceMissing: return "원본을 찾을 수 없습니다. 이동되었거나 삭제된 항목일 수 있습니다."
        case .failed(let message): return "작업에 실패했습니다: \(message)"
        case .invalidDestination(let reason): return "이동할 수 없는 위치입니다: \(reason)"
        }
    }
}

/// 단일 항목 파일 작업(F1a·F1b) — FileManager 기반 동기 함수. 영구 삭제 없음(휴지통 이동만).
enum FileOperations {

    /// 같은 디렉터리 안에서 이름을 바꾼다. `newName`은 확장자 포함 전체 파일명.
    /// 대상 이름이 이미 있으면 에러 — 사용자 지정 이름이므로 uniquify하지 않고 덮어쓰지도 않는다.
    static func rename(at url: URL, to newName: String) throws -> URL {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw FileOperationError.emptyName }
        guard !trimmed.contains("/") else { throw FileOperationError.invalidName }
        guard trimmed != url.lastPathComponent else { throw FileOperationError.sameName }

        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { throw FileOperationError.sourceMissing }

        let target = url.deletingLastPathComponent().appendingPathComponent(trimmed)
        // 대소문자 무시 볼륨(APFS 기본)에서 대소문자만 바꾸는 rename은 fileExists가 자기 자신을
        // 가리켜 true가 되므로, 그 경우만 존재 검사를 건너뛴다.
        let isCaseOnlyChange = trimmed.lowercased() == url.lastPathComponent.lowercased()
        guard isCaseOnlyChange || !fm.fileExists(atPath: target.path) else {
            throw FileOperationError.alreadyExists(trimmed)
        }
        do {
            try fm.moveItem(at: url, to: target)
        } catch {
            throw FileOperationError.failed(error.localizedDescription)
        }
        return target
    }

    /// parent 안에 새 폴더를 만든다. 이름이 겹치면 " (1)" 접미로 비켜 간다(uniquified 관례).
    static func createFolder(in parent: URL, name: String = "새 폴더") throws -> URL {
        let target = parent.appendingPathComponent(name).uniquified()
        do {
            try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        } catch {
            throw FileOperationError.failed(error.localizedDescription)
        }
        return target
    }

    /// 휴지통으로 이동하고 휴지통 안의 실제 위치를 반환한다(작업 로그·되돌리기용).
    static func trash(at url: URL) throws -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { throw FileOperationError.sourceMissing }
        var resultURL: NSURL?
        do {
            try fm.trashItem(at: url, resultingItemURL: &resultURL)
        } catch {
            throw FileOperationError.failed(error.localizedDescription)
        }
        guard let trashedURL = resultURL as URL? else {
            throw FileOperationError.failed("휴지통 내 위치를 확인하지 못했습니다.")
        }
        return trashedURL
    }

    /// 다른 폴더로 이동. 충돌 시 uniquify(덮어쓰기 금지). 결과 URL 반환.
    /// 같은 부모로의 이동은 에러 — 허용하면 uniquify가 제자리 이동을 "이름 (1)" 복제 개명으로 만든다.
    static func move(at url: URL, to destinationDir: URL) throws -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { throw FileOperationError.sourceMissing }
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: destinationDir.path, isDirectory: &isDir), isDir.boolValue else {
            throw FileOperationError.invalidDestination("대상 폴더가 없습니다.")
        }
        let srcStd = url.standardizedFileURL.path
        let destStd = destinationDir.standardizedFileURL.path
        guard url.standardizedFileURL.deletingLastPathComponent().path != destStd else {
            throw FileOperationError.invalidDestination("이미 이 폴더에 있습니다.")
        }
        try Self.guardNotIntoSelf(sourcePath: srcStd, destinationPath: destStd, at: url)
        let target = destinationDir.appendingPathComponent(url.lastPathComponent).uniquified()
        do {
            try fm.moveItem(at: url, to: target)
        } catch {
            throw FileOperationError.failed(error.localizedDescription)
        }
        return target
    }

    /// 다른(또는 같은) 폴더로 복사. 같은 폴더면 uniquify가 사본("이름 (1)")을 만든다. 원본 불변.
    static func copy(at url: URL, to destinationDir: URL) throws -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { throw FileOperationError.sourceMissing }
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: destinationDir.path, isDirectory: &isDir), isDir.boolValue else {
            throw FileOperationError.invalidDestination("대상 폴더가 없습니다.")
        }
        try Self.guardNotIntoSelf(sourcePath: url.standardizedFileURL.path,
                                  destinationPath: destinationDir.standardizedFileURL.path, at: url)
        let target = destinationDir.appendingPathComponent(url.lastPathComponent).uniquified()
        do {
            try fm.copyItem(at: url, to: target)
        } catch {
            throw FileOperationError.failed(error.localizedDescription)
        }
        return target
    }

    /// 폴더를 자기 자신/자기 하위로 넣는 요청 차단 — '/' 경계 prefix(형제 폴더 오감지 방지).
    private static func guardNotIntoSelf(sourcePath: String, destinationPath: String, at url: URL) throws {
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
        guard isDirectory else { return }
        if destinationPath == sourcePath || destinationPath.hasPrefix(sourcePath + "/") {
            throw FileOperationError.invalidDestination("폴더를 자기 자신 안으로 넣을 수 없습니다.")
        }
    }
}
