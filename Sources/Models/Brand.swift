import SwiftUI
import AppKit

// MARK: - CMDS Brand Color System (mirrors vault "CMDS Color System" v2.5)
//
// Single source of truth for CMDSPACE branding inside CmdMD. Corporate Identity
// is Dark Green (#134538), pinned for all CI touchpoints. Dark mode promotes
// Pink (#E985A2) to the accent slot. Everything accent-colored in the UI should
// resolve through `Color.cmdsAccent` so the whole app follows the active
// appearance automatically — light → green, dark → pink — with no per-call-site
// `colorScheme` branching.

enum CMDSBrand {
    // Corporate Identity — fixed across light/dark.
    static let green       = Color(hex: "134538")
    static let greenHover  = Color(hex: "1a5d4b")
    static let greenBright = Color(hex: "22896a")
    static let greenGlow   = Color(hex: "2fb488")
    static let green50     = Color(hex: "f1f7f4")
    static let green100    = Color(hex: "dcebe3")
    static let green200    = Color(hex: "bad9c9")

    // Dark-mode accent family.
    static let pink        = Color(hex: "E985A2")
    static let pinkLight   = Color(hex: "F4A4B8")
    static let pinkDark    = Color(hex: "D16C8A")
    static let pinkSoft    = Color(hex: "2b1922")

    // CMDS Process stage colors (used as semantic accents, e.g. routing).
    static let connect     = Color(hex: "3b82f6")
    static let merge       = Color(hex: "8b5cf6")
    static let develop     = Color(hex: "f59e0b")
    static let share       = Color(hex: "10b981")

    // Hex strings shared with the web preview CSS so the rendered document and
    // the native chrome use identical brand values.
    static let greenHex = "#134538"
    static let pinkHex  = "#E985A2"
}

// MARK: - Adaptive accent tokens

extension Color {
    /// The adaptive CMDS accent — Dark Green in light mode, Pink in dark mode.
    /// Backed by a dynamic `NSColor`, so it re-resolves on appearance changes.
    static let cmdsAccent = Color(nsColor: .cmdsAccent)

    /// A faint tint of the accent for selected rows, hover fills, and chips.
    static let cmdsAccentSoft = Color(nsColor: .cmdsAccentSoft)

    /// Text/icon color to place ON a solid accent fill. White over green (light),
    /// near-black over pink (dark) — the CMDS `--accent-on` rule. White-on-pink
    /// only reaches ~2.5:1; near-black-on-pink reaches ~7.7:1 (WCAG AA).
    static let cmdsAccentOn = Color(nsColor: .cmdsAccentOn)

    /// The CMDS green, fixed (used for brand marks / always-green affordances).
    static let cmdsGreen = CMDSBrand.green
}

extension NSColor {
    /// Dark Green (#134538) in light appearances, Pink (#E985A2) in dark.
    static let cmdsAccent = NSColor(name: NSColor.Name("CMDSAccent")) { appearance in
        appearance.isDarkMode ? NSColor(hex: "E985A2") : NSColor(hex: "134538")
    }

    /// Translucent accent for subtle fills; alpha tuned per appearance.
    static let cmdsAccentSoft = NSColor(name: NSColor.Name("CMDSAccentSoft")) { appearance in
        appearance.isDarkMode
            ? NSColor(hex: "E985A2").withAlphaComponent(0.18)
            : NSColor(hex: "134538").withAlphaComponent(0.12)
    }

    /// On-accent text: white over green (light), near-black over pink (dark).
    static let cmdsAccentOn = NSColor(name: NSColor.Name("CMDSAccentOn")) { appearance in
        appearance.isDarkMode ? NSColor(hex: "0b0f0d") : NSColor(hex: "ffffff")
    }

    /// Hex initializer matching `Color(hex:)` semantics (RGB / RRGGBB / AARRGGBB).
    convenience init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&int)
        let a, r, g, b: UInt64
        switch cleaned.count {
        case 3:
            (a, r, g, b) = (255, (int >> 8) * 17, (int >> 4 & 0xF) * 17, (int & 0xF) * 17)
        case 6:
            (a, r, g, b) = (255, int >> 16, int >> 8 & 0xFF, int & 0xFF)
        case 8:
            (a, r, g, b) = (int >> 24, int >> 16 & 0xFF, int >> 8 & 0xFF, int & 0xFF)
        default:
            (a, r, g, b) = (255, 0, 0, 0)
        }
        self.init(
            srgbRed: CGFloat(r) / 255,
            green: CGFloat(g) / 255,
            blue: CGFloat(b) / 255,
            alpha: CGFloat(a) / 255
        )
    }
}

extension NSAppearance {
    /// True when the effective appearance is one of the dark variants.
    var isDarkMode: Bool {
        bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}

// MARK: - Brand logo

/// The single, canonical CmdMD mark: the CMDS open-book on the green→pink tile.
/// Mirrors the app icon so every in-app hero shows the same logo. Loads the
/// bundled book glyph when present (packaged app), else an SF Symbol fallback.
struct BrandLogo: View {
    var size: CGFloat = 76
    /// Show the "MD" wordmark under the book (icon-style lockup).
    var showWordmark: Bool = false

    private var bookGlyph: NSImage? {
        guard let url = Bundle.main.url(forResource: "cmds-book-white", withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.235, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [CMDSBrand.green, CMDSBrand.greenBright, CMDSBrand.pink],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .frame(width: size, height: size)
            .overlay {
                VStack(spacing: size * 0.04) {
                    Group {
                        if let glyph = bookGlyph {
                            Image(nsImage: glyph).resizable().scaledToFit()
                        } else {
                            Image(systemName: "book.fill").resizable().scaledToFit()
                                .foregroundStyle(.white)
                        }
                    }
                    .frame(width: size * 0.56, height: size * (showWordmark ? 0.34 : 0.42))

                    if showWordmark {
                        Text("MD")
                            .font(.system(size: size * 0.22, weight: .heavy))
                            .foregroundStyle(.white)
                    }
                }
            }
    }
}
