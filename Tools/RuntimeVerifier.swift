import CoreGraphics
import Foundation
import ImageIO
import Metal
import UniformTypeIdentifiers

private struct PreviewVertex {
    var position: SIMD2<Float>
    var uv: SIMD2<Float>
}

private struct PreviewRelief {
    var opacity: Float = 0.5
    var exaggeration: Float = 45
    var contrast: Float = 2.5
    var ambient: Float = 0.08
    var azimuth: Float = 5.4977871438
    var padding0: Float = 0
    var padding1: Float = 0
    var padding2: Float = 0
}

private struct PreviewComparison {
    var mode: UInt32 = 0
    var splitPosition: Float = 0.5
    var drawableWidth: Float = 960
    var padding: Float = 0
}

private struct PreviewVectorUniforms {
    var tile: SIMD4<Float>
    var viewport: SIMD4<Float>
    var layer: UInt32
    var pass: UInt32
    var zoom: UInt32
    var padding: UInt32 = 0
}

@main
struct RuntimeVerifier {
    private static let outputWidth = 960
    private static let outputHeight = 640

    @MainActor
    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        let root = URL(fileURLWithPath: arguments.first ?? "MapData/Germany", isDirectory: true)
        let outputDirectory = URL(
            fileURLWithPath: arguments.dropFirst().first ?? "References/Generated",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let manifestData = try Data(contentsOf: root.appendingPathComponent("manifest.json"))
        let manifest = try JSONDecoder().decode(MapManifest.self, from: manifestData).validated()
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else {
            throw VerificationError.metalDevice
        }
        let library = try device.makeLibrary(source: MetalShader.source, options: nil)
        guard
            let vertexFunction = library.makeFunction(name: "tileVertex"),
            let fragmentFunction = library.makeFunction(name: "tileFragment")
        else { throw VerificationError.metalShader }

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        let pipeline = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        let palette = manifest.classes.map { RGBAColor(hex: $0.defaultColor).vector }

        for reference in MapReference.all {
            let outputURL = outputDirectory.appendingPathComponent("\(reference.id).png")
            try render(
                reference,
                root: root,
                manifest: manifest,
                device: device,
                queue: queue,
                pipeline: pipeline,
                palette: palette,
                comparisonMode: 0,
                outputURL: outputURL
            )
            print("Referenz \(reference.name): \(outputURL.path)")
        }
        if let harz = MapReference.all.first(where: { $0.id == "harz" }), manifest.hasLandcover2020 {
            let comparisonURL = outputDirectory.appendingPathComponent("vergleich-2015-2020.png")
            try render(
                harz, root: root, manifest: manifest, device: device, queue: queue,
                pipeline: pipeline, palette: palette, comparisonMode: 2,
                outputURL: comparisonURL
            )
            print("Zeitvergleich: \(comparisonURL.path)")
        }
        try verifyVectors(root: root, device: device, queue: queue, library: library)
        try verifyExport()
        try verifyHighResolutionExport(root: root, manifest: manifest)
        print("Kacheldekompression, Metal-Shader und Referenzbilder OK.")
    }

