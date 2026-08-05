import MetalKit

private struct TileVertex {
    var position: SIMD2<Float>
    var uv: SIMD2<Float>
}

private struct ReliefUniforms {
    var opacity: Float
    var exaggeration: Float
    var contrast: Float
    var ambient: Float
}

final class MapRenderer: NSObject, MTKViewDelegate {
    private weak var view: MapCanvasView?
    private weak var viewport: ViewportController?
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private var tileCache: TileCache

    private var manifest: MapManifest?
    private var dataDirectory: URL?
    private var style = RenderStyle(
        colors: Array(repeating: SIMD4<Float>(0, 0, 0, 1), count: 8),
        reliefOpacity: 0.5,
        reliefExaggeration: 45,
        reliefContrast: 2.5,
        ambientLight: 0.08
    )
    private var centerX = 0.0
    private var centerY = 0.0
    private var pixelsPerMeter = 0.001
    private var needsFit = true
    private var lastFitToken = -1
    private var lastReferenceToken = -1
    private var pendingReference: MapReference?

    init?(view: MapCanvasView, manifest: MapManifest, viewport: ViewportController) {
        guard
            let device = MTLCreateSystemDefaultDevice(),
            let commandQueue = device.makeCommandQueue(),
            let library = try? device.makeLibrary(source: MetalShader.source, options: nil),
            let vertex = library.makeFunction(name: "tileVertex"),
            let fragment = library.makeFunction(name: "tileFragment")
        else { return nil }

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.label = "TopoExplorer tile pipeline"
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }

        self.view = view
        self.viewport = viewport
        self.commandQueue = commandQueue
        self.pipeline = pipeline
        tileCache = TileCache(device: device, tileSize: manifest.tileSize, elevationBorder: manifest.elevationBorder)
        self.manifest = manifest
        super.init()

