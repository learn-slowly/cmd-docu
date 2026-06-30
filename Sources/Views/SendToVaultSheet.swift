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
    @State private var applyTemplate: Bool = false
    @State private var selectedTemplateId: UUID?
    @State private var isSending: Bool = false
    @State private var errorMessage: String?
    @State private var availableFolders: [String] = []
    @State private var routeCaption: String?      // Claude 제안 이유 또는 에러 표시
    @State private var suppressVaultReset = false   // 프로그램적 볼트 선택 시 onChange의 targetFolder 리셋을 막는다

    /// Batch mode is active when the sidebar queued multiple files
    /// ("Send Folder to Vault…").
    private var isBatch: Bool {
        !appState.batchSendURLs.isEmpty
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(isBatch ? "Send \(appState.batchSendURLs.count) Files to Vault" : "Send to Vault")
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
                            if suppressVaultReset {
                                suppressVaultReset = false
                            } else {
                                targetFolder = appState.effectiveSendFolder(for: vault)
                            }
                            loadFolders(for: vault, ensuring: targetFolder)
                        }
                    }

                    if !availableFolders.isEmpty {
                        Picker("Folder", selection: $targetFolder) {
                            ForEach(availableFolders, id: \.self) { folder in
                                // Indent nested folders so the vault hierarchy reads
                                // as a tree instead of a flat path soup.
                                Text(indentedLabel(for: folder)).tag(folder)
                            }
                        }
                    } else {
                        TextField("Folder", text: $targetFolder)
                    }

                    if !isBatch && appState.isParaRoutingConfigured() {
                        HStack {
                            Button {
                                runClaudeRoute()
                            } label: {
                                Label("Claude에게 맡기기", systemImage: "wand.and.stars")
                            }
                            .disabled(appState.claudeRouteInProgress)
                            if appState.claudeRouteInProgress {
                                ProgressView().controlSize(.small)
                            }
                        }
                        if let caption = routeCaption {
                            Text(caption)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
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
                    Toggle("Add source path to frontmatter", isOn: $addSourceLink)

                    if !isBatch {
                        Toggle("Open in Obsidian after send", isOn: $openAfterSend)
                    }
                }

                if !appState.templates.isEmpty {
                    Section("Template") {
                        Toggle("Apply template", isOn: $applyTemplate)

                        if applyTemplate {
                            Picker("Template", selection: $selectedTemplateId) {
                                ForEach(appState.templates) { template in
                                    Text(template.name).tag(template.id as UUID?)
                                }
                            }
                        }
                    }
                }

                Section("Preview") {
                    VStack(alignment: .leading, spacing: 4) {
                        if isBatch {
                            Text("\(appState.batchSendURLs.count) Markdown files")
                                .font(.callout)
                            ForEach(appState.batchSendURLs.prefix(5), id: \.self) { url in
                                Text("· \(url.lastPathComponent)")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            if appState.batchSendURLs.count > 5 {
                                Text("… and \(appState.batchSendURLs.count - 5) more")
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                            }
                        } else if let document = appState.currentDocument {
                            Text("File: \(document.displayTitle).md")
                                .font(.callout)
                        }

                        if let vault = selectedVault {
                            Text("To: \(vault.displayName)/\(targetFolder)/")
                                .font(.caption)
                                .foregroundStyle(.secondary)
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

                Button(isBatch ? "Send All" : "Send") {
                    send()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(selectedVault == nil || isSending)
            }
            .padding()
            .background(.bar)
        }
        .frame(width: 460, height: isBatch ? 560 : 540)
        .tint(.cmdsAccent)
        .onAppear {
            injectFrontmatter = appState.settings.injectFrontmatterByDefault
            conflictResolution = appState.settings.conflictResolution
            selectedTemplateId = appState.templates.first?.id

            if let vault = appState.defaultVault {
                selectedVault = vault
                targetFolder = appState.effectiveSendFolder(for: vault)
                loadFolders(for: vault)
            }

            if appState.autoTriggerClaudeRoute {
                appState.autoTriggerClaudeRoute = false   // 1회성 소비
                if !isBatch && appState.isParaRoutingConfigured() {
                    runClaudeRoute()
                }
            }
        }
    }

    private func indentedLabel(for folder: String) -> String {
        let depth = folder.components(separatedBy: "/").count - 1
        return String(repeating: "    ", count: depth) + (folder.components(separatedBy: "/").last ?? folder)
    }

    private func loadFolders(for vault: Vault, ensuring extra: String? = nil) {
        Task {
            let vaultService = VaultService(dataDirectory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("CmdMD"))
            let effective = appState.effectiveSendFolder(for: vault)
            do {
                var folders = try await vaultService.listFolders(in: vault)
                if !folders.contains(effective) { folders.insert(effective, at: 0) }
                if let extra, !extra.isEmpty, !folders.contains(extra) { folders.insert(extra, at: 0) }
                await MainActor.run { availableFolders = folders }
            } catch {
                var fallback = [effective]
                if let extra, !extra.isEmpty, extra != effective { fallback.insert(extra, at: 0) }
                await MainActor.run { availableFolders = fallback }
            }
        }
    }

    private func buildOptions(vault: Vault) -> SendOptions {
        var options = SendOptions()
        options.targetVault = vault
        options.targetFolder = targetFolder
        options.action = action
        options.conflictResolution = conflictResolution
        options.injectFrontmatter = injectFrontmatter
        options.addSourceLink = addSourceLink
        options.openAfterSend = openAfterSend && !isBatch
        options.applyTemplate = applyTemplate
        options.templateId = applyTemplate ? selectedTemplateId : nil
        return options
    }

    /// Claude에게 현재 문서 본문을 보내 PARA 폴더를 제안받아 Vault/Folder를 프리필한다.
    private func runClaudeRoute() {
        guard let body = appState.currentDocument?.content else {
            routeCaption = "보낼 문서를 찾을 수 없습니다."
            return
        }
        routeCaption = nil
        Task {
            let suggestion = await appState.requestClaudeRoute(noteBody: body)
            await MainActor.run {
                if let s = suggestion, let vault = appState.paraVault {
                    // 볼트가 실제로 바뀔 때만 onChange가 발화하므로, 그 때만 리셋 억제 플래그를 켠다.
                    // (이미 같은 볼트면 onChange 미발화 → 플래그가 잔류해 다음 변경을 망친다.)
                    suppressVaultReset = (selectedVault != vault)
                    targetFolder = s.folder.folder
                    selectedVault = vault
                    loadFolders(for: vault, ensuring: s.folder.folder)
                    routeCaption = "제안: \(s.folder.label) — \(s.reason)"
                } else {
                    routeCaption = appState.claudeRouteError ?? "제안을 받지 못했습니다."
                }
            }
        }
    }

    private func send() {
        guard let vault = selectedVault else { return }

        isSending = true
        errorMessage = nil
        let options = buildOptions(vault: vault)

        Task {
            do {
                if isBatch {
                    _ = await appState.sendFiles(appState.batchSendURLs, options: options)
                } else {
                    try await appState.sendToVault(options: options)
                }

                await MainActor.run {
                    appState.batchSendURLs = []
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

#if !SWIFT_PACKAGE
#Preview {
    SendToVaultSheet()
        .environment(AppState())
}
#endif
