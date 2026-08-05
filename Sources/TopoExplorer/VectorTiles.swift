import Foundation
import Metal

enum VectorLayer: UInt8, CaseIterable {
    case road = 1
    case railway = 2
    case waterway = 3
    case boundary = 4
}

/// Twelve-byte, GPU-native line segment. Styling stays encoded in one word:
/// kind (bits 0...7), minimum zoom (8...15), flags (16...23).
struct VectorSegment {
    let start: SIMD2<Int16>
    let end: SIMD2<Int16>
    let attributes: UInt32
}

struct VectorSegmentBuffer {
    let buffer: MTLBuffer?
    let count: Int
    let byteCount: Int
}

struct VectorZoomSegments {
    let minimumZoom: Int
    let withCasing: VectorSegmentBuffer?
    let plain: VectorSegmentBuffer?
    let lineCount: Int

    var segmentCount: Int { (withCasing?.count ?? 0) + (plain?.count ?? 0) }
    var byteCount: Int { (withCasing?.byteCount ?? 0) + (plain?.byteCount ?? 0) }
}

struct VectorLayerSegments {
    let zoomLevels: [VectorZoomSegments]

    var lineCount: Int { zoomLevels.reduce(0) { $0 + $1.lineCount } }
    var segmentCount: Int { zoomLevels.reduce(0) { $0 + $1.segmentCount } }
    var byteCount: Int { zoomLevels.reduce(0) { $0 + $1.byteCount } }
}

struct VectorPlace {
    let kind: UInt8
    let minZoom: UInt8
    let point: SIMD2<Int16>
    let population: UInt32
    let name: String
}

final class VectorTile: NSObject {
    let extent: Int
    let buffer: Int
    let layers: [VectorLayer: VectorLayerSegments]
    let places: [VectorPlace]
    let byteCount: Int

    var lineCount: Int { layers.values.reduce(0) { $0 + $1.lineCount } }
    var segmentCount: Int { layers.values.reduce(0) { $0 + $1.segmentCount } }

    init(
        extent: Int,
        buffer: Int,
        layers: [VectorLayer: VectorLayerSegments],
        places: [VectorPlace]
    ) {
        self.extent = extent
        self.buffer = buffer
        self.layers = layers
        self.places = places
        let segmentBytes = layers.values.reduce(0) { $0 + $1.byteCount }
        let placeBytes = places.reduce(0) {
            $0 + MemoryLayout<VectorPlace>.stride + $1.name.utf8.count + 32
        }
        byteCount = segmentBytes + placeBytes + 512
    }
}

private struct VectorDataReader {
    let data: Data
    var offset = 0

    mutating func bytes(_ count: Int) throws -> Data {
        guard count >= 0, offset + count <= data.count else { throw VectorTileError.truncated }
        defer { offset += count }
        return data.subdata(in: offset..<(offset + count))
    }

    mutating func skip(_ count: Int) throws {
        guard count >= 0, offset + count <= data.count else { throw VectorTileError.truncated }
        offset += count
    }

    mutating func uint8() throws -> UInt8 {
        guard offset < data.count else { throw VectorTileError.truncated }
        defer { offset += 1 }
        return data[offset]
    }

    mutating func uint16() throws -> UInt16 {
        let low = UInt16(try uint8())
        return low | (UInt16(try uint8()) << 8)
    }

    mutating func int16() throws -> Int16 { Int16(bitPattern: try uint16()) }

    mutating func uint32() throws -> UInt32 {
        UInt32(try uint16()) | (UInt32(try uint16()) << 16)
    }

    mutating func string(_ count: Int) throws -> String {
        guard let value = String(data: try bytes(count), encoding: .utf8) else {
            throw VectorTileError.invalidText
        }
        return value
    }
}

