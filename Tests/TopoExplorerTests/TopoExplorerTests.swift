import XCTest
import zlib
@testable import TopoExplorer

final class TopoExplorerTests: XCTestCase {
    func testManifestValidation() throws {
        let levels = [
            MapManifest.Level(z: 0, resolution: 100, width: 10, height: 20, tilesX: 1, tilesY: 1),
            MapManifest.Level(z: 1, resolution: 50, width: 20, height: 40, tilesX: 1, tilesY: 1),
        ]
        let classes = (0...7).map { MapManifest.LandClass(id: $0, name: "Klasse \($0)", defaultColor: "#000000") }
        let manifest = MapManifest(
            version: 1,
            name: "Test",
            crs: "EPSG:3035",
            bounds: [0, 0, 100, 200],
            tileSize: 512,
            elevationBorder: 1,
            minZoom: 0,
            maxZoom: 1,
            elevationMin: -10,
            elevationMax: 3500,
            compression: "zlib",
            levels: levels,
            classes: classes
        )
        XCTAssertNoThrow(try manifest.validated())
    }

    func testHexColor() {
        let color = RGBAColor(hex: "#CC0B1E")
        XCTAssertEqual(color.red, 204.0 / 255.0, accuracy: 0.0001)
        XCTAssertEqual(color.green, 11.0 / 255.0, accuracy: 0.0001)
        XCTAssertEqual(color.blue, 30.0 / 255.0, accuracy: 0.0001)
    }

    func testSurfaceTextureManifestAndZoomFade() throws {
        let levels = [
            MapManifest.Level(z: 0, resolution: 320, width: 32, height: 32, tilesX: 1, tilesY: 1),
            MapManifest.Level(z: 1, resolution: 160, width: 64, height: 64, tilesX: 1, tilesY: 1),
            MapManifest.Level(z: 2, resolution: 80, width: 128, height: 128, tilesX: 1, tilesY: 1),
            MapManifest.Level(z: 3, resolution: 40, width: 256, height: 256, tilesX: 1, tilesY: 1),
            MapManifest.Level(z: 4, resolution: 20, width: 512, height: 512, tilesX: 1, tilesY: 1),
            MapManifest.Level(z: 5, resolution: 10, width: 1024, height: 1024, tilesX: 2, tilesY: 2),
        ]
        let classes = (0...7).map {
            MapManifest.LandClass(id: $0, name: "Klasse \($0)", defaultColor: "#000000")
        }
        var manifest = MapManifest(
            version: 1, name: "Test", crs: "EPSG:3035", bounds: [0, 0, 10_240, 10_240],
            tileSize: 512, elevationBorder: 1, minZoom: 0, maxZoom: 5,
            elevationMin: -10, elevationMax: 3500, compression: "zlib",
            levels: levels, classes: classes
        )
        manifest.surfaceTexture = MapManifest.SurfaceTexture(
            suffix: "surface.z", minZoom: 1, maxZoom: 5, defaultStrength: 0.08,
            fullStrengthResolution: 20, hiddenResolution: 320,
            classWeights: [0, 0.4, 0.4, 0.4, 0, 0.7, 0.6, 1]
        )
        XCTAssertNoThrow(try manifest.validated())
        XCTAssertEqual(manifest.surfaceZoomWeight(at: levels[0]), 0)
        XCTAssertGreaterThan(manifest.surfaceZoomWeight(at: levels[2]), 0)
        XCTAssertLessThan(manifest.surfaceZoomWeight(at: levels[2]), 1)
        XCTAssertEqual(manifest.surfaceZoomWeight(at: levels[4]), 1)
        XCTAssertEqual(manifest.surfaceZoomWeight(at: levels[5]), 1)
    }

    func testThematicManifestValidation() throws {
        let levels = [
            MapManifest.Level(z: 0, resolution: 10, width: 1, height: 1, tilesX: 1, tilesY: 1),
        ]
        let classes = (0...7).map {
            MapManifest.LandClass(id: $0, name: "Klasse \($0)", defaultColor: "#000000")
        }
        var manifest = MapManifest(
            version: 1, name: "Test", crs: "EPSG:3035", bounds: [0, 0, 10, 10],
            tileSize: 512, elevationBorder: 1, minZoom: 0, maxZoom: 0,
            elevationMin: -10, elevationMax: 3500, compression: "zlib",
            levels: levels, classes: classes
        )
        manifest.thematicRasters = [
            MapManifest.ThematicRaster(
                id: "geology", name: "Geologie", suffix: "geology.z",
                qualitySuffix: "geology.quality.z",
                classes: [
                    MapManifest.LandClass(id: 0, name: "Keine Daten", defaultColor: "#000000"),
                    MapManifest.LandClass(id: 1, name: "Kalkstein", defaultColor: "#CCDDEE"),
                ],
                sources: []
            ),
        ]
        XCTAssertNoThrow(try manifest.validated())
        XCTAssertEqual(manifest.availableThematicRasters[0].palette.count, 256)
    }

    func testTVT2RemovedFeatureLayerIsIgnored() throws {
        var raw = Data("TVT2".utf8)
        raw.appendLittleEndian(UInt16(2))
        raw.appendLittleEndian(UInt16(8192))
        raw.appendLittleEndian(UInt16(128))
        raw.appendLittleEndian(UInt32(0))
        raw.appendLittleEndian(UInt32(0))
        raw.appendLittleEndian(UInt32(1))
        raw.append(contentsOf: [5, 1, 1, 0])
        raw.appendLittleEndian(UInt16(1))
        raw.appendLittleEndian(UInt16(4))
        raw.appendLittleEndian(UInt16(2))
        raw.appendLittleEndian(Int16(100))
        raw.appendLittleEndian(Int16(200))
        raw.append(Data("Mine{}".utf8))

        let tile = VectorTileDecoder.decode(try compressed(raw))
        XCTAssertNotNil(tile)
        XCTAssertTrue(tile?.layers.isEmpty == true)
    }

    func testEnergyMarkerDecoding() throws {
        var raw = Data("TVT1".utf8)
        raw.appendLittleEndian(UInt16(1))
        raw.appendLittleEndian(UInt16(8192))
        raw.appendLittleEndian(UInt16(128))
        raw.appendLittleEndian(UInt32(1))
        raw.appendLittleEndian(UInt32(0))
        raw.append(contentsOf: [8, 4, 5, 0])
        raw.appendLittleEndian(UInt16(2))
        raw.appendLittleEndian(UInt16(0))
        raw.appendLittleEndian(Int16(100))
        raw.appendLittleEndian(Int16(200))
        raw.appendLittleEndian(Int16(100))
        raw.appendLittleEndian(Int16(200))

        let tile = VectorTileDecoder.decode(try compressed(raw))
        XCTAssertEqual(tile?.layers[.energy]?.segmentCount, 1)
    }

    private func compressed(_ data: Data) throws -> Data {
        var result = Data(count: Int(compressBound(uLong(data.count))))
        var size = uLongf(result.count)
        let status = result.withUnsafeMutableBytes { destination in
            data.withUnsafeBytes { source in
                compress2(
                    destination.bindMemory(to: UInt8.self).baseAddress!, &size,
                    source.bindMemory(to: UInt8.self).baseAddress!, uLong(data.count), 6
                )
            }
        }
        XCTAssertEqual(status, Z_OK)
        result.count = Int(size)
        return result
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
