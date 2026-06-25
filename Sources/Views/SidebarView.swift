import SwiftUI

struct SidebarView: View {
    @Environment(AppState.self) private var appState
    @State private var showSearch = false
    
    var body: some View {
        @Bindable var state = appState
        
        HStack(spacing: 0) {
            SidebarRibbon()

            Divider()

            Group {
                if showSearch {
                    FolderSearchView(showSearch: $showSearch)
                } else {
                    switch appState.selectedSidebarTab {
                    case .files:
                        FileTreeView(showSearch: $showSearch)
                    case .favorites:
                        FavoritesListView()
                    case .drafts:
                        DraftListView()
                    case .recent:
                        RecentFilesView()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// VS Code / Obsidian-style vertical activity ribbon pinned to the sidebar's
/// leading edge. Section switchers up top; open/settings actions at the bottom.
struct SidebarRibbon: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        VStack(spacing: 4) {
            ForEach(SidebarTab.allCases, id: \.self) { tab in
                RibbonButton(
                    icon: tab.icon,
                    help: tab.rawValue,
                    isActive: appState.selectedSidebarTab == tab
                ) {
                    appState.selectedSidebarTab = tab
                }
            }

            Spacer(minLength: 8)

            RibbonButton(icon: "folder.badge.plus", help: "Open Folder (⌥⌘O)") {
                appState.openFolder()
            }
            RibbonButton(icon: "doc.badge.plus", help: "Open File (⌘O)") {
                appState.openFile()
            }
            SettingsLink {
                RibbonIcon(systemName: "gearshape", isActive: false, isHovering: false)
            }
            .buttonStyle(.plain)
            .help("Settings (⌘,)")
        }
        .padding(.vertical, 10)
        .frame(maxHeight: .infinity)
        .frame(width: 46)
    }
}

/// A flat, background-less ribbon icon. Active state is shown by an accent glyph
/// plus a thin leading bar — never a filled box, so it sits cleanly over headers.
struct RibbonButton: View {
    let icon: String
    let help: String
    var isActive: Bool = false
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            RibbonIcon(systemName: icon, isActive: isActive, isHovering: isHovering)
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help(help)
    }
}

struct RibbonIcon: View {
    let systemName: String
    var isActive: Bool
    var isHovering: Bool

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 16, weight: isActive ? .semibold : .regular))
            .frame(maxWidth: .infinity)
            .frame(height: 30)
            .foregroundStyle(
                isActive
                    ? AnyShapeStyle(Color.cmdsAccent)
                    : AnyShapeStyle(isHovering ? Color.primary : Color.secondary)
            )
            .overlay(alignment: .leading) {
                if isActive {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Color.cmdsAccent)
                        .frame(width: 2.5, height: 18)
                }
            }
            .contentShape(Rectangle())
    }
}

struct FileTreeView: View {
    @Environment(AppState.self) private var appState
    @Binding var showSearch: Bool
    