enum VectorTileDecoder {
    static func decode(_ packed: Data, device: MTLDevice? = nil) -> VectorTile? {
        guard let data = ZlibDecoder.decodeUnknown(packed) else { return nil }
        do {
            var reader = VectorDataReader(data: data)
            guard try reader.string(4) == "TVT1" else { throw VectorTileError.format }
            guard try reader.uint16() == 1 else { throw VectorTileError.version }
            let extent = Int(try reader.uint16())
            let buffer = Int(try reader.uint16())
            let lineCount = Int(try reader.uint32())
            let placeCount = Int(try reader.uint32())
            guard extent > 0, lineCount < 1_000_000, placeCount < 1_000_000 else {
                throw VectorTileError.format
            }

            let zoomSlots = 256
            let groupCount = 5 * zoomSlots
            var casedSegments = Array(repeating: [VectorSegment](), count: groupCount)
            var plainSegments = Array(repeating: [VectorSegment](), count: groupCount)
            var lineCounts = Array(repeating: 0, count: groupCount)
            for _ in 0..<lineCount {
                guard let layer = VectorLayer(rawValue: try reader.uint8()) else {
                    throw VectorTileError.format
                }
                let kind = try reader.uint8()
                let minZoom = try reader.uint8()
                let flags = try reader.uint8()
                let pointCount = Int(try reader.uint16())
                let nameLength = Int(try reader.uint16())
                guard pointCount >= 2 else { throw VectorTileError.format }
                let attributes = UInt32(kind) | (UInt32(minZoom) << 8) | (UInt32(flags) << 16)
                let groupIndex = Int(layer.rawValue) * zoomSlots + Int(minZoom)
                let usesCasing = hasCasing(layer: layer, kind: kind)
                var previous = SIMD2(try reader.int16(), try reader.int16())
                for _ in 1..<pointCount {
                    let current = SIMD2(try reader.int16(), try reader.int16())
                    if current != previous {
                        let segment = VectorSegment(start: previous, end: current, attributes: attributes)
                        if usesCasing {
                            casedSegments[groupIndex].append(segment)
                        } else {
                            plainSegments[groupIndex].append(segment)
                        }
                    }
                    previous = current
                }
                try reader.skip(nameLength)
                lineCounts[groupIndex] += 1
            }

            var places: [VectorPlace] = []
            places.reserveCapacity(placeCount)
            for _ in 0..<placeCount {
                let kind = try reader.uint8()
                let minZoom = try reader.uint8()
                _ = try reader.uint16()
                let x = try reader.int16()
                let y = try reader.int16()
                let population = try reader.uint32()
                let nameLength = Int(try reader.uint16())
                places.append(
                    VectorPlace(
                        kind: kind, minZoom: minZoom, point: SIMD2(x, y),
                        population: population, name: try reader.string(nameLength)
                    )
                )
            }
            guard reader.offset == data.count else { throw VectorTileError.trailingData }

            var layers: [VectorLayer: VectorLayerSegments] = [:]
            for layer in VectorLayer.allCases {
                var zoomLevels: [VectorZoomSegments] = []
                for minimumZoom in 0..<zoomSlots {
                    let index = Int(layer.rawValue) * zoomSlots + minimumZoom
                    guard lineCounts[index] > 0 else { continue }
                    zoomLevels.append(
                        VectorZoomSegments(
                            minimumZoom: minimumZoom,
                            withCasing: try makeBuffer(casedSegments[index], device: device),
                            plain: try makeBuffer(plainSegments[index], device: device),
                            lineCount: lineCounts[index]
                        )
                    )
                }
                if !zoomLevels.isEmpty {
                    layers[layer] = VectorLayerSegments(zoomLevels: zoomLevels)
                }
            }
            return VectorTile(extent: extent, buffer: buffer, layers: layers, places: places)
        } catch {
            return nil
        }
    }

    private static func makeBuffer(
        _ segments: [VectorSegment],
        device: MTLDevice?
    ) throws -> VectorSegmentBuffer? {
        guard !segments.isEmpty else { return nil }
        let logicalBytes = segments.count * MemoryLayout<VectorSegment>.stride
        guard let device else {
            return VectorSegmentBuffer(buffer: nil, count: segments.count, byteCount: logicalBytes)
        }
        let buffer: MTLBuffer? = segments.withUnsafeBytes { bytes -> MTLBuffer? in
            guard let address = bytes.baseAddress else { return nil }
            return device.makeBuffer(bytes: address, length: bytes.count, options: .storageModeShared)
        }
        guard let buffer else { throw VectorTileError.gpuAllocation }
        buffer.label = "TopoExplorer vector segments"
        return VectorSegmentBuffer(
            buffer: buffer,
            count: segments.count,
            byteCount: max(logicalBytes, buffer.allocatedSize)
        )
    }

    private static func hasCasing(layer: VectorLayer, kind: UInt8) -> Bool {
        switch layer {
        case .road: kind <= 3
        case .railway, .boundary: true
        case .waterway: false
        }
    }
}

private enum VectorTileError: Error {
    case truncated
    case format
    case version
    case invalidText
    case trailingData
    case gpuAllocation
}

