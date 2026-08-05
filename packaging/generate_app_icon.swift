import AppKit
import Foundation

private let canvas: CGFloat = 1024
private let outputDirectory = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "app/Assets.xcassets/AppIcon.appiconset")
private let icnsOutput = CommandLine.arguments.dropFirst(2).first.map(URL.init(fileURLWithPath:))

private struct IconVariant {
    let filename: String
    let points: Int
    let pixels: Int
}

private let variants = [
    IconVariant(filename: "icon_16x16.png", points: 16, pixels: 16),
    IconVariant(filename: "icon_16x16@2x.png", points: 16, pixels: 32),
    IconVariant(filename: "icon_32x32.png", points: 32, pixels: 32),
    IconVariant(filename: "icon_32x32@2x.png", points: 32, pixels: 64),
    IconVariant(filename: "icon_128x128.png", points: 128, pixels: 128),
    IconVariant(filename: "icon_128x128@2x.png", points: 128, pixels: 256),
    IconVariant(filename: "icon_256x256.png", points: 256, pixels: 256),
    IconVariant(filename: "icon_256x256@2x.png", points: 256, pixels: 512),
    IconVariant(filename: "icon_512x512.png", points: 512, pixels: 512),
    IconVariant(filename: "icon_512x512@2x.png", points: 512, pixels: 1024),
]

private func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: red / 255, green: green / 255, blue: blue / 255, alpha: alpha)
}

private func contour(center: CGPoint, radiusX: CGFloat, radiusY: CGFloat, phase: CGFloat) -> NSBezierPath {
    let path = NSBezierPath()
    let points = 160
    for index in 0...points {
        let angle = CGFloat(index) / CGFloat(points) * .pi * 2
        let ripple = 1 + 0.055 * sin(angle * 3 + phase) + 0.03 * cos(angle * 7 - phase)
        let point = CGPoint(
            x: center.x + cos(angle) * radiusX * ripple,
            y: center.y + sin(angle) * radiusY * ripple
        )
        index == 0 ? path.move(to: point) : path.line(to: point)
    }
    path.close()
    return path
}

private func drawIcon(in context: CGContext) {
    context.setAllowsAntialiasing(true)
    context.setShouldAntialias(true)

    let tile = NSBezierPath(roundedRect: NSRect(x: 70, y: 70, width: 884, height: 884), xRadius: 196, yRadius: 196)
    let shadow = NSShadow()
    shadow.shadowColor = color(1, 17, 14, 0.52)
    shadow.shadowBlurRadius = 45
    shadow.shadowOffset = NSSize(width: 0, height: -18)
    NSGraphicsContext.saveGraphicsState()
    shadow.set()
    color(8, 31, 26).setFill()
    tile.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGraphicsContext.saveGraphicsState()
    tile.addClip()
    NSGradient(colors: [color(8, 40, 34), color(24, 92, 65), color(58, 126, 78)])!
        .draw(in: NSRect(x: 70, y: 70, width: 884, height: 884), angle: 68)

    let highland = NSBezierPath()
    highland.move(to: CGPoint(x: 70, y: 70))
    highland.line(to: CGPoint(x: 70, y: 518))
    highland.curve(to: CGPoint(x: 420, y: 392), controlPoint1: CGPoint(x: 184, y: 594), controlPoint2: CGPoint(x: 312, y: 352))
    highland.curve(to: CGPoint(x: 954, y: 326), controlPoint1: CGPoint(x: 580, y: 454), controlPoint2: CGPoint(x: 760, y: 240))
    highland.line(to: CGPoint(x: 954, y: 70))
    highland.close()
    NSGradient(colors: [color(7, 50, 37, 0.85), color(17, 73, 48, 0.18)])!
        .draw(in: highland, angle: 74)

    let plain = NSBezierPath()
    plain.move(to: CGPoint(x: 70, y: 690))
    plain.curve(to: CGPoint(x: 954, y: 610), controlPoint1: CGPoint(x: 340, y: 780), controlPoint2: CGPoint(x: 710, y: 518))
    plain.line(to: CGPoint(x: 954, y: 954))
    plain.line(to: CGPoint(x: 70, y: 954))
    plain.close()
    color(111, 171, 101, 0.20).setFill()
    plain.fill()

    for index in 0..<8 {
        let path = contour(
            center: CGPoint(x: 430, y: 434),
            radiusX: 108 + CGFloat(index) * 49,
            radiusY: 74 + CGFloat(index) * 32,
            phase: CGFloat(index) * 0.48
        )
        color(186, 242, 190, index.isMultiple(of: 2) ? 0.46 : 0.27).setStroke()
        path.lineWidth = index.isMultiple(of: 2) ? 5.5 : 3.2
        path.stroke()
    }

    for index in 0..<5 {
        let path = contour(
            center: CGPoint(x: 734, y: 750),
            radiusX: 82 + CGFloat(index) * 43,
            radiusY: 60 + CGFloat(index) * 34,
            phase: 1.4 + CGFloat(index) * 0.55
        )
        color(184, 239, 180, 0.28).setStroke()
        path.lineWidth = 3.5
        path.stroke()
    }

    let river = NSBezierPath()
    river.move(to: CGPoint(x: 188, y: 954))
    river.curve(to: CGPoint(x: 428, y: 650), controlPoint1: CGPoint(x: 192, y: 820), controlPoint2: CGPoint(x: 392, y: 786))
    river.curve(to: CGPoint(x: 638, y: 420), controlPoint1: CGPoint(x: 458, y: 540), controlPoint2: CGPoint(x: 616, y: 568))
    river.curve(to: CGPoint(x: 866, y: 70), controlPoint1: CGPoint(x: 658, y: 280), controlPoint2: CGPoint(x: 820, y: 226))
    river.lineCapStyle = .round
    color(82, 218, 221, 0.94).setStroke()
    river.lineWidth = 19
    river.stroke()
    color(204, 255, 250, 0.56).setStroke()
    river.lineWidth = 5
    river.stroke()

    let road = NSBezierPath()
    road.move(to: CGPoint(x: 70, y: 584))
    road.curve(to: CGPoint(x: 420, y: 650), controlPoint1: CGPoint(x: 210, y: 560), controlPoint2: CGPoint(x: 300, y: 690))
    road.curve(to: CGPoint(x: 954, y: 792), controlPoint1: CGPoint(x: 610, y: 580), controlPoint2: CGPoint(x: 742, y: 842))
    road.lineCapStyle = .round
    color(251, 114, 112, 0.88).setStroke()
    road.lineWidth = 11
    road.stroke()

    let peak = NSBezierPath()
    peak.move(to: CGPoint(x: 390, y: 276))
    peak.line(to: CGPoint(x: 512, y: 536))
    peak.line(to: CGPoint(x: 634, y: 276))
    peak.line(to: CGPoint(x: 574, y: 326))
    peak.line(to: CGPoint(x: 512, y: 422))
    peak.line(to: CGPoint(x: 454, y: 326))
    peak.close()
    color(224, 255, 225, 0.96).setFill()
    peak.fill()

    NSGraphicsContext.restoreGraphicsState()

    color(218, 255, 224, 0.38).setStroke()
    tile.lineWidth = 5
    tile.stroke()
}

