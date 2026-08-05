import XCTest
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
}
