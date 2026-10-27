// Usage (from repo root): swift scripts/icons/make_icons.swift [outputRoot=.]  — regenerates the GHMac app icons and the rotor-map compass.png
//
// All artwork is drawn procedurally with CoreGraphics; no external images or fonts (labels use the system font).

import AppKit
import CoreGraphics
import Foundation

// MARK: - Palette

func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

let bgTop = rgb(0x24496F)
let bgBottom = rgb(0x0B1C30)
let serverAccent = rgb(0xFFB23F)   // amber: transmit / hardware hub
let clientAccent = rgb(0x3EE0C8)   // teal: operator control
let ink = rgb(0xEAF2FA)            // near-white for main strokes
let inkSoft = rgb(0xEAF2FA, 0.45)

// MARK: - Bitmap helpers

func makeContext(_ w: Int, _ h: Int, opaque: Bool = false) -> CGContext {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let info = opaque ? CGImageAlphaInfo.noneSkipLast.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue
    let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: cs, bitmapInfo: info)!
    ctx.setShouldAntialias(true)
    ctx.interpolationQuality = .high
    return ctx
}

func savePNG(_ ctx: CGContext, _ path: String) {
    let rep = NSBitmapImageRep(cgImage: ctx.makeImage()!)
    let data = rep.representation(using: .png, properties: [:])!
    try! FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
    try! data.write(to: URL(fileURLWithPath: path))
}

func rad(_ deg: CGFloat) -> CGFloat { deg * .pi / 180 }

/// Point at compass bearing `deg` (0 = up, clockwise) from `c`, in a y-up coordinate system.
func polar(_ c: CGPoint, _ r: CGFloat, _ deg: CGFloat) -> CGPoint {
    CGPoint(x: c.x + r * sin(rad(deg)), y: c.y + r * cos(rad(deg)))
}

// MARK: - Shared icon base (1024-unit design space, macOS Big Sur+ grid: 824pt tile, 100pt margin)

let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tileRadius: CGFloat = 185

