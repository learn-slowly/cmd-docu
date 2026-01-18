import SwiftUI

struct SendToVaultSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    
    @State private var selectedVault: Vault?
    @State private var targetFolder: String = "Inbox"
    @State private var action: SendAction = .copy
    @State private var conflictResolution: FileConflictResolution = .rename
    @State private var injectFrontmatter: Bool = true
    @State private var addSourceLink: Bool = false
    @State private var openAfterSend: Bool = false
    @State private var isSending: Bool = false
    @State private var errorMessage: String?
    @State private var availableFolders: [String] = []
    @State private var customFolder: String = ""
    @State private var useCustomFolder: Bool = false
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Send to Vault")
                    .font(.headline)
                Spacer()
                Button("Cancel") {
                    dismiss()
                }
                .buttonStyle(.borderless)
            }
            .padding()
            .background(.bar)
            
            Form {
                Section("Destination") {
                    Picker("Vault", selection: $selectedVault) {
                        Text("Select a vault...").tag(nil as Vault?)
                        ForEach(appState.vaults) { vault in
                            Text(vault.displayName).tag(vault as Vault?)
                        }
                    }
                    .onChange(of: selectedVault) { _, newVault in
                        if let vault = newVault {
                            targetFolder = vault.inboxPath
                            loadFolders(for: vault)
                        }
                    }
                    
                    if !availableFolders.isEmpty {
                        Picker("Folder", selection: $targetFolder) {
                            ForEach(availableFolders, id: \.self) { folder in
                                Text(folder).tag(folder)
                            }
                        }
                    } else {
                        TextField("Folder", text: $targetFolder)
                    }
                }
                
                Section("Options") {
                    Picker("Action", selection: $action) {
                        Text("Copy").tag(SendAction.copy)
                        Text("Move").tag(SendAction.move)
                    }
                    .pickerStyle(.segmented)
                    
                    Picker("If file exists", selection: $conflictResolution) {
                        ForEach(FileConflictResolution.allCases, id: \.self) { resolution in
                            Text(resolution.rawValue).tag(resolution)
                        }
                    }
                    
                    Toggle("Inject frontmatter", isOn: $injectFrontmatter)
                    Toggle("Add source link comment", isOn: $addSourceLink)
                    Toggle("Open in Obsidian after send", isOn: $openAfterSend)
                }
                
                if let document = appState.currentDocument {
                    Section("Preview") {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("File: \(document.displayTitle).md")
                                .font(.callout)
                            
                            if let vault = selectedVault {
                                Text("To: \(vault.displayName)/\(targetFolder)/")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                
                if let error = errorMessage {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.red)
                    }
                }
            }
            .formStyle(.grouped)
            
            HStack {
                Spacer()
                
                Button("Send") {
                    send()
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedVault == nil || isSending)
            }
            .padding()
            .background(.bar)
        }
        .frame(width: 450, height: 500)
        .onAppear {
            if let defaultVaultId = appState.settings.defaultVaultId,
               let vault = appState.vaults.first(where: { $0.id == defaultVaultId }) {
                selectedVault = vault
                targetFolder = vault.inboxPath
                loadFolders(for: vault)
            } else if let firstVault = appState.vaults.first {
                selectedVault = firstVault
                targetFolder = firstVault.inboxPath
                loadFolders(for: firstVault)
            }
        }
    }
    
    private func loadFolders(for vault: Vault) {
        Task {
            let vaultService = VaultService(dataDirectory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("CmdMD"))
            do {
                availableFolders = try await vaultService.listFolders(in: vault)
                if !availableFolders.contains(vault.inboxPath) {
                    availableFolders.insert(vault.inboxPath, at: 0)
                }
            } catch {
                availableFolders = [vault.inboxPath]
            }
        }
    }
    
    private func send() {
        guard let vault = selectedVault else { return }
        
        isSending = true
        errorMessage = nil
        
        Task {
            do {
                var options = SendOptions()
                options.targetVault = vault
                options.targetFolder = targetFolder
                options.action = action
                options.conflictResolution = conflictResolution
                options.injectFrontmatter = injectFrontmatter
                options.addSourceLink = addSourceLink
                options.openAfterSend = openAfterSend
                
                try await appState.sendToVault(options: options)
                
                await MainActor.run {
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isSending = false
                }
            }
        }
    }
}

#Preview {
    SendToVaultSheet()
        .environment(AppState())
}