    private static func verifyVectors(
        root: URL,
        device: MTLDevice,
        queue: MTLCommandQueue,
        library: MTLLibrary
    ) throws {
        let vectors = root.appendingPathComponent("Vectors", isDirectory: true)
        guard let enumerator = FileManager.default.enumerator(
            at: vectors,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { throw VerificationError.vector }
        let tileURLs = enumerator.compactMap { $0 as? URL }
            .filter { $0.lastPathComponent.hasSuffix(".vector.z") }
            .sorted { $0.path < $1.path }
        guard !tileURLs.isEmpty else { throw VerificationError.vector }
        var lineCount = 0
        var segmentCount = 0
        var placeCount = 0
        var sample: (
            buffer: VectorSegmentBuffer,
            layer: VectorLayer,
            extent: Int,
            minimumZoom: Int
        )?
        for url in tileURLs.prefix(12) {
            guard
                let packed = try? Data(contentsOf: url),
                let tile = VectorTileDecoder.decode(packed, device: device)
            else { throw VerificationError.vector }
            lineCount += tile.lineCount
            segmentCount += tile.segmentCount
            placeCount += tile.places.count
            if sample == nil {
                for layer in VectorLayer.allCases {
                    guard let layerSegments = tile.layers[layer] else { continue }
                    for group in layerSegments.zoomLevels {
                        if let buffer = group.withCasing ?? group.plain, buffer.buffer != nil {
                            sample = (buffer, layer, tile.extent, group.minimumZoom)
                            break
                        }
                    }
                    if sample != nil { break }
                }
            }
        }
        guard lineCount > 0, segmentCount > 0, let sample else {
            throw VerificationError.vector
        }

        let indexURL = vectors.appendingPathComponent("places-index.json.z")
        guard
            let packedIndex = try? Data(contentsOf: indexURL),
            let indexData = ZlibDecoder.decodeUnknown(packedIndex),
            let rootObject = try? JSONSerialization.jsonObject(with: indexData) as? [String: Any],
            let places = rootObject["places"] as? [[Any]]
        else { throw VerificationError.vector }
        let names = Set(places.compactMap { $0.first as? String })
        guard names.contains("Hannover"), names.contains("Braunschweig") else {
            throw VerificationError.vector
        }
        try verifyVectorDraw(sample, device: device, queue: queue, library: library)
        print(
            "Swift-Vektorbuffer und Ortssuche OK: \(lineCount) Linien, "
                + "\(segmentCount) Segmente, \(placeCount) Orte in Stichprobe"
        )
    }

    private static func verifyVectorDraw(
        _ sample: (
            buffer: VectorSegmentBuffer,
            layer: VectorLayer,
            extent: Int,
            minimumZoom: Int
        ),
        device: MTLDevice,
        queue: MTLCommandQueue,
        library: MTLLibrary
    ) throws {
        guard
            let vertex = library.makeFunction(name: "vectorVertex"),
            let fragment = library.makeFunction(name: "vectorFragment"),
            let segmentBuffer = sample.buffer.buffer
        else { throw VerificationError.vector }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        let pipeline = try device.makeRenderPipelineState(descriptor: descriptor)

        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm, width: 128, height: 128, mipmapped: false
        )
        textureDescriptor.usage = .renderTarget
        textureDescriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: textureDescriptor) else {
            throw VerificationError.vector
        }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        guard
            let command = queue.makeCommandBuffer(),
            let encoder = command.makeRenderCommandEncoder(descriptor: pass)
        else { throw VerificationError.vector }
        var uniforms = PreviewVectorUniforms(
            tile: SIMD4(0, 0, 128, Float(sample.extent)),
            viewport: SIMD4(128, 128, 0, 0),
            layer: UInt32(sample.layer.rawValue),
            pass: 1,
            zoom: UInt32(sample.minimumZoom)
        )
        encoder.setRenderPipelineState(pipeline)
        encoder.setScissorRect(MTLScissorRect(x: 0, y: 0, width: 128, height: 128))
        encoder.setVertexBuffer(segmentBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(
            &uniforms,
            length: MemoryLayout<PreviewVectorUniforms>.stride,
            index: 1
        )
        encoder.drawPrimitives(
            type: .triangle,
            vertexStart: 0,
            vertexCount: 6,
            instanceCount: min(sample.buffer.count, 4_096)
        )
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed else { throw VerificationError.vector }
    }

