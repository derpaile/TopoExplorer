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
    var azimuth: Float
    var padding0: Float = 0
    var padding1: Float = 0
    var padding2: Float = 0
}

private struct ComparisonUniforms {
    var mode: UInt32
    var splitPosition: Float
    var drawableWidth: Float
    var padding: Float = 0
}

private struct VectorUniforms {
    var tile: SIMD4<Float>
    var viewport: SIMD4<Float>
    var layer: UInt32
    var pass: UInt32
    var zoom: UInt32
    var padding: UInt32 = 0
}

private struct RenderViewport {
    let centerX: Double
    let centerY: Double
    let pixelsPerMeter: Double
    let logicalSize: CGSize
    let pixelSize: CGSize
}

final class MapRenderer: NSObject, MTKViewDelegate {
    private weak var view: MapCanvasView?
    private weak var viewport: ViewportController?
    private let commandQueue: MTLCommandQueue
    private let rasterPipeline: MTLRenderPipelineState
    private let vectorPipeline: MTLRenderPipelineState
    private var tileCache: TileCache
    private var vectorCache: VectorTileCache
    private var queryService: RasterQueryService?

    private var manifest: MapManifest?
    private var dataDirectory: URL?
    private var style = RenderStyle(
        colors: Array(repeating: SIMD4<Float>(0, 0, 0, 1), count: 11),
        reliefOpacity: 0.5, reliefExaggeration: 45, reliefContrast: 2.5,
        ambientLight: 0.08, sunAzimuthRadians: 5.4977871438
    )
    private var layers = RenderLayers(
        roads: true, railways: true, waterways: true, boundaries: true,
        places: true, geonames: true
    )
    private var comparison = RenderComparison(mode: 0, splitPosition: 0.5)
    private var centerX = 0.0
    private var centerY = 0.0
    private var pixelsPerMeter = 0.001
    private var needsFit = true
    private var lastFitToken = -1
    private var lastNavigationToken = -1
    private var pendingTarget: ViewportController.Target?
    private var probeGeneration = 0

    init?(view: MapCanvasView, manifest: MapManifest, viewport: ViewportController) {
        guard
            let device = MTLCreateSystemDefaultDevice(),
            let commandQueue = device.makeCommandQueue(),
            let library = try? device.makeLibrary(source: MetalShader.source, options: nil),
            let rasterVertex = library.makeFunction(name: "tileVertex"),
            let rasterFragment = library.makeFunction(name: "tileFragment"),
            let vectorVertex = library.makeFunction(name: "vectorVertex"),
            let vectorFragment = library.makeFunction(name: "vectorFragment")
        else { return nil }

        let rasterDescriptor = MTLRenderPipelineDescriptor()
        rasterDescriptor.label = "TopoExplorer raster tiles"
        rasterDescriptor.vertexFunction = rasterVertex
        rasterDescriptor.fragmentFunction = rasterFragment
        rasterDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        guard let rasterPipeline = try? device.makeRenderPipelineState(descriptor: rasterDescriptor) else { return nil }

        let vectorDescriptor = MTLRenderPipelineDescriptor()
        vectorDescriptor.label = "TopoExplorer vector overlays"
        vectorDescriptor.vertexFunction = vectorVertex
        vectorDescriptor.fragmentFunction = vectorFragment
        vectorDescriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        vectorDescriptor.colorAttachments[0].isBlendingEnabled = true
        vectorDescriptor.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        vectorDescriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        vectorDescriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        vectorDescriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        guard let vectorPipeline = try? device.makeRenderPipelineState(descriptor: vectorDescriptor) else { return nil }

        self.view = view
        self.viewport = viewport
        self.commandQueue = commandQueue
        self.rasterPipeline = rasterPipeline
        self.vectorPipeline = vectorPipeline
        tileCache = TileCache(
            device: device, tileSize: manifest.tileSize,
            elevationBorder: manifest.elevationBorder,
            landcoverSuffix: manifest.landcoverSuffix
        )
        vectorCache = VectorTileCache(device: device)
        self.manifest = manifest
        centerX = (manifest.left + manifest.right) / 2
        centerY = (manifest.bottom + manifest.top) / 2
        super.init()

        view.device = device
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColorMake(0, 0, 0, 1)
        view.framebufferOnly = false
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.delegate = self
        view.mapRenderer = self
    }

