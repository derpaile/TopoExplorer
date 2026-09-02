import Foundation

private final class RasterQueryTile: NSObject {
    let land2015: Data
    let land2020: Data?
    let elevation: Data

    init(land2015: Data, land2020: Data?, elevation: Data) {
        self.land2015 = land2015
        self.land2020 = land2020
        self.elevation = elevation
    }
}

private struct PopulationGrid: Decodable {
    let version: Int
    let source: String
    let crs: String
    let bounds: [Double]
    let resolution: Double
    let width: Int
    let height: Int
    let tileSize: Int
    let suffix: String
    let totalPopulation: Int
    let tileSums: [String: Int]

    var left: Double { bounds[0] }
    var bottom: Double { bounds[1] }
    var right: Double { bounds[2] }
    var top: Double { bounds[3] }
}

final class RasterQueryService {
    private let manifest: MapManifest
    private let directory: URL
    private let level: MapManifest.Level
    private let cache = NSCache<NSString, RasterQueryTile>()
    private let thematicCache = NSCache<NSString, NSData>()
    private let populationCache = NSCache<NSString, NSData>()
    private let queue = DispatchQueue(label: "TopoExplorer.map-query", qos: .userInteractive)
    private let populationGrid: PopulationGrid?
    private lazy var placeRecords: [PlaceSearchRecord] = {
        let url = directory.appendingPathComponent("Vectors/places-index.json.z")
        guard
            let packed = try? Data(contentsOf: url, options: .mappedIfSafe),
            let data = ZlibDecoder.decodeUnknown(packed),
            let index = try? JSONDecoder().decode(PlaceSearchIndex.self, from: data)
        else { return [] }
        return index.places
    }()

    init(manifest: MapManifest, directory: URL) {
        self.manifest = manifest
        self.directory = directory
        level = manifest.levels.last!
        let metadataURL = directory.appendingPathComponent("Analysis/population.json")
        populationGrid = try? JSONDecoder().decode(
            PopulationGrid.self, from: Data(contentsOf: metadataURL)
        )
        cache.totalCostLimit = 48 * 1024 * 1024
        thematicCache.totalCostLimit = 48 * 1024 * 1024
        populationCache.totalCostLimit = 24 * 1024 * 1024
    }