    private static func verifyExport() throws {
        var pixels = Data(count: 96 * 64 * 4)
        pixels.withUnsafeMutableBytes { raw in
            let values = raw.bindMemory(to: UInt8.self)
            for index in stride(from: 0, to: values.count, by: 4) {
                values[index] = 55
                values[index + 1] = 115
                values[index + 2] = 42
                values[index + 3] = 255
            }
        }
        let style = MapStyleDocument(
            id: "verification",
            name: "Prüfstil",
            colors: [
                "#101612", "#C84C55", "#C9A96E", "#B7CEA8",
                "#D6BE78", "#6FAF7A", "#245C3A", "#47785A",
                "#927A55", "#78A96D", "#39779B",
            ].map(RGBAColor.init(hex:)),
            relief: ReliefStyle(
                enabled: true, opacity: 0.5, exaggeration: 45,
                contrast: 2.5, ambientLight: 0.08, sunAzimuthDegrees: 315
            )
        )
        let url = URL(fileURLWithPath: "/tmp/topo-explorer-export.png")
        let request = MapExportRequest(
            id: 1, url: url, scale: 2, includeScaleBar: true,
            snapshot: ViewportSnapshot(
                centerX: 4_363_816, centerY: 3_182_365,
                metersPerPoint: 100, visibleWidthMeters: 9_600,
                visibleHeightMeters: 6_400
            ),
            labels: [
                MapLabel(
                    id: "harz", name: "Harz",
                    point: CGPoint(x: 48, y: 32), prominence: 100_000
                )
            ],
            styleDocument: style,
            landcoverMode: .year2015,
            renderStyle: RenderStyle(
                colors: style.colors.map(\.vector),
                reliefOpacity: 0.5, reliefExaggeration: 45,
                reliefContrast: 2.5, ambientLight: 0.08
            ),
            renderLayers: RenderLayers(
                roads: true, railways: true, waterways: true,
                boundaries: true, places: true, geonames: true
            ),
            renderComparison: RenderComparison(mode: 0, splitPosition: 0.5),
            sources: []
        )
        try MapExportWriter.write(pixels: pixels, width: 96, height: 64, request: request)
        guard
            FileManager.default.fileExists(atPath: url.path),
            let source = CGImageSourceCreateWithURL(url as CFURL, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
            image.width == 192, image.height == 128,
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
            let png = properties[kCGImagePropertyPNGDictionary] as? [CFString: Any],
            let description = png[kCGImagePropertyPNGDescription] as? String,
            description.contains("DLR/EOC"),
            description.contains("mundialis"),
            description.contains("BKG 2026"),
            description.contains("openstreetmap.org/copyright"),
            FileManager.default.fileExists(
                atPath: url.deletingPathExtension().appendingPathExtension("topostyle").path
            )
        else { throw VerificationError.image }
        print("PNG-, Maßstabs- und Stil-Export OK: \(url.path)")
    }

    @MainActor
    private static func verifyHighResolutionExport(
        root: URL,
        manifest: MapManifest
    ) throws {
        let view = MapCanvasView(frame: CGRect(x: 0, y: 0, width: 320, height: 240))
        let viewport = ViewportController()
        guard let renderer = MapRenderer(view: view, manifest: manifest, viewport: viewport) else {
            throw VerificationError.metalRenderer
        }
        let colors = manifest.classes.map { RGBAColor(hex: $0.defaultColor) }
        let renderStyle = RenderStyle(
            colors: colors.map(\.vector),
            reliefOpacity: 0.5, reliefExaggeration: 45,
            reliefContrast: 2.5, ambientLight: 0.08
        )
        let renderLayers = RenderLayers(
            roads: true, railways: true, waterways: true,
            boundaries: true, places: true, geonames: true
        )
        let renderComparison = RenderComparison(mode: 2, splitPosition: 0.42)
        renderer.update(
            manifest: manifest,
            dataDirectory: root,
            style: renderStyle,
            layers: renderLayers,
            comparison: renderComparison,
            fitToken: 0,
            navigationToken: 0,
            target: nil
        )
        guard let harz = MapReference.all.first(where: { $0.id == "harz" }) else {
            throw VerificationError.image
        }
        let output = URL(fileURLWithPath: "/tmp/topo-explorer-export-2x.png")
        let document = MapStyleDocument(
            id: "verification-2x",
            name: "2×-Prüfstil",
            colors: colors,
            relief: ReliefStyle(
                enabled: true, opacity: 0.5, exaggeration: 45,
                contrast: 2.5, ambientLight: 0.08, sunAzimuthDegrees: 315
            )
        )
        let request = MapExportRequest(
            id: 2,
            url: output,
            scale: 2,
            includeScaleBar: true,
            snapshot: ViewportSnapshot(
                centerX: harz.centerX,
                centerY: harz.centerY,
                metersPerPoint: harz.metersPerPoint,
                visibleWidthMeters: harz.metersPerPoint * 320,
                visibleHeightMeters: harz.metersPerPoint * 240
            ),
            labels: [
                MapLabel(
                    id: "harz-export", name: "Harz",
                    point: CGPoint(x: 160, y: 120), prominence: 100_000
                )
            ],
            styleDocument: document,
            landcoverMode: .comparison,
            renderStyle: renderStyle,
            renderLayers: renderLayers,
            renderComparison: renderComparison,
            sources: manifest.sources ?? []
        )

        var outcome: Result<URL, Error>?
        renderer.export(request) { outcome = $0 }
        let deadline = Date().addingTimeInterval(45)
        while outcome == nil, Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        guard let outcome else { throw VerificationError.image }
        _ = try outcome.get()
        guard
            let source = CGImageSourceCreateWithURL(output as CFURL, nil),
            let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
            image.width == 640,
            image.height == 480
        else { throw VerificationError.image }
        print("Echter Metal-2×-Export mit feineren Kacheln OK: \(output.path)")
        _ = renderer
    }

    private static func render(
        _ reference: MapReference,
        root: URL,
        manifest: MapManifest,
        device: MTLDevice,
        queue: MTLCommandQueue,
        pipeline: MTLRenderPipelineState,
        palette: [SIMD4<Float>],
        comparisonMode: UInt32,
        outputURL: URL
    ) throws {
        let level = manifest.levels.min {
            abs(log2($0.resolution / reference.metersPerPoint))
                < abs(log2($1.resolution / reference.metersPerPoint))
        } ?? manifest.levels[0]
        let pixelsPerMeter = 1 / reference.metersPerPoint
        let halfWidth = Double(outputWidth) / (2 * pixelsPerMeter)
        let halfHeight = Double(outputHeight) / (2 * pixelsPerMeter)
        let tileMeters = Double(manifest.tileSize) * level.resolution
        let minX = max(0, Int(floor((reference.centerX - halfWidth - manifest.left) / tileMeters)))
        let maxX = min(level.tilesX - 1, Int(floor((reference.centerX + halfWidth - manifest.left) / tileMeters)))
        let minY = max(0, Int(floor((manifest.top - reference.centerY - halfHeight) / tileMeters)))
        let maxY = min(level.tilesY - 1, Int(floor((manifest.top - reference.centerY + halfHeight) / tileMeters)))
        guard minX <= maxX, minY <= maxY else { throw VerificationError.outsideMap }

        let outputDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: outputWidth,
            height: outputHeight,
            mipmapped: false
        )
        outputDescriptor.usage = .renderTarget
        outputDescriptor.storageMode = .shared
        guard let output = device.makeTexture(descriptor: outputDescriptor) else {
            throw VerificationError.metalOutput
        }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = output
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        guard
            let command = queue.makeCommandBuffer(),
            let encoder = command.makeRenderCommandEncoder(descriptor: pass)
        else { throw VerificationError.metalEncoder }
        encoder.setRenderPipelineState(pipeline)
        palette.withUnsafeBytes { encoder.setFragmentBytes($0.baseAddress!, length: $0.count, index: 0) }
        var relief = PreviewRelief()
        var comparison = PreviewComparison(
            mode: comparisonMode,
            splitPosition: 0.5,
            drawableWidth: Float(outputWidth)
        )
        encoder.setFragmentBytes(&relief, length: MemoryLayout<PreviewRelief>.stride, index: 1)
        encoder.setFragmentBytes(
            &comparison,
            length: MemoryLayout<PreviewComparison>.stride,
            index: 2
        )

        var retainedTextures: [MTLTexture] = []
        let elevationTileSize = manifest.elevationTileSize(at: level)
        let elevationTextureSize = elevationTileSize + 2
        for y in minY...maxY {
            for x in minX...maxX {
                let directory = root.appendingPathComponent("z\(level.z)", isDirectory: true)
                let name = "\(x)_\(y)"
                let packedLand = try Data(
                    contentsOf: directory.appendingPathComponent("\(name).\(manifest.landcoverSuffix)")
                )
                let packedLand2020 = manifest.landcoverProduct == nil
                    ? try? Data(contentsOf: directory.appendingPathComponent("\(name).land2020.z"))
                    : nil
                let packedElevation = try Data(contentsOf: directory.appendingPathComponent("\(name).elev.z"))
                guard
                    let land = ZlibDecoder.decode(
                        packedLand,
                        expectedSize: manifest.tileSize * manifest.tileSize
                    ),
                    let elevation = ZlibDecoder.decode(
                        packedElevation,
                        expectedSize: elevationTextureSize * elevationTextureSize * 2
                    )
                else { throw VerificationError.decompression }
                let land2020 = packedLand2020.flatMap {
                    ZlibDecoder.decode($0, expectedSize: manifest.tileSize * manifest.tileSize)
                } ?? land
                let landTexture = try texture(
                    device: device,
                    format: .r8Uint,
                    width: manifest.tileSize,
                    height: manifest.tileSize,
                    bytes: land,
                    bytesPerRow: manifest.tileSize
                )
                let elevationTexture = try texture(
                    device: device,
                    format: .r16Unorm,
                    width: elevationTextureSize,
                    height: elevationTextureSize,
                    bytes: elevation,
                    bytesPerRow: elevationTextureSize * 2
                )
                let land2020Texture = try texture(
                    device: device,
                    format: .r8Uint,
                    width: manifest.tileSize,
                    height: manifest.tileSize,
                    bytes: land2020,
                    bytesPerRow: manifest.tileSize
                )
                retainedTextures.append(contentsOf: [landTexture, elevationTexture, land2020Texture])

                let left = manifest.left + Double(x) * tileMeters
                let right = left + tileMeters
                let top = manifest.top - Double(y) * tileMeters
                let bottom = top - tileMeters
                func normalizedX(_ world: Double) -> Float {
                    Float((world - reference.centerX) * pixelsPerMeter / (Double(outputWidth) / 2))
                }
                func normalizedY(_ world: Double) -> Float {
                    Float((world - reference.centerY) * pixelsPerMeter / (Double(outputHeight) / 2))
                }
                let x0 = normalizedX(left)
                let x1 = normalizedX(right)
                let y0 = normalizedY(bottom)
                let y1 = normalizedY(top)
                let vertices = [
                    PreviewVertex(position: [x0, y1], uv: [0, 0]),
                    PreviewVertex(position: [x0, y0], uv: [0, 1]),
                    PreviewVertex(position: [x1, y0], uv: [1, 1]),
                    PreviewVertex(position: [x0, y1], uv: [0, 0]),
                    PreviewVertex(position: [x1, y0], uv: [1, 1]),
                    PreviewVertex(position: [x1, y1], uv: [1, 0]),
                ]
                vertices.withUnsafeBytes {
                    encoder.setVertexBytes($0.baseAddress!, length: $0.count, index: 0)
                }
                encoder.setFragmentTexture(landTexture, index: 0)
                encoder.setFragmentTexture(elevationTexture, index: 1)
                encoder.setFragmentTexture(land2020Texture, index: 2)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertices.count)
            }
        }
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed else {
            throw command.error ?? VerificationError.metalCommand
        }