    var body: some View {
        Group {
            if appState.currentFolder == nil {
                VStack(alignment: .leading, spacing: 16) {
                    Image(systemName: "folder")
                        .font(.system(size: 36))
                        .foregroundStyle(.secondary)
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text("No Folder Open")
                            .font(.headline)
                        Text("Open a folder to browse files")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    
                    Button("Open Folder") {
                        appState.openFolder()
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding(20)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                List {
                    ForEach(appState.fileTree) { item in
                        FileTreeItemRow(item: item)
                    }
                }
                .listStyle(.sidebar)
            }
        }
        .navigationTitle(appState.currentFolder?.lastPathComponent ?? "Files")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                HStack(spacing: 8) {
                    Button {
                        showSearch = true
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .disabled(appState.currentFolder == nil)
                    .help("Search in Folder (⇧⌘F)")
                    
                    Button {
                        appState.loadFileTree()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .disabled(appState.currentFolder == nil)
                }
            }
        }
    }
}

struct FolderSearchView: View {
    @Environment(AppState.self) private var appState
    @Binding var showSearch: Bool
    @FocusState private var isSearchFieldFocused: Bool
    
    var body: some View {
        @Bindable var state = appState
        
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                
                TextField("Search in folder...", text: $state.folderSearchText)
                    .textFieldStyle(.plain)
                    .focused($isSearchFieldFocused)
                    .onSubmit {
                        appState.searchInFolder(query: appState.folderSearchText)
                    }
                
                if !appState.folderSearchText.isEmpty {
                    Button {
                        appState.clearSearch()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                
                Button {
                    showSearch = false
                    appState.clearSearch()
                } label: {
                    Text("Cancel")
                        .font(.system(size: 12))
                }
                .buttonStyle(.plain)
            }
            .padding(8)
            .background(Color(nsColor: .controlBackgroundColor))
            
            Divider()
            
            if appState.isSearching {
                VStack {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Searching...")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if appState.searchResults.isEmpty && !appState.folderSearchText.isEmpty {
                ContentUnavailableView {
                    Label("No Results", systemImage: "doc.text.magnifyingglass")
                } description: {
                    Text("No matches found for \"\(appState.folderSearchText)\"")
                }
            } else {
                SearchResultsList()
            }
        }
        .onAppear {
            isSearchFieldFocused = true
        }
    }
}

struct SearchResultsList: View {
    @Environment(AppState.self) private var appState
    
    private var groupedResults: [URL: [SearchResult]] {
        Dictionary(grouping: appState.searchResults, by: { $0.fileURL })
    }
    
    var body: some View {
        List {
            ForEach(Array(groupedResults.keys.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })), id: \.self) { fileURL in
                Section {
                    ForEach(groupedResults[fileURL] ?? []) { result in
                        SearchResultRow(result: result)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                // Jump straight to the matched line, not just the file.
                                appState.openDocument(at: result.fileURL, inNewTab: true, scrollToLine: result.lineNumber)
                            }
                    }
                } header: {
                    HStack {
                        Image(systemName: "doc.text")
                            .font(.caption)
                        Text(fileURL.lastPathComponent)
                            .font(.caption.bold())
                        Text("(\(groupedResults[fileURL]?.count ?? 0))")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }
}

struct SearchResultRow: View {
    let result: SearchResult
    
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text("Line \(result.lineNumber)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(3)
                Spacer()
            }
            
            Text(result.lineContent)
                .font(.system(size: 11))
                .lineLimit(2)
                .foregroundColor(.primary)
        }
        .padding(.vertical, 4)
    }
}

struct FileTreeItemRow: View {
    @Environment(AppState.self) private var appState
    let item: FileTreeItem
    
    private var isFavorited: Bool {
        appState.favorites.contains(where: { $0.url == item.url })
    }
    
    var body: some View {
        if item.isDirectory {
            DisclosureGroup(isExpanded: Binding(
                get: { appState.expandedFolders.contains(item.url) },
                set: { _ in appState.toggleFolderExpansion(item.url) }
            )) {
                ForEach(item.children) { child in
                    FileTreeItemRow(item: child)
                }
            } label: {
                HStack(spacing: 4) {
                    Label(item.name, systemImage: item.icon)
                        .lineLimit(1)
                    if isFavorited {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundColor(.yellow)
                    }
                }
            }
            .contextMenu {
                FileTreeContextMenu(item: item)
            }
        } else {
            HStack(spacing: 4) {
                Label(item.name, systemImage: item.icon)
                    .lineLimit(1)
                if isFavorited {
                    Image(systemName: "star.fill")
                        .font(.caption2)
                        .foregroundColor(.yellow)
                }
            }
            .onTapGesture {
                appState.openDocument(at: item.url, inNewTab: true)
            }
            .contextMenu {
                FileTreeContextMenu(item: item)
            }
        }
    }
}

struct FileTreeContextMenu: View {
    @Environment(AppState.self) private var appState
    let item: FileTreeItem
    
    private var isFavorited: Bool {
        appState.favorites.contains(where: { $0.url == item.url })
    }
    
    var body: some View {
        if item.isDirectory {
            Button {
                createNewFile(in: item.url)
            } label: {
                Label("New File", systemImage: "doc.badge.plus")
            }

            Button {
                createNewFolder(in: item.url)
            } label: {
                Label("New Folder", systemImage: "folder.badge.plus")
            }

            Divider()

            Button {
                appState.batchSendURLs = markdownFiles(in: item.url)
                appState.showSendToVault = true
            } label: {
                Label("Send Folder to Vault…", systemImage: "paperplane")
            }

            Divider()
        }
        
        if isFavorited {
            Button {
                if let favorite = appState.favorites.first(where: { $0.url == item.url }) {
                    appState.removeFromFavorites(favorite)
                }
            } label: {
                Label("Remove from Favorites", systemImage: "star.slash")
            }
        } else {
            Button {
                appState.addToFavorites(item.url)
            } label: {
                Label("Add to Favorites", systemImage: "star")
            }
        }
        
        Divider()
        
        Button {
            revealInFinder(item.url)
        } label: {
            Label("Reveal in Finder", systemImage: "folder")
        }
        
        Divider()
        
        Button(role: .destructive) {
            moveToTrash(item.url)
        } label: {
            Label("Move to Trash", systemImage: "trash")
        }
    }
    
    private func createNewFile(in folder: URL) {
        appState.createNewFile(in: folder)
    }

    private func createNewFolder(in parent: URL) {
        appState.createNewFolder(in: parent)
    }

    private func revealInFinder(_ url: URL) {
        NSWorkspace.shared.selectFile(url.path, inFileViewerRootedAtPath: url.deletingLastPathComponent().path)
    }
    
    private func moveToTrash(_ url: URL) {
        try? FileManager.default.trashItem(at: url, resultingItemURL: nil)
        appState.loadFileTree()
    }

    /// All Markdown files directly in `folder` and its subfolders (for batch send).
    private func markdownFiles(in folder: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: folder,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        return enumerator.allObjects
            .compactMap { $0 as? URL }
            .filter { ["md", "markdown"].contains($0.pathExtension.lowercased()) }
            .sorted { $0.path < $1.path }
    }
}

struct FavoritesListView: View {
    @Environment(AppState.self) private var appState
    
    var body: some View {
        List {
            ForEach(appState.favorites) { favorite in
                FavoriteRow(favorite: favorite)
                    .onTapGesture {
                        if FileManager.default.fileExists(atPath: favorite.url.path) {
                            appState.openDocument(at: favorite.url, inNewTab: true)
                        }
                    }
                    .contextMenu {
                        Button(role: .destructive) {
                            appState.removeFromFavorites(favorite)
                        } label: {
                            Label("Remove from Favorites", systemImage: "star.slash")
                        }
                    }
            }
            .onDelete { indexSet in
                for index in indexSet {
                    appState.removeFromFavorites(appState.favorites[index])
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Favorites")
        .overlay {
            if appState.favorites.isEmpty {
                ContentUnavailableView {
                    Label("No Favorites", systemImage: "star")
                } description: {
                    Text("Right-click files to add them to favorites")
                }
            }
        }
    }
}

struct FavoriteRow: View {
    let favorite: FavoriteItem
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "star.fill")
                    .font(.caption)
                    .foregroundColor(.yellow)
                Text(favorite.displayName)
                    .font(.headline)
                    .lineLimit(1)
            }
            
            Text(favorite.url.deletingLastPathComponent().path)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 4)
    }
}

struct DraftListView: View {
    @Environment(AppState.self) private var appState
    
