import AppKit
import CoreText
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct MapExportRequest: Identifiable {
    let id: Int
    let url: URL
    let scale: Int
    let includeScaleBar: Bool
    let snapshot: ViewportSnapshot
    let labels: [MapLabel]
    let styleDocument: MapStyleDocument
    let landcoverMode: LandcoverMode
    let renderStyle: RenderStyle
    let renderLayers: RenderLayers
    let renderComparison: RenderComparison
    let sources: [MapManifest.LandcoverSource]
}

@MainActor
final class MapExportController: ObservableObject {
    @Published var scale = 1
    @Published var includeScaleBar = true
    @Published private(set) var request: MapExportRequest?
    @Published var message: String?
    private var token = 0

    func chooseDestination(
        style: StyleSettings,
        layers: LayerSettings,
        snapshot: ViewportSnapshot?,
        labels: [MapLabel],
        comparison: ComparisonSettings,
        sources: [MapManifest.LandcoverSource] = []
    ) {
        guard let snapshot else {
            message = "Die Karte ist noch nicht vollständig gezeichnet."
            return
        }
        let panel = NSSavePanel()
        panel.title = "Kartenausschnitt exportieren"
        panel.prompt = "PNG exportieren"
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "TopoExplorer-Kartenausschnitt.png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        token &+= 1
        request = MapExportRequest(
            id: token, url: url, scale: min(max(scale, 1), 4),
            includeScaleBar: includeScaleBar, snapshot: snapshot,
            labels: labels,
            styleDocument: style.currentDocumentForExport,
            landcoverMode: comparison.mode,
            renderStyle: style.renderStyle,
            renderLayers: layers.renderLayers,
            renderComparison: comparison.renderComparison,
            sources: sources
        )
        message = "Export läuft …"
    }

    func finish(_ result: Result<URL, Error>) {
        switch result {
        case .success(let url): message = "Exportiert: \(url.lastPathComponent)"
        case .failure(let error): message = error.localizedDescription
        }
    }
}

enum MapExportWriter {
    static func write(
        pixels: Data,
        width: Int,
        height: Int,
        request: MapExportRequest,
        pixelsAreFinalSize: Bool = false
    ) throws {
        guard
            let provider = CGDataProvider(data: pixels as CFData),
            let sourceImage = CGImage(
                width: width, height: height,
                bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
                    .union(.byteOrder32Little),
                provider: provider,
                decode: nil,
                shouldInterpolate: true,
                intent: .defaultIntent
            )
        else { throw MapExportError.image }

        let outputWidth = pixelsAreFinalSize ? width : width * request.scale
        let outputHeight = pixelsAreFinalSize ? height : height * request.scale
        guard
            outputWidth <= 16_384, outputHeight <= 16_384,
            outputWidth > 0, outputHeight > 0,
            outputWidth <= 32_000_000 / outputHeight,
            let context = CGContext(
                data: nil,
                width: outputWidth,
                height: outputHeight,
                bitsPerComponent: 8,
                bytesPerRow: outputWidth * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { throw MapExportError.tooLarge }
        context.interpolationQuality = .high
        context.draw(sourceImage, in: CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight))
        if request.landcoverMode == .comparison {
            drawComparisonDivider(
                in: context,
                width: outputWidth,
                height: outputHeight,
                request: request
            )
        }
        drawLabels(in: context, width: outputWidth, height: outputHeight, request: request)
        drawAttribution(in: context, width: outputWidth, request: request)
        if request.includeScaleBar {
            drawScaleBar(in: context, width: outputWidth, height: outputHeight, request: request)
        }
        guard let image = context.makeImage() else { throw MapExportError.image }

        let encodedStyle = try JSONEncoder().encode(request.styleDocument)
        let styleJSON = String(data: encodedStyle, encoding: .utf8) ?? "{}"
        let landSources = request.sources.map {
            "\($0.name) \($0.year): \($0.role), \($0.license)."
        }.joined(separator: " ")
        let description = "TopoExplorer · Mittelpunkt E \(Int(request.snapshot.centerX)), N \(Int(request.snapshot.centerY)) · "
            + "Landbedeckung \(request.landcoverMode.title) · Stil \(request.styleDocument.name)\n"
            + (landSources.isEmpty
                ? "Land: DLR/EOC 2015, CC BY-NC 4.0; mundialis 2020, DL-DE/BY-2.0. "
                : landSources + " ")
            + "Vektordaten: © OpenStreetMap contributors, ODbL, https://www.openstreetmap.org/copyright. "
            + (request.renderLayers.geonames ? "Geonamen: © BKG 2026, dl-de/by-2.0.\n" : "\n")
            + "TopoStyle: \(styleJSON)"
        guard let destination = CGImageDestinationCreateWithURL(
            request.url as CFURL, UTType.png.identifier as CFString, 1, nil
        ) else { throw MapExportError.image }
        let properties: [CFString: Any] = [
            kCGImagePropertyDPIWidth: 300,
            kCGImagePropertyDPIHeight: 300,
            kCGImagePropertyPNGDictionary: [kCGImagePropertyPNGDescription: description],
        ]
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw MapExportError.write }