        var pixels = Data(count: outputWidth * outputHeight * 4)
        pixels.withUnsafeMutableBytes {
            output.getBytes(
                $0.baseAddress!,
                bytesPerRow: outputWidth * 4,
                from: MTLRegionMake2D(0, 0, outputWidth, outputHeight),
                mipmapLevel: 0
            )
        }
        try writePNG(pixels, width: outputWidth, height: outputHeight, to: outputURL)
        _ = retainedTextures
    }

    private static func texture(
        device: MTLDevice,
        format: MTLPixelFormat,
        width: Int,
        height: Int,
        bytes: Data,
        bytesPerRow: Int
    ) throws -> MTLTexture {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: format,
            width: width,
            height: height,
            mipmapped: false
        )
        descriptor.usage = .shaderRead
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor) else {
            throw VerificationError.metalTexture
        }
        bytes.withUnsafeBytes {
            texture.replace(
                region: MTLRegionMake2D(0, 0, width, height),
                mipmapLevel: 0,
                withBytes: $0.baseAddress!,
                bytesPerRow: bytesPerRow
            )
        }
        return texture
    }

    private static func writePNG(_ pixels: Data, width: Int, height: Int, to url: URL) throws {
        guard
            let provider = CGDataProvider(data: pixels as CFData),
            let image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
                    .union(.byteOrder32Little),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
            ),
            let destination = CGImageDestinationCreateWithURL(
                url as CFURL,
                UTType.png.identifier as CFString,
                1,
                nil
            )
        else { throw VerificationError.image }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw VerificationError.image }
    }
}

private enum VerificationError: Error {
    case decompression
    case metalDevice
    case metalShader
    case metalRenderer
    case metalOutput
    case metalEncoder
    case metalCommand
    case metalTexture
    case image
    case outsideMap
    case vector
}
