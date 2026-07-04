import SwiftUI

// MARK: - Key binding model

/// A user-remappable keyboard shortcut. Stored in settings and applied to menu
/// commands / views via `View.appShortcut(_:)`. Keys are encoded like Obsidian
/// ("ArrowLeft", "[", "p") so defaults can mirror the user's vault hotkeys.
struct KeyBinding: Codable, Equatable, Hashable {
    var key: String
    var command: Bool = false
    var shift: Bool = false
    var option: Bool = false
    var control: Bool = false

    var keyEquivalent: KeyEquivalent? {
        switch key {
        case "ArrowLeft":  return .leftArrow
        case "ArrowRight": return .rightArrow
        case "ArrowUp":    return .upArrow
        case "ArrowDown":  return .downArrow
        case "Space":      return .space
        case "Return", "Enter": return .return
        case "Tab":        return .tab
        case "Escape":     return .escape
        default:
            guard key.count == 1, let ch = key.first else { return nil }
            return KeyEquivalent(ch)
        }
    }

    var eventModifiers: EventModifiers {
        var m: EventModifiers = []
        if command { m.insert(.command) }
        if shift { m.insert(.shift) }
        if option { m.insert(.option) }
        if control { m.insert(.control) }
        return m
    }

    /// Human-readable combo, e.g. "⌃⌘←".
    var displayString: String {
        var s = ""
        if control { s += "⌃" }
        if option { s += "⌥" }
        if shift { s += "⇧" }
        if command { s += "⌘" }
        s += Self.keyLabel(key)
        return s
    }

    static func keyLabel(_ key: String) -> String {
        switch key {
        case "ArrowLeft":  return "←"
        case "ArrowRight": return "→"
        case "ArrowUp":    return "↑"
        case "ArrowDown":  return "↓"
        case "Space":      return "Space"
        case "Return", "Enter": return "↩"
        case "Tab":        return "⇥"
        case "Escape":     return "⎋"
        default:           return key.uppercased()
        }
    }
}

// MARK: - Remappable actions

/// Every shortcut-bound action. Defaults reference 구요한's Obsidian main-vault
/// hotkeys where an equivalent exists (Omnisearch ⇧⌘O, sidebars ⌃⌘←/→).
enum AppShortcut: String, CaseIterable, Identifiable {
    case commandPalette
    case omnisearch
    case toggleSidebar
    case toggleInspector
    case copyFilePath
    case sendToVault
    case autoRoute
    case quickCapture
    case sourceMode
    case splitMode
    case previewMode
    case newDraft
    case save
    case saveAs
    case findInDocument
    case reloadFromDisk
    case openFolder
    case askClaude
    case indexSearch
    case askCorpus
    case toggleLibraryMode
    case folderCleanup
    case fileInfo
    case navigateBack
    case navigateForward
    case navigateUp

    var id: String { rawValue }

    var title: String {
        switch self {
        case .commandPalette: return "Command Palette"
        case .omnisearch:     return "Omnisearch"
        case .toggleSidebar:  return "Toggle Left Sidebar"
        case .toggleInspector: return "Toggle Right Sidebar (Inspector)"
        case .copyFilePath:   return "Copy File Path"
        case .sendToVault:    return "Send to Vault…"
        case .autoRoute:      return "Auto-Route Send"
        case .quickCapture:   return "Quick Capture"
        case .sourceMode:     return "Source View"
        case .splitMode:      return "Split View"
        case .previewMode:    return "Preview View"
        case .newDraft:       return "New Draft"
        case .save:           return "Save"
        case .saveAs:         return "Save As…"
        case .findInDocument: return "Find in Document"
        case .reloadFromDisk: return "Reload from Disk"
        case .openFolder:     return "Open Folder…"
        case .askClaude:      return "Ask Claude"
        case .indexSearch:       return "Search Index (내용 검색)"
        case .askCorpus:         return "Ask Corpus (자료에 묻기)"
        case .toggleLibraryMode: return "Toggle Reader/Library"
        case .folderCleanup:     return "Folder Cleanup (폴더 정리)"
        case .fileInfo:          return "File Info (정보 보기)"
        case .navigateBack:    return "Back (폴더 뒤로)"
        case .navigateForward: return "Forward (폴더 앞으로)"
        case .navigateUp:      return "Enclosing Folder (상위 폴더)"
        }
    }

    var defaultBinding: KeyBinding {
        switch self {
        case .commandPalette:  return KeyBinding(key: "p", command: true)
        case .omnisearch:      return KeyBinding(key: "o", command: true, shift: true)
        case .toggleSidebar:   return KeyBinding(key: "ArrowLeft", command: true, control: true)
        case .toggleInspector: return KeyBinding(key: "ArrowRight", command: true, control: true)
        case .copyFilePath:    return KeyBinding(key: "c", command: true, option: true)
        case .sendToVault:     return KeyBinding(key: "t", command: true, shift: true)
        case .autoRoute:       return KeyBinding(key: "t", command: true, control: true)
        case .quickCapture:    return KeyBinding(key: "m", command: true, shift: true)
        case .sourceMode:      return KeyBinding(key: "1", command: true)
        case .splitMode:       return KeyBinding(key: "2", command: true)
        case .previewMode:     return KeyBinding(key: "3", command: true)
        case .newDraft:        return KeyBinding(key: "n", command: true)
        case .save:            return KeyBinding(key: "s", command: true)
        case .saveAs:          return KeyBinding(key: "s", command: true, shift: true)
        case .findInDocument:  return KeyBinding(key: "f", command: true)
        case .reloadFromDisk:  return KeyBinding(key: "r", command: true, option: true)
        case .openFolder:      return KeyBinding(key: "o", command: true, option: true)
        case .askClaude:       return KeyBinding(key: "a", command: true, shift: true)
        case .indexSearch:       return KeyBinding(key: "f", command: true, option: true)
        case .askCorpus:         return KeyBinding(key: "a", command: true, option: true)
        case .toggleLibraryMode: return KeyBinding(key: "l", command: true, shift: true)
        case .folderCleanup:     return KeyBinding(key: "k", command: true, option: true)
        case .fileInfo:          return KeyBinding(key: "i", command: true, option: true)  // ⌥⌘I
        case .navigateBack:    return KeyBinding(key: "[", command: true)
        case .navigateForward: return KeyBinding(key: "]", command: true)
        case .navigateUp:      return KeyBinding(key: "ArrowUp", command: true)
        }
    }
}

// MARK: - Applying a binding to a command/view

extension View {
    /// Applies a remappable shortcut. No-op when the key can't be represented.
    @ViewBuilder
    func appShortcut(_ binding: KeyBinding?) -> some View {
        if let binding, let key = binding.keyEquivalent {
            keyboardShortcut(key, modifiers: binding.eventModifiers)
        } else {
            self
        }
    }
}
