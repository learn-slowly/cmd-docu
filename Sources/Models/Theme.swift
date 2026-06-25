import SwiftUI

// MARK: - App Theme

enum AppTheme: String, CaseIterable, Codable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"
}

// MARK: - Editor Theme

enum EditorTheme: String, CaseIterable, Codable, Identifiable {
    case oneDark = "One Dark"
    case dracula = "Dracula"
    case github = "GitHub"
    case nord = "Nord"
    case tokyoNight = "Tokyo Night"
    case gruvbox = "Gruvbox"
    case solarizedDark = "Solarized Dark"
    case materialDark = "Material Dark"
    case cmds = "CMDS"
    case cmdsLight = "CMDS Light"

    var id: String { rawValue }

    var isDark: Bool { self != .github && self != .cmdsLight }

    /// The appearance-appropriate variant. The CMDS editor theme follows the
    /// app's light/dark appearance so a light app never shows a dark source pane.
    func resolved(forDark isDark: Bool) -> EditorTheme {
        switch self {
        case .cmds, .cmdsLight: return isDark ? .cmds : .cmdsLight
        default: return self
        }
    }

    /// Themes shown in the picker — `.cmdsLight` is an internal auto-variant of
    /// `.cmds`, so it is hidden (CMDS adapts to the app appearance on its own).
    static var selectableCases: [EditorTheme] {
        allCases.filter { $0 != .cmdsLight }
    }

    var backgroundColor: Color {
        switch self {
        case .oneDark: return Color(hex: "282c34")
        case .dracula: return Color(hex: "282a36")
        case .github: return Color(hex: "ffffff")
        case .nord: return Color(hex: "2e3440")
        case .tokyoNight: return Color(hex: "1a1b26")
        case .gruvbox: return Color(hex: "282828")
        case .solarizedDark: return Color(hex: "002b36")
        case .materialDark: return Color(hex: "263238")
        case .cmds: return Color(hex: "0b1310")
        case .cmdsLight: return Color(hex: "fbfbfa")
        }
    }

    var textColor: Color {
        switch self {
        case .oneDark: return Color(hex: "abb2bf")
        case .dracula: return Color(hex: "f8f8f2")
        case .github: return Color(hex: "24292e")
        case .nord: return Color(hex: "d8dee9")
        case .tokyoNight: return Color(hex: "a9b1d6")
        case .gruvbox: return Color(hex: "ebdbb2")
        case .solarizedDark: return Color(hex: "839496")
        case .materialDark: return Color(hex: "eeffff")
        case .cmds: return Color(hex: "e6efe9")
        case .cmdsLight: return Color(hex: "0a0d0b")
        }
    }

    var keywordColor: Color {
        switch self {
        case .oneDark: return Color(hex: "c678dd")
        case .dracula: return Color(hex: "ff79c6")
        case .github: return Color(hex: "d73a49")
        case .nord: return Color(hex: "81a1c1")
        case .tokyoNight: return Color(hex: "bb9af7")
        case .gruvbox: return Color(hex: "fb4934")
        case .solarizedDark: return Color(hex: "859900")
        case .materialDark: return Color(hex: "c792ea")
        case .cmds: return Color(hex: "E985A2")
        case .cmdsLight: return Color(hex: "134538")
        }
    }

    var stringColor: Color {
        switch self {
        case .oneDark: return Color(hex: "98c379")
        case .dracula: return Color(hex: "f1fa8c")
        case .github: return Color(hex: "032f62")
        case .nord: return Color(hex: "a3be8c")
        case .tokyoNight: return Color(hex: "9ece6a")
        case .gruvbox: return Color(hex: "b8bb26")
        case .solarizedDark: return Color(hex: "2aa198")
        case .materialDark: return Color(hex: "c3e88d")
        case .cmds: return Color(hex: "2fb488")
        case .cmdsLight: return Color(hex: "9a5b2f")
        }
    }

    var commentColor: Color {
        switch self {
        case .oneDark: return Color(hex: "5c6370")
        case .dracula: return Color(hex: "6272a4")
        case .github: return Color(hex: "6a737d")
        case .nord: return Color(hex: "616e88")
        case .tokyoNight: return Color(hex: "565f89")
        case .gruvbox: return Color(hex: "928374")
        case .solarizedDark: return Color(hex: "586e75")
        case .materialDark: return Color(hex: "546e7a")
        case .cmds: return Color(hex: "5d6b64")
        case .cmdsLight: return Color(hex: "8a938e")
        }
    }

