import Foundation
import Metal
import zlib

struct TileKey: Hashable {
    let z: Int
    let x: Int
    let y: Int

    var filename: String { "\(x)_\(y)" }
    var cacheKey: NSString { "\(z)/\(x)/\(y)" as NSString }
}

final class TileTextures: NSObject {
    let landcover: MTLTexture
    let landcover2020: MTLTexture?
    let elevation: MTLTexture
    let byteCount: Int

    init(landcover: MTLTexture, landcover2020: MTLTexture?, elevation: MTLTexture, byteCount: Int) {
        self.landcover = landcover
        self.landcover2020 = landcover2020
        self.elevation = elevation
        self.byteCount = byteCount
    }
}

enum ZlibDecoder {
    static func decode(_ source: Data, expectedSize: Int) -> Data? {
        guard expectedSize > 0, !source.isEmpty else { return nil }
        var destination = Data(count: expectedSize)
        var destinationSize = uLongf(expectedSize)
        let decodedSize = destination.withUnsafeMutableBytes { destinationBytes in
            source.withUnsafeBytes { sourceBytes in
                guard
                    let destinationAddress = destinationBytes.bindMemory(to: UInt8.self).baseAddress,
                    let sourceAddress = sourceBytes.bindMemory(to: UInt8.self).baseAddress
                else { return 0 }
                let result = uncompress(
                    destinationAddress,
                    &destinationSize,
                    sourceAddress,
                    uLong(source.count)
                )
                return result == Z_OK ? Int(destinationSize) : 0
            }
        }
        guard decodedSize == expectedSize else { return nil }
        return destination
    }

    static func decodeUnknown(_ source: Data, initialSize: Int = 256 * 1024) -> Data? {
        guard !source.isEmpty else { return nil }
        var capacity = max(initialSize, source.count * 3)
        for _ in 0..<12 {
            var destination = Data(count: capacity)
            var destinationSize = uLongf(capacity)
            let result = destination.withUnsafeMutableBytes { destinationBytes in
                source.withUnsafeBytes { sourceBytes in
                    guard
                        let destinationAddress = destinationBytes.bindMemory(to: UInt8.self).baseAddress,
                        let sourceAddress = sourceBytes.bindMemory(to: UInt8.self).baseAddress
                    else { return Z_DATA_ERROR }
                    return uncompress(
                        destinationAddress,
                        &destinationSize,
                        sourceAddress,
                        uLong(source.count)
                    )
                }
            }
            if result == Z_OK {
                destination.count = Int(destinationSize)
                return destination
            }
            guard result == Z_BUF_ERROR else { return nil }
            capacity *= 2
        }
        return nil
    }
}

final class TileCache: NSObject, NSCacheDelegate {
    private let device: MTLDevice
    private let tileSize: Int
    private let elevationSize: Int
    private let landcoverSuffix: String
    private let cache = NSCache<NSString, TileTextures>()
    private let loadingQueue = DispatchQueue(label: "TopoExplorer.tile-loading", qos: .userInitiated, attributes: .concurrent)
    private let stateLock = NSLock()
    private var pending: [TileKey: DispatchWorkItem] = [:]
    private var failed = Set<TileKey>()
    private var generation = 0
    private var loadedCost = 0
    private var hitCount = 0
    private var missCount = 0

    init(device: MTLDevice, tileSize: Int, elevationBorder: Int, landcoverSuffix: String = "land.z") {
        self.device = device
        self.tileSize = tileSize
        self.landcoverSuffix = landcoverSuffix
        elevationSize = tileSize + elevationBorder * 2
        super.init()
        cache.totalCostLimit = 384 * 1024 * 1024
        cache.delegate = self
    }

    subscript(key: TileKey) -> TileTextures? {
        let value = cache.object(forKey: key.cacheKey)
        stateLock.lock()
        if value == nil { missCount &+= 1 } else { hitCount &+= 1 }
        stateLock.unlock()
        return value
    }

    func reset() {
        stateLock.lock()
        generation &+= 1
        pending.values.forEach { $0.cancel() }
        pending.removeAll()
        failed.removeAll()
        loadedCost = 0
        stateLock.unlock()
        cache.removeAllObjects()
    }

