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
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "MapData/Germany")
        let level = root.appendingPathComponent("z0")
        let packedLand = try Data(contentsOf: level.appendingPathComponent("0_0.land.z"))
        let packedElevation = try Data(contentsOf: level.appendingPathComponent("0_0.elev.z"))
        guard
            let land = ZlibDecoder.decode(packedLand, expectedSize: 512 * 512),
            let elevation = ZlibDecoder.decode(packedElevation, expectedSize: 514 * 514 * 2)
        else { throw VerificationError.decompression }

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

        let landTexture = try texture(
            device: device,
            format: .r8Uint,
            width: 512,
            height: 512,
            bytes: land,
            bytesPerRow: 512
        )
        let elevationTexture = try texture(
            device: device,
            format: .r16Unorm,
            width: 514,
            height: 514,
            bytes: elevation,
            bytesPerRow: 514 * 2
        )

        let outputWidth = 468
        let outputHeight = 564
        let outputDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: outputWidth,
            height: outputHeight,
            mipmapped: false
        )
        outputDescriptor.usage = [.renderTarget]
        outputDescriptor.storageMode = .shared
        guard let output = device.makeTexture(descriptor: outputDescriptor) else { throw VerificationError.metal }

        let uvMax = SIMD2<Float>(234.0 / 512.0, 282.0 / 512.0)
        let vertices = [
            PreviewVertex(position: [-1, 1], uv: [0, 0]),
            PreviewVertex(position: [-1, -1], uv: [0, uvMax.y]),
            PreviewVertex(position: [1, -1], uv: [uvMax.x, uvMax.y]),
            PreviewVertex(position: [-1, 1], uv: [0, 0]),
            PreviewVertex(position: [1, -1], uv: [uvMax.x, uvMax.y]),
            PreviewVertex(position: [1, 1], uv: [uvMax.x, 0]),
        ]
        let palette = [
            "#000000", "#FF1111", "#FFD700", "#228B22",
            "#006400", "#98FB98", "#32CD32", "#0066CC",
        ].map { RGBAColor(hex: $0).vector }
        var relief = PreviewRelief()

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
        vertices.withUnsafeBytes { encoder.setVertexBytes($0.baseAddress!, length: $0.count, index: 0) }
        palette.withUnsafeBytes { encoder.setFragmentBytes($0.baseAddress!, length: $0.count, index: 0) }
        encoder.setFragmentBytes(&relief, length: MemoryLayout<PreviewRelief>.stride, index: 1)
        encoder.setFragmentTexture(landTexture, index: 0)
        encoder.setFragmentTexture(elevationTexture, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertices.count)
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
        let preview = URL(fileURLWithPath: "/tmp/topo-explorer-preview.png")
        try writePNG(pixels, width: outputWidth, height: outputHeight, to: preview)
        print("Kacheldekompression, Metal-Shader und Vorschaubild OK: \(preview.path)")
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
                shouldInterpolate: true,
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
}
