import SwiftUI

/// 다중 문서 인제스트 시트(일괄 처리) — 문서별 자동 배치 병합·독립 diff 승인 큐
/// (스펙 docs/superpowers/specs/2026-07-07-wiki-batch-ingest-design.md).
/// 단일 시트의 상태(wikiMergeProposal/wikiIngestError/wikiIngestBusy)·API를 그대로 쓴다 —
/// 배치 전용 상태는 큐(@State)와 request뿐. 두 시트는 동시에 열리지 않는다.
struct WikiBatchIngestView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    let request: WikiBatchIngestRequest

    @State private var queue: WikiBatchQueue
    @State private var started = false
    @State private var applying = false     // 적용 이중 클릭(중복 기록) 방지 — 단일 시트 관례
    @State private var diffLines: [LineDiff.Line] = []

    init(request: WikiBatchIngestRequest) {
        self.request = request
        _queue = State(initialValue: WikiBatchQueue(files: request.files))
    }

    private var wikiFolderURL: URL? {
        appState.settings.wikiFolder.map { URL(fileURLWithPath: $0) }
    }

    private var rulesReady: Bool {
        appState.settings.wikiRulesSummary?
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    /// 현재 문서의 제안만 신뢰 — 이전 문서 제안 잔상·단일 시트 잔재 방지.
    private var currentProposal: WikiMergeProposal? {
        guard let current = queue.current,
              let proposal = appState.wikiMergeProposal,
              proposal.sourceURL == current else { return nil }
        return proposal
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("위키에 일괄 인제스트 \(queue.progressLabel)").font(.headline)

            if wikiFolderURL == nil {
                Text("위키 폴더가 설정되지 않았습니다 — 설정 > Wiki 탭에서 지정하세요.")
                    .foregroundStyle(.secondary)
            } else if !rulesReady {
                Text("일괄 인제스트는 자동 배치(규칙에 따름) 기반입니다 — 설정 > Wiki 탭에서 " +
                     "먼저 위키 규칙을 파악하세요.")
                    .foregroundStyle(.secondary)
            } else if !started {
                startSection
            } else if queue.isDone {
                summarySection
            } else {
                currentSection
            }

            Spacer(minLength: 0)
            HStack {
                Spacer()
                Button(started && !queue.isDone ? "중단하고 닫기" : "닫기") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(minWidth: 640, minHeight: 520)
        .onChange(of: appState.wikiMergeProposal) { _, _ in
            diffLines = currentProposal.map { LineDiff.diff(old: $0.oldBody, new: $0.newBody) } ?? []
        }
        .onDisappear {
            // 시트가 닫히면 제안을 표시할 곳이 없다 — 진행 중 병합을 중단(단일 시트 관례).
            appState.cancelWikiMerge()
        }
    }

    // MARK: - 구획

    /// 시작 전 — 대상 파일 목록 확인(제안→확인→실행: 시작도 명시적 클릭).
    private var startSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("각 파일을 위키 규칙에 따라 각자 페이지로 인제스트합니다. " +
                 "문서마다 미리보기를 승인해야 적용됩니다.")
                .foregroundStyle(.secondary).font(.callout)
            List(queue.files, id: \.self) { url in
                Label(url.lastPathComponent, systemImage: "doc")
            }
            .frame(minHeight: 160, maxHeight: 280)
            Button("일괄 인제스트 시작") {
                started = true
                startCurrent()
            }
            .keyboardShortcut(.defaultAction)
        }
    }

    private var currentSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let current = queue.current {
                Label(current.lastPathComponent, systemImage: "doc")
                    .foregroundStyle(.secondary)
            }
            if appState.wikiIngestBusy {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Claude가 병합 중… (페이지 전문을 다시 쓰므로 몇 분 걸릴 수 있습니다)")
                        .foregroundStyle(.secondary).font(.callout)
                    Button("중단") { abortAll() }.font(.callout)
                }
            }
            if let error = appState.wikiIngestError {
                Text(error).foregroundStyle(.red).font(.callout)
            }

            if let proposal = currentProposal {
                Text("새 페이지: \(relativeDisplayPath(proposal.pageURL))")
                    .font(.subheadline).bold()
                WikiDiffListView(lines: diffLines)
                HStack {
                    // 적용 in-flight(applying) 동안 형제 버튼도 잠근다 — 적용이 recordApply
                    // actor 홉에서 MainActor를 양보하는 창에 [건너뛰기]/[중단]이 눌리면 큐 인덱스가
                    // 어긋나 재개된 적용이 엉뚱한 슬롯에 기록되고 문서가 조용히 누락된다(리뷰 확증).
                    Button("건너뛰기") { advance(.skipped) }
                        .disabled(applying)
                    Button("적용 후 다음") { applyCurrent(proposal) }
                        .keyboardShortcut(.defaultAction)
                        .disabled(appState.wikiIngestBusy || applying)
                    Button("중단") { abortAll() }
                        .disabled(applying)
                }
            } else if !appState.wikiIngestBusy, let error = appState.wikiIngestError {
                // 생성 실패 — 문서 단위로 재시도/실패 처리하고 큐는 계속 간다.
                HStack {
                    Button("다시 시도") { startCurrent() }
                    Button("이 문서는 실패로 두고 다음") { advance(.failed(error)) }
                    Button("중단") { abortAll() }
                }
            }
        }
    }

    private var summarySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("완료 — 적용 \(queue.appliedCount) · 건너뜀 \(queue.skippedCount) · " +
                 "실패 \(queue.failedCount) · 미처리 \(queue.unprocessedCount)")
                .font(.subheadline).bold()
            if !queue.appliedPages.isEmpty {
                List(queue.appliedPages, id: \.self) { url in
                    HStack {
                        Label(relativeDisplayPath(url), systemImage: "doc.badge.plus")
                        Spacer()
                        Button("열기") {
                            appState.openDocument(at: url, inNewTab: true)
                        }
                        .font(.caption)
                    }
                }
                .frame(minHeight: 120, maxHeight: 260)
            }
        }
    }

    // MARK: - 큐 구동

    private func startCurrent() {
        guard let current = queue.current else { return }
        appState.startWikiMerge(source: current, target: .auto)
    }

    private func applyCurrent(_ proposal: WikiMergeProposal) {
        guard !applying else { return }
        applying = true
        let indexAtStart = queue.currentIndex   // 재개 시 큐가 그대로인지 확인용(이중 방어).
        Task {
            let dest = await appState.applyWikiMerge(proposal)
            // 버튼 비활성이 클릭 경로를 닫지만, await 사이 큐가 움직였다면(방어) 재기록하지 않는다.
            if let dest, queue.currentIndex == indexAtStart {
                advance(.applied(dest))
            }
            // 실패 시 wikiIngestError가 표시되고 제안은 남는다 — 재적용/건너뛰기/중단 선택 가능.
            applying = false
        }
    }

    /// 현재 문서 결과 기록 → 공유 상태 클리어 → 다음 문서 자동 시작.
    private func advance(_ outcome: WikiBatchQueue.Outcome) {
        queue.advance(with: outcome)
        appState.wikiMergeProposal = nil
        appState.wikiIngestError = nil
        if !queue.isDone { startCurrent() }
    }

    private func abortAll() {
        appState.cancelWikiMerge()
        appState.wikiMergeProposal = nil
        appState.wikiIngestError = nil
        queue.abort()
    }

    /// 위키 루트 기준 상대경로 표시(WikiIngestView와 동일 규칙). 루트 밖이면 파일명만.
    private func relativeDisplayPath(_ url: URL) -> String {
        guard let root = wikiFolderURL else { return url.lastPathComponent }
        let rootPath = root.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        return path.hasPrefix(rootPath) ? String(path.dropFirst(rootPath.count)) : url.lastPathComponent
    }
}
