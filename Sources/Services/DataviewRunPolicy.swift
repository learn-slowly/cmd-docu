import Foundation

/// dataviewjs 자동 실행 판정(스펙 §7) — 결정 2: 볼트/등록 폴더 안이면 자동, 밖이면 클릭-투-런.
/// 순수 함수(파일 접근·상태 없음) — 경로 문자열만으로 판정한다.
enum DataviewRunPolicy {

    /// 노트가 볼트/등록 폴더 하위면 true(자동 실행 대상). '/' 경계로 형제 폴더 접두사 오매칭을 막는다.
    static func isAutoRun(notePath: String, vaultPaths: [String], indexedFolders: [String]) -> Bool {
        rootPath(for: notePath, vaultPaths: vaultPaths, indexedFolders: indexedFolders) != nil
    }

    /// 매칭 루트(가장 긴 것). 자동 아니면 nil — 호출자는 노트의 폴더를 루트로 쓴다.
    static func rootPath(for notePath: String, vaultPaths: [String], indexedFolders: [String]) -> String? {
        let note = (notePath as NSString).standardizingPath
        return (vaultPaths + indexedFolders)
            .map { ($0 as NSString).standardizingPath }
            .filter { note == $0 || note.hasPrefix($0 + "/") }
            .max(by: { $0.count < $1.count })
    }
}