    func queryStatistics(
        selection: MapSelection,
        year2020: Bool,
        thematic product: MapManifest.ThematicRaster?,
        completion: @escaping (AreaStatistics?, String?) -> Void
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            let clippedMinX = max(selection.minX, self.manifest.left)
            let clippedMinY = max(selection.minY, self.manifest.bottom)
            let clippedMaxX = min(selection.maxX, self.manifest.right)
            let clippedMaxY = min(selection.maxY, self.manifest.top)
            guard clippedMaxX > clippedMinX, clippedMaxY > clippedMinY else {
                DispatchQueue.main.async {
                    completion(nil, "Die Auswahl liegt außerhalb der Kartendaten.")
                }
                return
            }
            let clipped = MapSelection(
                x1: clippedMinX, y1: clippedMinY,
                x2: clippedMaxX, y2: clippedMaxY
            )

            let categorical = product.map { self.thematicStatistics(in: clipped, product: $0) }
                ?? self.landStatistics(in: clipped, year2020: year2020)
            let population = self.population(in: clipped)
            let statistics = AreaStatistics(
                selection: clipped,
                population: population.value,
                populationSource: self.populationGrid?.source,
                populationCoverage: population.coverage,
                sampledResolution: categorical.resolution,
                classes: categorical.classes,
                subjectName: product?.name ?? "Landbedeckung"
            )
            DispatchQueue.main.async { completion(statistics, nil) }
        }
    }

    private func thematicStatistics(
        in selection: MapSelection,
        product: MapManifest.ThematicRaster
    ) -> (resolution: Double, classes: [AreaClassStatistic]) {
        categoricalStatistics(in: selection, classes: product.classes) { key in
            self.thematicData(key, suffix: product.suffix)
        }
    }

    private func landStatistics(
        in selection: MapSelection, year2020: Bool
    ) -> (resolution: Double, classes: [AreaClassStatistic]) {
        categoricalStatistics(in: selection, classes: manifest.classes) { key in
            self.landData(key, year2020: year2020)
        }
    }

    private func categoricalStatistics(
        in selection: MapSelection,
        classes: [MapManifest.LandClass],
        dataForKey: (TileKey) -> Data?
    ) -> (resolution: Double, classes: [AreaClassStatistic]) {
        let maximumSamples = 900_000.0
        let selectedLevel = manifest.levels.reversed().first { candidate in
            ceil(selection.width / candidate.resolution)
                * ceil(selection.height / candidate.resolution) <= maximumSamples
        } ?? manifest.levels[0]
        let range = pixelRange(
            selection: selection,
            left: manifest.left,
            top: manifest.top,
            resolution: selectedLevel.resolution,
            width: selectedLevel.width,
            height: selectedLevel.height
        )
        var counts = Array(repeating: 0.0, count: 256)
        var sampled = 0.0
        guard !range.x.isEmpty, !range.y.isEmpty else {
            return (selectedLevel.resolution, [])
        }

        let firstTileX = range.x.lowerBound / manifest.tileSize
        let lastTileX = (range.x.upperBound - 1) / manifest.tileSize
        let firstTileY = range.y.lowerBound / manifest.tileSize
        let lastTileY = (range.y.upperBound - 1) / manifest.tileSize
        for tileY in firstTileY...lastTileY {
            for tileX in firstTileX...lastTileX {
                let key = TileKey(z: selectedLevel.z, x: tileX, y: tileY)
                guard let data = dataForKey(key) else { continue }
                let startX = max(range.x.lowerBound, tileX * manifest.tileSize)
                let endX = min(range.x.upperBound, (tileX + 1) * manifest.tileSize)
                let startY = max(range.y.lowerBound, tileY * manifest.tileSize)
                let endY = min(range.y.upperBound, (tileY + 1) * manifest.tileSize)
                for globalY in startY..<endY {
                    let localY = globalY - tileY * manifest.tileSize
                    let cellTop = manifest.top - Double(globalY) * selectedLevel.resolution
                    let cellBottom = cellTop - selectedLevel.resolution
                    let overlapHeight = max(
                        0, min(cellTop, selection.maxY) - max(cellBottom, selection.minY)
                    )
                    for globalX in startX..<endX {
                        let localX = globalX - tileX * manifest.tileSize
                        let cellLeft = manifest.left + Double(globalX) * selectedLevel.resolution
                        let cellRight = cellLeft + selectedLevel.resolution
                        let overlapWidth = max(
                            0, min(cellRight, selection.maxX) - max(cellLeft, selection.minX)
                        )
                        let weight = overlapWidth * overlapHeight
                            / (selectedLevel.resolution * selectedLevel.resolution)
                        let classID = Int(data[localY * manifest.tileSize + localX])
                        if counts.indices.contains(classID) { counts[classID] += weight }
                        sampled += weight
                    }
                }
            }
        }

        guard sampled > 0 else { return (selectedLevel.resolution, []) }
        let area = selection.squareKilometers
        let result = classes.compactMap { landClass -> AreaClassStatistic? in
            guard landClass.id != 0, counts[landClass.id] > 0 else { return nil }
            let share = counts[landClass.id] / sampled
            return AreaClassStatistic(
                classID: landClass.id,
                name: landClass.name,
                group: landClass.group ?? "Sonstige",
                squareKilometers: area * share,
                share: share
            )
        }.sorted { $0.squareKilometers > $1.squareKilometers }
        return (selectedLevel.resolution, result)
    }

    private func population(in selection: MapSelection) -> (value: Int?, coverage: Double) {
        guard
            let grid = populationGrid,
            grid.version == 1,
            grid.crs == manifest.crs,
            grid.bounds.count == 4
        else { return (nil, 0) }
        let clippedMinX = max(selection.minX, grid.left)
        let clippedMinY = max(selection.minY, grid.bottom)
        let clippedMaxX = min(selection.maxX, grid.right)
        let clippedMaxY = min(selection.maxY, grid.top)
        guard clippedMaxX > clippedMinX, clippedMaxY > clippedMinY else { return (nil, 0) }
        let clipped = MapSelection(
            x1: clippedMinX, y1: clippedMinY,
            x2: clippedMaxX, y2: clippedMaxY
        )
        let coverage = min(1, clipped.width * clipped.height / (selection.width * selection.height))
        let range = pixelRange(
            selection: clipped,
            left: grid.left,
            top: grid.top,
            resolution: grid.resolution,
            width: grid.width,
            height: grid.height
        )
        guard !range.x.isEmpty, !range.y.isEmpty else { return (nil, coverage) }
        let firstTileX = range.x.lowerBound / grid.tileSize
        let lastTileX = (range.x.upperBound - 1) / grid.tileSize
        let firstTileY = range.y.lowerBound / grid.tileSize
        let lastTileY = (range.y.upperBound - 1) / grid.tileSize
        var total = 0.0
        for tileY in firstTileY...lastTileY {
            for tileX in firstTileX...lastTileX {
                let tileLeft = grid.left + Double(tileX * grid.tileSize) * grid.resolution
                let tileRight = min(
                    grid.right,
                    grid.left + Double((tileX + 1) * grid.tileSize) * grid.resolution
                )
                let tileTop = grid.top - Double(tileY * grid.tileSize) * grid.resolution
                let tileBottom = max(
                    grid.bottom,
                    grid.top - Double((tileY + 1) * grid.tileSize) * grid.resolution
                )
                if clipped.minX <= tileLeft, clipped.maxX >= tileRight,
                   clipped.minY <= tileBottom, clipped.maxY >= tileTop
                {
                    total += Double(grid.tileSums["\(tileX)_\(tileY)"] ?? 0)
                    continue
                }
                guard let data = populationTile(x: tileX, y: tileY, grid: grid) else { continue }
                let startX = max(range.x.lowerBound, tileX * grid.tileSize)
                let endX = min(range.x.upperBound, (tileX + 1) * grid.tileSize)
                let startY = max(range.y.lowerBound, tileY * grid.tileSize)
                let endY = min(range.y.upperBound, (tileY + 1) * grid.tileSize)
                for globalY in startY..<endY {
                    let localY = globalY - tileY * grid.tileSize
                    let cellTop = grid.top - Double(globalY) * grid.resolution
                    let cellBottom = cellTop - grid.resolution
                    let overlapHeight = max(
                        0, min(cellTop, clipped.maxY) - max(cellBottom, clipped.minY)
                    )
                    for globalX in startX..<endX {
                        let localX = globalX - tileX * grid.tileSize
                        let offset = (localY * grid.tileSize + localX) * 2
                        let value = Int(data[offset]) | (Int(data[offset + 1]) << 8)
                        let cellLeft = grid.left + Double(globalX) * grid.resolution
                        let cellRight = cellLeft + grid.resolution
                        let overlapWidth = max(
                            0, min(cellRight, clipped.maxX) - max(cellLeft, clipped.minX)
                        )
                        let weight = overlapWidth * overlapHeight
                            / (grid.resolution * grid.resolution)
                        total += Double(value) * weight
                    }
                }
            }
        }
        return (Int(total.rounded()), coverage)
    }

    private func pixelRange(
        selection: MapSelection,
        left: Double,
        top: Double,
        resolution: Double,
        width: Int,
        height: Int
    ) -> (x: Range<Int>, y: Range<Int>) {
        let startX = min(width, max(0, Int(floor((selection.minX - left) / resolution))))
        let endX = min(width, max(startX, Int(ceil((selection.maxX - left) / resolution))))
        let startY = min(height, max(0, Int(floor((top - selection.maxY) / resolution))))
        let endY = min(height, max(startY, Int(ceil((top - selection.minY) / resolution))))
        return (startX..<endX, startY..<endY)
    }

    private func landData(_ key: TileKey, year2020: Bool) -> Data? {
        let levelDirectory = directory.appendingPathComponent("z\(key.z)", isDirectory: true)
        let selectedURL: URL
        if year2020, manifest.landcoverProduct == nil {
            let yearURL = levelDirectory.appendingPathComponent("\(key.filename).land2020.z")
            selectedURL = FileManager.default.fileExists(atPath: yearURL.path)
                ? yearURL
                : levelDirectory.appendingPathComponent("\(key.filename).\(manifest.landcoverSuffix)")
        } else {
            selectedURL = levelDirectory.appendingPathComponent("\(key.filename).\(manifest.landcoverSuffix)")
        }
        guard let packed = try? Data(contentsOf: selectedURL) else { return nil }
        return ZlibDecoder.decode(packed, expectedSize: manifest.tileSize * manifest.tileSize)
    }

    private func thematicData(_ key: TileKey, suffix: String) -> Data? {
        let cacheKey = "\(suffix)/\(key.z)/\(key.x)/\(key.y)" as NSString
        if let cached = thematicCache.object(forKey: cacheKey) { return cached as Data }
        var ancestor = key
        var difference = 0
        while ancestor.z >= 0 {
            let url = directory
                .appendingPathComponent("z\(ancestor.z)", isDirectory: true)
                .appendingPathComponent("\(ancestor.filename).\(suffix)")
            if
                let packed = try? Data(contentsOf: url),
                let source = ZlibDecoder.decode(
                    packed, expectedSize: manifest.tileSize * manifest.tileSize
                )
            {
                if difference == 0 {
                    thematicCache.setObject(source as NSData, forKey: cacheKey, cost: source.count)
                    return source
                }
                let factor = 1 << difference
                let offsetX = (key.x - ancestor.x * factor) * manifest.tileSize / factor
                let offsetY = (key.y - ancestor.y * factor) * manifest.tileSize / factor
                var expanded = Data(count: manifest.tileSize * manifest.tileSize)
                expanded.withUnsafeMutableBytes { destination in
                    guard let bytes = destination.bindMemory(to: UInt8.self).baseAddress else { return }
                    for y in 0..<manifest.tileSize {
                        let sourceY = min(
                            manifest.tileSize - 1,
                            offsetY + y / factor
                        )
                        for x in 0..<manifest.tileSize {
                            let sourceX = min(
                                manifest.tileSize - 1,
                                offsetX + x / factor
                            )
                            bytes[y * manifest.tileSize + x] = source[
                                sourceY * manifest.tileSize + sourceX
                            ]
                        }
                    }
                }
                thematicCache.setObject(
                    expanded as NSData, forKey: cacheKey, cost: expanded.count
                )
                return expanded
            }
            guard ancestor.z > 0 else { break }
            ancestor = TileKey(z: ancestor.z - 1, x: ancestor.x / 2, y: ancestor.y / 2)
            difference += 1
        }
        return nil
    }

    private func populationTile(x: Int, y: Int, grid: PopulationGrid) -> Data? {
        let key = "\(x)_\(y)" as NSString
        if let cached = populationCache.object(forKey: key) { return cached as Data }
        let url = directory.appendingPathComponent(
            "Analysis/\(x)_\(y).\(grid.suffix)"
        )
        guard
            let packed = try? Data(contentsOf: url),
            let decoded = ZlibDecoder.decode(
                packed, expectedSize: grid.tileSize * grid.tileSize * 2
            )
        else { return nil }
        populationCache.setObject(decoded as NSData, forKey: key, cost: decoded.count)
        return decoded
    }

    func query(
        worldX: Double,
        worldY: Double,
        year2020: Bool,
        thematic product: MapManifest.ThematicRaster?,
        completion: @escaping (MapProbe) -> Void
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            let result = self.probe(
                worldX: worldX, worldY: worldY,
                year2020: year2020, thematic: product
            )
            DispatchQueue.main.async { completion(result) }
        }
    }

    func queryLandscapeContext(
        around probe: MapProbe,
        radiusMeters: Double,
        year2020: Bool,
        thematic product: MapManifest.ThematicRaster?,
        completion: @escaping (LandscapeContext?, String?) -> Void
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            let radius = min(25_000, max(500, radiusMeters))
            let targetSpacing = max(self.level.resolution * 4, radius / 12)
            let steps = min(18, max(4, Int(ceil(radius / targetSpacing))))
            let spacing = radius / Double(steps)
            var samples: [MapProbe] = []
            var planned = 0
            samples.reserveCapacity((steps * 2 + 1) * (steps * 2 + 1))
            for row in -steps...steps {
                for column in -steps...steps {
                    let offsetX = Double(column) * spacing
                    let offsetY = Double(row) * spacing
                    guard offsetX * offsetX + offsetY * offsetY <= radius * radius else { continue }
                    planned += 1
                    let sample = self.probe(
                        worldX: probe.worldX + offsetX,
                        worldY: probe.worldY + offsetY,
                        year2020: year2020,
                        thematic: product
                    )
                    if sample.classID != nil { samples.append(sample) }
                }
            }
            guard !samples.isEmpty else {
                DispatchQueue.main.async {
                    completion(nil, "In diesem Radius sind keine Landschaftsdaten verfügbar.")
                }
                return
            }
            let population = self.population(
                inCircleAtX: probe.worldX, y: probe.worldY, radius: radius
            )
            let namedFeatures = self.namedFeatures(
                inCircleAtX: probe.worldX, y: probe.worldY, radius: radius
            )
            let context = LandscapeContext(
                centerX: probe.worldX, centerY: probe.worldY,
                radiusMeters: radius, sampledResolution: spacing,
                plannedSampleCount: planned, probes: samples,
                population: population,
                populationSource: population == nil ? nil : self.populationGrid?.source,
                namedFeatures: namedFeatures
            )
            DispatchQueue.main.async { completion(context, nil) }
        }
    }

    func queryProfile(
        selection: MapProfileSelection,
        year2020: Bool,
        thematic product: MapManifest.ThematicRaster?,
        completion: @escaping (LandscapeProfile?, String?) -> Void
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            let distance = selection.distanceMeters
            guard distance >= self.level.resolution * 2 else {
                DispatchQueue.main.async {
                    completion(nil, "Ziehe eine längere Profillinie.")
                }
                return
            }
            let desiredSpacing = max(self.level.resolution * 4, distance / 239)
            let sampleCount = min(240, max(2, Int(ceil(distance / desiredSpacing)) + 1))
            var samples: [LandscapeProfileSample] = []
            samples.reserveCapacity(sampleCount)
            for index in 0..<sampleCount {
                let fraction = Double(index) / Double(sampleCount - 1)
                let point = selection.point(at: fraction)
                let probe = self.probe(
                    worldX: point.x, worldY: point.y,
                    year2020: year2020, thematic: product
                )
                samples.append(
                    LandscapeProfileSample(
                        distanceMeters: distance * fraction,
                        elevation: probe.elevation,
                        classID: probe.classID,
                        className: probe.className,
                        classGroup: probe.classGroup,
                        thematicClassName: probe.thematic?.className
                    )
                )
            }
            guard samples.compactMap(\.elevation).count >= 2 else {
                DispatchQueue.main.async {
                    completion(nil, "Die Profillinie liegt außerhalb der verfügbaren Kartendaten.")
                }
                return
            }
            let result = LandscapeProfile(selection: selection, samples: samples)
            DispatchQueue.main.async { completion(result, nil) }
        }
    }

    private func probe(
        worldX: Double,
        worldY: Double,
        year2020: Bool,
        thematic product: MapManifest.ThematicRaster?
    ) -> MapProbe {
        guard
            worldX >= manifest.left, worldX < manifest.right,
            worldY >= manifest.bottom, worldY < manifest.top
        else { return emptyProbe(worldX: worldX, worldY: worldY) }
        let pixelX = Int((worldX - manifest.left) / level.resolution)
        let pixelY = Int((manifest.top - worldY) / level.resolution)
        let tileX = pixelX / manifest.tileSize
        let tileY = pixelY / manifest.tileSize
        let localX = pixelX % manifest.tileSize
        let localY = pixelY % manifest.tileSize
        let key = TileKey(z: level.z, x: tileX, y: tileY)
        guard let tile = tile(key) else { return emptyProbe(worldX: worldX, worldY: worldY) }
        let land = year2020 ? (tile.land2020 ?? tile.land2015) : tile.land2015
        let classID = Int(land[localY * manifest.tileSize + localX])
        let elevationTileSize = manifest.elevationTileSize(at: level)
        let elevationSize = elevationTileSize + manifest.elevationBorder * 2
        let elevationX = min(
            elevationTileSize - 1,
            localX * elevationTileSize / manifest.tileSize
        ) + manifest.elevationBorder
        let elevationY = min(
            elevationTileSize - 1,
            localY * elevationTileSize / manifest.tileSize
        ) + manifest.elevationBorder
        let elevationOffset = (elevationY * elevationSize + elevationX) * 2
        let encoded = UInt16(tile.elevation[elevationOffset])
            | (UInt16(tile.elevation[elevationOffset + 1]) << 8)
        let normalized = Double(encoded) / 65_535
        let meters = manifest.elevationMin
            + normalized * (manifest.elevationMax - manifest.elevationMin)
        let terrainResolution = level.resolution * Double(manifest.tileSize)
            / Double(elevationTileSize)
        let terrain = terrainMetrics(
            data: tile.elevation,
            x: elevationX,
            y: elevationY,
            size: elevationSize,
            cellSize: terrainResolution
        )
        let landClass = manifest.classes.first(where: { $0.id == classID })
        let thematicProbe: ThematicProbe?
        if let product, let thematic = thematicData(key, suffix: product.suffix) {
            let thematicID = Int(thematic[localY * manifest.tileSize + localX])
            let thematicClass = product.classes.first { $0.id == thematicID }
            let quality = thematicData(key, suffix: product.qualitySuffix)
            let sourceIndex = quality.map {
                Int($0[localY * manifest.tileSize + localX])
            } ?? 0
            let source = sourceIndex > 0 && product.sources.indices.contains(sourceIndex - 1)
                ? product.sources[sourceIndex - 1] : nil
            thematicProbe = thematicID == 0 || thematicClass == nil ? nil : ThematicProbe(
                productID: product.id,
                productName: product.name,
                classID: thematicID,
                className: thematicClass!.name,
                sourceName: source?.name,
                sourceScale: source?.scale
            )
        } else {
            thematicProbe = nil
        }
        return MapProbe(
            worldX: worldX, worldY: worldY,
            elevation: classID == 0 ? nil : Int(meters.rounded()),
            classID: classID == 0 ? nil : classID,
            className: classID == 0 ? nil : landClass?.name,
            classGroup: classID == 0 ? nil : landClass?.group,
            thematic: thematicProbe,
            slopeDegrees: classID == 0 ? nil : terrain.slope,
            aspectDegrees: classID == 0 ? nil : terrain.aspect,
            terrainResolutionMeters: classID == 0 ? nil : terrainResolution
        )
    }

    private func terrainMetrics(
        data: Data,
        x: Int,
        y: Int,
        size: Int,
        cellSize: Double
    ) -> (slope: Double, aspect: Double?) {
        func height(_ dx: Int, _ dy: Int) -> Double {
            let offset = ((y + dy) * size + x + dx) * 2
            let encoded = UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
            return manifest.elevationMin
                + Double(encoded) / 65_535 * (manifest.elevationMax - manifest.elevationMin)
        }
        let northWest = height(-1, -1)
        let north = height(0, -1)
        let northEast = height(1, -1)
        let west = height(-1, 0)
        let east = height(1, 0)
        let southWest = height(-1, 1)
        let south = height(0, 1)
        let southEast = height(1, 1)
        let eastward = ((northEast + 2 * east + southEast)
            - (northWest + 2 * west + southWest)) / (8 * cellSize)
        let northward = ((northWest + 2 * north + northEast)
            - (southWest + 2 * south + southEast)) / (8 * cellSize)
        let slope = atan(hypot(eastward, northward)) * 180 / .pi
        guard slope >= 0.05 else { return (slope, nil) }
        var aspect = atan2(-eastward, -northward) * 180 / .pi
        if aspect < 0 { aspect += 360 }
        return (slope, aspect)
    }

    private func population(inCircleAtX centerX: Double, y centerY: Double, radius: Double) -> Int? {
        guard
            let grid = populationGrid,
            grid.version == 1,
            grid.crs == manifest.crs,
            grid.bounds.count == 4
        else { return nil }
        let bounds = MapSelection(
            x1: max(grid.left, centerX - radius),
            y1: max(grid.bottom, centerY - radius),
            x2: min(grid.right, centerX + radius),
            y2: min(grid.top, centerY + radius)
        )
        guard bounds.width > 0, bounds.height > 0 else { return nil }
        let range = pixelRange(
            selection: bounds,
            left: grid.left,
            top: grid.top,
            resolution: grid.resolution,
            width: grid.width,
            height: grid.height
        )
        guard !range.x.isEmpty, !range.y.isEmpty else { return nil }
        let radiusSquared = radius * radius
        var total = 0
        var readableCells = 0
        let firstTileX = range.x.lowerBound / grid.tileSize
        let lastTileX = (range.x.upperBound - 1) / grid.tileSize
        let firstTileY = range.y.lowerBound / grid.tileSize
        let lastTileY = (range.y.upperBound - 1) / grid.tileSize
        for tileY in firstTileY...lastTileY {
            for tileX in firstTileX...lastTileX {
                guard let data = populationTile(x: tileX, y: tileY, grid: grid) else { continue }
                let startX = max(range.x.lowerBound, tileX * grid.tileSize)
                let endX = min(range.x.upperBound, (tileX + 1) * grid.tileSize)
                let startY = max(range.y.lowerBound, tileY * grid.tileSize)
                let endY = min(range.y.upperBound, (tileY + 1) * grid.tileSize)
                for globalY in startY..<endY {
                    let dy = grid.top - (Double(globalY) + 0.5) * grid.resolution - centerY
                    let localY = globalY - tileY * grid.tileSize
                    for globalX in startX..<endX {
                        let dx = grid.left + (Double(globalX) + 0.5) * grid.resolution - centerX
                        guard dx * dx + dy * dy <= radiusSquared else { continue }
                        let localX = globalX - tileX * grid.tileSize
                        let offset = (localY * grid.tileSize + localX) * 2
                        total += Int(data[offset]) | (Int(data[offset + 1]) << 8)
                        readableCells += 1
                    }
                }
            }
        }
        return readableCells > 0 ? total : nil
    }

    private func namedFeatures(
        inCircleAtX centerX: Double,
        y centerY: Double,
        radius: Double
    ) -> [LandscapeContextFeature] {
        let candidates = placeRecords.compactMap { record -> LandscapeContextFeature? in
            let dx = record.worldX - centerX
            let dy = record.worldY - centerY
            let distance = hypot(dx, dy)
            guard distance <= radius else { return nil }
            var direction = atan2(dx, dy) * 180 / .pi
            if direction < 0 { direction += 360 }
            return LandscapeContextFeature(
                name: record.name,
                kind: record.kind,
                population: record.population > 0 ? record.population : nil,
                worldX: record.worldX,
                worldY: record.worldY,
                distanceMeters: distance,
                directionDegrees: direction
            )
        }.sorted { $0.distanceMeters < $1.distanceMeters }

        var selected: [LandscapeContextFeature] = []
        var categories = Set<Int>()
        for candidate in candidates {
            let category = candidate.kind <= 6 ? 0 : candidate.kind
            guard categories.insert(category).inserted else { continue }
            selected.append(candidate)
            if selected.count == 5 { break }
        }
        if selected.count < 5 {
            let selectedIDs = Set(selected.map(\.id))
            selected.append(contentsOf: candidates.filter { !selectedIDs.contains($0.id) }
                .prefix(5 - selected.count))
        }
        return selected.sorted { $0.distanceMeters < $1.distanceMeters }
    }

    private func emptyProbe(worldX: Double, worldY: Double) -> MapProbe {
        MapProbe(
            worldX: worldX, worldY: worldY,
            elevation: nil, classID: nil, className: nil, classGroup: nil,
            thematic: nil
        )
    }

    private func tile(_ key: TileKey) -> RasterQueryTile? {
        if let cached = cache.object(forKey: key.cacheKey) { return cached }
        let levelDirectory = directory.appendingPathComponent("z\(key.z)", isDirectory: true)
        let elevationTileSize = manifest.elevationTileSize(at: level)
        let elevationSize = elevationTileSize + manifest.elevationBorder * 2
        guard
            let packedLand = try? Data(contentsOf: levelDirectory.appendingPathComponent(
                "\(key.filename).\(manifest.landcoverSuffix)"
            )),
            let packedElevation = try? Data(contentsOf: levelDirectory.appendingPathComponent("\(key.filename).elev.z")),
            let land2015 = ZlibDecoder.decode(
                packedLand, expectedSize: manifest.tileSize * manifest.tileSize
            ),
            let elevation = ZlibDecoder.decode(
                packedElevation,
                expectedSize: elevationSize * elevationSize * 2
            )
        else { return nil }
        let land2020: Data? = manifest.landcoverProduct == nil
            ? (try? Data(contentsOf: levelDirectory.appendingPathComponent("\(key.filename).land2020.z")))
                .flatMap { ZlibDecoder.decode($0, expectedSize: manifest.tileSize * manifest.tileSize) }
            : nil
        let tile = RasterQueryTile(land2015: land2015, land2020: land2020, elevation: elevation)
        cache.setObject(tile, forKey: key.cacheKey, cost: land2015.count + elevation.count + (land2020?.count ?? 0))
        return tile
    }
}
