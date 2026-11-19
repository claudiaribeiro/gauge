// Draws the app icon: two nested usage gauges (clay = Claude, teal = Codex) on a dark tile.
// Run: swift icon/make-icon.swift icon/AppIcon-1024.png   (build.sh turns it into AppIcon.icns)

import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments.dropFirst().first ?? "AppIcon-1024.png"

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                           bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                           colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
let ctx = NSGraphicsContext.current!.cgContext

// macOS icon grid: 824pt tile centred on a 1024 canvas, continuous-ish corner radius.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 186, cornerHeight: 186, transform: nil)

// Drop shadow
ctx.saveGState()
ctx.setShadow(offset: CGSize(width: 0, height: -12), blur: 28, color: rgb(0x000000, 0.35))
ctx.addPath(tilePath)
ctx.setFillColor(rgb(0x1E1E22))
ctx.fillPath()
ctx.restoreGState()

// Tile gradient
ctx.saveGState()
ctx.addPath(tilePath)
ctx.clip()
let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                          colors: [rgb(0x34343B), rgb(0x18181C)] as CFArray, locations: [0, 1])!
ctx.drawLinearGradient(gradient, start: CGPoint(x: 512, y: tile.maxY), end: CGPoint(x: 512, y: tile.minY), options: [])
// faint top highlight
ctx.setStrokeColor(rgb(0xFFFFFF, 0.08))
ctx.setLineWidth(4)
ctx.addPath(CGPath(roundedRect: tile.insetBy(dx: 2, dy: 2), cornerWidth: 184, cornerHeight: 184, transform: nil))
ctx.strokePath()
ctx.restoreGState()

// Gauges: 270° sweep, open at the bottom, filling clockwise from bottom-left.
let center = CGPoint(x: 512, y: 500)
let start: CGFloat = 225, sweep: CGFloat = 270

func gauge(radius: CGFloat, width: CGFloat, fraction: CGFloat, color: CGColor) {
    func arc(to f: CGFloat) {
        ctx.addArc(center: center, radius: radius,
                   startAngle: start * .pi / 180, endAngle: (start - sweep * f) * .pi / 180, clockwise: true)
    }
    ctx.setLineCap(.round)
    ctx.setLineWidth(width)
    // track
    ctx.setStrokeColor(rgb(0xFFFFFF, 0.10))
    arc(to: 1); ctx.strokePath()
    // fill
    ctx.setStrokeColor(color)
    arc(to: fraction); ctx.strokePath()
}

gauge(radius: 285, width: 62, fraction: 0.72, color: rgb(0xE0896A))   // Claude — clay
gauge(radius: 195, width: 62, fraction: 0.42, color: rgb(0x4CC2BA))   // Codex — teal

// Hub
ctx.setFillColor(rgb(0xF2F2F5))
ctx.fillEllipse(in: CGRect(x: center.x - 34, y: center.y - 34, width: 68, height: 68))

NSGraphicsContext.current = nil
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
print("wrote \(out)")