    func request(_ key: TileKey, from directory: URL, completion: @escaping () -> Void) {
        guard cache.object(forKey: key.cacheKey) == nil else { return }
        stateLock.lock()
        guard pending[key] == nil, !failed.contains(key) else {
            stateLock.unlock()
            return
        }
        let requestGeneration = generation
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.stateLock.lock()
            let shouldStart = self.pending[key]?.isCancelled == false
            self.stateLock.unlock()
            guard shouldStart else { return }
            let textures = self.load(key, from: directory)
            self.stateLock.lock()
            let wasCancelled = self.pending[key]?.isCancelled != false
            self.pending.removeValue(forKey: key)
            let isCurrent = requestGeneration == self.generation && !wasCancelled
            if textures == nil, isCurrent { self.failed.insert(key) }
            self.stateLock.unlock()

            guard isCurrent, let textures else { return }
            self.cache.setObject(textures, forKey: key.cacheKey, cost: textures.byteCount)
            self.stateLock.lock()
            self.loadedCost += textures.byteCount
            self.stateLock.unlock()
            DispatchQueue.main.async(execute: completion)
        }
        pending[key] = workItem
        stateLock.unlock()
        loadingQueue.async(execute: workItem)
    }

    func retainRequests(for keys: Set<TileKey>) {
        stateLock.lock()
        let obsolete = pending.filter { !keys.contains($0.key) }
        for (key, work) in obsolete {
            work.cancel()
            pending.removeValue(forKey: key)
        }
        stateLock.unlock()
    }

    func loadForExport(
        _ keys: [TileKey],
        from directory: URL,
        completion: @escaping (Result<[TileKey: TileTextures], Error>) -> Void
    ) {
        loadingQueue.async { [weak self] in
            guard let self else { return }
            var result: [TileKey: TileTextures] = [:]
            result.reserveCapacity(keys.count)
            for key in keys {
                guard let textures = self.cache.object(forKey: key.cacheKey) ?? self.load(key, from: directory) else {
                    DispatchQueue.main.async {
                        completion(.failure(TileCacheError.missing(key)))
                    }
                    return
                }
                result[key] = textures
            }
            DispatchQueue.main.async { completion(.success(result)) }
        }
    }

    var statistics: (megabytes: Double, pending: Int, hitRate: Double) {
        stateLock.lock()
        defer { stateLock.unlock() }
        let accesses = hitCount + missCount
        return (
            Double(max(0, loadedCost)) / 1_048_576,
            pending.count,
            accesses == 0 ? 1 : Double(hitCount) / Double(accesses)
        )
    }

    func cache(_ cache: NSCache<AnyObject, AnyObject>, willEvictObject object: Any) {
        guard let textures = object as? TileTextures else { return }
        stateLock.lock()
        loadedCost -= textures.byteCount
        stateLock.unlock()
    }

    private func load(_ key: TileKey, from directory: URL) -> TileTextures? {
        let levelDirectory = directory.appendingPathComponent("z\(key.z)", isDirectory: true)
        let landURL = levelDirectory.appendingPathComponent("\(key.filename).\(landcoverSuffix)")
        let land2020URL = levelDirectory.appendingPathComponent("\(key.filename).land2020.z")
        let elevationURL = levelDirectory.appendingPathComponent("\(key.filename).elev.z")
        guard
            let packedLand = try? Data(contentsOf: landURL, options: .mappedIfSafe),
            let packedElevation = try? Data(contentsOf: elevationURL, options: .mappedIfSafe),
            let land = ZlibDecoder.decode(packedLand, expectedSize: tileSize * tileSize),
            let elevation = ZlibDecoder.decode(
                packedElevation,
                expectedSize: elevationSize * elevationSize * MemoryLayout<UInt16>.size
            )
        else { return nil }
        let land2020 = landcoverSuffix == "land.z"
            ? (try? Data(contentsOf: land2020URL, options: .mappedIfSafe))
                .flatMap { ZlibDecoder.decode($0, expectedSize: tileSize * tileSize) }
            : nil

        let landDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r8Uint,
            width: tileSize,
            height: tileSize,
            mipmapped: false
        )
        landDescriptor.usage = .shaderRead
        landDescriptor.storageMode = .shared

        let elevationDescriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .r16Unorm,
            width: elevationSize,
            height: elevationSize,
            mipmapped: false
        )
        elevationDescriptor.usage = .shaderRead
        elevationDescriptor.storageMode = .shared

        guard
            let landTexture = device.makeTexture(descriptor: landDescriptor),
            let elevationTexture = device.makeTexture(descriptor: elevationDescriptor)
        else { return nil }
        let land2020Texture = land2020.flatMap { _ in device.makeTexture(descriptor: landDescriptor) }

        land.withUnsafeBytes { bytes in
            guard let address = bytes.baseAddress else { return }
            landTexture.replace(
                region: MTLRegionMake2D(0, 0, tileSize, tileSize),
                mipmapLevel: 0,
                withBytes: address,
                bytesPerRow: tileSize
            )
        }
        if let land2020, let land2020Texture {
            land2020.withUnsafeBytes { bytes in
                guard let address = bytes.baseAddress else { return }
                land2020Texture.replace(
                    region: MTLRegionMake2D(0, 0, tileSize, tileSize),
                    mipmapLevel: 0,
                    withBytes: address,
                    bytesPerRow: tileSize
                )
            }
        }
        elevation.withUnsafeBytes { bytes in
            guard let address = bytes.baseAddress else { return }
            elevationTexture.replace(
                region: MTLRegionMake2D(0, 0, elevationSize, elevationSize),
                mipmapLevel: 0,
                withBytes: address,
                bytesPerRow: elevationSize * MemoryLayout<UInt16>.size
            )
        }

        return TileTextures(
            landcover: landTexture,
            landcover2020: land2020Texture,
            elevation: elevationTexture,
            byteCount: land.count + (land2020?.count ?? 0) + elevation.count
        )
    }
}

private enum TileCacheError: LocalizedError {
    case missing(TileKey)

    var errorDescription: String? {
        switch self {
        case .missing(let key):
            "Rasterkachel z\(key.z)/\(key.x)/\(key.y) konnte nicht für den Export geladen werden."
        }
    }
}