    func update(
        manifest newManifest: MapManifest,
        dataDirectory newDirectory: URL,
        style newStyle: RenderStyle,
        layers newLayers: RenderLayers,
        comparison newComparison: RenderComparison,
        fitToken: Int,
        navigationToken: Int,
        target: ViewportController.Target?
    ) {
        let dataChanged = manifest != newManifest
            || dataDirectory?.standardizedFileURL != newDirectory.standardizedFileURL
        if dataChanged {
            manifest = newManifest
            dataDirectory = newDirectory
            tileCache = TileCache(
                device: commandQueue.device,
                tileSize: newManifest.tileSize,
                elevationBorder: newManifest.elevationBorder,
                landcoverSuffix: newManifest.landcoverSuffix
            )
            vectorCache = VectorTileCache(device: commandQueue.device)
            queryService = RasterQueryService(manifest: newManifest, directory: newDirectory)
            needsFit = true
        }
        style = newStyle
        layers = newLayers
        comparison = newComparison
        if let color = newStyle.colors.first {
            view?.clearColor = MTLClearColorMake(Double(color.x), Double(color.y), Double(color.z), 1)
        }
        if fitToken != lastFitToken {
            lastFitToken = fitToken
            needsFit = true
            pendingTarget = nil
        }
        if navigationToken != lastNavigationToken {
            lastNavigationToken = navigationToken
            if let target {
                pendingTarget = target
                needsFit = false
            }
        }
        requestDraw()
    }

    func draw(in view: MTKView) {
        let started = CFAbsoluteTimeGetCurrent()
        guard
            let manifest,
            let dataDirectory,
            let renderPass = view.currentRenderPassDescriptor,
            let drawable = view.currentDrawable,
            view.bounds.width > 1,
            view.bounds.height > 1
        else { return }

        if let target = pendingTarget {
            focus(target)
            pendingTarget = nil
        } else if needsFit {
            fit(manifest, in: view.bounds.size)
            needsFit = false
        }

        guard
            let commandBuffer = commandQueue.makeCommandBuffer(),
            let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPass)
        else { return }
        encoder.label = "Visible Germany map"

        let renderViewport = RenderViewport(
            centerX: centerX, centerY: centerY,
            pixelsPerMeter: pixelsPerMeter,
            logicalSize: view.bounds.size,
            pixelSize: view.drawableSize
        )
        let level = bestLevel(in: manifest, pixelsPerMeter: pixelsPerMeter)
        let keys = visibleTiles(level: level, manifest: manifest, viewport: renderViewport)
        encoder.setRenderPipelineState(rasterPipeline)
        style.colors.withUnsafeBytes { bytes in
            if let address = bytes.baseAddress {
                encoder.setFragmentBytes(address, length: bytes.count, index: 0)
            }
        }
        var relief = ReliefUniforms(
            opacity: style.reliefOpacity,
            exaggeration: style.reliefExaggeration,
            contrast: style.reliefContrast,
            ambient: style.ambientLight,
            azimuth: style.sunAzimuthRadians
        )
        var comparisonUniforms = ComparisonUniforms(
            mode: comparison.mode,
            splitPosition: comparison.splitPosition,
            drawableWidth: Float(view.drawableSize.width)
        )
        encoder.setFragmentBytes(&relief, length: MemoryLayout<ReliefUniforms>.stride, index: 1)
        encoder.setFragmentBytes(
            &comparisonUniforms,
            length: MemoryLayout<ComparisonUniforms>.stride,
            index: 2
        )

