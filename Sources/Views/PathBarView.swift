import SwiftUI

// MARK: - PathBarView

/// 공용 경로 바(24pt 스트립) — ‹ › 히스토리 버튼 + 클릭 가능 브레드크럼(스펙 §4).
/// 리더(target=활성 탭 파일)·라이브러리(target=표시 폴더) 양쪽이 재사용해 모드 토글 시
/// 같은 높이·위치라 점프가 없다. target nil이면 버튼만 표시(새 문서 탭 등).
struct PathBarView: View {
    @Environment(AppState.self) private var appState

    /// 경로를 분해할 대상(파일 또는 폴더). nil이면 세그먼트 없이 버튼만.
    let target: URL?
    /// target이 파일인가(마지막 세그먼트 클릭 불가·doc 아이콘).
    let targetIsFile: Bool
    /// 트레일링 라벨(라이브러리의 "N개 선택됨" 등).
    var trailingText: String? = nil

    var body: some View {
        HStack(spacing: 6) {
            historyButtons
            if let target {
                segmentStrip(for: target)
            }
            Spacer(minLength: 0)
            if let trailingText {
                Text(trailingText)
                    .font(.caption)
                    .foregroundStyle(Color.cmdsAccent)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 8)
        .frame(height: 24)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))
        .overlay(alignment: .bottom) {
            Divider()
        }
    }

    // MARK: - ‹ › 히스토리 버튼

    private var historyButtons: some View {
        HStack(spacing: 2) {
            Button {
                appState.goBackInHistory()
            } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.borderless)
            .disabled(!appState.navHistory.canGoBack)
            .help("뒤로 (\(appState.keyBinding(for: .navigateBack).displayString))")

            Button {
                appState.goForwardInHistory()
            } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .medium))
            }
            .buttonStyle(.borderless)
            .disabled(!appState.navHistory.canGoForward)
            .help("앞으로 (\(appState.keyBinding(for: .navigateForward).displayString))")
        }
    }

    // MARK: - 브레드크럼

    private func segmentStrip(for target: URL) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                let segments = PathBarModel.segments(target: target,
                                                     root: appState.currentFolder,
                                                     targetIsFile: targetIsFile)
                ForEach(Array(segments.enumerated()), id: \.offset) { index, seg in
                    if index > 0 {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                    segmentView(seg)
                }
            }
            .padding(.vertical, 4)
        }
        .contextMenu {
            Button("Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([target])
            }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(target.path, forType: .string)
                appState.showToast("Path copied")
            }
        }
    }

    @ViewBuilder
    private func segmentView(_ seg: PathSegment) -> some View {
        if seg.isFile {
            segmentLabel(seg)
                .foregroundStyle(.primary)
        } else {
            Button {
                navigate(to: seg)
            } label: {
                // 루트 안=보통 톤(주 동선), 루트 밖=옅은 톤(클릭은 가능 — 작업 폴더 전환).
                segmentLabel(seg)
                    .foregroundStyle(seg.isWithinRoot ? AnyShapeStyle(.secondary)
                                                      : AnyShapeStyle(.tertiary))
            }
            .buttonStyle(.plain)
        }
    }

    private func segmentLabel(_ seg: PathSegment) -> some View {
        HStack(spacing: 3) {
            Image(systemName: seg.isFile ? "doc.text" : (seg.name == "~" ? "house" : "folder"))
                .font(.system(size: 10))
            Text(seg.name)
                .font(.system(size: 11))
                .lineLimit(1)
        }
    }

    /// 폴더 세그먼트 클릭 — 루트 안이면 표시 폴더 전환(+라이브러리 모드),
    /// 루트 밖 조상이면 작업 폴더 전환(Open Folder와 동일 — 히스토리로 복귀 가능, 스펙 §4.3).
    private func navigate(to seg: PathSegment) {
        if seg.isWithinRoot {
            appState.selectFolderForLibrary(seg.url)
        } else {
            appState.openFolder(at: seg.url)
            appState.mainMode = .library
        }
    }
}
