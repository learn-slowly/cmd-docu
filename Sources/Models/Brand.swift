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

/// cmd-docu 마크 색(슬레이트 → 앰버). 앱 아이콘(scripts/make_icon.swift)과 동일.
enum DocBrand {
    static let slate    = Color(hex: "1E293B")
    static let slateMid = Color(hex: "475569")
    static let amber    = Color(hex: "F59E0B")
}

/// 앞장에 접힌 모서리가 있는 문서 모양(좌상 원점, y 아래로).
struct FoldedDoc: Shape {
    var fold: CGFloat = 0.26   // 가로 대비 접힌 모서리 비율
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let f = rect.width * fold
        let rr = rect.width * 0.10
        p.move(to: CGPoint(x: rect.minX, y: rect.minY + rr))
        p.addQuadCurve(to: CGPoint(x: rect.minX + rr, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX - f, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + f))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - rr))
        p.addQuadCurve(to: CGPoint(x: rect.maxX - rr, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX + rr, y: rect.maxY))
        p.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - rr), control: CGPoint(x: rect.minX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

/// cmd-docu 캐노니컬 마크: 슬레이트→앰버 타일 위에 쌓인 흰 문서 + AI 스파크.
/// 앱 아이콘과 같은 모티프(인앱 hero용). 순수 벡터라 swift run·패키지 모두 동일.
struct BrandLogo: View {
    var size: CGFloat = 76
    /// 호환용(현재 마크는 자체 텍스트 없음 — 워드마크는 호출부에서 별도 표기).
    var showWordmark: Bool = false

    private var sheetW: CGFloat { size * 0.40 }
    private var sheetH: CGFloat { size * 0.48 }
    private var d: CGFloat { size * 0.055 }

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.235, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [DocBrand.slate, DocBrand.slateMid, DocBrand.amber],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .frame(width: size, height: size)
            .overlay { mark }
            .clipShape(RoundedRectangle(cornerRadius: size * 0.235, style: .continuous))
    }

    private var mark: some View {
        ZStack {
            backSheet(2).opacity(0.55)
            backSheet(1).opacity(0.78)
            frontSheet
            Image(systemName: "sparkles")
                .font(.system(size: size * 0.20, weight: .semibold))
                .foregroundStyle(.white)
                .position(x: size * 0.75, y: size * 0.23)
        }
        .frame(width: size, height: size)
    }

    private func backSheet(_ i: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: size * 0.045, style: .continuous)
            .fill(.white)
            .frame(width: sheetW, height: sheetH)
            .position(x: size * 0.50 - i * d, y: size * 0.60 - i * d)
    }

    private var frontSheet: some View {
        FoldedDoc()
            .fill(.white)
            .overlay {
                // 접힌 모서리 그림자
                FoldFlap()
                    .fill(Color.black.opacity(0.15))
                // 본문 줄 3개(슬레이트)
                VStack(alignment: .leading, spacing: sheetH * 0.12) {
                    Capsule().fill(DocBrand.slate).frame(width: sheetW * 0.58, height: size * 0.028)
                    Capsule().fill(DocBrand.slate).frame(width: sheetW * 0.58, height: size * 0.028)
                    Capsule().fill(DocBrand.slate).frame(width: sheetW * 0.40, height: size * 0.028)
                }
                .frame(width: sheetW, height: sheetH, alignment: .center)
                .offset(y: sheetH * 0.14)
            }
            .frame(width: sheetW, height: sheetH)
            .position(x: size * 0.50, y: size * 0.60)
    }
}

/// 접힌 모서리 플랩(앞장 우상단 삼각형).
struct FoldFlap: Shape {
    var fold: CGFloat = 0.26
    func path(in rect: CGRect) -> Path {
        var p = Path()
        let f = rect.width * fold
        p.move(to: CGPoint(x: rect.maxX - f, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + f))
        p.addLine(to: CGPoint(x: rect.maxX - f, y: rect.minY + f))
        p.closeSubpath()
        return p
    }
}
