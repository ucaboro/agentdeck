// Renders the AgentDeck app icon (stacked violet diamonds on a charcoal squircle).
import AppKit

let out = CommandLine.arguments[1]
let sizes = [16, 32, 64, 128, 256, 512, 1024]
try? FileManager.default.createDirectory(atPath: out, withIntermediateDirectories: true)

func render(_ px: Int) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let s = CGFloat(px)
    let inset = s * 0.09
    let rect = NSRect(x: inset, y: inset, width: s - 2 * inset, height: s - 2 * inset)
    let bg = NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.225, yRadius: rect.width * 0.225)
    NSGradient(colors: [NSColor(red: 0.13, green: 0.12, blue: 0.18, alpha: 1), NSColor(red: 0.06, green: 0.055, blue: 0.08, alpha: 1)])!.draw(in: bg, angle: -90)
    NSColor(white: 1, alpha: 0.08).setStroke(); bg.lineWidth = max(1, s * 0.004); bg.stroke()
    let violet = NSColor(red: 0.545, green: 0.36, blue: 0.965, alpha: 1)
    for i in (0..<3).reversed() {
        let cx = s / 2, cy = s / 2 + CGFloat(1 - i) * s * 0.105
        let w = s * 0.46, h = s * 0.25
        let p = NSBezierPath()
        p.move(to: NSPoint(x: cx, y: cy + h / 2)); p.line(to: NSPoint(x: cx + w / 2, y: cy))
        p.line(to: NSPoint(x: cx, y: cy - h / 2)); p.line(to: NSPoint(x: cx - w / 2, y: cy)); p.close()
        p.lineJoinStyle = .round
        let a = 1.0 - Double(i) * 0.28
        NSGradient(colors: [violet.withAlphaComponent(a), NSColor(red: 0.39, green: 0.25, blue: 0.85, alpha: a)])!.draw(in: p, angle: -60)
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

for sz in sizes {
    for scale in [1, 2] where !(sz == 1024 && scale == 2) {
        let px = sz * scale
        let name = scale == 1 ? "icon_\(sz)x\(sz).png" : "icon_\(sz)x\(sz)@2x.png"
        if sz == 1024 { continue }
        try! render(px).representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out + "/" + name))
    }
}
