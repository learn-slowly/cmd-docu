import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var systemColorScheme
    @State private var hostWindow: NSWindow?
    /// 드래그 시작 시점의 Claude 패널 너비(제스처 동안 고정 기준).
    @State private var claudeDragStartWidth: CGFloat?
    
    private var effectiveColorScheme: ColorScheme? {
        switch appState.settings.theme {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
    
    var body: some View {
        @Bindable var state = appState

        HStack(spacing: 0) {
        NavigationSplitView(columnVisibility: Binding(
            get: { appState.sidebarVisible ? .all : .detailOnly },
            set: { appState.sidebarVisible = $0 != .detailOnly }
        )) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 300)
        } detail: {
            MainEditorView()
        }
        .navigationTitle(appState.windowTitle)
        .inspector(isPresented: $state.inspectorVisible) {
            InspectorView()
                .inspectorColumnWidth(min: 250, ideal: 280, max: 350)
        }
        .preferredColorScheme(effectiveColorScheme)
        .tint(.cmdsAccent)
        .background(WindowAccessor(window: $hostWindow))
        .onChange(of: appState.settings.defaultWindowWidth) { _, w in
            hostWindow?.setContentSize(NSSize(width: w, height: appState.settings.defaultWindowHeight))
        }
        .onChange(of: appState.settings.defaultWindowHeight) { _, h in
            hostWindow?.setContentSize(NSSize(width: appState.settings.defaultWindowWidth, height: h))
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                MainModePicker()
                if appState.mainMode == .reader {
                    ViewModePicker()
                } else {
                    LibraryLayoutPicker()
                }
            }

            ToolbarItemGroup(placement: .primaryAction) {
                SendToVaultButton()

                // The right-sidebar (inspector) toggle, pinned to the trailing edge.
                Button {
                    appState.inspectorVisible.toggle()
                } label: {
                    Image(systemName: "sidebar.right")
                }
                .help("Toggle Inspector (\(appState.keyBinding(for: .toggleInspector).displayString))")
            }
        }
        .sheet(isPresented: $state.showSendToVault, onDismiss: {
            appState.batchSendURLs = []
        }) {
            SendToVaultSheet()
        }
        .sheet(isPresented: $state.showVaultManager) {
            VaultManagerView()
        }
        .sheet(isPresented: $state.showCommandPalette) {
            CommandPaletteView()
        }
        .sheet(isPresented: $state.showOmnisearch) {
            OmnisearchView()
        }
        .sheet(isPresented: $state.showAskCorpus) {
            AskCorpusView()
        }
        .sheet(isPresented: $state.showQuickCapture) {
            // The ⇧⌘M quick-capture panel — previously the hotkey set a flag
            // that nothing observed.
            QuickCaptureView {
                appState.showQuickCapture = false
            }
        }
        .sheet(isPresented: Binding(
            get: { !appState.settings.hasCompletedOnboarding },
            set: { _ in }
        )) {
            OnboardingView()
                .interactiveDismissDisabled(true)
        }
        .sheet(isPresented: $state.showAbout) {
            AboutView()
        }
        .sheet(item: $state.officeSaveConfirm) { request in
            OfficeSaveConfirmView(request: request)
        }
        .sheet(item: $state.officeFillSession) { request in
            OfficeFillView(request: request)
        }
        .sheet(isPresented: $state.showIndexSearch) {
            IndexSearchView()
        }
        .sheet(isPresented: $state.showFolderCleanup) {
            FolderCleanupView()
        }
        .sheet(item: $state.renameRequest) { request in
            RenameSheetView(request: request)
        }
        .sheet(item: $state.fileInfoRequest) { request in
            FileInfoView(request: request)
        }
        .sheet(isPresented: $state.showFileOpsHistory) {
            FileOpsHistoryView()
        }
        .alert(
            "Something went wrong",
            isPresented: Binding(
                get: { appState.errorMessage != nil },
                set: { if !$0 { appState.errorMessage = nil } }
            )
        ) {
            Button("OK", role: .cancel) { appState.errorMessage = nil }
        } message: {
            Text(appState.errorMessage ?? "")
        }
        .overlay {
            if let toast = appState.toastMessage {
                ToastView(message: toast)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: appState.toastMessage)
        .focusedSceneValue(\.document, appState.currentDocument)

            if appState.claudePanelVisible {
                Divider()
                    .frame(width: 6)
                    .background(Color.gray.opacity(0.001)) // 히트 영역 확보
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() }
                    }
                    .gesture(
                        DragGesture()
                            .onChanged { value in
                                // 드래그 시작 너비를 한 번만 캡처해 그 기준에서 계산한다.
                                let start = claudeDragStartWidth ?? appState.claudePanelWidth
                                if claudeDragStartWidth == nil { claudeDragStartWidth = start }
                                appState.claudePanelWidth = min(600, max(280, start - value.translation.width))
                            }
                            .onEnded { _ in
                                claudeDragStartWidth = nil
                            }
                    )

                ClaudePanelView()
                    .frame(width: appState.claudePanelWidth)
                    .transition(.move(edge: .trailing))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: appState.claudePanelVisible)
    }
}

