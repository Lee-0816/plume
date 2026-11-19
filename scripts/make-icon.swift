// Renders the Plume app icon into an .iconset folder.
// Usage: swift scripts/make-icon.swift <output.iconset>
import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon.iconset")
try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func render(size: Int) -> Data {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let ctx = NSGraphicsContext.current!.cgContext
    ctx.scaleBy(x: s / 1024, y: s / 1024)

    // Body following the macOS icon grid (824pt square inside 1024 canvas).
    let body = CGRect(x: 100, y: 100, width: 824, height: 824)
    let path = CGPath(roundedRect: body, cornerWidth: 186, cornerHeight: 186, transform: nil)

    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -10), blur: 28, color: NSColor(white: 0, alpha: 0.28).cgColor)
    ctx.addPath(path)
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(path)
    ctx.clip()
    let colors = [
        NSColor(srgbRed: 0.42, green: 0.47, blue: 1.00, alpha: 1).cgColor,
        NSColor(srgbRed: 0.24, green: 0.20, blue: 0.72, alpha: 1).cgColor,
    ] as CFArray
    let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
    ctx.drawLinearGradient(gradient, start: CGPoint(x: 200, y: 924), end: CGPoint(x: 824, y: 100), options: [])

    // Soft highlight across the top.
    let shine = [NSColor(white: 1, alpha: 0.18).cgColor, NSColor(white: 1, alpha: 0).cgColor] as CFArray
    let shineGradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: shine, locations: [0, 1])!
    ctx.drawLinearGradient(shineGradient, start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 560), options: [])
    ctx.restoreGState()

    // White paper card.
    let card = CGRect(x: 262, y: 228, width: 500, height: 584)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 36, color: NSColor(white: 0, alpha: 0.30).cgColor)
    ctx.addPath(CGPath(roundedRect: card, cornerWidth: 44, cornerHeight: 44, transform: nil))
    ctx.setFillColor(NSColor(white: 0.995, alpha: 1).cgColor)
    ctx.fillPath()
    ctx.restoreGState()

    // Text lines on the card.
    let ink = NSColor(srgbRed: 0.30, green: 0.30, blue: 0.80, alpha: 1)
    ctx.setFillColor(ink.withAlphaComponent(0.20).cgColor)
    for (i, width) in [300.0, 360.0, 250.0].enumerated() {
        let y = 330.0 + Double(i) * 62
        ctx.addPath(CGPath(roundedRect: CGRect(x: 322, y: y, width: width, height: 26), cornerWidth: 13, cornerHeight: 13, transform: nil))
        ctx.fillPath()
    }

    // "M↓" mark.
    let base = NSFont.systemFont(ofSize: 190, weight: .heavy)
    let font = NSFont(descriptor: base.fontDescriptor.withDesign(.rounded) ?? base.fontDescriptor, size: 190) ?? base
    let text = NSAttributedString(string: "M↓", attributes: [.font: font, .foregroundColor: ink])
    let textSize = text.size()
    text.draw(at: NSPoint(x: 512 - textSize.width / 2, y: 560))

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let sizes: [(String, Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]
for (name, size) in sizes {
    try! render(size: size).write(to: output.appendingPathComponent("\(name).png"))
}
print("Wrote \(sizes.count) images to \(output.path)")
