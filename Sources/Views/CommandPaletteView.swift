import SwiftUI

struct CommandPaletteView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    
    @State private var searchText: String = ""
    @State private var selectedIndex: Int = 0
    @FocusState private var isSearchFocused: Bool
    
    var filteredCommands: [Command] {
        let allCommands = Command.allCommands(appState: appState)
        if searchText.isEmpty {
            return allCommands
        }
        return allCommands.filter { command in
            command.title.localizedCaseInsensitiveContains(searchText) ||
            command.keywords.contains { $0.localizedCaseInsensitiveContains(searchText) }
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                
                TextField("Type a command...", text: $searchText)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .focused($isSearchFocused)
                    .onSubmit {
                        executeSelectedCommand()
                    }
                
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                
                Text("ESC")
                    .font(.caption.monospaced())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.2))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .padding()
            .background(.bar)
            
            Divider()
            
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(filteredCommands.enumerated()), id: \.element.id) { index, command in
                            CommandRow(
                                command: command,
                                isSelected: index == selectedIndex
                            )
                            .id(index)
                            .onTapGesture {
                                selectedIndex = index
                                executeSelectedCommand()
                            }
                        }
                    }
                    .padding(.vertical, 8)
                }
                .onChange(of: selectedIndex) { _, newIndex in
                    withAnimation {
                        proxy.scrollTo(newIndex, anchor: .center)
                    }
                }
            }
        }
        .frame(width: 500, height: 400)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.2), radius: 20, y: 10)
        .onAppear {
            isSearchFocused = true
        }
        .onKeyPress(.upArrow) {
            if selectedIndex > 0 {
                selectedIndex -= 1
            }
            return .handled
        }
        .onKeyPress(.downArrow) {
            if selectedIndex < filteredCommands.count - 1 {
                selectedIndex += 1
            }
            return .handled
        }
        .onKeyPress(.escape) {
            dismiss()
            return .handled
        }
        .onChange(of: searchText) { _, _ in
            selectedIndex = 0
        }
    }
    
    private func executeSelectedCommand() {
        guard selectedIndex < filteredCommands.count else { return }
        let command = filteredCommands[selectedIndex]
        dismiss()
        command.action()
    }
}

struct CommandRow: View {
    let command: Command
    let isSelected: Bool
    
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: command.icon)
                .font(.title3)
                .frame(width: 24)
                .foregroundStyle(isSelected ? .white : .secondary)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(command.title)
                    .font(.body)
                    .foregroundStyle(isSelected ? .white : .primary)
                
                if let subtitle = command.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(isSelected ? .white.opacity(0.8) : .secondary)
                }
            }
            
            Spacer()
            
            if let shortcut = command.shortcut {
                    Text(shortcut)
                        .font(.caption.monospaced())
                        .foregroundStyle(isSelected ? .white.opacity(0.8) : .secondary.opacity(0.6))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(isSelected ? Color.accentColor : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 8)
    }
}

struct Command: Identifiable {
    let id = UUID()
    let title: String
    let subtitle: String?
    let icon: String
    let shortcut: String?
    let keywords: [String]
    let action: () -> Void
    