final class VectorTileCache: NSObject, NSCacheDelegate {
    private let device: MTLDevice
    private let cache = NSCache<NSString, VectorTile>()
    private let queue = DispatchQueue(
        label: "TopoExplorer.vector-loading",
        qos: .userInitiated,
        attributes: .concurrent
    )
    private let decodeSlots = DispatchSemaphore(value: 2)
    private let lock = NSLock()
    private var pending: [TileKey: DispatchWorkItem] = [:]
    private var missing = Set<TileKey>()
    private var loadedBytes = 0
    private var loadedTiles = 0

    init(device: MTLDevice) {
        self.device = device
        super.init()
        cache.totalCostLimit = 128 * 1024 * 1024
        cache.delegate = self
    }

    subscript(key: TileKey) -> VectorTile? { cache.object(forKey: key.cacheKey) }

    func request(_ key: TileKey, from directory: URL, completion: @escaping () -> Void) {
        guard cache.object(forKey: key.cacheKey) == nil else { return }
        lock.lock()
        guard pending[key] == nil, !missing.contains(key) else {
            lock.unlock()
            return
        }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.decodeSlots.wait()
            defer { self.decodeSlots.signal() }
            self.lock.lock()
            let shouldStart = self.pending[key]?.isCancelled == false
            self.lock.unlock()
            guard shouldStart else { return }
            let path = directory
                .appendingPathComponent("Vectors/z\(key.z)", isDirectory: true)
                .appendingPathComponent("\(key.filename).vector.z")
            let tile = (try? Data(contentsOf: path, options: .mappedIfSafe)).flatMap {
                VectorTileDecoder.decode($0, device: self.device)
            }
            self.lock.lock()
            let wasCancelled = self.pending[key]?.isCancelled != false
            self.pending.removeValue(forKey: key)
            if tile == nil, !wasCancelled { self.missing.insert(key) }
            if let tile, !wasCancelled {
                self.loadedBytes += tile.byteCount
                self.loadedTiles += 1
            }
            self.lock.unlock()
            if let tile, !wasCancelled {
                self.cache.setObject(tile, forKey: key.cacheKey, cost: tile.byteCount)
                DispatchQueue.main.async(execute: completion)
            }
        }
        pending[key] = work
        lock.unlock()
        queue.async(execute: work)
    }

    func retainRequests(for keys: Set<TileKey>) {
        lock.lock()
        let obsolete = pending.filter { !keys.contains($0.key) }
        for (key, work) in obsolete {
            work.cancel()
            pending.removeValue(forKey: key)
        }
        lock.unlock()
    }

    func loadForExport(
        _ keys: [TileKey],
        from directory: URL,
        completion: @escaping (Result<[TileKey: VectorTile], Error>) -> Void
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            self.decodeSlots.wait()
            defer { self.decodeSlots.signal() }
            var result: [TileKey: VectorTile] = [:]
            result.reserveCapacity(keys.count)
            for key in keys {
                if let cached = self.cache.object(forKey: key.cacheKey) {
                    result[key] = cached
                    continue
                }
                let path = directory
                    .appendingPathComponent("Vectors/z\(key.z)", isDirectory: true)
                    .appendingPathComponent("\(key.filename).vector.z")
                guard FileManager.default.fileExists(atPath: path.path) else { continue }
                guard
                    let packed = try? Data(contentsOf: path, options: .mappedIfSafe),
                    let tile = VectorTileDecoder.decode(packed, device: self.device)
                else {
                    DispatchQueue.main.async {
                        completion(.failure(VectorTileCacheError.invalid(key)))
                    }
                    return
                }
                result[key] = tile
            }
            DispatchQueue.main.async { completion(.success(result)) }
        }
    }

    var statistics: (tiles: Int, bytes: Int, pending: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (max(0, loadedTiles), max(0, loadedBytes), pending.count)
    }

    func cache(_ cache: NSCache<AnyObject, AnyObject>, willEvictObject object: Any) {
        guard let tile = object as? VectorTile else { return }
        lock.lock()
        loadedBytes -= tile.byteCount
        loadedTiles -= 1
        lock.unlock()
    }
}

private enum VectorTileCacheError: LocalizedError {
    case invalid(TileKey)

    var errorDescription: String? {
        switch self {
        case .invalid(let key):
            "Vektorkachel z\(key.z)/\(key.x)/\(key.y) konnte nicht für den Export geladen werden."
        }
    }
}
