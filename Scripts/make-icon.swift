// Draws the app icon and writes all macOS sizes into the asset catalog.
// Usage: swift Scripts/make-icon.swift
import AppKit

let canvas: CGFloat = 1024
let output = URL(fileURLWithPath: "Sources/Assets.xcassets/AppIcon.appiconset")

func color(_ hex: UInt32, alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha)
}

func drawIcon() {
    // Body: the standard macOS icon grid, an 824 pt rounded square centered on 1024.
    let body = NSRect(x: 100, y: 100, width: 824, height: 824)
    let bodyPath = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)

    NSGraphicsContext.saveGraphicsState()
    let bodyShadow = NSShadow()
    bodyShadow.shadowColor = .black.withAlphaComponent(0.3)
    bodyShadow.shadowOffset = NSSize(width: 0, height: -12)
    bodyShadow.shadowBlurRadius = 28
    bodyShadow.set()
    color(0x17541D).setFill()
    bodyPath.fill()
    NSGraphicsContext.restoreGraphicsState()

    // #17541D at the bottom, lightened slightly towards the top for depth.
    NSGradient(starting: color(0x226E2A), ending: color(0x17541D))!.draw(in: bodyPath, angle: -90)

    // Paper sheet with a folded top-right corner.
    let sheet = NSRect(x: 292, y: 222, width: 400, height: 520)
    let fold: CGFloat = 110
    let sheetPath = NSBezierPath()
    sheetPath.move(to: NSPoint(x: sheet.minX + 28, y: sheet.minY))
    sheetPath.line(to: NSPoint(x: sheet.maxX - 28, y: sheet.minY))
    sheetPath.curve(to: NSPoint(x: sheet.maxX, y: sheet.minY + 28),
                    controlPoint1: NSPoint(x: sheet.maxX - 12, y: sheet.minY),
                    controlPoint2: NSPoint(x: sheet.maxX, y: sheet.minY + 12))
    sheetPath.line(to: NSPoint(x: sheet.maxX, y: sheet.maxY - fold))
    sheetPath.line(to: NSPoint(x: sheet.maxX - fold, y: sheet.maxY))
    sheetPath.line(to: NSPoint(x: sheet.minX + 28, y: sheet.maxY))
    sheetPath.curve(to: NSPoint(x: sheet.minX, y: sheet.maxY - 28),
                    controlPoint1: NSPoint(x: sheet.minX + 12, y: sheet.maxY),
                    controlPoint2: NSPoint(x: sheet.minX, y: sheet.maxY - 12))
    sheetPath.line(to: NSPoint(x: sheet.minX, y: sheet.minY + 28))
    sheetPath.curve(to: NSPoint(x: sheet.minX + 28, y: sheet.minY),
                    controlPoint1: NSPoint(x: sheet.minX, y: sheet.minY + 12),
                    controlPoint2: NSPoint(x: sheet.minX + 12, y: sheet.minY))
    sheetPath.close()

    NSGraphicsContext.saveGraphicsState()
    let sheetShadow = NSShadow()
    sheetShadow.shadowColor = .black.withAlphaComponent(0.25)
    sheetShadow.shadowOffset = NSSize(width: 0, height: -10)
    sheetShadow.shadowBlurRadius = 24
    sheetShadow.set()
    color(0xFBFCFA).setFill()
    sheetPath.fill()
    NSGraphicsContext.restoreGraphicsState()

    let foldPath = NSBezierPath()
    foldPath.move(to: NSPoint(x: sheet.maxX - fold, y: sheet.maxY))
    foldPath.line(to: NSPoint(x: sheet.maxX - fold, y: sheet.maxY - fold + 18))
    foldPath.curve(to: NSPoint(x: sheet.maxX - fold + 18, y: sheet.maxY - fold),
                   controlPoint1: NSPoint(x: sheet.maxX - fold, y: sheet.maxY - fold + 6),
                   controlPoint2: NSPoint(x: sheet.maxX - fold + 6, y: sheet.maxY - fold))
    foldPath.line(to: NSPoint(x: sheet.maxX, y: sheet.maxY - fold))
    foldPath.close()
    color(0xD5DED8).setFill()
    foldPath.fill()

    // Text lines on the sheet.
    color(0xC9D3CD).setFill()
    for (index, width) in [230.0, 290, 260, 180].enumerated() {
        let y = sheet.maxY - 170 - CGFloat(index) * 62
        NSBezierPath(roundedRect: NSRect(x: sheet.minX + 56, y: y, width: width, height: 26),
                     xRadius: 13, yRadius: 13).fill()
    }

    // Upload badge overlapping the bottom-right corner of the sheet.
    let badge = NSRect(x: 560, y: 170, width: 250, height: 250)
    let badgePath = NSBezierPath(ovalIn: badge)
    NSGraphicsContext.saveGraphicsState()
    let badgeShadow = NSShadow()
    badgeShadow.shadowColor = .black.withAlphaComponent(0.3)
    badgeShadow.shadowOffset = NSSize(width: 0, height: -8)
    badgeShadow.shadowBlurRadius = 20
    badgeShadow.set()
    color(0xF2B33D).setFill()
    badgePath.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGradient(starting: color(0xF7C65A), ending: color(0xE59A1F))!.draw(in: badgePath, angle: -90)

    let arrow = NSBezierPath()
    let cx = badge.midX, cy = badge.midY
    arrow.move(to: NSPoint(x: cx, y: cy + 78))          // tip
    arrow.line(to: NSPoint(x: cx + 70, y: cy + 8))
    arrow.line(to: NSPoint(x: cx + 26, y: cy + 8))
    arrow.line(to: NSPoint(x: cx + 26, y: cy - 72))
    arrow.line(to: NSPoint(x: cx - 26, y: cy - 72))
    arrow.line(to: NSPoint(x: cx - 26, y: cy + 8))
    arrow.line(to: NSPoint(x: cx - 70, y: cy + 8))
    arrow.close()
    arrow.lineJoinStyle = .round
    arrow.lineWidth = 16
    NSColor.white.setFill()
    NSColor.white.setStroke()
    arrow.fill()
    arrow.stroke()
}

func render(size: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: canvas, height: canvas)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high
    drawIcon()
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
var images: [[String: String]] = []
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        try render(size: points * scale).write(to: output.appending(path: name))
        images.append(["idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name])
    }
}
let contents: [String: Any] = ["images": images, "info": ["version": 1, "author": "xcode"]]
try JSONSerialization.data(withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
    .write(to: output.appending(path: "Contents.json"))
try Data(#"{"info":{"version":1,"author":"xcode"}}"#.utf8)
    .write(to: output.deletingLastPathComponent().appending(path: "Contents.json"))
print("Wrote \(images.count) icon sizes to \(output.path)")