    static func allCommands(appState: AppState) -> [Command] {
        var commands: [Command] = [
            Command(
                title: "New Draft",
                subtitle: "Create a new draft document",
                icon: "square.and.pencil",
                shortcut: "⌘N",
                keywords: ["new", "create", "draft", "note"]
            ) {
                appState.createNewDraft()
            },
            
            Command(
                title: "Open File",
                subtitle: "Open a Markdown file",
                icon: "doc.badge.plus",
                shortcut: "⌘O",
                keywords: ["open", "file", "browse"]
            ) {
                appState.openFile()
            },
            
            Command(
                title: "Open Folder",
                subtitle: "Open a folder of Markdown files",
                icon: "folder.badge.plus",
                shortcut: "⇧⌘O",
                keywords: ["open", "folder", "directory"]
            ) {
                appState.openFolder()
            },
            
            Command(
                title: "Save",
                subtitle: "Save the current document",
                icon: "square.and.arrow.down",
                shortcut: "⌘S",
                keywords: ["save", "write"]
            ) {
                Task { await appState.saveCurrentDocument() }
            },
            
            Command(
                title: "Send to Vault",
                subtitle: "Send current file to an Obsidian vault",
                icon: "paperplane",
                shortcut: "⇧⌘T",
                keywords: ["send", "vault", "obsidian", "route"]
            ) {
                appState.showSendToVault = true
            },
            
            Command(
                title: "Manage Vaults",
                subtitle: "Configure Obsidian vault connections",
                icon: "folder.badge.gearshape",
                shortcut: nil,
                keywords: ["vault", "manage", "configure", "settings"]
            ) {
                appState.showVaultManager = true
            },
            
            Command(
                title: "Source View",
                subtitle: "Show source code only",
                icon: "text.alignleft",
                shortcut: "⌘1",
                keywords: ["view", "source", "edit", "code"]
            ) {
                appState.viewMode = .source
            },
            
            Command(
                title: "Split View",
                subtitle: "Show editor and preview side by side",
                icon: "rectangle.split.2x1",
                shortcut: "⌘2",
                keywords: ["view", "split", "side"]
            ) {
                appState.viewMode = .split
            },
            
            Command(
                title: "Preview",
                subtitle: "Show rendered preview only",
                icon: "eye",
                shortcut: "⌘3",
                keywords: ["view", "preview", "render"]
            ) {
                appState.viewMode = .preview
            },
            
            Command(
                title: "Toggle Sidebar",
                subtitle: "Show or hide the sidebar",
                icon: "sidebar.left",
                shortcut: "⌘B",
                keywords: ["sidebar", "toggle", "hide", "show"]
            ) {
                appState.sidebarVisible.toggle()
            },
            
            Command(
                title: "Toggle Inspector",
                subtitle: "Show or hide the inspector panel",
                icon: "sidebar.right",
                shortcut: "⌥⌘I",
                keywords: ["inspector", "toggle", "info", "details"]
            ) {
                appState.inspectorVisible.toggle()
            },
            
            Command(
                title: "Export as HTML",
                subtitle: "Save document as HTML file",
                icon: "doc.richtext",
                shortcut: "⇧⌘E",
                keywords: ["export", "html", "save"]
            ) {
                appState.exportAsHTML()
            },
            
            Command(
                title: "Export as PDF",
                subtitle: "Save document as PDF file",
                icon: "doc.fill",
                shortcut: nil,
                keywords: ["export", "pdf", "save", "print"]
            ) {
                appState.exportAsPDF()
            },
            
            Command(
                title: "Copy as HTML",
                subtitle: "Copy rendered HTML to clipboard",
                icon: "doc.on.doc",
                shortcut: nil,
                keywords: ["copy", "html", "clipboard"]
            ) {
                appState.copyAsHTML()
            }
        ]
        
        for file in appState.recentFiles.prefix(5) {
            commands.append(Command(
                title: file.lastPathComponent,
                subtitle: file.deletingLastPathComponent().path,
                icon: "doc.text",
                shortcut: nil,
                keywords: ["recent", "file", file.lastPathComponent]
            ) {
                appState.openDocument(at: file)
            })
        }
        
        for vault in appState.vaults {
            commands.append(Command(
                title: "Send to \(vault.displayName)",
                subtitle: "Send current file to \(vault.displayName) vault",
                icon: "folder",
                shortcut: nil,
                keywords: ["send", "vault", vault.name]
            ) {
                Task {
                    var options = SendOptions()
                    options.targetVault = vault
                    try? await appState.sendToVault(options: options)
                }
            })
        }
        
        return commands
    }
}

#Preview {
    CommandPaletteView()
        .environment(AppState())
}
