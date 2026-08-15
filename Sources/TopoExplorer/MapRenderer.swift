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

private struct ThematicUniforms {
    var active: UInt32
    var replacesBase: UInt32
    var opacity: Float
    var padding: Float = 0
    var uv: SIMD4<Float>
}

private struct SurfaceUniforms {
    var active: UInt32
    var strength: Float
    var zoomWeight: Float
    var edgeStrength: Float
}

private struct VectorUniforms {
    var tile: SIMD4<Float>
    var viewport: SIMD4<Float>
    var layer: UInt32
    var pass: UInt32
    var zoom: UInt32
    var kindMask: UInt32
    var preset: UInt32
    var padding0: UInt32 = 0
    var padding1: UInt32 = 0
    var padding2: UInt32 = 0
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
    private var roadShields: [RoadShield] = []
    private var queryService: RasterQueryService?

    private var manifest: MapManifest?
    private var dataDirectory: URL?
    private var style = RenderStyle(
        colors: Array(repeating: SIMD4<Float>(0, 0, 0, 1), count: MapStyleDocument.colorCount),
        reliefOpacity: 0.5, reliefExaggeration: 45, reliefContrast: 2.5,
        ambientLight: 0.08, sunAzimuthRadians: 5.4977871438
    )
    private var layers = RenderLayers(
        roads: true, roadKinds: .max, railways: true, railwayKinds: .max,
        energy: true, energyKinds: .max,
        waterways: true, boundaries: true, places: true,
        geonames: true, geonameKinds: .max,
        roadPreset: 2, railwayPreset: 2, waterwayPreset: 2,
        boundaryPreset: 2, energyPreset: 2
    )
    private var comparison = RenderComparison(mode: 0, splitPosition: 0.5)
    private var geoScience = GeoScienceRenderOptions.disabled
    private var centerX = 0.0
    private var centerY = 0.0
    private var pixelsPerMeter = 0.001
    private var needsFit = true
    private var lastFitToken = -1
    private var lastNavigationToken = -1
    private var pendingTarget: ViewportController.Target?
    private var probeGeneration = 0
    private var analysisGeneration = 0
    private var analysisStartPoint: CGPoint?
    private var analysisSelection: MapSelection?

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
            elevationSizes: Dictionary(
                uniqueKeysWithValues: manifest.levels.map {
                    ($0.z, manifest.elevationTileSize(at: $0))
                }
            ),
            landcoverSuffix: manifest.landcoverSuffix,
            thematicSuffix: nil,
            surfaceSuffix: manifest.surfaceTexture?.suffix
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
        geoScience newGeoScience: GeoScienceRenderOptions,
        fitToken: Int,
        navigationToken: Int,
        target: ViewportController.Target?
    ) {
        let dataChanged = manifest != newManifest
            || dataDirectory?.standardizedFileURL != newDirectory.standardizedFileURL
        let thematicChanged = geoScience.productID != newGeoScience.productID
        if dataChanged || thematicChanged {
            manifest = newManifest
            dataDirectory = newDirectory
            tileCache = TileCache(
                device: commandQueue.device,
                tileSize: newManifest.tileSize,
                elevationBorder: newManifest.elevationBorder,
                elevationSizes: Dictionary(
                    uniqueKeysWithValues: newManifest.levels.map {
                        ($0.z, newManifest.elevationTileSize(at: $0))
                    }
                ),
                landcoverSuffix: newManifest.landcoverSuffix,
                thematicSuffix: newGeoScience.suffix,
                surfaceSuffix: newManifest.surfaceTexture?.suffix
            )
            if dataChanged {
                vectorCache = VectorTileCache(device: commandQueue.device)
                roadShields = RoadShieldIndex.load(from: newDirectory)
                queryService = RasterQueryService(manifest: newManifest, directory: newDirectory)
                needsFit = true
            }
        }
        style = newStyle
        layers = newLayers
        comparison = newComparison
        geoScience = newGeoScience
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
        geoScience.palette.withUnsafeBytes { bytes in
            if let address = bytes.baseAddress {
                encoder.setFragmentBytes(address, length: bytes.count, index: 3)
            }
        }
        manifest.surfaceClassWeights.withUnsafeBytes { bytes in
            if let address = bytes.baseAddress {
                encoder.setFragmentBytes(address, length: bytes.count, index: 5)
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
            encoder.setFragmentTexture(textures.thematic ?? textures.landcover, index: 3)
            encoder.setFragmentTexture(textures.surface ?? textures.elevation, index: 4)
            var thematicUniforms = ThematicUniforms(
                active: textures.thematic == nil ? 0 : 1,
                replacesBase: geoScience.replacesBase ? 1 : 0,
                opacity: geoScience.opacity,
                uv: textures.thematicUV
            )
            encoder.setFragmentBytes(
                &thematicUniforms,
                length: MemoryLayout<ThematicUniforms>.stride,
                index: 4
            )
            var surfaceUniforms = SurfaceUniforms(
                active: textures.surface == nil || !style.surfaceEnabled ? 0 : 1,
                strength: style.surfaceStrength,
                zoomWeight: manifest.surfaceZoomWeight(at: level),
                edgeStrength: style.surfaceEdgeStrength
            )
            encoder.setFragmentBytes(
                &surfaceUniforms,
                length: MemoryLayout<SurfaceUniforms>.stride,
                index: 6
            )
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
        let selectionRect = analysisSelection.map { selection in
            screenRect(for: selection, in: view.bounds.size)
        }
        Task { @MainActor [weak viewport] in
            viewport?.updateStatus(status)
            viewport?.updateLabels(vectorResult.labels)
            viewport?.updateSnapshot(snapshot)
            viewport?.updateAnalysisScreenRect(selectionRect)
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
        let thematic = manifest?.availableThematicRasters.first { $0.id == geoScience.productID }
        queryService.query(
            worldX: worldX, worldY: worldY, year2020: use2020, thematic: thematic
        ) { [weak self] probe in
            guard let self, self.probeGeneration == generation else { return }
            Task { @MainActor [weak viewport] in viewport?.updateProbe(probe) }
        }
    }

    func clearInspection() {
        probeGeneration &+= 1
        Task { @MainActor [weak viewport] in viewport?.updateProbe(nil) }
    }

    func beginAreaSelection(at point: CGPoint) {
        guard manifest != nil else { return }
        analysisGeneration &+= 1
        analysisStartPoint = point
        updateAreaSelection(to: point)
    }

    func updateAreaSelection(to point: CGPoint) {
        guard let view, let start = analysisStartPoint else { return }
        let startWorld = worldPoint(for: start, in: view.bounds.size)
        let endWorld = worldPoint(for: point, in: view.bounds.size)
        let selection = MapSelection(
            x1: startWorld.x, y1: startWorld.y,
            x2: endWorld.x, y2: endWorld.y
        )
        analysisSelection = selection
        let rect = CGRect(
            x: min(start.x, point.x), y: min(start.y, point.y),
            width: abs(point.x - start.x), height: abs(point.y - start.y)
        )
        Task { @MainActor [weak viewport] in
            viewport?.updateAnalysisSelection(selection, screenRect: rect)
        }
    }

    func finishAreaSelection(at point: CGPoint) {
        updateAreaSelection(to: point)
        guard
            let start = analysisStartPoint,
            abs(point.x - start.x) >= 8,
            abs(point.y - start.y) >= 8,
            let selection = analysisSelection,
            let queryService
        else {
            cancelAreaSelection()
            return
        }
        analysisStartPoint = nil
        analysisGeneration &+= 1
        let generation = analysisGeneration
        let use2020 = comparison.mode == UInt32(LandcoverMode.year2020.rawValue)
        Task { @MainActor [weak viewport] in viewport?.beginAnalysis() }
        let thematic = manifest?.availableThematicRasters.first { $0.id == geoScience.productID }
        queryService.queryStatistics(
            selection: selection, year2020: use2020, thematic: thematic
        ) { [weak self] result, message in
            guard let self, self.analysisGeneration == generation else { return }
            Task { @MainActor [weak viewport] in
                viewport?.finishAnalysis(result, message: message)
            }
        }
    }

    func cancelAreaSelection() {
        analysisGeneration &+= 1
        analysisStartPoint = nil
        analysisSelection = nil
        Task { @MainActor [weak viewport] in viewport?.clearAnalysis() }
    }

    private func worldPoint(for point: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(
            x: centerX + (point.x - size.width / 2) / pixelsPerMeter,
            y: centerY - (point.y - size.height / 2) / pixelsPerMeter
        )
    }

    private func screenRect(for selection: MapSelection, in size: CGSize) -> CGRect {
        let x1 = size.width / 2 + (selection.minX - centerX) * pixelsPerMeter
        let x2 = size.width / 2 + (selection.maxX - centerX) * pixelsPerMeter
        let y1 = size.height / 2 + (centerY - selection.maxY) * pixelsPerMeter
        let y2 = size.height / 2 + (centerY - selection.minY) * pixelsPerMeter
        return CGRect(x: x1, y: y1, width: x2 - x1, height: y2 - y1)
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
        geoScience.palette.withUnsafeBytes { bytes in
            if let address = bytes.baseAddress {
                encoder.setFragmentBytes(address, length: bytes.count, index: 3)
            }
        }
        manifest.surfaceClassWeights.withUnsafeBytes { bytes in
            if let address = bytes.baseAddress {
                encoder.setFragmentBytes(address, length: bytes.count, index: 5)
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
            encoder.setFragmentTexture(textures.thematic ?? textures.landcover, index: 3)
            encoder.setFragmentTexture(textures.surface ?? textures.elevation, index: 4)
            var thematicUniforms = ThematicUniforms(
                active: textures.thematic == nil ? 0 : 1,
                replacesBase: geoScience.replacesBase ? 1 : 0,
                opacity: geoScience.opacity,
                uv: textures.thematicUV
            )
            encoder.setFragmentBytes(
                &thematicUniforms,
                length: MemoryLayout<ThematicUniforms>.stride,
                index: 4
            )
            var surfaceUniforms = SurfaceUniforms(
                active: textures.surface == nil || !request.renderStyle.surfaceEnabled ? 0 : 1,
                strength: request.renderStyle.surfaceStrength,
                zoomWeight: manifest.surfaceZoomWeight(at: level),
                edgeStrength: request.renderStyle.surfaceEdgeStrength
            )
            encoder.setFragmentBytes(
                &surfaceUniforms,
                length: MemoryLayout<SurfaceUniforms>.stride,
                index: 6
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
                || renderLayers.boundaries || renderLayers.energy
                || renderLayers.places || renderLayers.geonames
        else {
            return (0, [])
        }
        var places: [(VectorPlace, Double, Double)] = []
        var lineCount = 0
        let tileMeters = Double(manifest.tileSize) * level.resolution
        let visibleZoom = semanticZoom ?? level.z
        let lineLayersEnabled = renderLayers.roads || renderLayers.railways
            || renderLayers.waterways || renderLayers.boundaries || renderLayers.energy
        let layerOrder: [VectorLayer] = [
            .boundary, .waterway, .energy, .railway, .road,
        ]
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
                    zoom: UInt32(max(0, visibleZoom)),
                    kindMask: .max,
                    preset: 2
                )

                // Casings first, then cores: intersections retain the previous visual hierarchy.
                for layer in layerOrder where layerEnabled(layer, in: renderLayers) {
                    guard let layerSegments = tile.layers[layer] else { continue }
                    uniforms.layer = UInt32(layer.rawValue)
                    uniforms.kindMask = kindMask(for: layer, in: renderLayers)
                    uniforms.preset = preset(for: layer, in: renderLayers)
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
                    uniforms.kindMask = kindMask(for: layer, in: renderLayers)
                    uniforms.preset = preset(for: layer, in: renderLayers)
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
                for place in tile.places where effectiveMinimumZoom(for: place) <= visibleZoom
                    && labelKindEnabled(place.kind, in: renderLayers)
                {
                    let point = world(place.point)
                    places.append((place, point.x, point.y))
                }
            }
        }
        return (
            lineCount,
            layoutLabels(
                places, roadShields: roadShields, visibleZoom: visibleZoom,
                layers: renderLayers, viewport: viewport
            )
        )
    }

    private func layerEnabled(_ layer: VectorLayer, in layers: RenderLayers) -> Bool {
        switch layer {
        case .road: layers.roads
        case .railway: layers.railways
        case .waterway: layers.waterways
        case .boundary: layers.boundaries
        case .energy: layers.energy
        }
    }

    private func kindMask(for layer: VectorLayer, in layers: RenderLayers) -> UInt32 {
        switch layer {
        case .road: layers.roadKinds
        case .railway: layers.railwayKinds
        case .energy: layers.energyKinds
        case .waterway, .boundary: .max
        }
    }

    private func preset(for layer: VectorLayer, in layers: RenderLayers) -> UInt32 {
        switch layer {
        case .road: layers.roadPreset
        case .railway: layers.railwayPreset
        case .waterway: layers.waterwayPreset
        case .boundary: layers.boundaryPreset
        case .energy: layers.energyPreset
        }
    }

    private func labelKindEnabled(_ kind: UInt8, in layers: RenderLayers) -> Bool {
        if kind <= 6 { return layers.places }
        return layers.geonames && (layers.geonameKinds & (UInt32(1) << UInt32(kind))) != 0
    }

    private func effectiveMinimumZoom(for place: VectorPlace) -> Int {
        guard place.kind <= 6 else { return Int(place.minZoom) }
        let population = Int(place.population)
        let populationZoom: Int
        switch place.kind {
        case 1:
            populationZoom = population >= 500_000 ? 1 : population >= 100_000 ? 2 : population >= 20_000 ? 3 : 4
        case 2:
            populationZoom = population >= 50_000 ? 3 : population >= 10_000 ? 4 : 5
        case 3:
            populationZoom = population >= 5_000 ? 6 : 7
        case 4: populationZoom = 6
        case 5: populationZoom = 8
        default: populationZoom = 9
        }
        return max(Int(place.minZoom), populationZoom)
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
        roadShields: [RoadShield],
        visibleZoom: Int,
        layers: RenderLayers,
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
        let visibleBounds = CGRect(origin: .zero, size: viewport.logicalSize)
            .insetBy(dx: 6, dy: 6)
        if layers.roads {
            typealias ShieldCandidate = (shield: RoadShield, x: Double, y: Double)
            var grouped: [String: [ShieldCandidate]] = [:]
            for shield in roadShields where Int(shield.minZoom) <= visibleZoom {
                let kindBit = UInt32(1) << UInt32(shield.roadKind)
                guard layers.roadKinds & kindBit != 0 else { continue }
                let x = (shield.x - viewport.centerX) * viewport.pixelsPerMeter
                    + Double(viewport.logicalSize.width) / 2
                let y = (viewport.centerY - shield.y) * viewport.pixelsPerMeter
                    + Double(viewport.logicalSize.height) / 2
                guard visibleBounds.contains(CGPoint(x: x, y: y)) else { continue }
                grouped[shield.reference, default: []].append((shield, x, y))
            }
            let centerX = Double(viewport.logicalSize.width) / 2
            let centerY = Double(viewport.logicalSize.height) / 2
            let repetitions = visibleZoom <= 3 ? 1 : visibleZoom == 4 ? 2 : visibleZoom == 5 ? 3 : 4
            let spacing = visibleZoom <= 4 ? 250.0 : visibleZoom == 5 ? 220.0 : visibleZoom == 6 ? 200.0 : 180.0
            let references = grouped.keys.sorted { left, right in
                let leftA = left.hasPrefix("A "), rightA = right.hasPrefix("A ")
                if leftA != rightA { return leftA }
                let leftNumber = Int(left.dropFirst(2)) ?? .max
                let rightNumber = Int(right.dropFirst(2)) ?? .max
                return leftNumber == rightNumber ? left < right : leftNumber < rightNumber
            }
            var selected: [String: [ShieldCandidate]] = [:]
            for reference in references {
                let ordered = (grouped[reference] ?? []).sorted {
                    hypot($0.x - centerX, $0.y - centerY)
                        < hypot($1.x - centerX, $1.y - centerY)
                }
                for candidate in ordered {
                    let existing = selected[reference, default: []]
                    guard existing.count < repetitions else { break }
                    guard existing.allSatisfy({ hypot($0.x - candidate.x, $0.y - candidate.y) >= spacing }) else { continue }
                    selected[reference, default: []].append(candidate)
                }
            }
            let maximum = visibleZoom <= 2 ? 14 : visibleZoom == 3 ? 22 : visibleZoom == 4 ? 30 : 40
            routeRounds: for round in 0..<repetitions {
                for reference in references {
                    guard let route = selected[reference], round < route.count else { continue }
                    let candidate = route[round]
                    let width = max(20.0, Double(reference.count) * 5.2 + 7.0)
                    let rectangle = CGRect(
                        x: candidate.x - width / 2, y: candidate.y - 8,
                        width: width, height: 16
                    ).insetBy(dx: -8, dy: -6)
                    guard visibleBounds.contains(rectangle) else { continue }
                    guard !occupied.contains(where: { $0.intersects(rectangle) }) else { continue }
                    let shield = candidate.shield
                    let identity = "route|\(reference)|\(Int(shield.x / 100))|\(Int(shield.y / 100))"
                    occupied.append(rectangle)
                    labels.append(
                        MapLabel(
                            id: identity, name: reference,
                            point: CGPoint(x: candidate.x, y: candidate.y),
                            prominence: Double(shield.roadKind),
                            kind: reference.hasPrefix("A ") ? 13 : 14,
                            angleDegrees: 0
                        )
                    )
                    if labels.count >= maximum { break routeRounds }
                }
            }
        }
        for (place, worldX, worldY) in sorted {
            let x = (worldX - viewport.centerX) * viewport.pixelsPerMeter
                + Double(viewport.logicalSize.width) / 2
            let y = (viewport.centerY - worldY) * viewport.pixelsPerMeter
                + Double(viewport.logicalSize.height) / 2
            let identity = "\(place.name)|\(Int(worldX / 100))|\(Int(worldY / 100))"
            guard seen.insert(identity).inserted else { continue }
            let isLandscape = place.kind == 8
            let populationWidth = place.population >= 500_000 ? 9.2 : place.population >= 100_000 ? 8.2 : 7.0
            let characterWidth = isLandscape ? 9.5 : (place.kind >= 7 ? 7.5 : populationWidth)
            let width = min(
                isLandscape ? 220 : 190,
                max(34, Double(place.name.count) * characterWidth + 14)
            )
            let height = isLandscape ? 25.0 : 22.0
            let angle = 0.0
            let rotatedWidth = width
            let rotatedHeight = height
            let rectangle = CGRect(
                x: x - rotatedWidth / 2, y: y - rotatedHeight / 2,
                width: rotatedWidth, height: rotatedHeight
            ).insetBy(dx: -4, dy: -3)
            guard visibleBounds.contains(rectangle) else { continue }
            let conflicts = occupied.indices.filter { occupied[$0].intersects(rectangle) }
            guard conflicts.allSatisfy({ labels[$0].kind == 13 || labels[$0].kind == 14 }) else {
                continue
            }
            for index in conflicts.reversed() {
                occupied.remove(at: index)
                labels.remove(at: index)
            }
            occupied.append(rectangle)
            labels.append(
                MapLabel(
                    id: identity, name: place.name,
                    point: CGPoint(x: x, y: y), prominence: Double(place.population),
                    kind: place.kind, angleDegrees: angle
                )
            )
            if labels.count >= 80 { break }
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
