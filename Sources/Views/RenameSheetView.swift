import SwiftUI

/// 이름 변경 시트 — 현재 이름 프리필, Return 확정, Esc 취소, 에러 인라인 표시.
struct RenameSheetView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    let request: RenameRequest

    @State private var newName: String = ""
    @State private var errorText: String?
    @FocusState private var nameFieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("이름 변경").font(.headline)
            TextField("새 이름", text: $newName)
                .textFieldStyle(.roundedBorder)
                .focused($nameFieldFocused)
                .onSubmit { confirm() }
                .frame(width: 320)
            if let errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("취소") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("이름 변경") { confirm() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .onAppear {
            newName = request.url.lastPathComponent
            nameFieldFocused = true
        }
    }

    private func confirm() {
        Task { @MainActor in
            do {
                try await appState.performRename(at: request.url, to: newName)
                dismiss()
            } catch {
                errorText = (error as? FileOperationError)?.errorDescription
                    ?? error.localizedDescription
            }
        }
    }
}
