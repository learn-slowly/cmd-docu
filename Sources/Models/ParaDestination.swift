import Foundation

/// Claude PARA 라우팅의 후보 폴더 하나. folder는 PARA 볼트 rootPath 기준 상대 경로.
struct ParaFolder: Identifiable, Equatable, Codable, Hashable {
    let id: UUID
    var label: String   // 표시명
    var folder: String  // 예: "10000_Projects/Living_with_Damage"
    var hint: String    // Claude 분류용 짧은 설명(선택)

    init(id: UUID = UUID(), label: String, folder: String, hint: String = "") {
        self.id = id
        self.label = label
        self.folder = folder
        self.hint = hint
    }
}

extension ParaFolder {
    /// 레고 PARA 구조 시드. vaultId와 무관하게 라벨/경로/힌트만 제공한다.
    static func legoSeed() -> [ParaFolder] {
        [
            ParaFolder(label: "Projects — Living with Damage", folder: "10000_Projects/Living_with_Damage", hint: "피해·치료·회복 관련 진행 프로젝트"),
            ParaFolder(label: "Projects — Build and Deploy",   folder: "10000_Projects/Build_and_Deploy",   hint: "개발·배포·도구 제작 프로젝트"),
            ParaFolder(label: "Projects — Left Forward",       folder: "10000_Projects/Left_Forward",       hint: "정치·운동·조직 활동 프로젝트"),
            ParaFolder(label: "Areas",     folder: "20000_Areas",     hint: "지속 관리하는 역할·책임 영역"),
            ParaFolder(label: "Resources", folder: "30000_Resources", hint: "주제별 참고 자료·지식"),
            ParaFolder(label: "Archive",   folder: "40000_Archive",   hint: "끝났거나 비활성인 항목 보관"),
        ]
    }
}