    var headingColor: Color {
        switch self {
        case .oneDark: return Color(hex: "e06c75")
        case .dracula: return Color(hex: "bd93f9")
        case .github: return Color(hex: "005cc5")
        case .nord: return Color(hex: "88c0d0")
        case .tokyoNight: return Color(hex: "7aa2f7")
        case .gruvbox: return Color(hex: "83a598")
        case .solarizedDark: return Color(hex: "268bd2")
        case .materialDark: return Color(hex: "82aaff")
        case .cmds: return Color(hex: "F4A4B8")
        case .cmdsLight: return Color(hex: "0d3529")
        }
    }

    var linkColor: Color {
        switch self {
        case .oneDark: return Color(hex: "61afef")
        case .dracula: return Color(hex: "8be9fd")
        case .github: return Color(hex: "0366d6")
        case .nord: return Color(hex: "5e81ac")
        case .tokyoNight: return Color(hex: "73daca")
        case .gruvbox: return Color(hex: "458588")
        case .solarizedDark: return Color(hex: "cb4b16")
        case .materialDark: return Color(hex: "89ddff")
        case .cmds: return Color(hex: "5eead4")
        case .cmdsLight: return Color(hex: "1a5d4b")
        }
    }

    var selectionColor: Color {
        switch self {
        case .oneDark: return Color(hex: "3e4451")
        case .dracula: return Color(hex: "44475a")
        case .github: return Color(hex: "c8e1ff")
        case .nord: return Color(hex: "434c5e")
        case .tokyoNight: return Color(hex: "283457")
        case .gruvbox: return Color(hex: "3c3836")
        case .solarizedDark: return Color(hex: "073642")
        case .materialDark: return Color(hex: "37474f")
        case .cmds: return Color(hex: "183027")
        case .cmdsLight: return Color(hex: "dcebe3")
        }
    }

    var lineNumberColor: Color {
        switch self {
        case .oneDark: return Color(hex: "4b5263")
        case .dracula: return Color(hex: "6272a4")
        case .github: return Color(hex: "babbbc")
        case .nord: return Color(hex: "4c566a")
        case .tokyoNight: return Color(hex: "3b4261")
        case .gruvbox: return Color(hex: "665c54")
        case .solarizedDark: return Color(hex: "586e75")
        case .materialDark: return Color(hex: "37474f")
        case .cmds: return Color(hex: "3a4a43")
        case .cmdsLight: return Color(hex: "b9c2bc")
        }
    }

    var cursorColor: Color {
        switch self {
        case .oneDark: return Color(hex: "528bff")
        case .dracula: return Color(hex: "f8f8f0")
        case .github: return Color(hex: "044289")
        case .nord: return Color(hex: "d8dee9")
        case .tokyoNight: return Color(hex: "c0caf5")
        case .gruvbox: return Color(hex: "ebdbb2")
        case .solarizedDark: return Color(hex: "839496")
        case .materialDark: return Color(hex: "ffcc00")
        case .cmds: return Color(hex: "E985A2")
        case .cmdsLight: return Color(hex: "134538")
        }
    }

    /// Subtle background used to highlight the line containing the caret.
    var currentLineColor: Color {
        selectionColor
    }

    var highlightrThemeName: String {
        switch self {
        case .oneDark: return "atom-one-dark"
        case .dracula: return "dracula"
        case .github: return "github"
        case .nord: return "nord"
        case .tokyoNight: return "tokyo-night-dark"
        case .gruvbox: return "gruvbox-dark"
        case .solarizedDark: return "solarized-dark"
        case .materialDark: return "androidstudio"
        case .cmds: return "atom-one-dark"
        case .cmdsLight: return "github"
        }
    }
}

// MARK: - Color Hex Helper

extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch hex.count {
        case 3: // RGB (12-bit)
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6: // RGB (24-bit)
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8: // ARGB (32-bit)
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: Double(a) / 255
        )
    }
}
