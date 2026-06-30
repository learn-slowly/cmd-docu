#!/usr/bin/env swift
// cmd-docu 앱 아이콘 생성기.
// 콘셉: 그라디언트 타일 + 여러 장 쌓인 흰 문서(앞장은 접힌 모서리·본문 줄) + AI 스파크.
// 사용:
//   swift scripts/make_icon.swift <preview.png>                 # 1024 미리보기
//   swift scripts/make_icon.swift <preview.png> --colors A,B,C  # 팔레트 지정(hex, 좌상→우하)
//   swift scripts/make_icon.swift --install [--colors A,B,C]    # Resources/AppIcon.icns 생성
import AppKit

func c(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
            green: CGFloat((hex >> 8) & 0xff) / 255,
            blue: CGFloat(hex & 0xff) / 255, alpha: 1)
}

// 팔레트(좌상 → 중간 → 우하). --colors로 덮어쓸 수 있다.
var palette: [NSColor] = [c(0x4338CA), c(0x6D5BE0), c(0x9333EA)] // 기본: 인디고→바이올렛
if let idx = CommandLine.arguments.firstIndex(of: "--colors"),
   idx + 1 < CommandLine.arguments.count {
    let hexes = CommandLine.arguments[idx + 1].split(separator: ",").compactMap { UInt32($0, radix: 16) }
    if hexes.count == 3 { palette = hexes.map { c($0) } }
}

/// 둥근 사각형 path(접힌 모서리 옵션). 원점 좌하단 기준.
func sheetPath(_ rect: CGRect, fold: CGFloat, rr: CGFloat) -> CGMutablePath {
    let l = rect.minX, b = rect.minY, r = rect.maxX, t = rect.maxY
    let p = CGMutablePath()
    p.move(to: CGPoint(x: l, y: b + rr))
    p.addArc(tangent1End: CGPoint(x: l, y: b), tangent2End: CGPoint(x: l + rr, y: b), radius: rr)
    p.addArc(tangent1End: CGPoint(x: r, y: b), tangent2End: CGPoint(x: r, y: b + rr), radius: rr)
    if fold > 0 {
        p.addLine(to: CGPoint(x: r, y: t - fold))
        p.addLine(to: CGPoint(x: r - fold, y: t))
    } else {
        p.addArc(tangent1End: CGPoint(x: r, y: t), tangent2End: CGPoint(x: r - rr, y: t), radius: rr)
    }
    p.addArc(tangent1End: CGPoint(x: l, y: t), tangent2End: CGPoint(x: l, y: t - rr), radius: rr)
    p.closeSubpath()
    return p
}

func drawSymbol(_ name: String, into rect: CGRect, weight: NSFont.Weight = .regular) {
    let cfg = NSImage.SymbolConfiguration(pointSize: rect.height, weight: weight)
    guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
        .withSymbolConfiguration(cfg) else { return }
    let sz = base.size
    let tinted = NSImage(size: sz)
    tinted.lockFocus()
    base.draw(in: NSRect(origin: .zero, size: sz))
    NSColor.white.set()
    NSRect(origin: .zero, size: sz).fill(using: .sourceAtop)
    tinted.unlockFocus()
    let s = min(rect.width / sz.width, rect.height / sz.height)
    let w = sz.width * s, h = sz.height * s
    tinted.draw(in: CGRect(x: rect.midX - w / 2, y: rect.midY - h / 2, width: w, height: h))
}