func drawTile(_ ctx: CGContext, accent: CGColor) {
    let path = CGPath(roundedRect: tile, cornerWidth: tileRadius, cornerHeight: tileRadius, transform: nil)
    // Drop shadow
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: rgb(0x000000, 0.35))
    ctx.addPath(path); ctx.setFillColor(bgBottom); ctx.fillPath()
    ctx.restoreGState()
    // Vertical gradient body
    ctx.saveGState()
    ctx.addPath(path); ctx.clip()
    let g = CGGradient(colorsSpace: nil, colors: [bgTop, bgBottom] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(g, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 100), options: [])
    // Soft accent glow behind the symbol
    let glow = CGGradient(colorsSpace: nil, colors: [accent.copy(alpha: 0.28)!, accent.copy(alpha: 0)!] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(glow, startCenter: CGPoint(x: 512, y: 560), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: 560), endRadius: 430, options: [])
    // Top sheen
    let sheen = CGGradient(colorsSpace: nil, colors: [rgb(0xFFFFFF, 0.10), rgb(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(sheen, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 600), options: [])
    ctx.restoreGState()
    // Hairline inner border
    ctx.saveGState()
    ctx.addPath(CGPath(roundedRect: tile.insetBy(dx: 3, dy: 3), cornerWidth: tileRadius - 3, cornerHeight: tileRadius - 3, transform: nil))
    ctx.setStrokeColor(rgb(0xFFFFFF, 0.12)); ctx.setLineWidth(6); ctx.strokePath()
    ctx.restoreGState()
}

// MARK: - Server icon: Yagi antenna on a lattice mast, radiating signal arcs

func drawServer(_ ctx: CGContext, px: Int) {
    let small = px <= 32
    drawTile(ctx, accent: serverAccent)
    ctx.setLineCap(.round); ctx.setLineJoin(.round)

    let top = CGPoint(x: 512, y: 640)      // antenna feed point (top of mast)
    let baseY: CGFloat = 215
    let baseHalf: CGFloat = small ? 120 : 125
    let topHalf: CGFloat = small ? 26 : 16

    // Signal arcs (drawn first so the mast sits over them)
    let arcCount = px <= 16 ? 1 : (small ? 2 : 3)
    let arcCenter = CGPoint(x: top.x, y: top.y + 8)
    for i in 0..<arcCount {
        let r: CGFloat = small ? (px <= 16 ? 265 : 235 + CGFloat(i) * 100) : 215 + CGFloat(i) * 66
        let alpha: CGFloat = 1 - CGFloat(i) * (small ? 0.25 : 0.22)
        let lw: CGFloat = px <= 16 ? 70 : (small ? 52 : 30)
        for side in [-1.0, 1.0] as [CGFloat] {
            let mid: CGFloat = side < 0 ? .pi : 0
            let span: CGFloat = rad(small ? 30 : 30 - CGFloat(i) * 3)
            ctx.addArc(center: arcCenter, radius: r, startAngle: mid - span, endAngle: mid + span, clockwise: false)
            ctx.setStrokeColor(serverAccent.copy(alpha: alpha)!); ctx.setLineWidth(lw); ctx.strokePath()
        }
    }

    // Mast: tapered lattice tower
    let bl = CGPoint(x: 512 - baseHalf, y: baseY), br = CGPoint(x: 512 + baseHalf, y: baseY)
    let tl = CGPoint(x: 512 - topHalf, y: top.y - (small ? 40 : 14)), tr = CGPoint(x: 512 + topHalf, y: top.y - (small ? 40 : 14))
    ctx.setStrokeColor(ink)
    if small {
        ctx.move(to: bl); ctx.addLine(to: tl); ctx.move(to: br); ctx.addLine(to: tr)
        ctx.setLineWidth(52); ctx.strokePath()
        ctx.move(to: CGPoint(x: 512 - 70, y: 380)); ctx.addLine(to: CGPoint(x: 512 + 70, y: 380))
        ctx.setLineWidth(40); ctx.strokePath()
    } else {
        ctx.move(to: bl); ctx.addLine(to: tl); ctx.move(to: br); ctx.addLine(to: tr)
        ctx.setLineWidth(30); ctx.strokePath()
        // cross bracing
        let levels = 4
        func edge(_ t: CGFloat, _ side: CGFloat) -> CGPoint {
            let y = baseY + (tl.y - baseY) * t
            let half = baseHalf + (topHalf - baseHalf) * t
            return CGPoint(x: 512 + side * half, y: y)
        }
        // Geometric spacing so panels shrink toward the top
        var ts: [CGFloat] = [0]
        let ratio: CGFloat = 0.72
        let total = (0..<levels).reduce(CGFloat(0)) { $0 + pow(ratio, CGFloat($1)) }
        var acc: CGFloat = 0
        for i in 0..<levels { acc += pow(ratio, CGFloat(i)) / total; ts.append(acc) }
        ctx.setLineWidth(16)
        for i in 0..<levels {
            let a = ts[i], b = ts[i + 1]
            ctx.move(to: edge(a, -1)); ctx.addLine(to: edge(b, 1))
            ctx.move(to: edge(a, 1)); ctx.addLine(to: edge(b, -1))
            if i > 0 { ctx.move(to: edge(a, -1)); ctx.addLine(to: edge(a, 1)) }
        }
        ctx.strokePath()
        // footing
        ctx.move(to: CGPoint(x: bl.x - 30, y: baseY)); ctx.addLine(to: CGPoint(x: br.x + 30, y: baseY))
        ctx.setLineWidth(26); ctx.strokePath()
    }

    // Mast pole up to the boom
    ctx.move(to: CGPoint(x: 512, y: tl.y)); ctx.addLine(to: top)
    ctx.setLineWidth(small ? 44 : 26); ctx.strokePath()

    // Yagi: horizontal boom with vertical elements (side view), reflector longest at the back
    let boomL: CGFloat = small ? 175 : 165
    let boomY = top.y
    ctx.move(to: CGPoint(x: 512 - boomL, y: boomY)); ctx.addLine(to: CGPoint(x: 512 + boomL, y: boomY))
    ctx.setLineWidth(small ? 40 : 22); ctx.strokePath()
    let elements: [(CGFloat, CGFloat)] = small
        ? [(-160, 105), (0, 80), (160, 60)]
        : [(-150, 112), (-50, 94), (50, 82), (150, 70)]
    ctx.setLineWidth(small ? 38 : 20)
    for (dx, h) in elements {
        ctx.move(to: CGPoint(x: 512 + dx, y: boomY - h)); ctx.addLine(to: CGPoint(x: 512 + dx, y: boomY + h))
    }
    ctx.strokePath()

    // Accent hub at the feed point
    let hubR: CGFloat = small ? 40 : 30
    ctx.setFillColor(serverAccent)
    ctx.fillEllipse(in: CGRect(x: top.x - hubR, y: top.y - hubR, width: hubR * 2, height: hubR * 2))
}

// MARK: - Client icon: azimuth dial with beam-heading pointer

func drawClient(_ ctx: CGContext, px: Int) {
    let small = px <= 32
    drawTile(ctx, accent: clientAccent)
    ctx.setLineCap(.round); ctx.setLineJoin(.round)
    let c = CGPoint(x: 512, y: 500)
    let R: CGFloat = 300
    let heading: CGFloat = 52

    // Dial face
    let face = CGGradient(colorsSpace: nil, colors: [rgb(0x16324F), rgb(0x0E2236)] as CFArray, locations: [0, 1])!
    ctx.saveGState()
    ctx.addEllipse(in: CGRect(x: c.x - R, y: c.y - R, width: 2 * R, height: 2 * R)); ctx.clip()
    ctx.drawLinearGradient(face, start: CGPoint(x: 512, y: c.y + R), end: CGPoint(x: 512, y: c.y - R), options: [])
    ctx.restoreGState()

    // Faint four-point compass rose behind everything
    if !small {
        let long = R - 110, short: CGFloat = 46
        for deg in stride(from: 0, to: 360, by: 90) {
            let d = CGFloat(deg)
            ctx.move(to: c); ctx.addLine(to: polar(c, short, d - 45)); ctx.addLine(to: polar(c, long, d))
            ctx.addLine(to: polar(c, short, d + 45)); ctx.closePath()
        }
        ctx.setFillColor(rgb(0xFFFFFF, 0.08)); ctx.fillPath()
    }

    // Beam wedge (the antenna's beam at the current heading)
    let beamWidth: CGFloat = small ? 40 : 34
    let wedgeR = R - (small ? 24 : 13)
    ctx.saveGState()
    ctx.move(to: c)
    // CG angles: counter-clockwise from +x; bearing b -> angle 90° - b
    ctx.addArc(center: c, radius: wedgeR, startAngle: rad(90 - heading - beamWidth / 2),
               endAngle: rad(90 - heading + beamWidth / 2), clockwise: false)
    ctx.closePath(); ctx.clip()
    let wg = CGGradient(colorsSpace: nil, colors: [clientAccent.copy(alpha: 0.05)!, clientAccent.copy(alpha: 0.55)!] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(wg, startCenter: c, startRadius: 0, endCenter: c, endRadius: wedgeR, options: [])
    ctx.restoreGState()

    // Ticks: 36 fine ticks, bold cardinals
    if small {
        ctx.setLineWidth(40); ctx.setStrokeColor(ink)
        for deg in stride(from: 90, to: 360, by: 90) {
            ctx.move(to: polar(c, R - 20, CGFloat(deg))); ctx.addLine(to: polar(c, R - 95, CGFloat(deg)))
        }
        ctx.strokePath()
    } else {
        for deg in stride(from: 0, to: 360, by: 5) {
            if deg == 0 { continue }
            let cardinal = deg % 90 == 0, ten = deg % 10 == 0
            let len: CGFloat = cardinal ? 62 : (ten ? 30 : 18)
            ctx.move(to: polar(c, R - 32, CGFloat(deg))); ctx.addLine(to: polar(c, R - 32 - len, CGFloat(deg)))
            ctx.setStrokeColor(cardinal ? ink : (ten ? rgb(0xEAF2FA, 0.7) : rgb(0xEAF2FA, 0.35)))
            ctx.setLineWidth(cardinal ? 18 : (ten ? 9 : 7)); ctx.strokePath()
        }
    }

    // Outer bezel ring
    ctx.addEllipse(in: CGRect(x: c.x - R, y: c.y - R, width: 2 * R, height: 2 * R))
    ctx.setStrokeColor(ink); ctx.setLineWidth(small ? 48 : 26); ctx.strokePath()

    // North marker: accent triangle sitting on the bezel, pointing in
    let nW: CGFloat = small ? 78 : 50
    let nTop = c.y + R + (small ? 20 : 34)
    let nTip = CGPoint(x: c.x, y: c.y + R - (small ? 115 : 92))
    ctx.move(to: nTip)
    ctx.addLine(to: CGPoint(x: c.x - nW, y: nTop)); ctx.addLine(to: CGPoint(x: c.x + nW, y: nTop)); ctx.closePath()
    ctx.setFillColor(clientAccent); ctx.fillPath()
    ctx.move(to: nTip)
    ctx.addLine(to: CGPoint(x: c.x - nW, y: nTop)); ctx.addLine(to: CGPoint(x: c.x + nW, y: nTop)); ctx.closePath()
    ctx.setStrokeColor(rgb(0x0E2236)); ctx.setLineWidth(small ? 0 : 8); if !small { ctx.strokePath() }

    // Heading pointer: slim lance from the hub to the ring
    let tip = polar(c, R - (small ? 60 : 50), heading)
    let back = polar(c, small ? 40 : 54, heading + 180)
    let halfW: CGFloat = small ? 52 : 30
    let left = polar(c, halfW, heading - 90), right = polar(c, halfW, heading + 90)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -6), blur: 16, color: rgb(0x000000, 0.5))
    ctx.move(to: tip); ctx.addLine(to: left); ctx.addLine(to: back); ctx.addLine(to: right); ctx.closePath()
    ctx.setFillColor(clientAccent); ctx.fillPath()
    ctx.restoreGState()
    if !small {
        ctx.move(to: tip); ctx.addLine(to: right); ctx.addLine(to: back); ctx.closePath()
        ctx.setFillColor(rgb(0x0B1C30, 0.22)); ctx.fillPath()
    }

    // Center hub
    let hub: CGFloat = small ? 40 : 36
    ctx.setFillColor(ink)
    ctx.fillEllipse(in: CGRect(x: c.x - hub, y: c.y - hub, width: hub * 2, height: hub * 2))
    if !small {
        ctx.setFillColor(rgb(0x0E2236))
        ctx.fillEllipse(in: CGRect(x: c.x - 13, y: c.y - 13, width: 26, height: 26))
    }
}

