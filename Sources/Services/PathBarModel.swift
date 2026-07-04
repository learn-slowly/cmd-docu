import Foundation

// MARK: - PathSegment

/// 경로 바 세그먼트 하나(스펙 §4.1).
/// isWithinRoot = 작업 폴더(루트) 안(루트 자신 포함) — 클릭 시맨틱 분기(§4.3).
struct PathSegment: Equatable {
    let url: URL
    let name: String
    let isWithinRoot: Bool
    let isFile: Bool
}

// MARK: - PathBarModel

/// 경로 바 세그먼트 계산 — 순수 헬퍼(FS 접근 없음).
/// 비교는 standardizedFileURL + '/' 경계 — 기존 SimpleBreadcrumbView의 경계 없는
/// hasPrefix(형제 폴더 오감지) 버그를 제거한 구현(스펙 §4.1, 함정 #5).
enum PathBarModel {

    /// target(파일 또는 폴더)의 조상 체인을 위→아래 순서 세그먼트로 분해한다.
    /// 표시 범위: target이 home 하위면 home("~")부터, 아니면 "/"부터 전부.
    static func segments(target: URL, root: URL?,
                         home: URL = FileManager.default.homeDirectoryForCurrentUser,
                         targetIsFile: Bool) -> [PathSegment] {
        let targetStd = target.standardizedFileURL
        let homePath = home.standardizedFileURL.path
        let rootPath = root?.standardizedFileURL.path

        // target에서 위로 올라가며 수집 후 뒤집는다.
        let stopPath = isWithin(targetStd.path, ancestor: homePath) ? homePath : "/"
        var chain: [URL] = []
        var cursor = targetStd
        while true {
            chain.append(cursor)
            if cursor.path == stopPath || cursor.path == "/" { break }
            cursor = cursor.deletingLastPathComponent()
        }
        chain.reverse()

        return chain.enumerated().map { index, url in
            let isLast = index == chain.count - 1
            let name: String
            if url.path == homePath { name = "~" }
            else if url.path == "/" { name = "/" }
            else { name = url.lastPathComponent }
            return PathSegment(url: url,
                               name: name,
                               isWithinRoot: rootPath.map { isWithin(url.path, ancestor: $0) } ?? false,
                               isFile: isLast && targetIsFile)
        }
    }

    /// path가 ancestor와 같거나 그 하위인가 — '/' 경계 포함.
    static func isWithin(_ path: String, ancestor: String) -> Bool {
        if path == ancestor { return true }
        let prefix = ancestor.hasSuffix("/") ? ancestor : ancestor + "/"
        return path.hasPrefix(prefix)
    }
}
