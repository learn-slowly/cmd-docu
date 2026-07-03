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

    /// 폴더(또는 정렬 기준 currentFolder)가 바뀔 때, 그리고 파일 작업 후 재계산하기 위한 키.
    private var folderKey: String {
        "\(displayFolder?.path ?? "∅")|\(appState.currentFolder?.path ?? "∅")|\(appState.fileOpsGeneration)"
    }

    /// 캐시된 항목 목록. .task(id: folderKey)로 폴더 변경 시에만 갱신.
    @State private var entries: [FileTreeItem] = []

    /// 상위 폴더로 이동 가능한가(currentFolder보다 위로는 안 감).
    private var canGoUp: Bool {
        guard let display = displayFolder,
              let root = appState.currentFolder else { return false }
        // standardizedFileURL로 비교해 /var → /private/var 차이를 없앤다.
        let displayStd = display.standardizedFileURL.path
        let rootStd    = root.standardizedFileURL.path
        // '/' 경계를 포함해 형제 폴더 오감지를 방지한다.
        return displayStd != rootStd && displayStd.hasPrefix(rootStd + "/")
    }

    private func reloadEntries() {
        guard let folder = displayFolder else { entries = []; return }
        entries = ParaLens.sorted(LibraryListing.entries(of: folder), under: appState.currentFolder)
    }

    var body: some View {
        VStack(spacing: 0) {
            libraryHeader
            Divider()
            libraryBody
        }
        // 폴더가 바뀔 때만 1회 열거 — 매 렌더 동기 FS 호출 제거.
        .task(id: folderKey) { reloadEntries() }
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
                // url 기준 동일성으로 안정화 — 재열거 시 UUID가 새로 생겨도 셀 재생성·애니메이션 파괴 방지.
                ForEach(entries, id: \.url) { item in
                    LibraryGridCell(item: item)
                        .onTapGesture {
                            handleTap(item: item)
                        }
                        .contextMenu { LibraryCellContextMenu(item: item) }
                }
            }
            .padding(16)
        }
    }

    // MARK: - 리스트 뷰

    private func listView(entries: [FileTreeItem]) -> some View {
        List {
            // url 기준 동일성으로 안정화 — 재열거 시 UUID가 새로 생겨도 행 재생성·애니메이션 파괴 방지.
            ForEach(entries, id: \.url) { item in
                LibraryListCell(item: item)
                    .onTapGesture {
                        handleTap(item: item)
                    }
                    .contextMenu { LibraryCellContextMenu(item: item) }
                    .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
            }
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
        // root보다 위로는 올라가지 않는다. '/' 경계로 형제 폴더 오감지 방지.
        let parentStd = parent.standardizedFileURL.path
        let rootStd   = root.standardizedFileURL.path
        if parentStd == rootStd || parentStd.hasPrefix(rootStd + "/") {
            appState.selectedFolder = parent
        }
    }
}

// MARK: - 격자 셀

struct LibraryGridCell: View {
    @Environment(AppState.self) private var appState
    let item: FileTreeItem

    @State private var thumbnail: NSImage?

    private var paraCategory: ParaCategory {
        ParaLens.classify(item.url, under: appState.currentFolder)
    }

    var body: some View {
        VStack(spacing: 6) {
            imageArea
                .frame(width: 64, height: 64)
                .overlay(alignment: .topTrailing) {
                    if item.hasCompanionNote {
                        Image(systemName: "note.text")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(2)
                            .background(.thinMaterial, in: .rect(cornerRadius: 3))
                            .help("짝꿍 노트 있음")
                    }
                }

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
        .task(id: item.url) {
            // 파일만 썸네일 생성(폴더는 폴더 아이콘 유지). 셀이 사라지면 .task가 취소된다.
            guard !item.isDirectory else { return }
            thumbnail = await ThumbnailService.shared.thumbnail(for: item.url, pointSize: 64, scale: 2)
        }
    }

    @ViewBuilder
    private var imageArea: some View {
        if !item.isDirectory, let thumbnail {
            Image(nsImage: thumbnail)
                .resizable()
                .scaledToFit()
                .clipShape(.rect(cornerRadius: 4))
        } else {
            Image(systemName: cellIcon)
                .font(.system(size: 32))
                .foregroundStyle(iconColor)
        }
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

    /// 짝꿍 노트의 summary — 셀이 보일 때만 lazy 로드(썸네일 패턴, 셀 사라지면 취소).
    @State private var summary: String?

    private var paraCategory: ParaCategory {
        ParaLens.classify(item.url, under: appState.currentFolder)
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: item.isDirectory ? "folder" : item.icon)
                .font(.system(size: 14))
                .foregroundStyle(iconColor)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 1) {
                Text(item.name)
                    .lineLimit(1)
                    .font(paraCategory == .projects && item.isDirectory ? .body.weight(.medium) : .body)
                if item.hasCompanionNote {
                    // summary가 늦게 도착해도 행 높이가 변하지 않게 자리부터 확보(리플로우 방지)
                    Text(summary ?? " ")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            if item.hasCompanionNote {
                Image(systemName: "note.text")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .help("짝꿍 노트 있음")
            }

            // 수정일·크기 열 — 표시만(정렬은 F3). 고정폭·모노 숫자로 세로 정렬 유지.
            Text(item.modifiedAt?.formatted(.dateTime.year().month().day()) ?? "--")
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .frame(width: 92, alignment: .trailing)
            Text(item.isDirectory ? "--" : (item.fileSize.map(FileInfoService.formatSize) ?? "--"))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .lineLimit(1)
                .frame(width: 68, alignment: .trailing)
        }
        .opacity(paraCategory == .archive ? 0.45 : 1.0)
        .contentShape(Rectangle())
        .padding(.vertical, 2)
        .task(id: item.url) {
            guard item.hasCompanionNote else { summary = nil; return }
            summary = await CompanionNote.loadSummary(noteURL: CompanionNote.noteURL(for: item.url))
        }
    }

    private var iconColor: Color {
        if item.isDirectory && paraCategory == .projects {
            return .cmdsAccent
        }
        return .secondary
    }
}

// MARK: - 컨텍스트 메뉴

/// 라이브러리 셀 우클릭 메뉴 — 그리드·리스트 공통(스펙 §3). 빈 영역 우클릭은 범위 밖.
struct LibraryCellContextMenu: View {
    @Environment(AppState.self) private var appState
    let item: FileTreeItem

    var body: some View {
        Button {
            appState.renameRequest = RenameRequest(url: item.url)
        } label: {
            Label("이름 변경…", systemImage: "pencil")
        }
        Button {
            appState.fileInfoRequest = FileInfoRequest(url: item.url)
        } label: {
            Label("정보 보기", systemImage: "info.circle")
        }
        if item.isDirectory {
            Button {
                appState.createNewFolder(in: item.url)
            } label: {
                Label("이 안에 새 폴더", systemImage: "folder.badge.plus")
            }
        }
        Divider()
        Button(role: .destructive) {
            appState.trashWithConfirmation(item.url)
        } label: {
            Label("휴지통으로 이동", systemImage: "trash")
        }
    }
}
