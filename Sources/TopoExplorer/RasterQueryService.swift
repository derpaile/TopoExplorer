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
    private let populationCache = NSCache<NSString, NSData>()
    private let queue = DispatchQueue(label: "TopoExplorer.map-query", qos: .userInteractive)
    private let populationGrid: PopulationGrid?

    init(manifest: MapManifest, directory: URL) {
        self.manifest = manifest
        self.directory = directory
        level = manifest.levels.last!
        let metadataURL = directory.appendingPathComponent("Analysis/population.json")
        populationGrid = try? JSONDecoder().decode(
            PopulationGrid.self, from: Data(contentsOf: metadataURL)
        )
        cache.totalCostLimit = 48 * 1024 * 1024
        populationCache.totalCostLimit = 24 * 1024 * 1024
    }

    func queryStatistics(
        selection: MapSelection,
        year2020: Bool,
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

            let land = self.landStatistics(in: clipped, year2020: year2020)
            let population = self.population(in: clipped)
            let statistics = AreaStatistics(
                selection: clipped,
                population: population.value,
                populationSource: self.populationGrid?.source,
                populationCoverage: population.coverage,
                sampledResolution: land.resolution,
                classes: land.classes
            )
            DispatchQueue.main.async { completion(statistics, nil) }
        }
    }

    private func landStatistics(
        in selection: MapSelection, year2020: Bool
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
        var counts = Array(repeating: 0.0, count: manifest.classes.count)
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
                guard let data = landData(key, year2020: year2020) else { continue }
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
        let classes = manifest.classes.compactMap { landClass -> AreaClassStatistic? in
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
        return (selectedLevel.resolution, classes)
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

    func query(worldX: Double, worldY: Double, year2020: Bool, completion: @escaping (MapProbe) -> Void) {
        guard
            worldX >= manifest.left, worldX < manifest.right,
            worldY >= manifest.bottom, worldY < manifest.top
        else {
            completion(MapProbe(
                worldX: worldX, worldY: worldY,
                elevation: nil, classID: nil, className: nil
            ))
            return
        }
        let pixelX = Int((worldX - manifest.left) / level.resolution)
        let pixelY = Int((manifest.top - worldY) / level.resolution)
        let tileX = pixelX / manifest.tileSize
        let tileY = pixelY / manifest.tileSize
        let localX = pixelX % manifest.tileSize
        let localY = pixelY % manifest.tileSize
        let key = TileKey(z: level.z, x: tileX, y: tileY)
        queue.async { [weak self] in
            guard let self, let tile = self.tile(key) else { return }
            let land = year2020 ? (tile.land2020 ?? tile.land2015) : tile.land2015
            let classID = Int(land[localY * self.manifest.tileSize + localX])
            let elevationTileSize = self.manifest.elevationTileSize(at: self.level)
            let elevationSize = elevationTileSize + self.manifest.elevationBorder * 2
            let elevationX = min(
                elevationTileSize - 1,
                localX * elevationTileSize / self.manifest.tileSize
            ) + self.manifest.elevationBorder
            let elevationY = min(
                elevationTileSize - 1,
                localY * elevationTileSize / self.manifest.tileSize
            ) + self.manifest.elevationBorder
            let elevationOffset = (elevationY * elevationSize + elevationX) * 2
            let encoded = UInt16(tile.elevation[elevationOffset])
                | (UInt16(tile.elevation[elevationOffset + 1]) << 8)
            let normalized = Double(encoded) / 65_535
            let meters = self.manifest.elevationMin
                + normalized * (self.manifest.elevationMax - self.manifest.elevationMin)
            let className = self.manifest.classes.first(where: { $0.id == classID })?.name
            let result = MapProbe(
                worldX: worldX, worldY: worldY,
                elevation: classID == 0 ? nil : Int(meters.rounded()),
                classID: classID == 0 ? nil : classID,
                className: classID == 0 ? nil : className
            )
            DispatchQueue.main.async { completion(result) }
        }
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
