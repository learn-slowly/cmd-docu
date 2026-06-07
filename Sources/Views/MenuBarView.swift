import SwiftUI

struct MenuBarView: View {
    @Environment(AppState.self) private var appState
    @State private var quickNoteText: String = ""
    @FocusState private var isTextFieldFocused: Bool
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "doc.text")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                
                Text("Quick Capture")
                    .font(.headline)
                
                Spacer()
                
                if !appState.vaults.isEmpty {
                    Menu {
                        ForEach(appState.vaults) { vault in
                            Button(vault.displayName) {
                                saveAndSendToVault(vault)
                            }
                        }
                    } label: {
                        Image(systemName: "paperplane")
                    }
                    .menuStyle(.borderlessButton)
                    .disabled(quickNoteText.isEmpty)
                }
            }
            .padding()
            
            Divider()
            
            TextEditor(text: $quickNoteText)
                .font(.body)
                .scrollContentBackground(.hidden)
                .focused($isTextFieldFocused)
                .frame(height: 150)
                .padding(8)
            
            Divider()
            
            HStack {
                Text("\(quickNoteText.count) characters")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                
                Spacer()
                
                Button("Save as Draft") {
                    saveDraft()
                }
                .buttonStyle(.bordered)
                .disabled(quickNoteText.isEmpty)
                
                Button("Clear") {
                    quickNoteText = ""
                }
                .buttonStyle(.borderless)
            }
            .padding()
        }
        .frame(width: 300)
        .background(.regularMaterial)
        .onAppear {
            isTextFieldFocused = true
        }
    }
    
    private func saveDraft() {
        guard !quickNoteText.isEmpty else { return }
        
        let draft = Draft(
            body: quickNoteText,
            sourceDevice: Host.current().localizedName ?? "Mac"
        )
        
        appState.drafts.insert(draft, at: 0)
        appState.saveUserData()
        appState.showToast("Saved to Drafts")
        quickNoteText = ""
    }
    
    private func saveAndSendToVault(_ vault: Vault) {
        guard !quickNoteText.isEmpty else { return }

        let document = MarkdownDocument(
            title: extractTitle(from: quickNoteText),
            content: quickNoteText,
            isDraft: true
        )

        Task {
            var options = SendOptions()
            options.targetVault = vault
            options.targetFolder = vault.inboxPath
            options.conflictResolution = appState.settings.conflictResolution
            options.injectFrontmatter = appState.settings.injectFrontmatterByDefault

            do {
                // Pass the document explicitly — quick capture has no active tab,
                // so routing through currentDocument would silently drop the note.
                try await appState.sendToVault(document: document, options: options)
                await MainActor.run {
                    quickNoteText = ""
                }
            } catch {
                appState.errorMessage = error.localizedDescription
            }
        }
    }
    
    private func extractTitle(from text: String) -> String {
        let lines = text.components(separatedBy: .newlines)
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("# ") {
                return String(trimmed.dropFirst(2))
            }
        }
        
        if let firstLine = lines.first, !firstLine.isEmpty {
            return String(firstLine.prefix(50))
        }
        
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return "Quick Note \(formatter.string(from: Date()))"
    }
}

#if !SWIFT_PACKAGE
#Preview {
    MenuBarView()
        .environment(AppState())
}
#endif