        let styleURL = request.url.deletingPathExtension().appendingPathExtension("topostyle")
        // Der Stil steckt immer in den PNG-Metadaten. Neben Powerbox-Zielen
        // wird zusätzlich eine direkt teilbare .topostyle-Datei geschrieben.
        try? MapStyleFile.write(request.styleDocument, to: styleURL)
    }

    private static func drawAttribution(
        in context: CGContext,
        width: Int,
        request: MapExportRequest
    ) {
        let logicalWidth = request.snapshot.visibleWidthMeters / request.snapshot.metersPerPoint
        let pixelScale = max(1, CGFloat(width) / CGFloat(max(logicalWidth, 1)))
        let landText = request.sources.isEmpty
            ? "Land: DLR/EOC 2015 · CC BY-NC 4.0 | mundialis 2020 · DL-DE/BY-2.0"
            : "Land: " + request.sources.prefix(4).map {
                "\($0.name) \($0.year) · \($0.license)"
            }.joined(separator: " | ")
        var texts = [
            "Vektor: © OpenStreetMap contributors · ODbL · https://www.openstreetmap.org/copyright",
            landText,
        ]
        if request.renderLayers.geonames {
            texts.insert("Geonamen: © BKG 2026 · dl-de/by-2.0", at: 1)
        }
        let font = CTFontCreateWithName(
            "Helvetica" as CFString, 9 * pixelScale,
            nil
        )
        let lines = texts.map { text -> CTLine in
            let attributed = CFAttributedStringCreate(
                nil, text as CFString,
                [kCTFontAttributeName: font, kCTForegroundColorAttributeName: CGColor(gray: 1, alpha: 0.92)] as CFDictionary
            )!
            return CTLineCreateWithAttributedString(attributed)
        }
        let widths = lines.map { CGFloat(CTLineGetTypographicBounds($0, nil, nil, nil)) }
        let lineHeight = 12 * pixelScale
        let padding = 5 * pixelScale
        let margin = 14 * pixelScale
        let boxWidth = (widths.max() ?? 0) + padding * 2
        let boxHeight = lineHeight * CGFloat(lines.count) + padding * 2
        let boxX = max(0, CGFloat(width) - boxWidth - margin)
        context.setFillColor(CGColor(gray: 0, alpha: 0.55))
        context.fill(CGRect(x: boxX, y: margin, width: boxWidth, height: boxHeight))
        for (index, line) in lines.enumerated() {
            context.textPosition = CGPoint(
                x: boxX + padding,
                y: margin + padding + CGFloat(index) * lineHeight + 2 * pixelScale
            )
            CTLineDraw(line, context)
        }
    }

    private static func drawComparisonDivider(
        in context: CGContext,
        width: Int,
        height: Int,
        request: MapExportRequest
    ) {
        let logicalWidth = request.snapshot.visibleWidthMeters / request.snapshot.metersPerPoint
        let pixelScale = max(1, CGFloat(width) / CGFloat(max(logicalWidth, 1)))
        let x = CGFloat(width) * CGFloat(request.renderComparison.splitPosition)
        context.saveGState()
        context.setStrokeColor(CGColor(gray: 1, alpha: 0.9))
        context.setShadow(offset: .zero, blur: pixelScale, color: CGColor(gray: 0, alpha: 0.7))
        context.setLineWidth(2 * pixelScale)
        context.move(to: CGPoint(x: x, y: 0))
        context.addLine(to: CGPoint(x: x, y: CGFloat(height)))
        context.strokePath()
        context.restoreGState()
    }

    private static func drawLabels(
        in context: CGContext,
        width: Int,
        height: Int,
        request: MapExportRequest
    ) {
        let viewWidth = request.snapshot.visibleWidthMeters / request.snapshot.metersPerPoint
        let viewHeight = request.snapshot.visibleHeightMeters / request.snapshot.metersPerPoint
        let pixelRatio = CGFloat(width) / CGFloat(max(viewWidth, 1))
        for label in request.labels {
            let size = CGFloat(label.prominence >= 100_000 ? 13 : 11) * pixelRatio
            let font = CTFontCreateWithName("Helvetica-Semibold" as CFString, size, nil)
            let attributed = CFAttributedStringCreate(
                nil,
                label.name as CFString,
                [kCTFontAttributeName: font, kCTForegroundColorAttributeName: CGColor(gray: 1, alpha: 1)] as CFDictionary
            )!
            let line = CTLineCreateWithAttributedString(attributed)
            let bounds = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
            let x = CGFloat(label.point.x) / CGFloat(max(viewWidth, 1)) * CGFloat(width)
            let y = CGFloat(height) - CGFloat(label.point.y) / CGFloat(max(viewHeight, 1)) * CGFloat(height)
            let background = CGRect(
                x: x - bounds.width / 2 - 4 * pixelRatio,
                y: y - bounds.height / 2 - 3 * pixelRatio,
                width: bounds.width + 8 * pixelRatio,
                height: bounds.height + 6 * pixelRatio
            )
            context.setFillColor(CGColor(gray: 0, alpha: 0.45))
            context.fill(background)
            context.textPosition = CGPoint(x: x - bounds.width / 2, y: y - bounds.height / 2)
            CTLineDraw(line, context)
        }
    }

    private static func drawScaleBar(
        in context: CGContext,
        width: Int,
        height: Int,
        request: MapExportRequest
    ) {
        let logicalWidth = request.snapshot.visibleWidthMeters / request.snapshot.metersPerPoint
        let pixelScale = max(1, CGFloat(width) / CGFloat(max(logicalWidth, 1)))
        let target = request.snapshot.visibleWidthMeters * 0.2
        let magnitude = pow(10.0, floor(log10(max(target, 1))))
        let normalized = target / magnitude
        let step = normalized >= 5 ? 5.0 : normalized >= 2 ? 2.0 : 1.0
        let meters = step * magnitude
        let pixelLength = CGFloat(meters / request.snapshot.visibleWidthMeters) * CGFloat(width)
        let unitText = meters >= 1_000
            ? String(format: "%.0f km", meters / 1_000)
            : String(format: "%.0f m", meters)
        let margin = 32 * pixelScale
        let lineY = margin + 18 * pixelScale
        let startX = margin

        context.saveGState()
        context.setFillColor(CGColor(gray: 0, alpha: 0.58))
        context.fill(
            CGRect(
                x: margin * 0.55, y: margin * 0.45,
                width: pixelLength + margin * 0.9,
                height: 58 * pixelScale
            )
        )
        context.setStrokeColor(CGColor(gray: 1, alpha: 1))
        context.setLineWidth(3 * pixelScale)
        context.move(to: CGPoint(x: startX, y: lineY))
        context.addLine(to: CGPoint(x: startX + pixelLength, y: lineY))
        context.move(to: CGPoint(x: startX, y: lineY - 6 * pixelScale))
        context.addLine(to: CGPoint(x: startX, y: lineY + 6 * pixelScale))
        context.move(to: CGPoint(x: startX + pixelLength, y: lineY - 6 * pixelScale))
        context.addLine(to: CGPoint(x: startX + pixelLength, y: lineY + 6 * pixelScale))
        context.strokePath()

        let font = CTFontCreateWithName(
            "Helvetica-Semibold" as CFString,
            13 * pixelScale,
            nil
        )
        let attributed = CFAttributedStringCreate(
            nil,
            unitText as CFString,
            [kCTFontAttributeName: font, kCTForegroundColorAttributeName: CGColor(gray: 1, alpha: 1)] as CFDictionary
        )!
        let textLine = CTLineCreateWithAttributedString(attributed)
        context.textPosition = CGPoint(x: startX, y: lineY + 8 * pixelScale)
        CTLineDraw(textLine, context)
        context.restoreGState()
    }
}

private enum MapExportError: LocalizedError {
    case image
    case write
    case tooLarge

    var errorDescription: String? {
        switch self {
        case .image: "Das Kartenbild konnte nicht erzeugt werden."
        case .write: "Die PNG-Datei konnte nicht geschrieben werden."
        case .tooLarge: "Der Export überschreitet 16.384 Pixel Kantenlänge oder 32 Megapixel."
        }
    }
}