try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

for variant in variants {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: variant.pixels,
        pixelsHigh: variant.pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bitmapFormat: [.alphaFirst],
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        throw CocoaError(.fileWriteUnknown)
    }

    bitmap.size = NSSize(width: variant.points, height: variant.points)
    guard let graphics = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw CocoaError(.fileWriteUnknown)
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = graphics
    graphics.cgContext.scaleBy(x: CGFloat(variant.points) / canvas, y: CGFloat(variant.points) / canvas)
    drawIcon(in: graphics.cgContext)
    graphics.flushGraphics()
    NSGraphicsContext.restoreGraphicsState()

    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    try data.write(to: outputDirectory.appendingPathComponent(variant.filename), options: .atomic)
}

if let icnsOutput {
    let chunks = [
        ("icp4", "icon_16x16.png"),
        ("ic11", "icon_16x16@2x.png"),
        ("icp5", "icon_32x32.png"),
        ("ic12", "icon_32x32@2x.png"),
        ("ic07", "icon_128x128.png"),
        ("ic13", "icon_128x128@2x.png"),
        ("ic08", "icon_256x256.png"),
        ("ic14", "icon_256x256@2x.png"),
        ("ic09", "icon_512x512.png"),
        ("ic10", "icon_512x512@2x.png"),
    ]
    let payloads = try chunks.map { type, filename in
        (type, try Data(contentsOf: outputDirectory.appendingPathComponent(filename)))
    }
    let totalSize = 8 + payloads.reduce(0) { $0 + 8 + $1.1.count }
    var file = Data("icns".utf8)
    var fileSize = UInt32(totalSize).bigEndian
    file.append(Data(bytes: &fileSize, count: MemoryLayout<UInt32>.size))
    for (type, payload) in payloads {
        file.append(Data(type.utf8))
        var chunkSize = UInt32(payload.count + 8).bigEndian
        file.append(Data(bytes: &chunkSize, count: MemoryLayout<UInt32>.size))
        file.append(payload)
    }
    try file.write(to: icnsOutput, options: .atomic)
}

print("App-Icon erzeugt: \(outputDirectory.path)")