        view.device = device
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColorMake(0, 0, 0, 1)
        view.framebufferOnly = true
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.delegate = self
        view.mapRenderer = self
    }

    func update(
        manifest newManifest: MapManifest,
        dataDirectory newDirectory: URL,
        style newStyle: RenderStyle,
        fitToken: Int,
        referenceToken: Int,
        reference: MapReference?
    ) {
        let dataChanged = manifest != newManifest || dataDirectory?.standardizedFileURL != newDirectory.standardizedFileURL
        if dataChanged {
            manifest = newManifest
            dataDirectory = newDirectory
            tileCache = TileCache(
                device: commandQueue.device,
                tileSize: newManifest.tileSize,
                elevationBorder: newManifest.elevationBorder
            )
            needsFit = true
        }
        style = newStyle
        if let color = newStyle.colors.first {
            view?.clearColor = MTLClearColorMake(Double(color.x), Double(color.y), Double(color.z), 1)
        }
        if fitToken != lastFitToken {
            lastFitToken = fitToken
            needsFit = true
            pendingReference = nil
        }
        if referenceToken != lastReferenceToken {
            lastReferenceToken = referenceToken
            pendingReference = reference
            needsFit = false
        }
        requestDraw()
    }

    func draw(in view: MTKView) {
        guard
            let manifest,
            let dataDirectory,
            let renderPass = view.currentRenderPassDescriptor,
            let drawable = view.currentDrawable,
            view.bounds.width > 1,
            view.bounds.height > 1
        else { return }

        if let reference = pendingReference {
            focus(reference)
            pendingReference = nil
        } else if needsFit {
            fit(manifest, in: view.bounds.size)
            needsFit = false
        }

        guard
            let commandBuffer = commandQueue.makeCommandBuffer(),
            let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPass)
        else { return }

        encoder.label = "Visible Germany tiles"
        encoder.setRenderPipelineState(pipeline)

        let palette = style.colors
        palette.withUnsafeBytes { bytes in
            if let address = bytes.baseAddress {
                encoder.setFragmentBytes(address, length: bytes.count, index: 0)
            }
        }
        var relief = ReliefUniforms(
            opacity: style.reliefOpacity,
            exaggeration: style.reliefExaggeration,
            contrast: style.reliefContrast,
            ambient: style.ambientLight
        )
        encoder.setFragmentBytes(&relief, length: MemoryLayout<ReliefUniforms>.stride, index: 1)

        let level = bestLevel(in: manifest)
        let keys = visibleTiles(level: level, manifest: manifest, viewSize: view.bounds.size)
        for key in keys {
            guard let textures = tileCache[key] else {
                tileCache.request(key, from: dataDirectory) { [weak self] in self?.requestDraw() }
                continue
            }
            let vertices = vertices(for: key, level: level, manifest: manifest, viewSize: view.bounds.size)
            vertices.withUnsafeBytes { bytes in
                if let address = bytes.baseAddress {
                    encoder.setVertexBytes(address, length: bytes.count, index: 0)
                }
            }
            encoder.setFragmentTexture(textures.landcover, index: 0)
            encoder.setFragmentTexture(textures.elevation, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertices.count)
        }

        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
        let status = "z\(level.z) · \(Int(level.resolution)) m/Pixel · \(keys.count) Kacheln"
        Task { @MainActor [weak viewport] in
            viewport?.updateStatus(status)
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        requestDraw()
    }

    func pan(deltaX: Double, deltaY: Double) {
        centerX -= deltaX / pixelsPerMeter
        centerY += deltaY / pixelsPerMeter
        constrainCenter()
        requestDraw()
    }

    func zoom(factor: Double, around point: CGPoint) {
        guard let view, let manifest, factor.isFinite, factor > 0 else { return }
        let size = view.bounds.size
        let worldX = centerX + (point.x - size.width / 2) / pixelsPerMeter
        let worldY = centerY - (point.y - size.height / 2) / pixelsPerMeter
        let minimum = fitScale(manifest, in: size) * 0.35
        let maximum = 0.20
        pixelsPerMeter = min(max(pixelsPerMeter * factor, minimum), maximum)
        centerX = worldX - (point.x - size.width / 2) / pixelsPerMeter
        centerY = worldY + (point.y - size.height / 2) / pixelsPerMeter
        constrainCenter()
        requestDraw()
    }

    func forceFit() {
        needsFit = true
        requestDraw()
    }

    private func fit(_ manifest: MapManifest, in size: CGSize) {
        centerX = (manifest.left + manifest.right) / 2
        centerY = (manifest.bottom + manifest.top) / 2
        pixelsPerMeter = fitScale(manifest, in: size)
    }

    private func focus(_ reference: MapReference) {
        centerX = reference.centerX
        centerY = reference.centerY
        pixelsPerMeter = 1 / reference.metersPerPoint
        constrainCenter()
    }

    private func fitScale(_ manifest: MapManifest, in size: CGSize) -> Double {
        let availableWidth = max(1, size.width - 48)
        let availableHeight = max(1, size.height - 48)
        return min(availableWidth / manifest.width, availableHeight / manifest.height)
    }

    private func constrainCenter() {
        guard let manifest else { return }
        centerX = min(max(centerX, manifest.left), manifest.right)
        centerY = min(max(centerY, manifest.bottom), manifest.top)
    }

    private func bestLevel(in manifest: MapManifest) -> MapManifest.Level {
        let metersPerPoint = 1 / pixelsPerMeter
        return manifest.levels.min {
            abs(log2($0.resolution / metersPerPoint)) < abs(log2($1.resolution / metersPerPoint))
        } ?? manifest.levels[0]
    }

    private func visibleTiles(
        level: MapManifest.Level,
        manifest: MapManifest,
        viewSize: CGSize
    ) -> [TileKey] {
        let halfWidth = Double(viewSize.width) / (2 * pixelsPerMeter)
        let halfHeight = Double(viewSize.height) / (2 * pixelsPerMeter)
        let visibleLeft = centerX - halfWidth
        let visibleRight = centerX + halfWidth
        let visibleBottom = centerY - halfHeight
        let visibleTop = centerY + halfHeight
        let tileMeters = Double(manifest.tileSize) * level.resolution

        let minX = max(0, Int(floor((visibleLeft - manifest.left) / tileMeters)))
        let maxX = min(level.tilesX - 1, Int(floor((visibleRight - manifest.left) / tileMeters)))
        let minY = max(0, Int(floor((manifest.top - visibleTop) / tileMeters)))
        let maxY = min(level.tilesY - 1, Int(floor((manifest.top - visibleBottom) / tileMeters)))
        guard minX <= maxX, minY <= maxY else { return [] }

        var result: [TileKey] = []
        result.reserveCapacity((maxX - minX + 1) * (maxY - minY + 1))
        for y in minY...maxY {
            for x in minX...maxX {
                result.append(TileKey(z: level.z, x: x, y: y))
            }
        }
        return result
    }

    private func vertices(
        for key: TileKey,
        level: MapManifest.Level,
        manifest: MapManifest,
        viewSize: CGSize
    ) -> [TileVertex] {
        let tileMeters = Double(manifest.tileSize) * level.resolution
        let left = manifest.left + Double(key.x) * tileMeters
        let right = left + tileMeters
        let top = manifest.top - Double(key.y) * tileMeters
        let bottom = top - tileMeters

        func normalizedX(_ world: Double) -> Float {
            Float((world - centerX) * pixelsPerMeter / (Double(viewSize.width) / 2))
        }
        func normalizedY(_ world: Double) -> Float {
            Float((world - centerY) * pixelsPerMeter / (Double(viewSize.height) / 2))
        }

        let x0 = normalizedX(left)
        let x1 = normalizedX(right)
        let y0 = normalizedY(bottom)
        let y1 = normalizedY(top)
        return [
            TileVertex(position: SIMD2(x0, y1), uv: SIMD2(0, 0)),
            TileVertex(position: SIMD2(x0, y0), uv: SIMD2(0, 1)),
            TileVertex(position: SIMD2(x1, y0), uv: SIMD2(1, 1)),
            TileVertex(position: SIMD2(x0, y1), uv: SIMD2(0, 0)),
            TileVertex(position: SIMD2(x1, y0), uv: SIMD2(1, 1)),
            TileVertex(position: SIMD2(x1, y1), uv: SIMD2(1, 0)),
        ]
    }

    private func requestDraw() {
        view?.needsDisplay = true
    }
}