/// 메인 모드 토글(리더 ↔ 라이브러리).
struct MainModePicker: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState

        Picker("Main Mode", selection: $state.mainMode) {
            Label("리더", systemImage: "doc.text")
                .tag(MainMode.reader)
            Label("라이브러리", systemImage: "square.grid.2x2")
                .tag(MainMode.library)
        }
        .pickerStyle(.segmented)
        .labelStyle(.iconOnly)
        .controlSize(.regular)
        .fixedSize()
        .help("리더 모드 · 라이브러리 모드")
    }
}

/// 리더 모드 보기 토글(Source/Split/Preview).
struct ViewModePicker: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState

        Picker("View Mode", selection: $state.viewMode) {
            Label("Source", systemImage: "text.alignleft")
                .tag(ViewMode.source)
            Label("Split", systemImage: "rectangle.split.2x1")
                .tag(ViewMode.split)
            Label("Preview", systemImage: "eye")
                .tag(ViewMode.preview)
        }
        .pickerStyle(.segmented)
        .labelStyle(.iconOnly)
        .controlSize(.regular)
        .fixedSize()
        .help("Source ⌘1 · Split ⌘2 · Preview ⌘3")
    }
}

/// 라이브러리 레이아웃 토글(리스트 ↔ 격자).
struct LibraryLayoutPicker: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        @Bindable var state = appState

        Picker("Library Layout", selection: $state.libraryLayout) {
            Label("리스트", systemImage: "list.bullet")
                .tag(LibraryLayout.list)
            Label("격자", systemImage: "square.grid.2x2")
                .tag(LibraryLayout.grid)
        }
        .pickerStyle(.segmented)
        .labelStyle(.iconOnly)
        .controlSize(.regular)
        .fixedSize()
        .help("리스트 · 격자")
    }
}

struct SendToVaultButton: View {
    @Environment(AppState.self) private var appState
    
    var body: some View {
        Menu {
            if appState.vaults.isEmpty {
                Text("No vaults configured")
                Button("Add Vault…") {
                    appState.showVaultManager = true
                }
            } else {
                ForEach(appState.vaults) { vault in
                    Button {
                        Task {
                            var options = SendOptions()
                            options.targetVault = vault
                            options.targetFolder = appState.effectiveSendFolder(for: vault)
                            options.conflictResolution = appState.settings.conflictResolution
                            options.injectFrontmatter = appState.settings.injectFrontmatterByDefault
                            try? await appState.sendToVault(options: options)
                        }
                    } label: {
                        Label("\(vault.displayName) / \(appState.effectiveSendFolder(for: vault))", systemImage: "tray.and.arrow.down")
                    }
                }

                Divider()

                Button("Send with Options…") {
                    appState.showSendToVault = true
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])

                Button("Auto-Route") {
                    appState.autoRouteCurrentDocument()
                }
                .keyboardShortcut("t", modifiers: [.command, .control])
            }
        } label: {
            Image(systemName: "paperplane")
        }
        .disabled(appState.currentDocument == nil)
        .help("Send to Vault (⇧⌘T)")
    }
}

struct ToastView: View {
    let message: String
    
    var body: some View {
        VStack {
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                Text(message)
                    .font(.system(size: 13, weight: .medium))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .shadow(color: .black.opacity(0.1), radius: 10, y: 4)
            .padding(.top, 8)
            
            Spacer()
        }
    }
}

extension AppState {
    var sidebarColumnVisibility: NavigationSplitViewVisibility {
        get { sidebarVisible ? .all : .detailOnly }
        set { sidebarVisible = newValue != .detailOnly }
    }
}

// MARK: - First-run onboarding

