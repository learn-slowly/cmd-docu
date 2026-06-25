import SwiftUI

struct StatusBarView: View {
    @Environment(AppState.self) private var appState
    
    var body: some View {
        HStack(spacing: 16) {
            if let document = appState.currentDocument {
                if appState.viewMode != .preview {
                    CursorPositionView()

                    Divider()
                        .frame(height: 12)
                }

                WordCountView(document: document)

                Divider()
                    .frame(height: 12)

                CharacterCountView(document: document)

                Divider()
                    .frame(height: 12)

                ReadingTimeView(document: document)
            }

            Spacer()

            if appState.updateAvailable {
                UpdateBadge()

                Divider()
                    .frame(height: 12)
            }

            if appState.isDirty {
                HStack(spacing: 4) {
                    Circle()
                        .fill(CMDSBrand.develop)
                        .frame(width: 6, height: 6)
                    Text("Modified")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }

            ViewModeIndicator()
        }
        .padding(.horizontal, 12)
        .frame(height: 24)
        .background(Color(nsColor: .windowBackgroundColor))
        .overlay(alignment: .top) {
            Divider()
        }
    }
}

/// A subtle "update available" pill in the status bar that opens the release page.
struct UpdateBadge: View {
    @Environment(AppState.self) private var appState
    @State private var isHovering = false

    var body: some View {
        Button {
            if let url = appState.updateURL { NSWorkspace.shared.open(url) }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 10))
                Text(appState.latestVersion.map { "Update \($0)" } ?? "Update available")
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(Color.cmdsAccent)
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(isHovering ? Color.cmdsAccentSoft : Color.clear)
            .clipShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("A new version is available — click to open the download page")
    }
}

struct CursorPositionView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        Text("Ln \(appState.cursorLine), Col \(appState.cursorColumn)")
            .font(.system(size: 11).monospacedDigit())
            .foregroundColor(.secondary)
    }
}

struct WordCountView: View {
    let document: MarkdownDocument
    
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "text.word.spacing")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
            Text("\(document.wordCount) words")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
    }
}

struct CharacterCountView: View {
    let document: MarkdownDocument
    
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "character")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
            Text("\(document.characterCount) chars")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
    }
}

struct ReadingTimeView: View {
    let document: MarkdownDocument
    
    private var readingTimeMinutes: Int {
        let wordsPerMinute = 200
        return max(1, document.wordCount / wordsPerMinute)
    }
    
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "clock")
                .font(.system(size: 10))
                .foregroundColor(.secondary)
            Text("\(readingTimeMinutes) min read")
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
    }
}

struct ViewModeIndicator: View {
    @Environment(AppState.self) private var appState
    @State private var isHovering = false

    var body: some View {
        @Bindable var state = appState

        Menu {
            Picker("View Mode", selection: $state.viewMode) {
                Label("Source", systemImage: "text.alignleft").tag(ViewMode.source)
                Label("Split", systemImage: "rectangle.split.2x1").tag(ViewMode.split)
                Label("Preview", systemImage: "eye").tag(ViewMode.preview)
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: viewModeIcon)
                    .font(.system(size: 10))
                Text(appState.viewMode.rawValue)
                    .font(.system(size: 11))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 7))
            }
            .foregroundColor(isHovering ? .primary : .secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(isHovering ? Color.secondary.opacity(0.15) : Color.clear)
            .clipShape(RoundedRectangle(cornerRadius: 4))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .onHover { isHovering = $0 }
        .help("Change view mode (⌘1 / ⌘2 / ⌘3)")
    }

    private var viewModeIcon: String {
        switch appState.viewMode {
        case .source:
            return "text.alignleft"
        case .split:
            return "rectangle.split.2x1"
        case .preview:
            return "eye"
        }
    }
}

#if !SWIFT_PACKAGE
#Preview {
    VStack {
        Spacer()
        StatusBarView()
    }
    .frame(width: 600, height: 100)
    .environment(AppState())
}
#endif