// MARK: - Icon set rendering

let iconFiles: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32), ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256), ("icon_256x256.png", 256),
    ("icon_256x256@2x.png", 512), ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]

func renderIcon(_ draw: (CGContext, Int) -> Void, px: Int) -> CGContext {
    let ctx = makeContext(px, px)
    ctx.scaleBy(x: CGFloat(px) / 1024, y: CGFloat(px) / 1024)
    draw(ctx, px)
    return ctx
}

// MARK: - Rotor map compass (366×365, opaque white, rose centered)

func drawCompass(path: String) {
    let W = 366, H = 365
    let ctx = makeContext(W, H, opaque: true)
    ctx.setFillColor(rgb(0xFFFFFF)); ctx.fill(CGRect(x: 0, y: 0, width: W, height: H))
    let c = CGPoint(x: CGFloat(W) / 2, y: CGFloat(H) / 2)
    let R: CGFloat = 142   // outer edge of tick ring
    let line = rgb(0x8A97A6), lineDark = rgb(0x4A5868), faint = rgb(0xC9D2DC)
    ctx.setLineCap(.butt)

    // Range rings and crosshair
    ctx.setStrokeColor(faint); ctx.setLineWidth(1)
    for f in [1.0 / 3.0, 2.0 / 3.0] as [CGFloat] {
        let r = (R - 22) * f
        ctx.strokeEllipse(in: CGRect(x: c.x - r, y: c.y - r, width: 2 * r, height: 2 * r))
    }
    ctx.setLineDash(phase: 0, lengths: [3, 3])
    for deg in stride(from: 0, to: 180, by: 45) {
        ctx.move(to: polar(c, R - 22, CGFloat(deg))); ctx.addLine(to: polar(c, R - 22, CGFloat(deg) + 180))
    }
    ctx.strokePath()
    ctx.setLineDash(phase: 0, lengths: [])

    // Ring
    ctx.setStrokeColor(lineDark); ctx.setLineWidth(1.5)
    ctx.strokeEllipse(in: CGRect(x: c.x - R, y: c.y - R, width: 2 * R, height: 2 * R))
    let rIn = R - 22
    ctx.setStrokeColor(line); ctx.setLineWidth(1)
    ctx.strokeEllipse(in: CGRect(x: c.x - rIn, y: c.y - rIn, width: 2 * rIn, height: 2 * rIn))

    // Ticks every 1/5/10/30°
    for deg in 0..<360 {
        let len: CGFloat; let w: CGFloat; let col: CGColor
        if deg % 30 == 0 { len = 22; w = 2; col = lineDark }
        else if deg % 10 == 0 { len = 14; w = 1.4; col = lineDark }
        else if deg % 5 == 0 { len = 9; w = 1; col = line }
        else { len = 5; w = 0.7; col = line }
        ctx.move(to: polar(c, R, CGFloat(deg))); ctx.addLine(to: polar(c, R - len, CGFloat(deg)))
        ctx.setStrokeColor(col); ctx.setLineWidth(w); ctx.strokePath()
    }

    // Small center dot
    ctx.setFillColor(lineDark); ctx.fillEllipse(in: CGRect(x: c.x - 2, y: c.y - 2, width: 4, height: 4))

    // Labels (upright, system font)
    let gctx = NSGraphicsContext(cgContext: ctx, flipped: false)
    NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = gctx
    func label(_ s: String, _ deg: CGFloat, _ r: CGFloat, _ font: NSFont, _ color: NSColor) {
        let a = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color])
        let sz = a.size()
        let p = polar(c, r, deg)
        a.draw(at: CGPoint(x: p.x - sz.width / 2, y: p.y - sz.height / 2 + font.descender / 2))
    }
    let cardinal = NSFont.systemFont(ofSize: 17, weight: .bold)
    let degFont = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .medium)
    let cardColor = NSColor(cgColor: rgb(0x1F2D3D))!, degColor = NSColor(cgColor: rgb(0x4A5868))!
    for deg in stride(from: 0, to: 360, by: 30) {
        switch deg {
        case 0: label("N", 0, R + 17, cardinal, NSColor(cgColor: rgb(0xC0392B))!)
        case 90: label("E", 90, R + 15, cardinal, cardColor)
        case 180: label("S", 180, R + 15, cardinal, cardColor)
        case 270: label("W", 270, R + 17, cardinal, cardColor)
        default: label("\(deg)", CGFloat(deg), R + 17, degFont, degColor)
        }
    }
    NSGraphicsContext.restoreGraphicsState()
    savePNG(ctx, path)
}

// MARK: - Main

let root = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."
let serverSet = "\(root)/Sources/GHEServer/Resources/Assets.xcassets/AppIcon.appiconset"
let clientSet = "\(root)/Sources/GHEClient/Resources/Assets.xcassets/AppIcon.appiconset"
for (name, px) in iconFiles {
    savePNG(renderIcon(drawServer, px: px), "\(serverSet)/\(name)")
    savePNG(renderIcon(drawClient, px: px), "\(clientSet)/\(name)")
}
drawCompass(path: "\(root)/Sources/GHEClient/Resources/compass.png")
print("Wrote icons to \(serverSet), \(clientSet) and compass.png")
