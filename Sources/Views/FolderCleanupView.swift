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
                ProgressView("Claude가 분류 중…")
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
            Button("닫기") { dismiss() }
                .buttonStyle(.borderless)
        }
    }

    // MARK: - 스킴 편집: 버킷 이름·힌트 수정·삭제·추가

    private var schemeEditorView: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("정리 스킴 (편집 가능)")
                .font(.subheadline).bold()

            ForEach(appState.cleanupScheme.indices, id: \.self) { i in
                HStack(spacing: 6) {
                    // 폴더명 — 입력 시 sanitize 후 id·relativePath도 동기화
                    TextField("폴더명", text: Binding(
                        get: { appState.cleanupScheme[i].name },
                        set: { newVal in
                            let clean = CleanupPlanner.sanitizeBucketName(newVal)
                            appState.cleanupScheme[i].name = clean
                            appState.cleanupScheme[i].id = clean
                            appState.cleanupScheme[i].relativePath = clean
                        }
                    ))
                    .frame(minWidth: 120, maxWidth: 200)

                    // 설명(hint)
                    TextField("설명", text: Binding(
                        get: { appState.cleanupScheme[i].hint },
                        set: { appState.cleanupScheme[i].hint = $0 }
                    ))
                    .frame(minWidth: 160)

                    // 버킷 삭제
                    Button(role: .destructive) {
                        appState.cleanupScheme.remove(at: i)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(.borderless)
                }
            }

            // 버킷 추가
            Button("버킷 추가") {
                let name = "새폴더"
                appState.cleanupScheme.append(
                    CleanupBucket(id: name, name: name, hint: "", relativePath: name)
                )
            }
            .padding(.top, 2)
        }
        .padding(.vertical, 4)
    }

    // MARK: - 계획 없음: "정리 계획 만들기" 버튼

    private var planActionsView: some View {
        HStack {
            Button("정리 계획 만들기") {
                Task { await appState.runCleanupPlan() }
            }
            .disabled(appState.cleanupMode == nil || appState.cleanupBusy)
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