/// Shown once on first launch. Keeps setup to a single decision — appearance —
/// and applies the CMDS theme as the default automatically.
struct OnboardingView: View {
    @Environment(AppState.self) private var appState
    @State private var appearance: AppTheme = .system

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 14) {
                BrandLogo(size: 84, showWordmark: true)

                VStack(spacing: 4) {
                    Text("Welcome to cmdALL")
                        .font(.title2.bold())
                    Text("리뷰 우선 마크다운 에디터 · Obsidian 볼트 라우터")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                Text("Appearance")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)

                HStack(spacing: 10) {
                    ForEach(AppTheme.allCases, id: \.self) { theme in
                        AppearanceCard(theme: theme, isSelected: appearance == theme) {
                            appearance = theme
                        }
                    }
                }

                Text("CMDS 테마가 기본으로 적용됩니다. 세부 설정은 언제든 설정에서 바꿀 수 있어요.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Button {
                appState.settings.theme = appearance
                appState.settings.previewTheme = PreviewTheme.cmds.rawValue
                appState.settings.editorTheme = .cmds
                appState.settings.hasCompletedOnboarding = true
                appState.saveUserData()
            } label: {
                Text("시작하기")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(28)
        .frame(width: 460)
        .tint(.cmdsAccent)
    }
}

struct AppearanceCard: View {
    let theme: AppTheme
    let isSelected: Bool
    let action: () -> Void

    private var icon: String {
        switch theme {
        case .system: return "circle.lefthalf.filled"
        case .light: return "sun.max"
        case .dark: return "moon.stars"
        }
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 22))
                    .foregroundStyle(isSelected ? Color.cmdsAccent : .secondary)
                Text(theme.rawValue)
                    .font(.callout)
                    .foregroundStyle(.primary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.5))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(isSelected ? Color.cmdsAccent : Color.gray.opacity(0.25), lineWidth: isSelected ? 2 : 1)
            )
        }
        .buttonStyle(.plain)
    }
}

/// Captures the hosting `NSWindow` so the main window (not the Settings window)
/// can be resized live when the window-size settings change.
struct WindowAccessor: NSViewRepresentable {
    @Binding var window: NSWindow?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { window = view.window }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if window == nil {
            DispatchQueue.main.async { window = nsView.window }
        }
    }
}

// MARK: - About / creator info

enum AppInfo {
    static var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.9.0"
    }
    static var build: String {
        Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? ""
    }
    static var versionLabel: String {
        build.isEmpty ? "Version \(version)" : "Version \(version) (\(build))"
    }
    static let forkMaker = "레고 (learn-slowly)"
    static let originalMaker = "구요한 · CMDSPACE"
    static let website = URL(string: "https://damaged.kr")!
    static let github = URL(string: "https://github.com/learn-slowly/cmd-docu")!
    static let originalGithub = URL(string: "https://github.com/johnfkoo951/CmdMD")!
    static let tagline = "문서·이미지·사운드·동영상을 읽고, Claude에게 묻고, 내용으로 검색해 알맞은 자리로 정리하는 macOS 도구."
}

/// Shared row of brand links — reused by the About window and Settings.
struct CreatorLinks: View {
    var body: some View {
        HStack(spacing: 16) {
            Link(destination: AppInfo.website) {
                Label("damaged.kr", systemImage: "globe")
            }
            Link(destination: AppInfo.github) {
                Label("GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
            }
        }
        .font(.callout)
        .tint(.cmdsAccent)
    }
}

struct AboutView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            BrandLogo(size: 76, showWordmark: true)

            VStack(spacing: 3) {
                Text("cmdALL")
                    .font(.title2.bold())
                Text(AppInfo.versionLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(AppInfo.tagline)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            // Update status / action
            if appState.updateAvailable {
                Button {
                    if let url = appState.updateURL { NSWorkspace.shared.open(url) }
                } label: {
                    Label("Update available: \(appState.latestVersion ?? "")", systemImage: "arrow.down.circle.fill")
                }
                .buttonStyle(.borderedProminent)
                .tint(.cmdsAccent)
            } else {
                Button {
                    appState.checkForUpdates(userInitiated: true)
                } label: {
                    if appState.isCheckingForUpdate {
                        ProgressView().controlSize(.small)
                    } else {
                        Text("Check for Updates")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(appState.isCheckingForUpdate)
            }

            Divider().frame(width: 220)

            VStack(spacing: 8) {
                Text("Fork by \(AppInfo.forkMaker)")
                    .font(.callout.weight(.medium))
                CreatorLinks()
            }

            VStack(spacing: 2) {
                Text("Original CmdMD by \(AppInfo.originalMaker)")
                Text("© 2026 CMDSPACE · MIT License")
            }
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .multilineTextAlignment(.center)

            Button("Done") { dismiss() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(28)
        .frame(width: 360)
        .tint(.cmdsAccent)
    }
}

struct FocusedDocumentKey: FocusedValueKey {
    typealias Value = MarkdownDocument
}

extension FocusedValues {
    var document: MarkdownDocument? {
        get { self[FocusedDocumentKey.self] }
        set { self[FocusedDocumentKey.self] = newValue }
    }
}

#if !SWIFT_PACKAGE
#Preview {
    ContentView()
        .environment(AppState())
        .frame(width: 1200, height: 800)
}
#endif
