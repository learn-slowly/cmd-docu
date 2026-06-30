import Foundation

/// 정리 목적지 모드. 두 모드 공통으로 root 하위로만 이동한다.
enum CleanupMode: Equatable {
    case subfolder(root: URL)
    case para(vault: Vault)

    var root: URL {
        switch self {
        case .subfolder(let r): return r
        case .para(let v): return v.rootPath
        }
    }

    var label: String {
        switch self {
        case .subfolder(let r): return "하위폴더 정리 — \(r.lastPathComponent)"
        case .para(let v): return "PARA — \(v.displayName)"
        }
    }
}

/// 정리 스킴의 한 폴더(버킷). subfolder 모드는 name==relativePath, PARA 모드는 ParaFolder에서 매핑.
struct CleanupBucket: Identifiable, Equatable, Codable, Hashable {
    var id: String
    var name: String          // 표시·폴더명
    var hint: String          // Claude 분류용 설명
    var relativePath: String  // root 기준 상대경로

    static func from(para: ParaFolder) -> CleanupBucket {
        CleanupBucket(id: para.id.uuidString, name: para.label, hint: para.hint, relativePath: para.folder)
    }
}

typealias CleanupScheme = [CleanupBucket]

/// 폴더 스캔으로 수집한 파일 메타데이터.
struct FileMeta: Equatable {
    let url: URL
    let name: String
    let ext: String
    let size: Int64
    let createdAt: Date
    let modifiedAt: Date
}

/// Claude가 파일을 버킷에 배정한 결과(미분류면 bucketId == "").
struct CleanupAssignment: Equatable {
    let fileURL: URL
    let bucketId: String
    let reason: String
    let confidence: Double
}

/// 미리보기·승인 단위. 목적지 URL은 실행 시 root + bucket에서 해석한다.
struct CleanupMove: Identifiable, Equatable {
    let id: UUID
    let source: URL
    let bucketId: String
    let reason: String
    let confidence: Double
    var approved: Bool
}

struct CleanupPlan: Equatable {
    let scheme: CleanupScheme
    var moves: [CleanupMove]
}

/// undo용 from→to 기록.
struct MoveRecord: Codable, Equatable {
    let from: URL
    let to: URL
}

/// 한 번의 정리 실행(배치). undo 단위.
struct MoveBatch: Codable, Equatable, Identifiable {
    let id: UUID
    let date: Date
    let modeLabel: String
    let records: [MoveRecord]
    let createdDirs: [URL]   // 우리가 생성한 폴더(undo 시 비었으면 제거 후보)
}
