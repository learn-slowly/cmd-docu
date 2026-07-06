import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }

            EditorSettingsView()
                .tabItem {
                    Label("Editor", systemImage: "text.cursor")
                }

            PreviewSettingsView()
                .tabItem {
                    Label("Preview", systemImage: "eye")
                }

            ShortcutsSettingsView()
                .tabItem {
                    Label("Shortcuts", systemImage: "keyboard")
                }

            VaultSettingsView()
                .tabItem {
                    Label("Vaults", systemImage: "folder")
                }

            ToolsSettingsView()
                .tabItem {
                    Label("Tools", systemImage: "wrench.and.screwdriver")
                }
        }
        .frame(width: 560, height: 500)
    }
}

struct GeneralSettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState

        Form {
            Section("Appearance") {
                Picker("Theme", selection: $state.settings.theme) {
                    ForEach(AppTheme.allCases, id: \.self) { theme in
                        Text(theme.rawValue).tag(theme)
                    }
                }
            }

            Section("Saving") {
                Toggle("Autosave", isOn: $state.settings.autosaveEnabled)

                if appState.settings.autosaveEnabled {
                    Picker("Autosave interval", selection: $state.settings.autosaveInterval) {
                        Text("10 seconds").tag(TimeInterval(10))
                        Text("30 seconds").tag(TimeInterval(30))
                        Text("1 minute").tag(TimeInterval(60))
                        Text("5 minutes").tag(TimeInterval(300))
                    }
                }

                Toggle("Confirm before closing unsaved tabs", isOn: $state.settings.confirmBeforeClosingDirtyTabs)
            }

            Section {
                HStack {
                    Text("Default width")
                    Slider(value: $state.settings.defaultWindowWidth, in: 720...2000, step: 20)
                    Text("\(Int(appState.settings.defaultWindowWidth)) px")
                        .monospacedDigit()
                        .frame(width: 60, alignment: .trailing)
                }
                HStack {
                    Text("Default height")
                    Slider(value: $state.settings.defaultWindowHeight, in: 480...1400, step: 20)
                    Text("\(Int(appState.settings.defaultWindowHeight)) px")
                        .monospacedDigit()
                        .frame(width: 60, alignment: .trailing)
                }
                Button("Fit to Markdown layout") {
                    // Preview column (max-width) + sidebar + ribbon + padding chrome.
                    state.settings.defaultWindowWidth = appState.settings.previewSettings.maxWidth + 360
                }
            } header: {
                Text("Window")
            } footer: {
                Text("Sets the launch size and resizes the current window. “Fit to Markdown layout” matches the preview’s max-width.")
                    .font(.caption)
            }

            Section("Session") {
                Toggle("Restore last session on launch", isOn: $state.settings.restoreLastSession)

                Text("Reopens the files, folder, and view mode from your previous session.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Drafts") {
                LabeledContent("Storage") {
                    Text("\(appState.drafts.count) drafts, stored locally")
                        .foregroundStyle(.secondary)
                }

                Text("Drafts live in Application Support and persist across launches. Your Markdown files are never uploaded anywhere.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                claudeStatusRow
                HStack {
                    if let s = appState.claudeAuthStatus, s.loggedIn {
                        Button("로그아웃") { Task { await appState.claudeLogout() } }
                    } else {
                        Button("브라우저로 로그인") { Task { await appState.claudeLogin() } }
                    }
                    Button("상태 새로고침") { Task { await appState.refreshClaudeAuth() } }
                    if appState.claudeAuthBusy {
                        ProgressView().controlSize(.small)
                    }
                }
                .disabled(appState.claudeAuthBusy)
            } header: {
                Text("Claude")
            } footer: {
                Text("폴더 정리·라우팅·질의는 로컬 claude CLI를 씁니다. ‘브라우저로 로그인’을 누르면 claude auth login이 실행돼 브라우저 로그인 페이지가 열립니다. 별도 API 키는 필요 없습니다.")
                    .font(.caption)
            }

            Section {
                LabeledContent("Version", value: AppInfo.versionLabel)
                LabeledContent("Fork by", value: AppInfo.forkMaker)
                LabeledContent("Original", value: AppInfo.originalMaker)
                Link(destination: AppInfo.github) {
                    Label("cmdALL (GitHub)", systemImage: "chevron.left.forwardslash.chevron.right")
                }
                Button("About cmdALL…") { appState.showAbout = true }
            } header: {
                Text("About")
            } footer: {
                Text("cmdALL — CmdMD(© 2026 CMDSPACE) 포크 · MIT License")
                    .font(.caption)
            }
        }
        .formStyle(.grouped)
        .task {
            await appState.refreshClaudeAuth()
        }
        .onChange(of: appState.settings) { _, _ in
            appState.saveUserData()
        }
    }

    /// claude 로그인 상태 한 줄.
    @ViewBuilder
    private var claudeStatusRow: some View {
        LabeledContent("상태") {
            if !appState.claudeAuthChecked {
                Text("확인 중…").foregroundStyle(.secondary)
            } else if let s = appState.claudeAuthStatus {
                if s.loggedIn {
                    VStack(alignment: .trailing, spacing: 2) {
                        Label(s.email ?? "로그인됨", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                        if let sub = s.subscriptionType {
                            Text("구독: \(sub)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } else {
                    Label("미로그인", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            } else {
                Label("claude CLI 미설치", systemImage: "xmark.octagon")
                    .foregroundStyle(.red)
            }
        }
    }
}

struct EditorSettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState

        Form {
            Section("Theme") {
                Picker("Editor theme", selection: $state.settings.editorTheme) {
                    ForEach(EditorTheme.selectableCases, id: \.self) { theme in
                        HStack {
                            Circle()
                                .fill(theme.backgroundColor)
                                .frame(width: 12, height: 12)
                                .overlay(Circle().stroke(Color.gray.opacity(0.3), lineWidth: 1))
                            Text(theme.rawValue)
                        }
                        .tag(theme)
                    }
                }

                EditorThemePreview(theme: appState.settings.editorTheme)
            }

            Section("Display") {
                Toggle("Show line numbers", isOn: $state.settings.showLineNumbers)
                Toggle("Soft wrap", isOn: $state.settings.softWrap)
                Toggle("Highlight current line", isOn: $state.settings.highlightCurrentLine)
            }

            Section("Font") {
                Picker("Font", selection: $state.settings.fontName) {
                    Text("SF Mono").tag("SF Mono")
                    Text("Menlo").tag("Menlo")
                    Text("Monaco").tag("Monaco")
                    Text("Courier New").tag("Courier New")
                    Text("JetBrains Mono").tag("JetBrains Mono")
                    Text("Fira Code").tag("Fira Code")
                }

                HStack {
                    Text("Size")
                    Slider(value: $state.settings.fontSize, in: 10...24, step: 1)
                    Text("\(Int(appState.settings.fontSize)) pt")
                        .frame(width: 50)
                }

                Stepper("Tab size: \(appState.settings.tabSize)", value: $state.settings.tabSize, in: 2...8)
                Toggle("Insert spaces when pressing Tab", isOn: $state.settings.insertSpacesInsteadOfTabs)
            }

            Section("Editing") {
                Toggle("Wiki-link and tag autocompletion", isOn: $state.settings.enableAutocompletion)

                Text("Type [[ to complete note names from your open folder and vaults, # to complete known tags.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Interface") {
                Toggle("Show tab bar", isOn: $state.settings.showTabBar)
                Toggle("Show status bar", isOn: $state.settings.showStatusBar)
            }
        }
        .formStyle(.grouped)
        .onChange(of: appState.settings) { _, _ in
            appState.saveUserData()
        }
    }
}

struct EditorThemePreview: View {
    let theme: EditorTheme

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("# Heading")
                .foregroundColor(theme.headingColor)
            Text("Normal text with **bold** and *italic*")
                .foregroundColor(theme.textColor)
            Text("// Comment")
                .foregroundColor(theme.commentColor)
            Text("\"String value\"")
                .foregroundColor(theme.stringColor)
            Text("[Link](url) and [[Wiki Link]]")
                .foregroundColor(theme.linkColor)
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.backgroundColor)
        .cornerRadius(6)
    }
}

struct PreviewSettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState

        Form {
            Section("Theme") {
                Picker("Preview theme", selection: $state.settings.previewTheme) {
                    ForEach(PreviewTheme.allCases, id: \.self) { theme in
                        Text(theme.rawValue).tag(theme.rawValue)
                    }
                }
            }

            Section("Typography") {
                HStack {
                    Text("Line height")
                    Slider(value: $state.settings.previewSettings.lineHeight, in: 1.2...2.4, step: 0.1)
                    Text(String(format: "%.1f", appState.settings.previewSettings.lineHeight))
                        .frame(width: 40)
                }

                HStack {
                    Text("Font size")
                    Slider(value: $state.settings.previewSettings.fontSize, in: 12...24, step: 1)
                    Text("\(Int(appState.settings.previewSettings.fontSize)) px")
                        .frame(width: 50)
                }

                HStack {
                    Text("Max width")
                    Slider(value: $state.settings.previewSettings.maxWidth, in: 600...1200, step: 50)
                    Text("\(Int(appState.settings.previewSettings.maxWidth)) px")
                        .frame(width: 60)
                }

                Picker("Font family", selection: $state.settings.previewSettings.fontFamily) {
                    Text("System UI").tag("system-ui")
                    Text("Georgia").tag("Georgia, serif")
                    Text("Times New Roman").tag("Times New Roman, serif")
                    Text("Inter").tag("Inter, sans-serif")
                    Text("SF Pro Text").tag("SF Pro Text, sans-serif")
                }

                HStack {
                    Text("Letter spacing (자간)")
                    Slider(value: $state.settings.previewSettings.letterSpacing, in: -0.05...0.3, step: 0.01)
                    Text(String(format: "%.2f em", appState.settings.previewSettings.letterSpacing))
                        .monospacedDigit()
                        .frame(width: 64, alignment: .trailing)
                }

                HStack {
                    Text("Character width (장평)")
                    Slider(value: $state.settings.previewSettings.charWidth, in: 0.8...1.2, step: 0.01)
                    Text(String(format: "%.0f%%", appState.settings.previewSettings.charWidth * 100))
                        .monospacedDigit()
                        .frame(width: 64, alignment: .trailing)
                }

                HStack {
                    Text("Word spacing (단어 간격)")
                    Slider(value: $state.settings.previewSettings.wordSpacing, in: 0...1, step: 0.05)
                    Text(String(format: "%.2f em", appState.settings.previewSettings.wordSpacing))
                        .monospacedDigit()
                        .frame(width: 64, alignment: .trailing)
                }
            }

            Section("Headings") {
                HStack {
                    Text("Scale")
                    Slider(value: $state.settings.previewSettings.headingScale, in: 0.8...1.5, step: 0.1)
                    Text(String(format: "%.1fx", appState.settings.previewSettings.headingScale))
                        .frame(width: 40)
                }

                HStack {
                    Text("Top margin")
                    Slider(value: $state.settings.previewSettings.headingMarginTop, in: 12...48, step: 4)
                    Text("\(Int(appState.settings.previewSettings.headingMarginTop)) px")
                        .frame(width: 50)
                }
            }

            Section("Code Blocks") {
                Toggle("Syntax highlighting in preview", isOn: $state.settings.enablePreviewCodeHighlight)

                if appState.settings.enablePreviewCodeHighlight {
                    Picker("Highlight theme", selection: $state.settings.previewSettings.codeBlockTheme) {
                        Text("GitHub (auto light/dark)").tag("github")
                        Text("Atom One Dark").tag("atom-one-dark")
                        Text("Atom One Light").tag("atom-one-light")
                        Text("Monokai").tag("monokai")
                        Text("Nord").tag("nord")
                        Text("Tokyo Night Dark").tag("tokyo-night-dark")
                    }
                }
            }

            Section("Obsidian Compatibility") {
                Toggle("Wiki links [[...]] and #tags", isOn: $state.settings.enableWikiLinks)
                Toggle("Callouts > [!note]", isOn: $state.settings.enableCallouts)
                Toggle("Mermaid diagrams", isOn: $state.settings.enableMermaid)
                Toggle("KaTeX math ($...$, $$...$$)", isOn: $state.settings.enableKaTeX)

                Text("Mermaid and KaTeX load from bundled assets (CDN fallback). Code highlighting is bundled for the default theme; other themes load from a CDN.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Custom CSS") {
                TextEditor(text: $state.settings.previewSettings.customCSS)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(height: 100)
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.gray.opacity(0.3), lineWidth: 1)
                    )

                Text("Injected after the theme styles — overrides anything above.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onChange(of: appState.settings) { _, _ in
            appState.saveUserData()
        }
    }
}

struct VaultSettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var showAddVault = false
    @State private var defaultVaultFolders: [String] = []

    var body: some View {
        @Bindable var state = appState

        Form {
            Section {
                ForEach(appState.vaults) { vault in
                    HStack {
                        VStack(alignment: .leading) {
                            HStack {
                                Text(vault.displayName)
                                    .font(.headline)

                                if vault.id == appState.settings.defaultVaultId {
                                    Text("Default")
                                        .font(.caption.weight(.medium))
                                        .padding(.horizontal, 7)
                                        .padding(.vertical, 2)
                                        .background(Color.cmdsAccent.opacity(0.18))
                                        .foregroundStyle(Color.cmdsAccent)
                                        .clipShape(Capsule())
                                }
                            }

                            Text(vault.rootPath.path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }

                        Spacer()

                        Button(role: .destructive) {
                            appState.removeVault(vault)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                    .padding(.vertical, 4)
                }
            } header: {
                HStack {
                    Text("Connected Vaults")
                    Spacer()
                    Button("Add Vault…") {
                        showAddVault = true
                    }
                }
            }

            if appState.vaults.isEmpty {
                ContentUnavailableView("No Vaults", systemImage: "folder.badge.plus", description: Text("Connect an Obsidian vault to get started"))
            }

            Section {
                Picker("Default vault for Send", selection: Binding(
                    get: { appState.settings.defaultVaultId },
                    set: { appState.settings.defaultVaultId = $0; loadDefaultVaultFolders() }
                )) {
                    Text("None").tag(nil as UUID?)
                    ForEach(appState.vaults) { vault in
                        Text(vault.displayName).tag(vault.id as UUID?)
                    }
                }

                // App-wide default send folder. Type any name (created on send if
                // missing), or pick from the default vault's existing folders.
                LabeledContent("Default send folder") {
                    HStack(spacing: 6) {
                        TextField("Default send folder", text: $state.settings.defaultSendFolder, prompt: Text("Inbox"))
                            .textFieldStyle(.roundedBorder)
                            .labelsHidden()
                            .frame(maxWidth: 180)
                        if !defaultVaultFolders.isEmpty {
                            Menu {
                                ForEach(defaultVaultFolders, id: \.self) { folder in
                                    Button(folder) { state.settings.defaultSendFolder = folder }
                                }
                            } label: {
                                Image(systemName: "folder")
                            }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                        }
                    }
                }

                Picker("File conflict resolution", selection: $state.settings.conflictResolution) {
                    ForEach(FileConflictResolution.allCases, id: \.self) { resolution in
                        Text(resolution.rawValue).tag(resolution)
                    }
                }

                Toggle("Inject frontmatter by default", isOn: $state.settings.injectFrontmatterByDefault)
            } header: {
                Text("Sending")
            } footer: {
                Text("Per-vault Inbox folders take priority over the default send folder.")
                    .font(.caption)
            }

            Section {
                Button("Manage Vaults, Templates & Rules…") {
                    appState.showVaultManager = true
                }
            }
        }
        .formStyle(.grouped)
        .sheet(isPresented: $showAddVault) {
            AddVaultSheet()
        }
        .onAppear { loadDefaultVaultFolders() }
        .onChange(of: appState.settings) { _, _ in
            appState.saveUserData()
        }
    }

    /// Loads the default vault's folders so the default-send-folder picker shows
    /// real destinations. Falls back to a free-text field when none load.
    private func loadDefaultVaultFolders() {
        guard let vault = appState.defaultVault else {
            defaultVaultFolders = []
            return
        }
        let vaultService = VaultService(dataDirectory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!.appendingPathComponent("CmdMD"))
        Task {
            var folders = (try? await vaultService.listFolders(in: vault)) ?? []
            let current = appState.settings.defaultSendFolder
            if !current.isEmpty, !folders.contains(current) { folders.insert(current, at: 0) }
            if !folders.contains("Inbox") { folders.insert("Inbox", at: 0) }
            await MainActor.run { defaultVaultFolders = folders }
        }
    }
}

// MARK: - Shortcuts

struct ShortcutsSettingsView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Form {
            Section {
                ForEach(AppShortcut.allCases) { shortcut in
                    ShortcutRow(shortcut: shortcut)
                }
            } header: {
                Text("Keyboard Shortcuts")
            } footer: {
                Text("Click a shortcut, then press the new key combination. Defaults mirror your Obsidian vault where possible. Press ⎋ to cancel.")
                    .font(.caption)
            }

            Section {
                Button("Reset all to defaults", role: .destructive) {
                    appState.settings.keyBindings = [:]
                    appState.saveUserData()
                }
                .disabled(appState.settings.keyBindings.isEmpty)
            }
        }
        .formStyle(.grouped)
    }
}

struct ShortcutRow: View {
    @Environment(AppState.self) private var appState
    let shortcut: AppShortcut

    @State private var recording = false
    @State private var monitor: Any?

    private var binding: KeyBinding { appState.keyBinding(for: shortcut) }
    private var isCustom: Bool { appState.settings.keyBindings[shortcut.rawValue] != nil }

    var body: some View {
        HStack {
            Text(shortcut.title)
            Spacer()
            Button(recording ? "Press keys…" : binding.displayString) {
                toggleRecord()
            }
            .monospaced()
            .foregroundStyle(recording ? Color.cmdsAccent : .primary)
            .frame(minWidth: 96)

            Button {
                reset()
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .buttonStyle(.borderless)
            .help("Reset to default")
            .opacity(isCustom ? 1 : 0)
            .disabled(!isCustom)
        }
        .onDisappear { stop() }
    }

    private func toggleRecord() {
        if recording { stop(); return }
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            capture(event)
            return nil   // swallow while recording
        }
    }

    private func capture(_ event: NSEvent) {
        defer { stop() }
        if event.keyCode == 53 { return }   // Escape cancels

        let flags = event.modifierFlags
        let key: String
        switch event.keyCode {
        case 123: key = "ArrowLeft"
        case 124: key = "ArrowRight"
        case 126: key = "ArrowUp"
        case 125: key = "ArrowDown"
        case 49:  key = "Space"
        default:
            // 한글 입력 소스에서 자모("ㅁ")가 키로 저장되면 영구 불일치 바인딩이 된다 —
            // 입력 소스 독립 판독으로 물리 키 문자를 기록한다.
            let letter = AppState.keyLetter(
                ignoringModifiers: event.charactersIgnoringModifiers,
                commandApplied: event.characters(byApplyingModifiers: .command))
            guard letter.count == 1 else { return }
            key = letter
        }

        var b = KeyBinding(key: key)
        b.command = flags.contains(.command)
        b.shift = flags.contains(.shift)
        b.option = flags.contains(.option)
        b.control = flags.contains(.control)

        appState.settings.keyBindings[shortcut.rawValue] = b
        appState.saveUserData()
    }

    private func reset() {
        appState.settings.keyBindings[shortcut.rawValue] = nil
        appState.saveUserData()
    }

    private func stop() {
        recording = false
        if let m = monitor {
            NSEvent.removeMonitor(m)
            monitor = nil
        }
    }
}

// MARK: - Tools (외부 CLI 상태·신규 기능 설정 통합)

/// kordoc·claude CLI 탐지 상태와 신규 기능(라우팅·검색 인덱스·RAG) 설정을 한 곳에 모은 탭.
/// 경로 탐지는 리졸버만 호출한다(버전 프로브 없음 — 스펙 §3). 리졸버가 후보 경로 밖 설치에서
/// `which` 셸 프로브로 폴백할 수 있어 탐지는 백그라운드에서 돌리고 결과만 메인에 반영한다.
struct ToolsSettingsView: View {
    @Environment(AppState.self) private var appState

    @State private var kordocPath: String?
    @State private var claudePath: String?
    @State private var hasChecked = false

    /// 파일 연결 상태(그룹 id 키): 현재 기본 앱 이름·성공 표시·부분 실패 확장자.
    @State private var defaultAppNames: [String: String] = [:]
    @State private var associatedGroups: Set<String> = []
    @State private var associationFailures: [String: [String]] = [:]

    var body: some View {
        @Bindable var state = appState

        Form {
            Section {
                toolStatusRows(name: "kordoc (npx)", path: kordocPath,
                               missingHint: "미설치 — Node 18+와 npx가 필요합니다. 한글·오피스 문서 읽기/쓰기가 비활성화됩니다.")
            } header: {
                Text("kordoc")
            }

            Section {
                toolStatusRows(name: "claude CLI", path: claudePath,
                               missingHint: "미설치 — Claude 연동(패널·라우팅·RAG·폴더 정리)이 비활성화됩니다.")
                Toggle("Claude 스마트 라우팅 (PARA)", isOn: $state.settings.claudeRoutingEnabled)
                Text("볼트로 보낼 때 규칙에 안 맞으면 Claude가 PARA 폴더를 제안합니다. (Vault Manager의 PARA 탭과 같은 설정)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Claude")
            }

            Section {
                if appState.settings.indexedFolders.isEmpty {
                    Text("등록된 폴더 없음")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(appState.settings.indexedFolders, id: \.self) { path in
                        Text(path)
                            .font(.callout)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
                Toggle("질의 확장 (RAG)", isOn: $state.settings.ragExpandQuery)
                Button("내용 검색 열기…") {
                    appState.showIndexSearch = true
                }
            } header: {
                Text("검색 인덱스")
            } footer: {
                Text("폴더 등록·해제는 내용 검색 창에서 합니다. 질의 확장은 자료에 묻기(RAG)가 검색어를 넓히는 옵션입니다.")
                    .font(.caption)
            }

            Section {
                HStack {
                    if let folder = appState.settings.wikiFolder {
                        Text(folder)
                            .font(.callout)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    } else {
                        Text("설정 안 됨")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(appState.settings.wikiFolder == nil ? "지정…" : "변경…") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        panel.allowsMultipleSelection = false
                        if panel.runModal() == .OK, let url = panel.url {
                            appState.settings.wikiFolder = url.path
                            appState.saveUserData()
                        }
                    }
                }
            } header: {
                Text("LLM-Wiki")
            } footer: {
                Text("파일을 위키 페이지에 병합하는 인제스트의 대상 폴더입니다.")
                    .font(.caption)
            }

            Section {
                if FileAssociationService.appBundleURL == nil {
                    Text("패키징된 앱(/Applications의 cmdALL.app)에서만 사용할 수 있습니다.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(FileTypeGroup.all) { group in
                        associationRow(for: group)
                    }
                }
            } header: {
                Text("파일 연결")
            } footer: {
                Text("다른 앱으로 되돌리려면 Finder에서 파일 정보(⌘I) → 다음으로 열기에서 바꾸세요. 마크다운·텍스트 그룹의 txt는 macOS 일반 텍스트(public.plain-text) 유형 전체에 적용될 수 있습니다.")
                    .font(.caption)
            }

            Section {
                Button("상태 새로고침") { refresh() }
            }
        }
        .formStyle(.grouped)
        .onAppear { refresh() }
        .onChange(of: appState.settings) { _, _ in
            appState.saveUserData()
        }
    }

    /// 경로를 찾으면 모노스페이스로, 못 찾으면 "미설치"와 안내 캡션을 표시한다.
    /// 첫 탐지가 끝나기 전에는 "확인 중…"으로 오신호(미설치 깜빡임)를 막는다.
    @ViewBuilder
    private func toolStatusRows(name: String, path: String?, missingHint: String) -> some View {
        LabeledContent(name) {
            if let path {
                Text(path)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else if !hasChecked {
                Text("확인 중…")
                    .foregroundStyle(.secondary)
            } else {
                Text("미설치")
                    .foregroundStyle(.orange)
            }
        }
        if hasChecked && path == nil {
            Text(missingHint)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    /// 그룹 한 행: 그룹명+확장자 캡션 / 현재 기본 앱 이름 / "cmdALL로" 버튼(+성공 체크·부분 실패 캡션).
    @ViewBuilder
    private func associationRow(for group: FileTypeGroup) -> some View {
        LabeledContent {
            HStack(spacing: 8) {
                if associatedGroups.contains(group.id) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                }
                Text(defaultAppNames[group.id] ?? "없음")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Button("cmdALL로") { associate(group) }
            }
        } label: {
            Text(group.name)
            Text(group.extensions.joined(separator: ", "))
        }
        if let failed = associationFailures[group.id] {
            Text("일부 실패: \(failed.joined(separator: ", "))")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    private func associate(_ group: FileTypeGroup) {
        Task { @MainActor in
            switch await FileAssociationService.setAsDefault(group: group) {
            case .success:
                associatedGroups.insert(group.id)
                associationFailures[group.id] = nil
            case .failure(.partialFailure(let failed)):
                associatedGroups.remove(group.id)
                associationFailures[group.id] = failed
            case .failure(.notPackagedApp):
                associationFailures[group.id] = group.extensions
            }
            refreshDefaultAppNames()
        }
    }

    /// 현재 기본 앱 이름 일괄 재조회 — 가벼운 LS 질의(프로세스 스폰 없음, Tools 탭 원칙 유지).
    private func refreshDefaultAppNames() {
        guard FileAssociationService.appBundleURL != nil else { return }
        var names: [String: String] = [:]
        for group in FileTypeGroup.all {
            names[group.id] = FileAssociationService.currentDefaultAppName(for: group)
        }
        defaultAppNames = names
    }

    private func refresh() {
        refreshDefaultAppNames()
        // 리졸버는 후보 경로 밖 설치에서 `which` 셸 프로브(프로세스 스폰·무제한 대기)로
        // 폴백할 수 있어 메인 스레드에서 직접 부르지 않는다 — 탐지는 백그라운드, 반영만 메인.
        Task.detached(priority: .userInitiated) {
            let kordoc = KordocService.resolveNpxPath()
            let claude = ClaudeService.resolveClaudePath()
            await MainActor.run {
                kordocPath = kordoc
                claudePath = claude
                hasChecked = true
            }
        }
    }
}

#if !SWIFT_PACKAGE
#Preview {
    SettingsView()
        .environment(AppState())
}
#endif
