import SwiftUI

// MARK: - LibraryView

/// 폴더 항목을 격자/리스트로 훑는 라이브러리 뷰.
/// 읽기·탐색 전용 — 파일 이동·삭제 없음.
struct LibraryView: View {
    @Environment(AppState.self) private var appState

    /// 현재 표시할 폴더. selectedFolder ?? currentFolder.
    private var displayFolder: URL? {
        appState.selectedFolder ?? appState.currentFolder
    }

    /// 상위 폴더로 이동 가능한가(currentFolder보다 위로는 안 감).
    private var canGoUp: Bool {
        guard let display = displayFolder,
              let root = appState.currentFolder else { return false }
        // standardizedFileURL로 비교해 /var → /private/var 차이를 없앤다.
        let displayStd = display.standardizedFileURL.path
        let rootStd    = root.standardizedFileURL.path
        return displayStd != rootStd && displayStd.hasPrefix(rootStd)
    }

    var body: some View {
        VStack(spacing: 0) {
            libraryHeader
            Divider()
            libraryBody
        }
    }

    // MARK: - 헤더

    private var libraryHeader: some View {
        HStack(spacing: 6) {
            if canGoUp {
                Button {
                    goUp()
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.borderless)
                .help("상위 폴더로")
            }

            Text(displayFolder?.lastPathComponent ?? "라이브러리")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - 본문

    @ViewBuilder
    private var libraryBody: some View {
        if let folder = displayFolder {
            let entries = ParaLens.sorted(
                LibraryListing.entries(of: folder),
                under: appState.currentFolder
            )

            if entries.isEmpty {
                ContentUnavailableView {
                    Label("이 폴더에 항목이 없습니다", systemImage: "folder")
                } description: {
                    Text(folder.lastPathComponent)
                        .foregroundStyle(.secondary)
                }
            } else {
                switch appState.libraryLayout {
                case .grid:
                    gridView(entries: entries)
                case .list:
                    listView(entries: entries)
                }
            }
        } else {
            ContentUnavailableView {
                Label("폴더를 여세요", systemImage: "folder.badge.plus")
            } description: {
                Text("사이드바에서 폴더를 열면 라이브러리로 탐색할 수 있습니다.")
            }
        }
    }

    // MARK: - 격자 뷰

    private func gridView(entries: [FileTreeItem]) -> some View {
        let columns = [GridItem(.adaptive(minimum: 90, maximum: 120), spacing: 12)]

        return ScrollView {
            LazyVGrid(columns: columns, spacing: 16) {
                ForEach(entries) { item in
                    LibraryGridCell(item: item)
                        .onTapGesture {
                            handleTap(item: item)
                        }
                }
            }
            .padding(16)
        }
    }

    // MARK: - 리스트 뷰

    private func listView(entries: [FileTreeItem]) -> some View {
        List(entries) { item in
            LibraryListCell(item: item)
                .onTapGesture {
                    handleTap(item: item)
                }
                .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
        }
        .listStyle(.plain)
    }

    // MARK: - 탭 처리

    private func handleTap(item: FileTreeItem) {
        if item.isDirectory {
            // 폴더 → 드릴인(library 유지)
            appState.selectedFolder = item.url
        } else {
            // 파일 → 리더 전환 (openDocument 내부에서 mainMode = .reader 설정)
            appState.openDocument(at: item.url, inNewTab: true)
        }
    }

    // MARK: - 상위 이동

    private func goUp() {
        guard let current = displayFolder,
              let root = appState.currentFolder else { return }
        let parent = current.deletingLastPathComponent()
        // root보다 위로는 올라가지 않는다
        let parentStd = parent.standardizedFileURL.path
        let rootStd   = root.standardizedFileURL.path
        if parentStd == rootStd || parentStd.hasPrefix(rootStd) {
            appState.selectedFolder = parent
        }
    }
}

// MARK: - 격자 셀

struct LibraryGridCell: View {
    @Environment(AppState.self) private var appState
    let item: FileTreeItem

    private var paraCategory: ParaCategory {
        ParaLens.classify(item.url, under: appState.currentFolder)
    }

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: cellIcon)
                .font(.system(size: 32))
                .foregroundStyle(iconColor)

            Text(item.name)
                .font(.caption)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .foregroundStyle(.primary)
        }
        .padding(8)
        .frame(maxWidth: .infinity)
        .opacity(paraCategory == .archive ? 0.45 : 1.0)
        .contentShape(Rectangle())
    }

    private var cellIcon: String {
        item.isDirectory ? "folder" : item.icon
    }

    private var iconColor: Color {
        if item.isDirectory && paraCategory == .projects {
            return .cmdsAccent
        }
        return .secondary
    }
}

// MARK: - 리스트 셀

struct LibraryListCell: View {
    @Environment(AppState.self) private var appState
    let item: FileTreeItem

    private var paraCategory: ParaCategory {
        ParaLens.classify(item.url, under: appState.currentFolder)
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: item.isDirectory ? "folder" : item.icon)
                .font(.system(size: 14))
                .foregroundStyle(iconColor)
                .frame(width: 20)

            Text(item.name)
                .lineLimit(1)
                .font(paraCategory == .projects && item.isDirectory ? .body.weight(.medium) : .body)
        }
        .opacity(paraCategory == .archive ? 0.45 : 1.0)
        .contentShape(Rectangle())
        .padding(.vertical, 2)
    }

    private var iconColor: Color {
        if item.isDirectory && paraCategory == .projects {
            return .cmdsAccent
        }
        return .secondary
    }
}
