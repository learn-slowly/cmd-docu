import Foundation

/// 다중 문서 인제스트 큐(순수) — 문서별 독립 병합·승인·백업 진행 상태만 담는다
/// (스펙 docs/superpowers/specs/2026-07-07-wiki-batch-ingest-design.md).
struct WikiBatchQueue: Equatable {
    enum Outcome: Equatable {
        case applied(URL)      // 적용됨 — 실제 쓴 페이지 URL(재uniquify 반영)
        case skipped           // 사용자가 건너뜀
        case failed(String)    // 생성/적용 실패를 안고 다음으로 넘어감(사유)
    }

    let files: [URL]
    private(set) var outcomes: [Outcome?]
    private(set) var currentIndex: Int = 0

    init(files: [URL]) {
        self.files = files
        self.outcomes = Array(repeating: nil, count: files.count)
    }

    var current: URL? { currentIndex < files.count ? files[currentIndex] : nil }
    var isDone: Bool { currentIndex >= files.count }

    /// 진행 라벨 "(i/n)" — 끝나면 (n/n), 빈 큐는 (0/0).
    var progressLabel: String {
        files.isEmpty ? "(0/0)" : "(\(min(currentIndex + 1, files.count))/\(files.count))"
    }

    /// 현재 문서의 결과를 기록하고 다음으로. 끝 이후 호출은 무동작.
    mutating func advance(with outcome: Outcome) {
        guard currentIndex < files.count else { return }
        outcomes[currentIndex] = outcome
        currentIndex += 1
    }

    /// 중단 — 남은 항목은 미처리(nil)로 두고 끝으로 이동.
    mutating func abort() { currentIndex = files.count }

    /// 적용된 페이지 목록(순서 보존) — 요약 화면 "열기"용.
    var appliedPages: [URL] {
        outcomes.compactMap {
            if case .applied(let url) = $0 { return url }
            return nil
        }
    }

    var appliedCount: Int { appliedPages.count }
    var skippedCount: Int { outcomes.filter { $0 == .skipped }.count }
    var failedCount: Int {
        outcomes.compactMap { $0 }.filter {
            if case .failed = $0 { return true }
            return false
        }.count
    }
    var unprocessedCount: Int { outcomes.filter { $0 == nil }.count }
}

/// 일괄 인제스트 시트 요청 — .sheet(item:) 배선용(WikiIngestRequest 패턴).
struct WikiBatchIngestRequest: Identifiable {
    let id = UUID()
    let files: [URL]
}
