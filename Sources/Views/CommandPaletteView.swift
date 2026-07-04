import SwiftUI

/// Reference-type state for the palette. A class (not @State value) is required
/// because the ↑/↓ key monitor is an escaping closure — mutating @State through a
/// captured View value doesn't re-render, but mutating an @Observable object does.
@Observable final class CommandPaletteModel {
    var query = ""
    var selectedIndex = 0
    var navigatingByKeyboard = false
}

struct CommandPaletteView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var model = CommandPaletteModel()

    var filteredCommands: [Command] {
        let allCommands = Command.allCommands(appState: appState)
        guard !model.query.isEmpty else { return allCommands }

        return allCommands
            .compactMap { command -> (Command, Int)? in
                guard let score = command.matchScore(for: model.query) else { return nil }
                return (command, score)
            }
            .sorted { $0.1 > $1.1 }
            .map { $0.0 }
    }

    var body: some View {
        @Bindable var model = model

        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)

                PaletteTextField(
                    text: $model.query,
                    placeholder: "Type a command or file name…",
                    onMoveUp: { moveSelection(-1) },
                    onMoveDown: { moveSelection(1) },
                    onSubmit: { executeSelectedCommand() },
                    onCancel: { dismiss() }
                )
                .frame(height: 24)

                if !model.query.isEmpty {
                    Button {
                        model.query = ""
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
                    VStack(spacing: 0) {
                        ForEach(Array(filteredCommands.enumerated()), id: \.element.id) { index, command in
                            CommandRow(
                                command: command,
                                isSelected: index == model.selectedIndex
                            )
                            .id(index)
                            .contentShape(Rectangle())
                            .onHover { hovering in
                                if hovering {
                                    model.navigatingByKeyboard = false
                                    model.selectedIndex = index
                                }
                            }
                            .onTapGesture {
                                model.selectedIndex = index
                                executeSelectedCommand()
                            }
                        }
                    }
                    .padding(.vertical, 8)
                }
                .onChange(of: model.selectedIndex) { _, newIndex in
                    guard model.navigatingByKeyboard else { return }
                    withAnimation {
                        proxy.scrollTo(newIndex, anchor: .center)
                    }
                }
            }
        }
        .frame(width: 520, height: 420)
        .tint(.cmdsAccent)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .shadow(color: .black.opacity(0.2), radius: 20, y: 10)
        .onChange(of: model.query) { _, _ in
            model.selectedIndex = 0
        }
    }

    /// Moves the highlight by `delta`, clamped to the result list.
    private func moveSelection(_ delta: Int) {
        let count = filteredCommands.count
        guard count > 0 else { return }
        model.navigatingByKeyboard = true
        model.selectedIndex = min(max(model.selectedIndex + delta, 0), count - 1)
    }

    private func executeSelectedCommand() {
        guard model.selectedIndex < filteredCommands.count else { return }
        let command = filteredCommands[model.selectedIndex]
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
                .foregroundStyle(isSelected ? Color.cmdsAccentOn : .secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(command.title)
                    .font(.body)
                    .foregroundStyle(isSelected ? Color.cmdsAccentOn : .primary)

                if let subtitle = command.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(isSelected ? Color.cmdsAccentOn.opacity(0.8) : .secondary)
                        .lineLimit(1)
                }
            }

            Spacer()

            if let shortcut = command.shortcut {
                Text(shortcut)
                    .font(.caption.monospaced())
                    .foregroundStyle(isSelected ? Color.cmdsAccentOn.opacity(0.8) : .secondary.opacity(0.6))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(isSelected ? Color.cmdsAccent : Color.clear)
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

    /// Fuzzy subsequence score: every query character must appear in order in
    /// the title or a keyword. Consecutive runs and word-start hits rank higher,
    /// so "otv" finds "Open in Obsidian: TOC View" style entries sensibly.
    func matchScore(for query: String) -> Int? {
        let candidates = [title] + keywords + [subtitle ?? ""]
        var best: Int?
        for candidate in candidates {
            if let score = Self.fuzzyScore(query: query.lowercased(), in: candidate.lowercased()) {
                best = max(best ?? Int.min, score)
            }
        }
        return best
    }

    static func fuzzyScore(query: String, in candidate: String) -> Int? {
        guard !query.isEmpty else { return 0 }
        var score = 0
        var lastMatchIndex: String.Index?
        var searchStart = candidate.startIndex

        for char in query {
            guard let found = candidate[searchStart...].firstIndex(of: char) else { return nil }

            if let last = lastMatchIndex, candidate.index(after: last) == found {
                score += 8 // consecutive run
            } else if found == candidate.startIndex {
                score += 10 // start of string
            } else {
                let before = candidate[candidate.index(before: found)]
                score += (before == " " || before == "/" || before == "-") ? 6 : 1
            }

            lastMatchIndex = found
            searchStart = candidate.index(after: found)
        }

        // Shorter candidates with the same hits rank higher.
        score -= candidate.count / 8
        return score
    }

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
                shortcut: "⌥⌘O",
                keywords: ["open", "folder", "directory"]
            ) {
                appState.openFolder()
            },

            Command(
                title: "Omnisearch",
                subtitle: "Search file names and contents everywhere",
                icon: "sparkle.magnifyingglass",
                shortcut: "⇧⌘O",
                keywords: ["omnisearch", "search", "find", "everywhere", "quick", "switcher"]
            ) {
                appState.showOmnisearch = true
            },

            Command(
                title: "내용 검색 (인덱스)",
                subtitle: "등록 폴더의 본문을 키워드로 검색",
                icon: "magnifyingglass.circle",
                shortcut: nil,
                keywords: ["내용", "검색", "인덱스", "index", "search", "fts", "keyword"]
            ) {
                appState.showIndexSearch = true
            },

            Command(
                title: "자료에 묻기 (RAG)",
                subtitle: "등록 폴더를 근거로 Claude가 답하고 출처를 표시",
                icon: "text.magnifyingglass",
                shortcut: nil,
                keywords: ["자료", "질문", "묻기", "rag", "ask", "claude", "근거", "출처"]
            ) {
                appState.showAskCorpus = true
            },

            Command(
                title: "폴더 정리 (배치)",
                subtitle: "Claude 제안으로 폴더를 종류·주제별로 정리",
                icon: "folder.badge.gearshape",
                shortcut: nil,
                keywords: ["정리", "폴더", "cleanup", "organize", "batch", "para", "이동"]
            ) {
                appState.resetCleanup()
                appState.showFolderCleanup = true
            },

            Command(
                title: "정보 보기",
                subtitle: "현재 파일 또는 폴더의 종류·크기·날짜",
                icon: "info.circle",
                shortcut: appState.keyBinding(for: .fileInfo).displayString,
                keywords: ["정보", "info", "크기", "size", "날짜", "get info", "파일 정보"]
            ) {
                appState.showFileInfoForCurrentContext()
            },

            Command(
                title: "뒤로 (폴더 히스토리)",
                subtitle: "이전에 보던 폴더로",
                icon: "chevron.left",
                shortcut: appState.keyBinding(for: .navigateBack).displayString,
                keywords: ["뒤로", "back", "history", "히스토리", "폴더", "이전"]
            ) {
                appState.goBackInHistory()
            },

            Command(
                title: "앞으로 (폴더 히스토리)",
                subtitle: "다음 폴더로",
                icon: "chevron.right",
                shortcut: appState.keyBinding(for: .navigateForward).displayString,
                keywords: ["앞으로", "forward", "history", "히스토리", "폴더", "다음"]
            ) {
                appState.goForwardInHistory()
            },

            Command(
                title: "상위 폴더",
                subtitle: "라이브러리 표시 폴더의 상위로",
                icon: "chevron.up",
                shortcut: appState.keyBinding(for: .navigateUp).displayString,
                keywords: ["상위", "up", "enclosing", "parent", "폴더"]
            ) {
                appState.goUpInLibrary()
            },

            Command(
                title: "파일 작업 기록",
                subtitle: "휴지통·이름 변경 기록을 보고 되돌리기",
                icon: "clock.arrow.circlepath",
                shortcut: nil,
                keywords: ["기록", "되돌리기", "undo", "휴지통", "history", "파일 작업"]
            ) {
                appState.showFileOpsHistory = true
            },

            Command(
                title: "Ask Claude",
                subtitle: "Ask Claude about the open document",
                icon: "sparkles",
                shortcut: appState.keyBinding(for: .askClaude).displayString,
                keywords: ["claude", "ai", "ask", "assistant", "chat"]
            ) {
                appState.claudePanelVisible = true
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
                title: "Reload from Disk",
                subtitle: "Discard in-memory changes and reload",
                icon: "arrow.clockwise",
                shortcut: "⌥⌘R",
                keywords: ["reload", "refresh", "revert"]
            ) {
                appState.reloadCurrentDocument()
            },

            Command(
                title: "Quick Capture",
                subtitle: "Capture a quick note",
                icon: "bolt",
                shortcut: "⇧⌘M",
                keywords: ["quick", "capture", "note", "scratch"]
            ) {
                appState.showQuickCapture = true
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
                title: "Auto-Route Send",
                subtitle: "Send using routing rules, no dialog",
                icon: "arrow.triangle.branch",
                shortcut: "⌃⌘T",
                keywords: ["auto", "route", "send", "rule"]
            ) {
                appState.autoRouteCurrentDocument()
            },

            Command(
                title: "Manage Vaults, Templates & Rules",
                subtitle: "Configure vault connections",
                icon: "folder.badge.gearshape",
                shortcut: nil,
                keywords: ["vault", "manage", "configure", "template", "rule"]
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
                shortcut: "⌃⌘B",
                keywords: ["sidebar", "toggle", "hide", "show"]
            ) {
                appState.sidebarVisible.toggle()
            },

            Command(
                title: "Toggle Inspector",
                subtitle: "Show or hide the inspector panel",
                icon: "sidebar.right",
                shortcut: appState.keyBinding(for: .toggleInspector).displayString,
                keywords: ["inspector", "toggle", "info", "details", "toc", "properties"]
            ) {
                appState.inspectorVisible.toggle()
            },

            Command(
                title: "Toggle Line Numbers",
                subtitle: nil,
                icon: "list.number",
                shortcut: nil,
                keywords: ["line", "numbers", "gutter"]
            ) {
                appState.settings.showLineNumbers.toggle()
                appState.saveUserData()
            },

            Command(
                title: "Toggle Scroll Sync",
                subtitle: "Sync editor and preview scrolling in split view",
                icon: "link",
                shortcut: nil,
                keywords: ["scroll", "sync", "split"]
            ) {
                appState.settings.scrollSyncEnabled.toggle()
                appState.saveUserData()
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

        for theme in EditorTheme.allCases {
            commands.append(Command(
                title: "Editor Theme: \(theme.rawValue)",
                subtitle: nil,
                icon: "paintpalette",
                shortcut: nil,
                keywords: ["theme", "editor", "color", theme.rawValue]
            ) {
                appState.settings.editorTheme = theme
                appState.saveUserData()
            })
        }

        for theme in PreviewTheme.allCases {
            commands.append(Command(
                title: "Preview Theme: \(theme.rawValue)",
                subtitle: nil,
                icon: "paintbrush",
                shortcut: nil,
                keywords: ["theme", "preview", theme.rawValue]
            ) {
                appState.settings.previewTheme = theme.rawValue
                appState.saveUserData()
            })
        }

        for file in appState.recentFiles.prefix(8) {
            commands.append(Command(
                title: file.deletingPathExtension().lastPathComponent,
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
                subtitle: "Send current file to \(vault.displayName) inbox",
                icon: "folder",
                shortcut: nil,
                keywords: ["send", "vault", vault.name]
            ) {
                Task {
                    var options = SendOptions()
                    options.targetVault = vault
                    options.targetFolder = appState.effectiveSendFolder(for: vault)
                    options.conflictResolution = appState.settings.conflictResolution
                    options.injectFrontmatter = appState.settings.injectFrontmatterByDefault
                    try? await appState.sendToVault(options: options)
                }
            })
        }

        return commands
    }
}

#if !SWIFT_PACKAGE
#Preview {
    CommandPaletteView()
        .environment(AppState())
}
#endif