func makeIcon(px: Int) -> CGImage? {
    let S = CGFloat(px)
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    guard let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8,
                              bytesPerRow: 0, space: cs,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }

    // 1) 둥근 타일 + 대각 그라디언트
    let radius = S * 0.235
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: CGRect(x: 0, y: 0, width: S, height: S),
                       cornerWidth: radius, cornerHeight: radius, transform: nil))
    ctx.clip()
    let grad = CGGradient(colorsSpace: cs, colors: palette.map { $0.cgColor } as CFArray,
                          locations: [0, 0.5, 1])!
    ctx.drawLinearGradient(grad, start: CGPoint(x: 0, y: S), end: CGPoint(x: S, y: 0), options: [])
    ctx.restoreGState()

    // 2) 쌓인 문서 — 뒤 두 장은 좌상으로 살짝 비껴 흰색(반투명), 앞장은 접힌 모서리+본문 줄
    let w = S * 0.40, h = S * 0.48
    let frontX = S * 0.30, frontY = S * 0.16   // 앞장(가장 우하)
    let dx = S * 0.055, dy = S * 0.055         // 뒤로 갈수록 좌상으로
    let rr = S * 0.045

    func sheet(_ i: Int, alpha: CGFloat) {
        let rect = CGRect(x: frontX - CGFloat(i) * dx, y: frontY + CGFloat(i) * dy, width: w, height: h)
        ctx.addPath(sheetPath(rect, fold: 0, rr: rr))
        ctx.setFillColor(NSColor(white: 1, alpha: alpha).cgColor)
        ctx.fillPath()
    }
    sheet(2, alpha: 0.55)
    sheet(1, alpha: 0.78)

    // 앞장
    let front = CGRect(x: frontX, y: frontY, width: w, height: h)
    let fold = S * 0.11
    ctx.addPath(sheetPath(front, fold: fold, rr: rr))
    ctx.setFillColor(NSColor.white.cgColor)
    ctx.fillPath()
    // 접힌 모서리 플랩(연한 그림자)
    let flap = CGMutablePath()
    flap.move(to: CGPoint(x: front.maxX - fold, y: front.maxY))
    flap.addLine(to: CGPoint(x: front.maxX, y: front.maxY - fold))
    flap.addLine(to: CGPoint(x: front.maxX - fold, y: front.maxY - fold))
    flap.closeSubpath()
    ctx.addPath(flap)
    ctx.setFillColor(NSColor(white: 0.0, alpha: 0.16).cgColor)
    ctx.fillPath()
    // 본문 줄 3개(팔레트 짙은 색)
    let lineColor = palette[0].cgColor
    let lx = front.minX + w * 0.16
    let lw = w * 0.60
    let lh = S * 0.022
    for (k, frac) in [0.30, 0.46, 0.62].enumerated() {
        _ = k
        let ly = front.minY + h * CGFloat(frac)
        ctx.addPath(CGPath(roundedRect: CGRect(x: lx, y: ly, width: k == 2 ? lw * 0.7 : lw, height: lh),
                           cornerWidth: lh / 2, cornerHeight: lh / 2, transform: nil))
        ctx.setFillColor(lineColor)
        ctx.fillPath()
    }

    // 3) AI 스파크(우상단, 흰색)
    let nsctx = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = nsctx
    drawSymbol("sparkles", into: CGRect(x: S * 0.60, y: S * 0.62, width: S * 0.30, height: S * 0.30),
               weight: .semibold)
    NSGraphicsContext.restoreGraphicsState()

    return ctx.makeImage()
}

func writePNG(_ img: CGImage, to url: URL) {
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
    CGImageDestinationAddImage(dest, img, nil)
    CGImageDestinationFinalize(dest)
}

let args = CommandLine.arguments
let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

if args.contains("--install") {
    let tmp = root.appendingPathComponent("dist/AppIcon.iconset")
    try? FileManager.default.removeItem(at: tmp)
    try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    let plan: [(String, Int)] = [
        ("icon_16x16", 16), ("icon_16x16@2x", 32),
        ("icon_32x32", 32), ("icon_32x32@2x", 64),
        ("icon_128x128", 128), ("icon_128x128@2x", 256),
        ("icon_256x256", 256), ("icon_256x256@2x", 512),
        ("icon_512x512", 512), ("icon_512x512@2x", 1024),
    ]
    for (name, px) in plan {
        if let img = makeIcon(px: px) { writePNG(img, to: tmp.appendingPathComponent("\(name).png")) }
    }
    let icns = root.appendingPathComponent("Resources/AppIcon.icns")
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
    p.arguments = ["-c", "icns", tmp.path, "-o", icns.path]
    try? p.run(); p.waitUntilExit()
    print("wrote \(icns.path) (exit \(p.terminationStatus))")
} else {
    let out = args.count > 1 && !args[1].hasPrefix("--") ? URL(fileURLWithPath: args[1])
        : root.appendingPathComponent("dist/icon-preview.png")
    if let img = makeIcon(px: 1024) {
        try? FileManager.default.createDirectory(at: out.deletingLastPathComponent(), withIntermediateDirectories: true)
        writePNG(img, to: out)
        print("wrote preview \(out.path)")
    }
}
