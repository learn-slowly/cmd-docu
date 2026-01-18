import SwiftUI

@main
struct CmdMDApp: App {
    @State private var appState = AppState()
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
                .onOpenURL { url in
                    handleURL(url)
                }
                .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                    handleDrop(providers)
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unified(showsTitle: false))
        .defaultSize(width: 1200, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Draft") {
                    appState.createNewDraft()
                }
                .keyboardShortcut("n", modifiers: .command)
                
                Divider()
                
                Button("Open File...") {
                    appState.openFile()
                }
                .keyboardShortcut("o", modifiers: .command)
                
                Button("Open Folder...") {
                    appState.openFolder()
                }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                
                Divider()
                
                Menu("Open Recent") {
                    ForEach(appState.recentFiles.prefix(10), id: \.self) { url in
                        Button(url.lastPathComponent) {
                            appState.openDocument(at: url)
                        }
                    }
                    
                    if !appState.recentFiles.isEmpty {
                        Divider()
                        Button("Clear Recent") {
                            appState.clearRecentFiles()
                        }
                    }
                }
            }
            
            CommandGroup(replacing: .saveItem) {
                Button("Save") {
                    Task { await appState.saveCurrentDocument() }
                }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!appState.isDirty)
                
                Button("Save As...") {
                    Task { await appState.saveDocumentAs() }
                }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(appState.currentDocument == nil)
                
                Divider()
                
                Button("Export as HTML...") {
                    appState.exportAsHTML()
                }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(appState.currentDocument == nil)
                
                Button("Export as PDF...") {
                    appState.exportAsPDF()
                }
                .disabled(appState.currentDocument == nil)
                
                Button("Copy as HTML") {
                    appState.copyAsHTML()
                }
                .disabled(appState.currentDocument == nil)
            }
            
            CommandMenu("View") {
                Button("Source Only") {
                    appState.viewMode = .source
                }
                .keyboardShortcut("1", modifiers: .command)
                
                Button("Split View") {
                    appState.viewMode = .split
                }
                .keyboardShortcut("2", modifiers: .command)
                
                Button("Preview Only") {
                    appState.viewMode = .preview
                }
                .keyboardShortcut("3", modifiers: .command)
                
                Divider()
                
                Button("Toggle Sidebar") {
                    withAnimation {
                        appState.sidebarVisible.toggle()
                    }
                }
                .keyboardShortcut("b", modifiers: .command)
                
                Button("Toggle Inspector") {
                    withAnimation {
                        appState.inspectorVisible.toggle()
                    }
                }
                .keyboardShortcut("i", modifiers: [.command, .option])
                
                Divider()
                
                Button("Toggle Tab Bar") {
                    appState.settings.showTabBar.toggle()
                }
                
                Button("Toggle Status Bar") {
                    appState.settings.showStatusBar.toggle()
                }
            }
            
            CommandMenu("Tab") {
                Button("New Tab") {
                    appState.createNewTab()
                }
                .keyboardShortcut("t", modifiers: .command)
                
                Button("Close Tab") {
                    if let tab = appState.activeTab {
                        appState.closeTab(tab)
                    }
                }
                .keyboardShortcut("w", modifiers: .command)
                .disabled(appState.tabs.isEmpty)
                
                Divider()
                
                Button("Next Tab") {
                    appState.selectNextTab()
                }
                .keyboardShortcut("]", modifiers: [.command, .shift])
                .disabled(appState.tabs.count <= 1)
                
                Button("Previous Tab") {
                    appState.selectPreviousTab()
                }
                .keyboardShortcut("[", modifiers: [.command, .shift])
                .disabled(appState.tabs.count <= 1)
                
                Divider()
                
                ForEach(0..<min(9, appState.tabs.count), id: \.self) { index in
                    Button("Tab \(index + 1): \(appState.tabs[index].displayTitle)") {
                        appState.selectTab(at: index)
                    }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                }
            }
            
            CommandMenu("Find") {
                Button("Find in Document...") {
                    NotificationCenter.default.post(name: .showDocumentSearch, object: nil)
                }
                .keyboardShortcut("f", modifiers: .command)
                
                Button("Find in Folder...") {
                    appState.selectedSidebarTab = .files
                    appState.sidebarVisible = true
                }
                .keyboardShortcut("f", modifiers: [.command, .shift])
            }
            
            CommandMenu("Vault") {
                Button("Send to Vault...") {
                    appState.showSendToVault = true
                }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(appState.currentDocument == nil)
                
                Divider()
                
                Button("Manage Vaults...") {
                    appState.showVaultManager = true
                }
            }
            
            CommandGroup(replacing: .help) {
                Button("Command Palette") {
                    appState.showCommandPalette = true
                }
                .keyboardShortcut("k", modifiers: .command)
            }
        }
        
        Settings {
            SettingsView()
                .environment(appState)
        }
        
        // Menu bar quick capture
        MenuBarExtra("CmdMD", systemImage: "doc.text") {
            MenuBarView()
                .environment(appState)
        }
        .menuBarExtraStyle(.window)
    }
    
    private func handleURL(_ url: URL) {
        if url.scheme == "cmdmd" {
            // Handle custom URL scheme
            if url.host == "open", let path = url.pathComponents.dropFirst().first {
                let fileURL = URL(fileURLWithPath: path)
                appState.openDocument(at: fileURL)
            }
        } else if url.isFileURL {
            appState.openDocument(at: url)
        }
    }
    
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier("public.file-url") {
                provider.loadItem(forTypeIdentifier: "public.file-url", options: nil) { item, _ in
                    if let data = item as? Data,
                       let url = URL(dataRepresentation: data, relativeTo: nil) {
                        DispatchQueue.main.async {
                            appState.openDocument(at: url)
                        }
                    }
                }
                return true
            }
        }
        return false
    }
}

// MARK: - AppDelegate for Menu Bar & Global Hotkey
class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Register for global hotkey (Cmd+Shift+M for quick capture)
        NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.modifierFlags.contains([.command, .shift]) && event.keyCode == 46 { // M key
                self?.showQuickCapture()
            }
        }
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false // Keep running for menu bar
    }
    
    private func showQuickCapture() {
        // Post notification to show quick capture
        NotificationCenter.default.post(name: .showQuickCapture, object: nil)
    }
}

extension Notification.Name {
    static let showQuickCapture = Notification.Name("showQuickCapture")
    static let showDocumentSearch = Notification.Name("showDocumentSearch")
}
