import SwiftUI

// MARK: - LibraryView

/// 폴더 항목을 격자/리스트로 훑는 라이브러리 뷰.
/// F1b: 다중 선택 + 배치 파일 작업 진입점(컨텍스트 메뉴·키).
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

    private func reloadEntries() {
        guard let folder = displayFolder else {
            entries = []
            appState.libraryOrderedURLs = []
            return
        }
        entries = LibraryListing.entries(of: folder)
        applySort()
    }

    /// 현재 정렬로 entries를 재정렬하고 표시 순서 진실원을 **원자적으로** 동기 갱신한다.
    /// entries와 libraryOrderedURLs가 어긋나면 ⌘A·⇧범위 선택이 화면과 불일치(스펙 함정 #2).
    private func applySort() {
        entries = LibrarySorting.sorted(entries, by: appState.librarySort, under: appState.currentFolder)
        appState.libraryOrderedURLs = entries.map(\.url)
    }

    var body: some View {
        VStack(spacing: 0) {
            PathBarView(target: displayFolder, targetIsFile: false,
                        trailingText: appState.fileSelection.isEmpty
                            ? nil : "\(appState.fileSelection.count)개 선택됨")
            Divider()
            libraryBody
        }
        // 폴더가 바뀔 때만 1회 열거 — 매 렌더 동기 FS 호출 제거.
        .task(id: folderKey) { reloadEntries() }
        // 정렬 변경은 캐시 재정렬만(재열거 없음). 폴더 전환 직후엔 옛 entries에 한 번 적용된 뒤
        // .task(id: folderKey)가 새 폴더를 다시 열거한다(일시적 중복 — 무해).
        .onChange(of: appState.librarySort) { _, _ in applySort() }
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
                    VStack(spacing: 0) {
                        listHeader
                        Divider()
                        listView(entries: entries)
                    }
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
                    LibraryDraggableCell(item: item, isGrid: true) {
                        LibraryGridCell(item: item,
                                        isSelected: appState.fileSelection.contains(item.url))
                    }
                    .onTapGesture(count: 2) { handleDoubleClick(item: item) }
                    .onTapGesture { handleClick(item: item) }
                    .contextMenu { LibraryCellContextMenu(item: item) }
                }
            }
            .padding(16)
        }
        .onTapGesture { appState.clearFileSelection() }
        // 배경 드롭 = 표시 중 폴더로(스펙 §3). 셀 타깃이 안쪽이라 우선하고, 빗나간 드롭을 받는다.
        // 배경은 하이라이트 없음(표면이 넓어 시각 소음 — 셀·행만 하이라이트).
        // "/" 폴백은 도달 불가 — displayFolder nil이면 libraryBody가 placeholder를 렌더해
        // gridView/listView 자체가 계층에 없다(:59-78). 컴파일용 방어값.
        .onDrop(of: FileDropDelegate.acceptedTypes,
                delegate: FileDropDelegate(destination: displayFolder ?? URL(fileURLWithPath: "/"),
                                           appState: appState))
    }

    // MARK: - 리스트 열 헤더 (F3 — 클릭 정렬)

    /// 열 헤더 행 — 스크롤 영역 **밖**(배경 탭 선택 해제 제스처와 히트 경합 없음, 스펙 §2.6).
    /// 폭·간격은 셀(HStack spacing 8, 수정일 92pt·크기 68pt, listRowInsets 좌우 8)과 수동 동기.
    /// 종류 정렬은 열이 없으므로 툴바 메뉴로만.
    private var listHeader: some View {
        HStack(spacing: 8) {
            sortHeaderButton(title: "이름", key: .name)
                .frame(maxWidth: .infinity, alignment: .leading)
            sortHeaderButton(title: "수정일", key: .date)
                .frame(width: 92, alignment: .trailing)
            sortHeaderButton(title: "크기", key: .size)
                .frame(width: 68, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }

    /// 헤더 버튼 — 클릭=키 선택, 같은 키 재클릭=방향 토글(LibrarySort.selecting 공용 전이).
    private func sortHeaderButton(title: String, key: LibrarySortKey) -> some View {
        Button {
            appState.librarySort = appState.librarySort.selecting(key)
        } label: {
            HStack(spacing: 2) {
                Text(title)
                if appState.librarySort.key == key {
                    Image(systemName: appState.librarySort.ascending ? "chevron.up" : "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                }
            }
            .font(.caption)
            .foregroundStyle(appState.librarySort.key == key ? Color.cmdsAccent : Color.secondary)
        }
        .buttonStyle(.plain)
    }

    // MARK: - 리스트 뷰

    private func listView(entries: [FileTreeItem]) -> some View {
        List {
            // url 기준 동일성으로 안정화 — 재열거 시 UUID가 새로 생겨도 행 재생성·애니메이션 파괴 방지.
            ForEach(entries, id: \.url) { item in
                LibraryDraggableCell(item: item, isGrid: false) {
                    LibraryListCell(item: item,
                                    isSelected: appState.fileSelection.contains(item.url))
                }
                .onTapGesture(count: 2) { handleDoubleClick(item: item) }
                .onTapGesture { handleClick(item: item) }
                .contextMenu { LibraryCellContextMenu(item: item) }
                .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
            }
        }
        .listStyle(.plain)
        .onTapGesture { appState.clearFileSelection() }
        // 배경 드롭 = 표시 중 폴더로(스펙 §3). 셀 타깃이 안쪽이라 우선하고, 빗나간 드롭을 받는다.
        // 배경은 하이라이트 없음(표면이 넓어 시각 소음 — 셀·행만 하이라이트).
        // "/" 폴백은 도달 불가 — displayFolder nil이면 libraryBody가 placeholder를 렌더해
        // gridView/listView 자체가 계층에 없다(:59-78). 컴파일용 방어값.
        .onDrop(of: FileDropDelegate.acceptedTypes,
                delegate: FileDropDelegate(destination: displayFolder ?? URL(fileURLWithPath: "/"),
                                           appState: appState))
    }

    // MARK: - 클릭 처리 (F1b — Finder식: 클릭=선택, 더블클릭=열기/드릴인)

    private func handleClick(item: FileTreeItem) {
        let flags = NSEvent.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let modifier: SelectionModifier = flags.contains(.command) ? .command
            : (flags.contains(.shift) ? .shift : .none)
        appState.handleFileClick(item.url, modifier: modifier, ordered: entries.map(\.url))
    }

    private func handleDoubleClick(item: FileTreeItem) {
        if item.isDirectory {
            // 폴더 → 드릴인(selectedFolder didSet이 선택을 클리어)
            appState.selectedFolder = item.url
        } else {
            // 파일 → 리더 전환 (openDocument 내부에서 mainMode = .reader 설정).
            // 더블클릭의 첫 탭이 단일탭(선택)으로 먼저 발화해 선택이 남는다 — 트리 일반 클릭과
            // 패리티를 맞춰 클리어. 잔존 선택 + 리더의 ⌘C 가드 통과 시 파일 복사 강탈을 막는다.
            appState.clearFileSelection()
            appState.openDocument(at: item.url, inNewTab: true)
        }
    }
}

// MARK: - 격자 셀

struct LibraryGridCell: View {
    @Environment(AppState.self) private var appState
    let item: FileTreeItem
    let isSelected: Bool

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
        // fill 뒤엔 View라 strokeBorder 체인 불가 — 배경(fill)과 테두리(overlay)를 분리한다.
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.cmdsAccent.opacity(0.15) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(isSelected ? Color.cmdsAccent : Color.clear, lineWidth: 1)
        )
        .opacity(paraCategory == .archive ? 0.45 : 1.0)   // 기존 줄 유지 — 선택 배경도 함께 dim(항목 스타일 일관)
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
    let isSelected: Bool

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
        .background(isSelected ? Color.cmdsAccent.opacity(0.15) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 4))
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

// MARK: - 드래그 소스+폴더 드롭 타깃 래퍼 (F2)

/// 셀에 드래그 소스(.onDrag)와, 폴더 셀이면 드롭 타깃을 얹는 래퍼.
/// 탭 제스처는 호출부(ForEach 체인)에 그대로 남아 F1b 클릭 시맨틱 불변(스펙 §2.1).
struct LibraryDraggableCell<Content: View>: View {
    @Environment(AppState.self) private var appState
    let item: FileTreeItem
    let isGrid: Bool
    @ViewBuilder let content: Content

    @State private var isDropTargeted = false

    var body: some View {
        let base = content
            .onDrag {
                // 드래그 시작 — 선택 불변, 페이로드는 규칙(선택 포함=전체/미포함=단일)으로.
                let urls = DragPayload.urls(for: item.url, selection: appState.fileSelection)
                appState.draggingURLs = urls
                return DragPayload.makeProvider(for: urls, primary: item.url)
            }
        if item.isDirectory {
            base
                .overlay(
                    RoundedRectangle(cornerRadius: isGrid ? 6 : 4)
                        .strokeBorder(isDropTargeted ? Color.cmdsAccent : Color.clear,
                                      lineWidth: 2)
                )
                .onDrop(of: FileDropDelegate.acceptedTypes,
                        delegate: FileDropDelegate(destination: item.url, appState: appState,
                                                   onHoverChange: { isDropTargeted = $0 }))
        } else {
            base
        }
    }
}

// MARK: - 컨텍스트 메뉴

/// 라이브러리 셀 우클릭 메뉴 — 그리드·리스트 공통(스펙 §3). 빈 영역 우클릭은 범위 밖.
struct LibraryCellContextMenu: View {
    @Environment(AppState.self) private var appState
    let item: FileTreeItem

    var body: some View {
        if appState.fileSelection.count > 1 && appState.fileSelection.contains(item.url) {
            BatchSelectionMenu(item: item)
        } else {
            singleItemMenu
        }
    }

    @ViewBuilder
    private var singleItemMenu: some View {
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
            if !FilePasteboard.readFileURLs().isEmpty {
                Button {
                    appState.pasteFromPasteboard(move: false, into: item.url)
                } label: {
                    Label("이 폴더에 붙여넣기", systemImage: "doc.on.clipboard")
                }
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
