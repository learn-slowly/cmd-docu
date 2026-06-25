import SwiftUI

struct CompletionPopupView: View {
    let items: [CompletionItem]
    @Binding var selectedIndex: Int
    let onSelect: (CompletionItem) -> Void
    
    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                CompletionRowView(
                    item: item,
                    isSelected: index == selectedIndex
                )
                .onTapGesture {
                    onSelect(item)
                }
            }
        }
        .frame(width: 300)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
    }
}

struct CompletionRowView: View {
    let item: CompletionItem
    let isSelected: Bool
    
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: iconForType(item.type))
                .foregroundStyle(isSelected ? Color.cmdsAccentOn : colorForType(item.type))
                .frame(width: 20)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayText)
                    .font(.body)
                    .foregroundStyle(isSelected ? Color.cmdsAccentOn : .primary)
                    .lineLimit(1)

                if let detail = item.detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(isSelected ? Color.cmdsAccentOn.opacity(0.8) : .secondary)
                        .lineLimit(1)
                }
            }
            
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(isSelected ? Color.cmdsAccent : Color.clear)
    }

    private func iconForType(_ type: CompletionContext.Kind) -> String {
        switch type {
        case .wikiLink: return "doc.text"
        case .tag: return "tag"
        }
    }

    private func colorForType(_ type: CompletionContext.Kind) -> Color {
        switch type {
        case .wikiLink: return .cmdsAccent
        case .tag: return CMDSBrand.connect
        }
    }
}

class CompletionWindowController: NSObject {
    private var window: NSWindow?
    private var hostingView: NSHostingView<CompletionPopupView>?
    private var items: [CompletionItem] = []
    private var selectedIndex: Int = 0
    private var onSelect: ((CompletionItem) -> Void)?
    
    func show(items: [CompletionItem], at point: NSPoint, in parentWindow: NSWindow?, onSelect: @escaping (CompletionItem) -> Void) {
        guard !items.isEmpty else {
            dismiss()
            return
        }
        
        self.items = items
        self.selectedIndex = 0
        self.onSelect = onSelect
        
        let popupView = CompletionPopupView(
            items: items,
            selectedIndex: Binding(get: { [weak self] in self?.selectedIndex ?? 0 },
                                   set: { [weak self] in self?.selectedIndex = $0 }),
            onSelect: { [weak self] item in
                self?.selectItem(item)
            }
        )
        
        if window == nil {
            let contentRect = NSRect(x: 0, y: 0, width: 300, height: min(CGFloat(items.count) * 44, 300))
            window = NSWindow(
                contentRect: contentRect,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window?.isOpaque = false
            window?.backgroundColor = .clear
            window?.level = .floating
            window?.hasShadow = true
        }
        
        hostingView = NSHostingView(rootView: popupView)
        window?.contentView = hostingView
        
        let height = min(CGFloat(items.count) * 44, 300)
        let origin = NSPoint(x: point.x, y: point.y - height)
        window?.setFrame(NSRect(origin: origin, size: NSSize(width: 300, height: height)), display: true)
        
        if let parentWindow = parentWindow {
            parentWindow.addChildWindow(window!, ordered: .above)
        }
        
        window?.orderFront(nil)
    }
    
    func dismiss() {
        guard let window else { return }
        window.parent?.removeChildWindow(window)
        window.orderOut(nil)
        items = []
        selectedIndex = 0
    }
    
    func moveSelectionUp() {
        guard !items.isEmpty else { return }
        selectedIndex = max(0, selectedIndex - 1)
        updateView()
    }
    
    func moveSelectionDown() {
        guard !items.isEmpty else { return }
        selectedIndex = min(items.count - 1, selectedIndex + 1)
        updateView()
    }
    
    func confirmSelection() {
        guard selectedIndex < items.count else { return }
        selectItem(items[selectedIndex])
    }
    
    private func selectItem(_ item: CompletionItem) {
        onSelect?(item)
        dismiss()
    }
    
    private func updateView() {
        let popupView = CompletionPopupView(
            items: items,
            selectedIndex: Binding(get: { [weak self] in self?.selectedIndex ?? 0 },
                                   set: { [weak self] in self?.selectedIndex = $0 }),
            onSelect: { [weak self] item in
                self?.selectItem(item)
            }
        )
        hostingView?.rootView = popupView
    }
    
    var isVisible: Bool {
        window?.isVisible ?? false
    }
}
