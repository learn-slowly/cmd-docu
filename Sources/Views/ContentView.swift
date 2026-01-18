import SwiftUI

struct ContentView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var systemColorScheme
    
    private var effectiveColorScheme: ColorScheme? {
        switch appState.settings.theme {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
    
    var body: some View {
        @Bindable var state = appState
        
        NavigationSplitView(columnVisibility: Binding(
            get: { appState.sidebarVisible ? .all : .detailOnly },
            set: { appState.sidebarVisible = $0 != .detailOnly }
        )) {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 300)
        } detail: {
            MainEditorView()
        }
        .inspector(isPresented: $state.inspectorVisible) {
            InspectorView()
                .inspectorColumnWidth(min: 250, ideal: 280, max: 350)
        }
        .preferredColorScheme(effectiveColorScheme)
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                ViewModePicker()
            }
            
            ToolbarItemGroup(placement: .primaryAction) {
                SendToVaultButton()
                
                Button {
                    appState.inspectorVisible.toggle()
                } label: {
                    Image(systemName: "sidebar.right")
                }
                .help("Toggle Inspector")
            }
        }
        .sheet(isPresented: $state.showSendToVault) {
            SendToVaultSheet()
        }
        .sheet(isPresented: $state.showVaultManager) {
            VaultManagerView()
        }
        .sheet(isPresented: $state.showCommandPalette) {
            CommandPaletteView()
        }
        .overlay {
            if let toast = appState.toastMessage {
                ToastView(message: toast)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: appState.toastMessage)
        .focusedSceneValue(\.document, appState.currentDocument)
    }
}

struct ViewModePicker: View {
    @Environment(AppState.self) private var appState
    
    var body: some View {
        @Bindable var state = appState
        
        Picker("View Mode", selection: $state.viewMode) {
            Image(systemName: "text.alignleft")
                .tag(ViewMode.source)
                .help("Source Only")
            
            Image(systemName: "rectangle.split.2x1")
                .tag(ViewMode.split)
                .help("Split View")
            
            Image(systemName: "eye")
                .tag(ViewMode.preview)
                .help("Preview Only")
        }
        .pickerStyle(.segmented)
        .fixedSize()
    }
}

struct SendToVaultButton: View {
    @Environment(AppState.self) private var appState
    
    var body: some View {
        Menu {
            if appState.vaults.isEmpty {
                Text("No vaults configured")
                Button("Add Vault...") {
                    appState.showVaultManager = true
                }
            } else {
                ForEach(appState.vaults) { vault in
                    Button {
                        Task {
                            var options = SendOptions()
                            options.targetVault = vault
                            try? await appState.sendToVault(options: options)
                        }
                    } label: {
                        Label(vault.displayName, systemImage: "folder")
                    }
                }
                
                Divider()
                
                Button("More Options...") {
                    appState.showSendToVault = true
                }
            }
        } label: {
            Image(systemName: "paperplane")
        }
        .disabled(appState.currentDocument == nil)
        .help("Send to Vault")
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

struct FocusedDocumentKey: FocusedValueKey {
    typealias Value = MarkdownDocument
}

extension FocusedValues {
    var document: MarkdownDocument? {
        get { self[FocusedDocumentKey.self] }
        set { self[FocusedDocumentKey.self] = newValue }
    }
}

#Preview {
    ContentView()
        .environment(AppState())
        .frame(width: 1200, height: 800)
}
