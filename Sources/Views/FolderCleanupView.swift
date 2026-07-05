import SwiftUI
import AppKit

/// 폴더 정리 전용 시트: 폴더 선택 → Claude 스킴 제안 → 미리보기/승인 → 실행 → 기록/되돌리기.
struct FolderCleanupView: View {
    // IndexSearchView와 동일한 AppState 주입 형태(@Observable / @Environment)
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerView
            Divider()

            if appState.cleanupBusy {
                ProgressView(appState.cleanupProgress ?? "Claude가 분류 중…")
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }

            if let errMsg = appState.cleanupError {
                Text(errMsg)
                    .foregroundColor(.red)
                    .font(.caption)
                    .padding(.horizontal, 4)
            }

            // 스킴 편집기는 subfolder 모드에서만 표시한다.
            // PARA 모드에서 표시하면 버킷의 name TextField setter가 id·relativePath를 덮어써
            // MoveExecutor가 잘못된 경로로 파일을 이동하는 버그가 생긴다.
            if !appState.cleanupScheme.isEmpty, case .subfolder = appState.cleanupMode {
                schemeEditorView
            }

            if let plan = appState.cleanupPlan {
                planTableView(plan: plan)
            } else {
                planActionsView
            }

            Divider()
            historySectionView
        }
        .padding(16)
        .frame(minWidth: 640, minHeight: 520)
        .task { await appState.loadCleanupBatches() }
    }

    // MARK: - 헤더: 제목 + 폴더 선택 + 닫기

    private var headerView: some View {
        HStack {
            Text(appState.cleanupMode?.label ?? "폴더 정리")
                .font(.headline)
            Spacer()
            Button("폴더 선택…") { pickFolder() }
                .buttonStyle(.borderless)
                .disabled(appState.cleanupBusy)
            Button("닫기") { dismiss() }
                .buttonStyle(.borderless)
        }
    }

    // MARK: - 스킴 편집: 버킷 이름·힌트 수정·삭제·추가

    private var schemeEditorView: some View {
        @Bindable var state = appState

        return VStack(alignment: .leading, spacing: 6) {
            Text("정리 스킴 (편집 가능)")
                .font(.subheadline).bold()

            // 안정 id(요소 바인딩) 기준 ForEach — 인덱스 기준이면 삭제 시 뒤 항목들의
            // 배열 위치가 한 칸씩 당겨지며 id도 함께 바뀌어 삭제 애니메이션이 깨진다.
            // CleanupBucket이 Identifiable이라 요소 바인딩으로 바로 전환 가능.
            ForEach($state.cleanupScheme) { $bucket in
                HStack(spacing: 6) {
                    // 폴더명 — 입력 시 sanitize 후 relativePath만 동기화.
                    // id는 생성 시점 값으로 고정한다(절대 여기서 바꾸지 않는다):
                    // ForEach($state.cleanupScheme)가 id로 행 정체성을 추적하므로,
                    // 키 입력마다 id를 바꾸면 매번 새 행으로 인식돼 백킹 NSTextField가
                    // 파기·재생성되며 포커스를 잃는다(한 글자 치면 포커스가 튐).
                    // MoveExecutor는 id로 버킷을 찾고 목적지는 relativePath로 해석하므로
                    // id 고정이어도 rename된 relativePath로 정확히 이동한다.
                    // 대가: rename 후에도 CleanupPlanner가 Claude에게 보내는 프롬프트
                    // 라벨은 rename 전 이름으로 남는다(hint는 갱신되니 영향은 미미).
                    TextField("폴더명", text: Binding(
                        get: { bucket.name },
                        set: { newVal in
                            let clean = CleanupPlanner.sanitizeBucketName(newVal)
                            bucket.name = clean
                            bucket.relativePath = clean
                        }
                    ))
                    .frame(minWidth: 120, maxWidth: 200)

                    // 설명(hint)
                    TextField("설명", text: $bucket.hint)
                        .frame(minWidth: 160)

                    // 버킷 삭제 — id 기준 제거라 남은 행들의 정체성이 흔들리지 않는다.
                    // 주의: id를 클로저 밖에서 값으로 복사해야 한다. bucket은 $bucket 바인딩 경유라
                    // removeAll(쓰기 접근) 도중 클로저 안에서 bucket.id를 읽으면 같은 cleanupScheme을
                    // 다시 읽어 배타적 접근 위반으로 즉사한다(스모크 실측 크래시, 2026-07-02).
                    Button(role: .destructive) {
                        let removedId = bucket.id
                        withAnimation {
                            state.cleanupScheme.removeAll { $0.id == removedId }
                        }
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                }
            }

            // 버킷 추가 — 기본 이름이 이미 있으면(연속 추가 등) id 충돌을 피해 UUID로 대체.
            // id는 ForEach 정체성이자 CleanupPlanner가 Claude에게 보여주는 라벨이라 반드시
            // 유일해야 한다(중복 시 두 행이 같은 정체성을 공유해 ForEach가 깨진다).
            Button("버킷 추가") {
                let base = "새폴더"
                let existingIds = Set(state.cleanupScheme.map { $0.id })
                let newId = existingIds.contains(base) ? UUID().uuidString : base
                state.cleanupScheme.append(
                    CleanupBucket(id: newId, name: base, hint: "", relativePath: base)
                )
            }
            .padding(.top, 2)
        }
        .padding(.vertical, 4)
    }

    // MARK: - 계획 없음: 2단계 흐름 버튼

    private var planActionsView: some View {
        HStack {
            if appState.cleanupMode != nil && appState.cleanupScheme.isEmpty {
                // 1단계: 스킴 제안 요청(subfolder 모드) 또는 PARA 직접 배정
                Button("스킴 만들기") {
                    Task { await appState.proposeCleanupScheme() }
                }
                .disabled(appState.cleanupBusy)
            } else if !appState.cleanupScheme.isEmpty {
                // 2단계: 스킴 편집 후 배정
                Button("배정하기") {
                    Task { await appState.assignCleanupPlan() }
                }
                .disabled(appState.cleanupBusy)
            }
            Spacer()
        }
        .padding(.vertical, 4)
    }

    // MARK: - 미리보기 표: 소스 → 버킷, 이유, confidence, 승인 체크박스

    private func planTableView(plan: CleanupPlan) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("미리보기 (체크된 것만 이동)")
                .font(.subheadline).bold()

            ScrollView {
                VStack(spacing: 0) {
                    ForEach(plan.moves.indices, id: \.self) { i in
                        HStack(spacing: 8) {
                            // 승인 여부 체크박스 — cleanupPlan이 옵셔널이므로 Binding(get:set:) 사용
                            Toggle("", isOn: Binding(
                                get: { appState.cleanupPlan?.moves[i].approved ?? false },
                                set: { appState.cleanupPlan?.moves[i].approved = $0 }
                            ))
                            .labelsHidden()
                            .disabled(plan.moves[i].bucketId.isEmpty)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(plan.moves[i].source.lastPathComponent)
                                    .lineLimit(1)
                                if plan.moves[i].bucketId.isEmpty {
                                    Text("미분류")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                } else {
                                    Text("→ \(plan.moves[i].bucketId) · \(plan.moves[i].reason)")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                }
                            }

                            Spacer()

                            // confidence — 60% 미만이면 주황색 강조
                            Text(String(format: "%.0f%%", plan.moves[i].confidence * 100))
                                .font(.caption)
                                .foregroundColor(plan.moves[i].confidence < 0.6 ? .orange : .secondary)
                        }
                        .padding(.vertical, 4)
                        .padding(.horizontal, 4)
                        Divider()
                    }
                }
            }
            .frame(maxHeight: 260)

            HStack {
                Button("적용") {
                    Task { await appState.applyCleanup() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(appState.cleanupBusy)

                Button("취소") {
                    appState.cleanupPlan = nil
                }
                .buttonStyle(.borderless)
            }
            .padding(.top, 4)
        }
    }

    // MARK: - 정리 기록 + 되돌리기

    private var historySectionView: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("정리 기록")
                .font(.subheadline).bold()

            if appState.cleanupBatches.isEmpty {
                Text("기록 없음")
                    .font(.caption)
                    .foregroundColor(.secondary)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(appState.cleanupBatches) { batch in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(batch.modeLabel)
                                        .font(.caption)
                                    Text("\(batch.records.count)개 이동 · \(batch.date.formatted())")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                                Spacer()
                                Button("되돌리기") {
                                    Task { await appState.undoCleanupBatch(batch) }
                                }
                                .controlSize(.small)
                            }
                            .padding(.vertical, 4)
                            Divider()
                        }
                    }
                }
                .frame(maxHeight: 140)
            }
        }
    }

    // MARK: - 폴더 선택 패널

    private func pickFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            appState.startCleanup(folder: url)
        }
    }
}
