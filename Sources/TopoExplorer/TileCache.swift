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
    let elevation: MTLTexture
    let byteCount: Int

    init(landcover: MTLTexture, elevation: MTLTexture, byteCount: Int) {
        self.landcover = landcover
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
}

final class TileCache {
    private let device: MTLDevice
    private let tileSize: Int
    private let elevationSize: Int
    private let cache = NSCache<NSString, TileTextures>()
    private let loadingQueue = DispatchQueue(label: "TopoExplorer.tile-loading", qos: .userInitiated, attributes: .concurrent)
    private let stateLock = NSLock()
    private var pending = Set<TileKey>()
    private var failed = Set<TileKey>()
    private var generation = 0

    init(device: MTLDevice, tileSize: Int, elevationBorder: Int) {
        self.device = device
        self.tileSize = tileSize
        elevationSize = tileSize + elevationBorder * 2
        cache.totalCostLimit = 384 * 1024 * 1024
    }

    subscript(key: TileKey) -> TileTextures? {
        cache.object(forKey: key.cacheKey)
    }

    func reset() {
        stateLock.lock()
        generation &+= 1
        pending.removeAll()
        failed.removeAll()
        stateLock.unlock()
        cache.removeAllObjects()
    }

    func request(_ key: TileKey, from directory: URL, completion: @escaping () -> Void) {
        guard cache.object(forKey: key.cacheKey) == nil else { return }
        stateLock.lock()
        guard !pending.contains(key), !failed.contains(key) else {
            stateLock.unlock()
            return
        }
        pending.insert(key)
        let requestGeneration = generation
        stateLock.unlock()

        loadingQueue.async { [weak self] in
            guard let self else { return }
            let textures = self.load(key, from: directory)
            self.stateLock.lock()
            self.pending.remove(key)
            let isCurrent = requestGeneration == self.generation
            if textures == nil, isCurrent { self.failed.insert(key) }
            self.stateLock.unlock()

            guard isCurrent, let textures else { return }
            self.cache.setObject(textures, forKey: key.cacheKey, cost: textures.byteCount)
            DispatchQueue.main.async(execute: completion)
        }
    }

    private func load(_ key: TileKey, from directory: URL) -> TileTextures? {
        let levelDirectory = directory.appendingPathComponent("z\(key.z)", isDirectory: true)
        let landURL = levelDirectory.appendingPathComponent("\(key.filename).land.z")
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

        land.withUnsafeBytes { bytes in
            guard let address = bytes.baseAddress else { return }
            landTexture.replace(
                region: MTLRegionMake2D(0, 0, tileSize, tileSize),
                mipmapLevel: 0,
                withBytes: address,
                bytesPerRow: tileSize
            )
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
            elevation: elevationTexture,
            byteCount: land.count + elevation.count
        )
    }
}
