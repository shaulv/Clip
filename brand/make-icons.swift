import AppKit

// Renders every icon Clip ships from one source mark.
//
// The mark is ⌘C: the shortcut the whole app is about. Kept as vector art and
// rasterised here, so the 16pt menu-bar size and the 1024pt Finder size come
// from the same drawing rather than from someone resizing a PNG.
//
//   swift make-icons.swift <glyph.svg> <out-dir>

let args = CommandLine.arguments
guard args.count >= 3, let glyph = NSImage(contentsOfFile: args[1]) else {
    FileHandle.standardError.write(Data("usage: make-icons.swift <glyph.svg> <out>\n".utf8))
    exit(1)
}
let outDir = URL(fileURLWithPath: args[2])
try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

/// Apple's macOS icon grid: on a 1024 canvas the rounded body is 824 across
/// with a 185.4 corner radius. Drawing edge to edge instead makes an icon that
/// stands out in the Dock for the wrong reason - every other icon is inset.
let bodyRatio: CGFloat = 824.0 / 1024.0
let radiusRatio: CGFloat = 185.4 / 824.0
/// How much of the body the glyph fills.
let glyphRatio: CGFloat = 0.62

let background = NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)

func render(size: Int, rounded: Bool, tint: NSColor?, scale: Int = 1) -> Data? {
    let side = CGFloat(size * scale)
    guard let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: Int(side), pixelsHigh: Int(side),
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
    rep.size = NSSize(width: side, height: side)

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSGraphicsContext.current?.imageInterpolation = .high

    var glyphBox: NSRect
    if rounded {
        let body = side * bodyRatio
        let origin = (side - body) / 2
        let rect = NSRect(x: origin, y: origin, width: body, height: body)
        let radius = body * radiusRatio
        background.setFill()
        NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        let inner = body * glyphRatio
        glyphBox = NSRect(x: (side - inner) / 2, y: (side - inner) / 2,
                          width: inner, height: inner)
    } else {
        // A menu-bar template fills its canvas: the bar provides the margin.
        glyphBox = NSRect(x: 0, y: 0, width: side, height: side)
    }

    // The source art is wider than it is tall, so fit rather than stretch.
    let art = glyph.size
    let fit = min(glyphBox.width / art.width, glyphBox.height / art.height)
    let drawn = NSRect(x: glyphBox.midX - art.width * fit / 2,
                       y: glyphBox.midY - art.height * fit / 2,
                       width: art.width * fit, height: art.height * fit)
    glyph.draw(in: drawn, from: .zero, operation: .sourceOver, fraction: 1)

    if let tint {
        // Template images are one colour; the system tints them for the bar.
        tint.setFill()
        drawn.fill(using: .sourceAtop)
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])
}

func write(_ data: Data?, _ name: String) {
    guard let data else { print("  failed: \(name)"); return }
    try? data.write(to: outDir.appendingPathComponent(name))
    print("  \(name)  \(data.count) bytes")
}

print("app icon")
for (size, scale, name) in [
    (16, 1, "icon_16x16.png"), (16, 2, "icon_16x16@2x.png"),
    (32, 1, "icon_32x32.png"), (32, 2, "icon_32x32@2x.png"),
    (128, 1, "icon_128x128.png"), (128, 2, "icon_128x128@2x.png"),
    (256, 1, "icon_256x256.png"), (256, 2, "icon_256x256@2x.png"),
    (512, 1, "icon_512x512.png"), (512, 2, "AppIcon-1024.png"),
] {
    write(render(size: size, rounded: true, tint: nil, scale: scale), name)
}

print("menu bar template")
for (size, scale, name) in [(18, 1, "MenuBarIcon.png"), (18, 2, "MenuBarIcon@2x.png"),
                            (18, 3, "MenuBarIcon@3x.png")] {
    write(render(size: size, rounded: false, tint: .black, scale: scale), name)
}

print("brand")
write(render(size: 512, rounded: true, tint: nil, scale: 2), "clip-icon-1024.png")