    var activeDrafts: [Draft] {
        appState.drafts.filter { $0.status == .active }
    }
    
    var body: some View {
        List {
            ForEach(activeDrafts) { draft in
                DraftRow(draft: draft)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        appState.openDraft(draft)
                    }
                    .contextMenu {
                        Button {
                            appState.openDraft(draft)
                        } label: {
                            Label("Open", systemImage: "doc.text")
                        }

                        Divider()

                        Button(role: .destructive) {
                            appState.deleteDraft(draft)
                        } label: {
                            Label("Delete Draft", systemImage: "trash")
                        }
                    }
            }
            .onDelete { indexSet in
                for index in indexSet.sorted().reversed() {
                    appState.deleteDraft(activeDrafts[index])
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Drafts")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    appState.createNewDraft()
                } label: {
                    Image(systemName: "plus")
                }
            }
        }
        .overlay {
            if activeDrafts.isEmpty {
                ContentUnavailableView {
                    Label("No Drafts", systemImage: "doc.text")
                } description: {
                    Text("Create a new draft to get started")
                } actions: {
                    Button("New Draft") {
                        appState.createNewDraft()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
    }
}

struct DraftRow: View {
    let draft: Draft
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(draft.displayTitle)
                    .font(.headline)
                    .lineLimit(1)
                
                Spacer()
                
                if draft.sourceDevice != Host.current().localizedName {
                    Image(systemName: "iphone")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            
            Text(draft.body.prefix(100).replacingOccurrences(of: "\n", with: " "))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            
            Text(draft.updatedAt.formatted(.relative(presentation: .named)))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 4)
    }
}

struct RecentFilesView: View {
    @Environment(AppState.self) private var appState
    
    var body: some View {
        List {
            ForEach(appState.recentFiles, id: \.self) { url in
                RecentFileRow(url: url)
                    .onTapGesture {
                        appState.openDocument(at: url, inNewTab: true)
                    }
            }
            .onDelete { indexSet in
                for index in indexSet.sorted().reversed() {
                    appState.recentFiles.remove(at: index)
                }
                appState.saveUserData()
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Recents")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Clear") {
                    appState.clearRecentFiles()
                }
                .disabled(appState.recentFiles.isEmpty)
            }
        }
        .overlay {
            if appState.recentFiles.isEmpty {
                ContentUnavailableView {
                    Label("No Recent Files", systemImage: "clock")
                } description: {
                    Text("Recently opened files will appear here")
                }
            }
        }
    }
}

struct RecentFileRow: View {
    let url: URL
    
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(url.deletingPathExtension().lastPathComponent)
                .font(.headline)
                .lineLimit(1)
            
            Text(url.deletingLastPathComponent().path)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 4)
    }
}

#if !SWIFT_PACKAGE
#Preview {
    NavigationSplitView {
        SidebarView()
    } detail: {
        Text("Detail")
    }
    .environment(AppState())
}
#endif
