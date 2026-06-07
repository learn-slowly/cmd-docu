import SwiftUI

struct StatusBarView: View {
    @Environment(AppState.self) private var appState
    
    var body: some View {
        HStack(spacing: 16) {
            if let document = appState.currentDocument {
                WordCountView(document: document)
                
                Divider()
                    .frame(height: 12)
                
                CharacterCountView(document: document)
                
                Divider()
                    .frame(height: 12)
                
                ReadingTimeView(document: document)
            }
            
            Spacer()
            
            if appState.isDirty {
                HStack(spacing: 4) {
                    Circle()
                        .fill(Color.orange)
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
    
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: viewModeIcon)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
            Text(appState.viewMode.rawValue)
                .font(.system(size: 11))
                .foregroundColor(.secondary)
        }
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
