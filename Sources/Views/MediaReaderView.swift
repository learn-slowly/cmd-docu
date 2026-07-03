import SwiftUI
import AVKit

/// 미디어(음악·동영상) 리더 — 플레이어 + 짝꿍 노트 한 화면.
/// 핵심은 "재생하지 않고도 그 파일이 뭔지 아는 것": 노트가 항상 곁에 보인다.
/// 원본 미디어는 읽기 전용 — 앱이 쓰는 파일은 짝꿍 .md뿐.
struct MediaReaderView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var colorScheme
    let tabID: UUID
    let url: URL

    @State private var player: AVPlayer?
    @State private var playerFailed = false
    @State private var noteState: NoteState = .checking
    @State private var editBuffer = ""
    @State private var isEditing = false
    @State private var errorText: String?

    private enum NoteState: Equatable {
        case checking          // 노트 존재 확인 중
        case missing           // 노트 없음 → "메모 만들기"
        case creating          // 메타데이터 읽고 생성 중
        case loaded(String)    // 노트 본문(디스크 기준)
    }

    private var noteURL: URL { CompanionNote.noteURL(for: url) }

    var body: some View {
        Group {
            if DocumentKind.isVideo(url) {
                // 동영상: 좌 플레이어 / 우 노트
                HSplitView {
                    playerArea
                        .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
                    notePane
                        .frame(minWidth: 280, maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                // 음악: 상단 컴팩트 재생 바 / 아래 노트 전체
                VStack(spacing: 0) {
                    playerArea
                        .frame(height: 72)
                    Divider()
                    notePane
                }
            }
        }
        .task(id: url) {
            await setUpPlayer()
            loadNote()
            consumePendingScroll()
        }
        .onChange(of: appState.pendingMediaScrollLines[tabID]) {
            consumePendingScroll()
        }
        .onDisappear {
            player?.pause()
            saveIfEditing()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            // 앱 종료 시 onDisappear가 보장되지 않으므로 별도로 저장 경로를 확보한다.
            saveIfEditing()
        }
    }

    /// 검색·옴니서치·RAG에서 짝꿍 노트를 줄 번호와 함께 열어 이 탭으로 리다이렉트된
    /// 경우, AppState가 담아둔 pending 줄을 소비해 노트 패널로 점프 알림을 보낸다.
    /// 편집 모드용 `.scrollToLine`과 미리보기용 `.scrollToHeading`을 둘 다 게시한다
    /// (지금 어느 모드인지 몰라도 두 구독자 중 있는 쪽이 반응).
    private func consumePendingScroll() {
        guard let line = appState.pendingMediaScrollLines[tabID],
              case .loaded(let content) = noteState else { return }
        appState.pendingMediaScrollLines.removeValue(forKey: tabID)
        // 노트 패널(에디터/프리뷰)이 막 나타나 구독을 마칠 시간을 준다(scrollEditor와 동일 패턴).
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NotificationCenter.default.post(name: .scrollToLine, object: line)
            if let slug = AppState.nearestHeadingSlug(in: content, before: line) {
                NotificationCenter.default.post(name: .scrollToHeading, object: slug)
            }
        }
    }

    // MARK: - 플레이어

    @ViewBuilder
    private var playerArea: some View {
        if playerFailed {
            VStack(spacing: 8) {
                Image(systemName: "play.slash")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("이 파일은 재생할 수 없습니다 (지원하지 않는 코덱일 수 있어요)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let player {
            VideoPlayer(player: player)
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// 재생 가능 여부를 먼저 확인해 실패 시 플레이스홀더로(PDF 실패 패턴).
    private func setUpPlayer() async {
        player?.pause()
        player = nil
        playerFailed = false
        let asset = AVURLAsset(url: url)
        let playable = (try? await asset.load(.isPlayable)) ?? false
        if playable {
            // 직접 생성하지 않고 AppState에서 탭당 단일 인스턴스를 획득 — 같은 탭을 여러 창이
            // 보여줘도 플레이어는 하나라 레지스트리 밖 고아가 없고, 정지 책임은 AppState가
            // 가진다(onDisappear는 창 숨김·탭 전환에서 못 미덥다, 실측).
            player = appState.mediaPlayer(forTab: tabID, url: url)
        } else {
            playerFailed = true
        }
    }

    // MARK: - 노트 패널

    @ViewBuilder
    private var notePane: some View {
        VStack(spacing: 0) {
            noteToolbar
            Divider()
            if let errorText {
                Text(errorText)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(6)
            }
            switch noteState {
            case .checking, .creating:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .missing:
                ContentUnavailableView {
                    Label("짝꿍 노트가 없습니다", systemImage: "note.text.badge.plus")
                } description: {
                    Text("메모를 만들면 길이·제목 같은 정보가 자동으로 채워집니다.")
                } actions: {
                    Button("메모 만들기") { createNote() }
                        .buttonStyle(.borderedProminent)
                }
            case .loaded(let content):
                if isEditing {
                    noteEditor
                } else {
                    // 일반 마크다운 문서 미리보기와 동일하게 frontmatter는 감춘다(편집 모드는 원문).
                    MarkdownPreviewView(
                        documentID: tabID,
                        markdown: CompanionNote.bodyStrippingFrontmatter(content),
                        baseURL: url.deletingLastPathComponent(),
                        options: appState.renderOptions(),
                        scrollSyncEnabled: false
                    )
                }
            }
        }
    }

    private var noteToolbar: some View {
        HStack(spacing: 8) {
            Label("짝꿍 노트", systemImage: "note.text")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            switch noteState {
            case .loaded:
                if isEditing {
                    Button("취소") {
                        // 편집 내용 파기 — 디스크 기준으로 되돌린다.
                        isEditing = false
                        errorText = nil
                    }
                    Button("저장") { save() }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button {
                        if case .loaded(let content) = noteState { editBuffer = content }
                        isEditing = true
                    } label: {
                        Label("편집", systemImage: "pencil")
                    }
                }
            default:
                EmptyView()
            }
        }
        .padding(8)
    }

    private var noteEditor: some View {
        let settings = appState.settings
        let theme = settings.editorTheme.resolved(forDark: colorScheme == .dark)
        return MarkdownTextEditor(
            documentID: tabID,
            text: $editBuffer,
            font: editorFont(),
            editorTheme: theme,
            softWrap: settings.softWrap,
            showLineNumbers: settings.showLineNumbers,
            highlightCurrentLine: settings.highlightCurrentLine,
            tabSize: settings.tabSize,
            insertSpacesForTab: settings.insertSpacesInsteadOfTabs,
            enableCompletion: false,
            scrollSyncEnabled: false
        )
    }

    private func editorFont() -> NSFont {
        let size = appState.settings.fontSize
        let name = appState.settings.fontName
        if !name.isEmpty, let custom = NSFont(name: name, size: size) { return custom }
        return .monospacedSystemFont(ofSize: size, weight: .regular)
    }

    // MARK: - 노트 IO

    private func loadNote() {
        if let content = try? String(contentsOf: noteURL, encoding: .utf8) {
            noteState = .loaded(content)
        } else {
            noteState = .missing
        }
    }

    /// "메모 만들기" — 메타데이터 자동 채움. 기존 파일이 있으면(레이스) 덮어쓰지 않고 그 파일을 연다.
    private func createNote() {
        noteState = .creating
        errorText = nil
        Task {
            let meta = await MediaMetadataService.load(url: url)
            let content = CompanionNote.initialContent(mediaFileName: url.lastPathComponent, metadata: meta)
            if !FileManager.default.fileExists(atPath: noteURL.path) {
                do {
                    try Data(content.utf8).write(to: noteURL, options: [.withoutOverwriting])
                } catch {
                    // 레이스로 이미 생겼으면 아래 loadNote가 그 파일을 연다. 그 외 실패는 안내.
                    if !FileManager.default.fileExists(atPath: noteURL.path) {
                        errorText = "메모 생성 실패: \(error.localizedDescription)"
                        noteState = .missing
                        return
                    }
                }
            }
            loadNote()
            if case .loaded(let loaded) = noteState {
                editBuffer = loaded
                isEditing = true
            }
            appState.loadFileTree()   // 사이드바 배지 갱신
        }
    }

    private func save() {
        do {
            try editBuffer.write(to: noteURL, atomically: true, encoding: .utf8)
            noteState = .loaded(editBuffer)
            isEditing = false
            errorText = nil
        } catch {
            errorText = "저장 실패: \(error.localizedDescription)"
        }
    }

    /// 탭 전환·닫기·앱 종료 시 편집 중이던 내용을 잃지 않도록 저장.
    private func saveIfEditing() {
        guard isEditing, case .loaded(let content) = noteState, editBuffer != content else { return }
        do {
            try editBuffer.write(to: noteURL, atomically: true, encoding: .utf8)
        } catch {
            appState.showToast("짝꿍 노트 저장 실패: \(error.localizedDescription)")
        }
    }
}
