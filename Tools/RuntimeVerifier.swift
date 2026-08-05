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
}

@main
struct RuntimeVerifier {
    private static let outputWidth = 960
    private static let outputHeight = 640

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
        guard
            let device = MTLCreateSystemDefaultDevice(),
            let queue = device.makeCommandQueue(),
            let library = try? device.makeLibrary(source: MetalShader.source, options: nil),
            let vertexFunction = library.makeFunction(name: "tileVertex"),
            let fragmentFunction = library.makeFunction(name: "tileFragment")
        else { throw VerificationError.metal }

        let pipelineDescriptor = MTLRenderPipelineDescriptor()
        pipelineDescriptor.vertexFunction = vertexFunction
        pipelineDescriptor.fragmentFunction = fragmentFunction
        pipelineDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        let pipeline = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
        let palette = [
            "#000000", "#FF1111", "#FFD700", "#228B22",
            "#006400", "#98FB98", "#32CD32", "#0066CC",
        ].map { RGBAColor(hex: $0).vector }

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
                outputURL: outputURL
            )
            print("Referenz \(reference.name): \(outputURL.path)")
        }
        print("Kacheldekompression, Metal-Shader und fünf Referenzbilder OK.")
    }

    private static func render(
        _ reference: MapReference,
        root: URL,
        manifest: MapManifest,
        device: MTLDevice,
        queue: MTLCommandQueue,
        pipeline: MTLRenderPipelineState,
        palette: [SIMD4<Float>],
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
        guard let output = device.makeTexture(descriptor: outputDescriptor) else { throw VerificationError.metal }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = output
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        pass.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        guard
            let command = queue.makeCommandBuffer(),
            let encoder = command.makeRenderCommandEncoder(descriptor: pass)
        else { throw VerificationError.metal }
        encoder.setRenderPipelineState(pipeline)
        palette.withUnsafeBytes { encoder.setFragmentBytes($0.baseAddress!, length: $0.count, index: 0) }
        var relief = PreviewRelief()
        encoder.setFragmentBytes(&relief, length: MemoryLayout<PreviewRelief>.stride, index: 1)

        var retainedTextures: [MTLTexture] = []
        for y in minY...maxY {
            for x in minX...maxX {
                let directory = root.appendingPathComponent("z\(level.z)", isDirectory: true)
                let name = "\(x)_\(y)"
                let packedLand = try Data(contentsOf: directory.appendingPathComponent("\(name).land.z"))
                let packedElevation = try Data(contentsOf: directory.appendingPathComponent("\(name).elev.z"))
                guard
                    let land = ZlibDecoder.decode(
                        packedLand,
                        expectedSize: manifest.tileSize * manifest.tileSize
                    ),
                    let elevation = ZlibDecoder.decode(
                        packedElevation,
                        expectedSize: (manifest.tileSize + 2) * (manifest.tileSize + 2) * 2
                    )
                else { throw VerificationError.decompression }
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
                    width: manifest.tileSize + 2,
                    height: manifest.tileSize + 2,
                    bytes: elevation,
                    bytesPerRow: (manifest.tileSize + 2) * 2
                )
                retainedTextures.append(contentsOf: [landTexture, elevationTexture])

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
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertices.count)
            }
        }
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        guard command.status == .completed else { throw command.error ?? VerificationError.metal }

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
        guard let texture = device.makeTexture(descriptor: descriptor) else { throw VerificationError.metal }
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
    case metal
    case image
    case outsideMap
}
