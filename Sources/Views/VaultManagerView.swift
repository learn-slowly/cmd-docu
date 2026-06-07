import SwiftUI

struct VaultManagerView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    
    @State private var selectedVault: Vault?
    @State private var isAddingVault: Bool = false
    
    var body: some View {
        NavigationSplitView {
            List(selection: $selectedVault) {
                ForEach(appState.vaults) { vault in
                    VaultListRow(vault: vault)
                        .tag(vault)
                }
                .onDelete { indexSet in
                    for index in indexSet {
                        appState.removeVault(appState.vaults[index])
                    }
                }
            }
            .navigationTitle("Vaults")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isAddingVault = true
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .frame(minWidth: 200)
        } detail: {
            if let vault = selectedVault {
                VaultDetailView(vault: vault)
            } else {
                ContentUnavailableView("Select a Vault", systemImage: "folder", description: Text("Choose a vault from the sidebar or add a new one"))
            }
        }
        .frame(width: 700, height: 500)
        .sheet(isPresented: $isAddingVault) {
            AddVaultSheet()
        }
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Done") {
                    dismiss()
                }
            }
        }
    }
}

struct VaultListRow: View {
    let vault: Vault
    
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(vault.displayName)
                    .font(.headline)
                
                if vault.isDefault {
                    Image(systemName: "star.fill")
                        .font(.caption)
                        .foregroundStyle(.yellow)
                }
            }
            
            Text(vault.rootPath.lastPathComponent)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

struct VaultDetailView: View {
    @Environment(AppState.self) private var appState
    let vault: Vault
    
    @State private var editedName: String = ""
    @State private var editedInboxPath: String = ""
    @State private var isDefault: Bool = false
    
    var body: some View {
        Form {
            Section("General") {
                TextField("Name", text: $editedName)
                
                LabeledContent("Path") {
                    Text(vault.rootPath.path)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                
                Toggle("Default Vault", isOn: $isDefault)
                    .onChange(of: isDefault) { _, newValue in
                        if newValue {
                            appState.settings.defaultVaultId = vault.id
                            appState.saveUserData()
                        } else if appState.settings.defaultVaultId == vault.id {
                            appState.settings.defaultVaultId = nil
                            appState.saveUserData()
                        }
                    }
            }
            
            Section("Inbox") {
                TextField("Inbox Folder", text: $editedInboxPath)
                    .help("The default folder where files will be sent")
            }
            
            Section("Info") {
                LabeledContent("Created") {
                    Text(vault.createdAt.formatted(.dateTime))
                }
                
                LabeledContent("ID") {
                    Text(vault.id.uuidString)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                }
            }
            
            Section {
                Button("Open in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([vault.rootPath])
                }
                
                Button("Open in Obsidian") {
                    openInObsidian()
                }
                
                Button("Remove Vault", role: .destructive) {
                    appState.removeVault(vault)
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(vault.displayName)
        .onAppear {
            editedName = vault.name
            editedInboxPath = vault.inboxPath
            isDefault = appState.settings.defaultVaultId == vault.id
        }
        .onChange(of: editedName) { _, _ in saveChanges() }
        .onChange(of: editedInboxPath) { _, _ in saveChanges() }
    }
    
    private func saveChanges() {
        if let index = appState.vaults.firstIndex(where: { $0.id == vault.id }) {
            var updated = appState.vaults[index]
            updated.name = editedName
            updated.inboxPath = editedInboxPath
            appState.vaults[index] = updated
            appState.saveUserData()
        }
    }
    
    private func openInObsidian() {
        var components = URLComponents(string: "obsidian://open")!
        components.queryItems = [
            URLQueryItem(name: "vault", value: vault.name.isEmpty ? vault.rootPath.lastPathComponent : vault.name)
        ]
        if let url = components.url {
            NSWorkspace.shared.open(url)
        }
    }
}

struct AddVaultSheet: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    
    @State private var name: String = ""
    @State private var selectedURL: URL?
    @State private var inboxPath: String = "Inbox"
    @State private var isDefault: Bool = false
    @State private var errorMessage: String?
    @State private var isAdding: Bool = false
    
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Add Vault")
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
                Section("Vault Folder") {
                    HStack {
                        if let url = selectedURL {
                            VStack(alignment: .leading) {
                                Text(url.lastPathComponent)
                                    .font(.headline)
                                Text(url.path)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            Text("No folder selected")
                                .foregroundStyle(.secondary)
                        }
                        
                        Spacer()
                        
                        Button("Choose...") {
                            selectFolder()
                        }
                    }
                }
                
                Section("Settings") {
                    TextField("Name (optional)", text: $name)
                        .help("Leave empty to use folder name")
                    
                    TextField("Inbox Folder", text: $inboxPath)
                        .help("Default folder for incoming files")
                    
                    Toggle("Set as default vault", isOn: $isDefault)
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
                
                Button("Add Vault") {
                    addVault()
                }
                .buttonStyle(.borderedProminent)
                .disabled(selectedURL == nil || isAdding)
            }
            .padding()
            .background(.bar)
        }
        .frame(width: 450, height: 350)
    }
    
    private func selectFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select your Obsidian vault folder"
        panel.prompt = "Select"
        
        if panel.runModal() == .OK {
            selectedURL = panel.url
            if name.isEmpty, let url = panel.url {
                name = url.lastPathComponent
            }
        }
    }
    
    private func addVault() {
        guard let url = selectedURL else { return }
        
        isAdding = true
        errorMessage = nil
        
        Task {
            let vaultService = VaultService(dataDirectory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("CmdMD"))
            
            do {
                var vault = try await vaultService.registerVault(name: name, at: url, inboxPath: inboxPath)
                vault.isDefault = isDefault
                
                await MainActor.run {
                    appState.addVault(vault)
                    
                    if isDefault {
                        appState.settings.defaultVaultId = vault.id
                        appState.saveUserData()
                    }
                    
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    isAdding = false
                }
            }
        }
    }
}

#if !SWIFT_PACKAGE
#Preview {
    VaultManagerView()
        .environment(AppState())
}
#endif