        var loadedRasterCount = 0
        for key in keys {
            guard let textures = tileCache[key] else {
                tileCache.request(key, from: dataDirectory) { [weak self] in self?.requestDraw() }
                continue
            }
            loadedRasterCount += 1
            let vertices = vertices(
                for: key, level: level, manifest: manifest,
                viewport: renderViewport
            )
            vertices.withUnsafeBytes { bytes in
                if let address = bytes.baseAddress {
                    encoder.setVertexBytes(address, length: bytes.count, index: 0)
                }
            }
            encoder.setFragmentTexture(textures.landcover, index: 0)
            encoder.setFragmentTexture(textures.elevation, index: 1)
            encoder.setFragmentTexture(textures.landcover2020 ?? textures.landcover, index: 2)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: vertices.count)
        }

        let vectorResult = drawVectors(
            encoder: encoder, keys: keys, level: level,
            semanticZoom: level.z, manifest: manifest,
            directory: dataDirectory, viewport: renderViewport,
            renderLayers: layers, loadedTiles: nil
        )
        encoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()

        prefetch(around: keys, level: level, manifest: manifest, directory: dataDirectory)
        let elapsedMilliseconds = (CFAbsoluteTimeGetCurrent() - started) * 1_000
        let rasterStats = tileCache.statistics
        let vectorStats = vectorCache.statistics
        let status = "z\(level.z) · \(Int(level.resolution)) m/Pixel · "
            + "\(loadedRasterCount)/\(keys.count) Raster · \(vectorResult.lineCount) Linien · "
            + String(
                format: "%.1f ms · %.0f MB · %d lädt",
                elapsedMilliseconds,
                rasterStats.megabytes + Double(vectorStats.bytes) / 1_048_576,
                rasterStats.pending + vectorStats.pending
            )
        let snapshot = ViewportSnapshot(
            centerX: centerX, centerY: centerY,
            metersPerPoint: 1 / pixelsPerMeter,
            visibleWidthMeters: Double(view.bounds.width) / pixelsPerMeter,
            visibleHeightMeters: Double(view.bounds.height) / pixelsPerMeter
        )
        Task { @MainActor [weak viewport] in
            viewport?.updateStatus(status)
            viewport?.updateLabels(vectorResult.labels)
            viewport?.updateSnapshot(snapshot)
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { requestDraw() }

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

    func viewBecameVisible() {
        requestDraw()
    }

    func inspect(at point: CGPoint) {
        guard let view, let queryService else { return }
        let worldX = centerX + (point.x - view.bounds.width / 2) / pixelsPerMeter
        let worldY = centerY - (point.y - view.bounds.height / 2) / pixelsPerMeter
        let use2020 = comparison.mode == UInt32(LandcoverMode.year2020.rawValue)
            || (comparison.mode == UInt32(LandcoverMode.comparison.rawValue)
                && point.x >= view.bounds.width * CGFloat(comparison.splitPosition))
        probeGeneration &+= 1
        let generation = probeGeneration
        queryService.query(worldX: worldX, worldY: worldY, year2020: use2020) { [weak self] probe in
            guard let self, self.probeGeneration == generation else { return }
            Task { @MainActor [weak viewport] in viewport?.updateProbe(probe) }
        }
    }

    func clearInspection() {
        probeGeneration &+= 1
        Task { @MainActor [weak viewport] in viewport?.updateProbe(nil) }
    }

    func export(_ request: MapExportRequest, completion: @escaping (Result<URL, Error>) -> Void) {
        guard let manifest, let directory = dataDirectory else {
            completion(.failure(MapRendererError.noSnapshot))
            return
        }
        let logicalSize = CGSize(
            width: request.snapshot.visibleWidthMeters / request.snapshot.metersPerPoint,
            height: request.snapshot.visibleHeightMeters / request.snapshot.metersPerPoint
        )
        let width = Int(logicalSize.width.rounded()) * request.scale
        let height = Int(logicalSize.height.rounded()) * request.scale
        guard
            width > 0, height > 0,
            width <= 16_384,
            height <= 16_384,
            width <= 32_000_000 / height
        else {
            completion(.failure(MapRendererError.tooLarge))
            return
        }

        let exportViewport = RenderViewport(
            centerX: request.snapshot.centerX,
            centerY: request.snapshot.centerY,
            pixelsPerMeter: 1 / request.snapshot.metersPerPoint,
            logicalSize: logicalSize,
            pixelSize: CGSize(width: width, height: height)
        )
        let semanticLevel = bestLevel(
            in: manifest, pixelsPerMeter: exportViewport.pixelsPerMeter
        )
        let detailLevel = bestLevel(
            in: manifest,
            pixelsPerMeter: exportViewport.pixelsPerMeter * Double(request.scale)
        )
        let keys = visibleTiles(
            level: detailLevel, manifest: manifest, viewport: exportViewport
        )
        tileCache.loadForExport(keys, from: directory) { [weak self] rasterResult in
            guard let self else {
                completion(.failure(MapRendererError.noSnapshot))
                return
            }
            switch rasterResult {
            case .failure(let error):
                completion(.failure(error))
            case .success(let rasterTiles):
                self.vectorCache.loadForExport(keys, from: directory) { [weak self] vectorResult in
                    guard let self else {
                        completion(.failure(MapRendererError.noSnapshot))
                        return
                    }
                    switch vectorResult {
                    case .failure(let error):
                        completion(.failure(error))
                    case .success(let vectorTiles):
                        self.renderExport(
                            request: request,
                            manifest: manifest,
                            directory: directory,
                            level: detailLevel,
                            semanticZoom: semanticLevel.z,
                            keys: keys,
                            viewport: exportViewport,
                            rasterTiles: rasterTiles,
                            vectorTiles: vectorTiles,
                            completion: completion
                        )
                    }
                }
            }
        }
    }

    private func renderExport(
        request: MapExportRequest,
        manifest: MapManifest,
        directory: URL,
        level: MapManifest.Level,
        semanticZoom: Int,
        keys: [TileKey],
        viewport: RenderViewport,
        rasterTiles: [TileKey: TileTextures],
        vectorTiles: [TileKey: VectorTile],
        completion: @escaping (Result<URL, Error>) -> Void
    ) {
        let width = Int(viewport.pixelSize.width)
        let height = Int(viewport.pixelSize.height)
        let rowBytes = width * 4
        let alignedRowBytes = (rowBytes + 255) & ~255
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: width,
            height: height,
            mipmapped: false
        )
        textureDescriptor.usage = .renderTarget
        textureDescriptor.storageMode = .private
        guard
            let target = commandQueue.device.makeTexture(descriptor: textureDescriptor),
            let staging = commandQueue.device.makeBuffer(
                length: alignedRowBytes * height,
                options: .storageModeShared
            ),
            let command = commandQueue.makeCommandBuffer()
        else {
            completion(.failure(MapRendererError.gpuAllocation))
            return
        }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = target
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        let clear = request.renderStyle.colors.first ?? SIMD4<Float>(0, 0, 0, 1)
        pass.colorAttachments[0].clearColor = MTLClearColorMake(
            Double(clear.x), Double(clear.y), Double(clear.z), 1
        )
        guard let encoder = command.makeRenderCommandEncoder(descriptor: pass) else {
            completion(.failure(MapRendererError.gpuAllocation))
            return
        }
        encoder.label = "TopoExplorer high-resolution export"
        encoder.setRenderPipelineState(rasterPipeline)
        request.renderStyle.colors.withUnsafeBytes { bytes in
            if let address = bytes.baseAddress {
                encoder.setFragmentBytes(address, length: bytes.count, index: 0)
            }
        }
        var relief = ReliefUniforms(
            opacity: request.renderStyle.reliefOpacity,
            exaggeration: request.renderStyle.reliefExaggeration,
            contrast: request.renderStyle.reliefContrast,
            ambient: request.renderStyle.ambientLight,
            azimuth: request.renderStyle.sunAzimuthRadians
        )
        var comparisonUniforms = ComparisonUniforms(
            mode: request.renderComparison.mode,
            splitPosition: request.renderComparison.splitPosition,
            drawableWidth: Float(width)
        )
        encoder.setFragmentBytes(
            &relief, length: MemoryLayout<ReliefUniforms>.stride, index: 1
        )
        encoder.setFragmentBytes(
            &comparisonUniforms,
            length: MemoryLayout<ComparisonUniforms>.stride,
            index: 2
        )
        for key in keys {
            guard let textures = rasterTiles[key] else { continue }
            let tileVertices = vertices(
                for: key, level: level, manifest: manifest,
                viewport: viewport
            )
            tileVertices.withUnsafeBytes { bytes in
                if let address = bytes.baseAddress {
                    encoder.setVertexBytes(address, length: bytes.count, index: 0)
                }
            }
            encoder.setFragmentTexture(textures.landcover, index: 0)
            encoder.setFragmentTexture(textures.elevation, index: 1)
            encoder.setFragmentTexture(
                textures.landcover2020 ?? textures.landcover,
                index: 2
            )
            encoder.drawPrimitives(
                type: .triangle, vertexStart: 0, vertexCount: tileVertices.count
            )
        }
        _ = drawVectors(
            encoder: encoder, keys: keys, level: level,
            semanticZoom: semanticZoom, manifest: manifest,
            directory: directory, viewport: viewport,
            renderLayers: request.renderLayers,
            loadedTiles: vectorTiles
        )
        encoder.endEncoding()

        guard let blit = command.makeBlitCommandEncoder() else {
            completion(.failure(MapRendererError.gpuAllocation))
            return
        }
        blit.copy(
            from: target,
            sourceSlice: 0,
            sourceLevel: 0,
            sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
            sourceSize: MTLSize(width: width, height: height, depth: 1),
            to: staging,
            destinationOffset: 0,
            destinationBytesPerRow: alignedRowBytes,
            destinationBytesPerImage: alignedRowBytes * height
        )
        blit.endEncoding()
        command.addCompletedHandler { finished in
            guard finished.status == .completed else {
                let error = finished.error ?? MapRendererError.gpuExecution
                DispatchQueue.main.async { completion(.failure(error)) }
                return
            }
            var pixels = Data(count: rowBytes * height)
            pixels.withUnsafeMutableBytes { destination in
                guard let base = destination.baseAddress else { return }
                let source = staging.contents()
                for row in 0..<height {
                    base.advanced(by: row * rowBytes).copyMemory(
                        from: source.advanced(by: row * alignedRowBytes),
                        byteCount: rowBytes
                    )
                }
            }
            let result: Result<URL, Error>
            do {
                try MapExportWriter.write(
                    pixels: pixels,
                    width: width,
                    height: height,
                    request: request,
                    pixelsAreFinalSize: true
                )
                result = .success(request.url)
            } catch {
                result = .failure(error)
            }
            withExtendedLifetime((rasterTiles, vectorTiles)) {}
            DispatchQueue.main.async { completion(result) }
        }
        command.commit()
    }

    private func fit(_ manifest: MapManifest, in size: CGSize) {
        centerX = (manifest.left + manifest.right) / 2
        centerY = (manifest.bottom + manifest.top) / 2
        pixelsPerMeter = fitScale(manifest, in: size)
    }

    private func focus(_ target: ViewportController.Target) {
        centerX = target.centerX
        centerY = target.centerY
        pixelsPerMeter = 1 / target.metersPerPoint
        constrainCenter()
    }

    private func fitScale(_ manifest: MapManifest, in size: CGSize) -> Double {
        min(max(1, size.width - 48) / manifest.width, max(1, size.height - 48) / manifest.height)
    }

    private func constrainCenter() {
        guard let manifest else { return }
        centerX = min(max(centerX, manifest.left), manifest.right)
        centerY = min(max(centerY, manifest.bottom), manifest.top)
    }

    private func bestLevel(
        in manifest: MapManifest,
        pixelsPerMeter: Double
    ) -> MapManifest.Level {
        let metersPerPoint = 1 / pixelsPerMeter
        return manifest.levels.min {
            abs(log2($0.resolution / metersPerPoint)) < abs(log2($1.resolution / metersPerPoint))
        } ?? manifest.levels[0]
    }

    private func visibleTiles(
        level: MapManifest.Level,
        manifest: MapManifest,
        viewport: RenderViewport
    ) -> [TileKey] {
        let halfWidth = Double(viewport.logicalSize.width) / (2 * viewport.pixelsPerMeter)
        let halfHeight = Double(viewport.logicalSize.height) / (2 * viewport.pixelsPerMeter)
        let tileMeters = Double(manifest.tileSize) * level.resolution
        let minX = max(0, Int(floor((viewport.centerX - halfWidth - manifest.left) / tileMeters)))
        let maxX = min(level.tilesX - 1, Int(floor((viewport.centerX + halfWidth - manifest.left) / tileMeters)))
        let minY = max(0, Int(floor((manifest.top - viewport.centerY - halfHeight) / tileMeters)))
        let maxY = min(level.tilesY - 1, Int(floor((manifest.top - viewport.centerY + halfHeight) / tileMeters)))
        guard minX <= maxX, minY <= maxY else { return [] }
        return (minY...maxY).flatMap { y in (minX...maxX).map { x in TileKey(z: level.z, x: x, y: y) } }
    }

    private func vertices(
        for key: TileKey,
        level: MapManifest.Level,
        manifest: MapManifest,
        viewport: RenderViewport
    ) -> [TileVertex] {
        let tileMeters = Double(manifest.tileSize) * level.resolution
        let left = manifest.left + Double(key.x) * tileMeters
        let right = left + tileMeters
        let top = manifest.top - Double(key.y) * tileMeters
        let bottom = top - tileMeters
        func x(_ world: Double) -> Float {
            Float(
                (world - viewport.centerX) * viewport.pixelsPerMeter
                    / (Double(viewport.logicalSize.width) / 2)
            )
        }
        func y(_ world: Double) -> Float {
            Float(
                (world - viewport.centerY) * viewport.pixelsPerMeter
                    / (Double(viewport.logicalSize.height) / 2)
            )
        }
        let x0 = x(left), x1 = x(right), y0 = y(bottom), y1 = y(top)
        return [
            TileVertex(position: [x0, y1], uv: [0, 0]),
            TileVertex(position: [x0, y0], uv: [0, 1]),
            TileVertex(position: [x1, y0], uv: [1, 1]),
            TileVertex(position: [x0, y1], uv: [0, 0]),
            TileVertex(position: [x1, y0], uv: [1, 1]),
            TileVertex(position: [x1, y1], uv: [1, 0]),
        ]
    }

    private func drawVectors(
        encoder: MTLRenderCommandEncoder,
        keys: [TileKey],
        level: MapManifest.Level,
        semanticZoom: Int? = nil,
        manifest: MapManifest,
        directory: URL,
        viewport: RenderViewport,
        renderLayers: RenderLayers,
        loadedTiles: [TileKey: VectorTile]?
    ) -> (lineCount: Int, labels: [MapLabel]) {
        guard
            renderLayers.roads || renderLayers.railways || renderLayers.waterways
                || renderLayers.boundaries || renderLayers.places || renderLayers.geonames
        else {
            return (0, [])
        }
        var places: [(VectorPlace, Double, Double)] = []
        var lineCount = 0
        let tileMeters = Double(manifest.tileSize) * level.resolution
        let visibleZoom = semanticZoom ?? level.z
        let lineLayersEnabled = renderLayers.roads || renderLayers.railways
            || renderLayers.waterways || renderLayers.boundaries
        let layerOrder: [VectorLayer] = [.boundary, .waterway, .railway, .road]
        if lineLayersEnabled { encoder.setRenderPipelineState(vectorPipeline) }

        for key in keys {
            let tile: VectorTile?
            if let loadedTiles {
                tile = loadedTiles[key]
            } else {
                tile = vectorCache[key]
                if tile == nil {
                    vectorCache.request(key, from: directory) { [weak self] in
                        self?.requestDraw()
                    }
                }
            }
            guard let tile else {
                continue
            }
            let left = manifest.left + Double(key.x) * tileMeters
            let top = manifest.top - Double(key.y) * tileMeters
            func world(_ point: SIMD2<Int16>) -> SIMD2<Double> {
                SIMD2(
                    left + Double(point.x) / Double(tile.extent) * tileMeters,
                    top - Double(point.y) / Double(tile.extent) * tileMeters
                )
            }

            if
                lineLayersEnabled,
                let scissor = vectorScissor(
                    for: key, level: level, manifest: manifest,
                    viewport: viewport
                )
            {
                encoder.setScissorRect(scissor)
                let originX = (left - viewport.centerX) * viewport.pixelsPerMeter
                    + Double(viewport.logicalSize.width) / 2
                let originY = (viewport.centerY - top) * viewport.pixelsPerMeter
                    + Double(viewport.logicalSize.height) / 2
                var uniforms = VectorUniforms(
                    tile: SIMD4(
                        Float(originX), Float(originY),
                        Float(tileMeters * viewport.pixelsPerMeter), Float(tile.extent)
                    ),
                    viewport: SIMD4(
                        Float(viewport.logicalSize.width),
                        Float(viewport.logicalSize.height), 0, 0
                    ),
                    layer: 0,
                    pass: 0,
                    zoom: UInt32(max(0, visibleZoom))
                )

                // Casings first, then cores: intersections retain the previous visual hierarchy.
                for layer in layerOrder where layerEnabled(layer, in: renderLayers) {
                    guard let layerSegments = tile.layers[layer] else { continue }
                    uniforms.layer = UInt32(layer.rawValue)
                    uniforms.pass = 0
                    for group in layerSegments.zoomLevels where group.minimumZoom <= visibleZoom {
                        drawVectorBuffer(
                            group.withCasing, uniforms: &uniforms, encoder: encoder
                        )
                    }
                }
                for layer in layerOrder where layerEnabled(layer, in: renderLayers) {
                    guard let layerSegments = tile.layers[layer] else { continue }
                    uniforms.layer = UInt32(layer.rawValue)
                    uniforms.pass = 1
                    for group in layerSegments.zoomLevels where group.minimumZoom <= visibleZoom {
                        drawVectorBuffer(
                            group.withCasing, uniforms: &uniforms, encoder: encoder
                        )
                        drawVectorBuffer(group.plain, uniforms: &uniforms, encoder: encoder)
                        lineCount += group.lineCount
                    }
                }
            }

            if renderLayers.places || renderLayers.geonames {
                for place in tile.places where Int(place.minZoom) <= visibleZoom
                    && (place.kind <= 6 ? renderLayers.places : renderLayers.geonames)
                {
                    let point = world(place.point)
                    places.append((place, point.x, point.y))
                }
            }
        }
        return (lineCount, layoutLabels(places, viewport: viewport))
    }

    private func layerEnabled(_ layer: VectorLayer, in layers: RenderLayers) -> Bool {
        switch layer {
        case .road: layers.roads
        case .railway: layers.railways
        case .waterway: layers.waterways
        case .boundary: layers.boundaries
        }
    }

    private func drawVectorBuffer(
        _ segmentBuffer: VectorSegmentBuffer?,
        uniforms: inout VectorUniforms,
        encoder: MTLRenderCommandEncoder
    ) {
        guard
            let segmentBuffer,
            let buffer = segmentBuffer.buffer,
            segmentBuffer.count > 0
        else { return }
        encoder.setVertexBuffer(buffer, offset: 0, index: 0)
        encoder.setVertexBytes(
            &uniforms,
            length: MemoryLayout<VectorUniforms>.stride,
            index: 1
        )
        encoder.drawPrimitives(
            type: .triangle,
            vertexStart: 0,
            vertexCount: 6,
            instanceCount: segmentBuffer.count
        )
    }

    private func vectorScissor(
        for key: TileKey,
        level: MapManifest.Level,
        manifest: MapManifest,
        viewport: RenderViewport
    ) -> MTLScissorRect? {
        let tileMeters = Double(manifest.tileSize) * level.resolution
        let left = manifest.left + Double(key.x) * tileMeters
        let top = manifest.top - Double(key.y) * tileMeters
        let x0 = (left - viewport.centerX) * viewport.pixelsPerMeter
            + Double(viewport.logicalSize.width) / 2
        let y0 = (viewport.centerY - top) * viewport.pixelsPerMeter
            + Double(viewport.logicalSize.height) / 2
        let span = tileMeters * viewport.pixelsPerMeter
        let clippedLeft = max(0, x0)
        let clippedTop = max(0, y0)
        let clippedRight = min(Double(viewport.logicalSize.width), x0 + span)
        let clippedBottom = min(Double(viewport.logicalSize.height), y0 + span)
        guard clippedRight > clippedLeft, clippedBottom > clippedTop else { return nil }

        let scaleX = Double(viewport.pixelSize.width) / Double(viewport.logicalSize.width)
        let scaleY = Double(viewport.pixelSize.height) / Double(viewport.logicalSize.height)
        // Identische Rundung beider Seiten teilt Nachbarkacheln ohne
        // überzeichnete oder ausgelassene Pixel exakt an derselben Kante.
        let pixelLeft = max(0, Int((clippedLeft * scaleX).rounded()))
        let pixelTop = max(0, Int((clippedTop * scaleY).rounded()))
        let pixelRight = min(
            Int(viewport.pixelSize.width), Int((clippedRight * scaleX).rounded())
        )
        let pixelBottom = min(
            Int(viewport.pixelSize.height), Int((clippedBottom * scaleY).rounded())
        )
        guard pixelRight > pixelLeft, pixelBottom > pixelTop else { return nil }
        return MTLScissorRect(
            x: pixelLeft,
            y: pixelTop,
            width: pixelRight - pixelLeft,
            height: pixelBottom - pixelTop
        )
    }

    private func layoutLabels(
        _ candidates: [(VectorPlace, Double, Double)],
        viewport: RenderViewport
    ) -> [MapLabel] {
        var seen = Set<String>()
        let sorted = candidates.sorted {
            if $0.0.minZoom != $1.0.minZoom { return $0.0.minZoom < $1.0.minZoom }
            if $0.0.population != $1.0.population { return $0.0.population > $1.0.population }
            return $0.0.kind < $1.0.kind
        }
        var occupied: [CGRect] = []
        var labels: [MapLabel] = []
        for (place, worldX, worldY) in sorted {
            let x = (worldX - viewport.centerX) * viewport.pixelsPerMeter
                + Double(viewport.logicalSize.width) / 2
            let y = (viewport.centerY - worldY) * viewport.pixelsPerMeter
                + Double(viewport.logicalSize.height) / 2
            guard
                x > 20, y > 12,
                x < Double(viewport.logicalSize.width) - 20,
                y < Double(viewport.logicalSize.height) - 12
            else { continue }
            let identity = "\(place.name)|\(Int(worldX / 100))|\(Int(worldY / 100))"
            guard seen.insert(identity).inserted else { continue }
            let width = min(180, max(32, Double(place.name.count) * 7.2 + 12))
            let rectangle = CGRect(x: x - width / 2, y: y - 10, width: width, height: 20).insetBy(dx: -3, dy: -2)
            guard !occupied.contains(where: { $0.intersects(rectangle) }) else { continue }
            occupied.append(rectangle)
            labels.append(
                MapLabel(
                    id: identity, name: place.name,
                    point: CGPoint(x: x, y: y), prominence: Double(place.population)
                )
            )
            if labels.count >= 120 { break }
        }
        return labels
    }

    private func prefetch(
        around keys: [TileKey],
        level: MapManifest.Level,
        manifest: MapManifest,
        directory: URL
    ) {
        guard !keys.isEmpty else { return }
        let visible = Set(keys)
        var adjacent = Set<TileKey>()
        for key in keys {
            for y in max(0, key.y - 1)...min(level.tilesY - 1, key.y + 1) {
                for x in max(0, key.x - 1)...min(level.tilesX - 1, key.x + 1) {
                    adjacent.insert(TileKey(z: key.z, x: x, y: y))
                }
            }
        }
        tileCache.retainRequests(for: adjacent)
        vectorCache.retainRequests(for: adjacent)
        for key in adjacent.subtracting(visible) {
            tileCache.request(key, from: directory) { [weak self] in self?.requestDraw() }
            vectorCache.request(key, from: directory) { [weak self] in self?.requestDraw() }
        }
    }

    private func requestDraw() { view?.needsDisplay = true }
}

private enum MapRendererError: LocalizedError {
    case noSnapshot
    case tooLarge
    case gpuAllocation
    case gpuExecution

    var errorDescription: String? {
        switch self {
        case .noSnapshot: "Die Karte ist noch nicht exportbereit."
        case .tooLarge: "Der Export überschreitet 16.384 Pixel Kantenlänge oder 32 Megapixel."
        case .gpuAllocation: "Für diese Exportgröße steht nicht genügend Grafikspeicher bereit."
        case .gpuExecution: "Das hochauflösende Kartenbild konnte nicht gerendert werden."
        }
    }
}
