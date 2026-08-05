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

final class RasterQueryService {
    private let manifest: MapManifest
    private let directory: URL
    private let level: MapManifest.Level
    private let cache = NSCache<NSString, RasterQueryTile>()
    private let queue = DispatchQueue(label: "TopoExplorer.map-query", qos: .userInteractive)

    init(manifest: MapManifest, directory: URL) {
        self.manifest = manifest
        self.directory = directory
        level = manifest.levels.last!
        cache.totalCostLimit = 48 * 1024 * 1024
    }

    func query(worldX: Double, worldY: Double, year2020: Bool, completion: @escaping (MapProbe) -> Void) {
        guard
            worldX >= manifest.left, worldX < manifest.right,
            worldY >= manifest.bottom, worldY < manifest.top
        else {
            completion(MapProbe(worldX: worldX, worldY: worldY, elevation: nil, className: nil))
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
            let elevationSize = self.manifest.tileSize + 2
            let elevationOffset = ((localY + 1) * elevationSize + localX + 1) * 2
            let encoded = UInt16(tile.elevation[elevationOffset])
                | (UInt16(tile.elevation[elevationOffset + 1]) << 8)
            let normalized = Double(encoded) / 65_535
            let meters = self.manifest.elevationMin
                + normalized * (self.manifest.elevationMax - self.manifest.elevationMin)
            let className = self.manifest.classes.first(where: { $0.id == classID })?.name
            let result = MapProbe(
                worldX: worldX, worldY: worldY,
                elevation: classID == 0 ? nil : Int(meters.rounded()),
                className: classID == 0 ? nil : className
            )
            DispatchQueue.main.async { completion(result) }
        }
    }

    private func tile(_ key: TileKey) -> RasterQueryTile? {
        if let cached = cache.object(forKey: key.cacheKey) { return cached }
        let levelDirectory = directory.appendingPathComponent("z\(key.z)", isDirectory: true)
        guard
            let packedLand = try? Data(contentsOf: levelDirectory.appendingPathComponent("\(key.filename).land.z")),
            let packedElevation = try? Data(contentsOf: levelDirectory.appendingPathComponent("\(key.filename).elev.z")),
            let land2015 = ZlibDecoder.decode(
                packedLand, expectedSize: manifest.tileSize * manifest.tileSize
            ),
            let elevation = ZlibDecoder.decode(
                packedElevation,
                expectedSize: (manifest.tileSize + 2) * (manifest.tileSize + 2) * 2
            )
        else { return nil }
        let land2020URL = levelDirectory.appendingPathComponent("\(key.filename).land2020.z")
        let land2020 = (try? Data(contentsOf: land2020URL)).flatMap {
            ZlibDecoder.decode($0, expectedSize: manifest.tileSize * manifest.tileSize)
        }
        let tile = RasterQueryTile(land2015: land2015, land2020: land2020, elevation: elevation)
        cache.setObject(tile, forKey: key.cacheKey, cost: land2015.count + elevation.count + (land2020?.count ?? 0))
        return tile
    }
}
