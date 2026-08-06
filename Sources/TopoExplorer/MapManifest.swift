import Foundation

struct MapManifest: Codable, Equatable {
    struct LandcoverProduct: Codable, Equatable {
        let name: String
        let suffix: String
    }

    struct LandcoverYear: Codable, Equatable, Identifiable {
        let year: Int
        let suffix: String
        var id: Int { year }
    }

    struct Level: Codable, Equatable, Identifiable {
        let z: Int
        let resolution: Double
        let width: Int
        let height: Int
        let tilesX: Int
        let tilesY: Int
        var elevationTileSize: Int? = nil

        var id: Int { z }
    }

    struct LandClass: Codable, Equatable, Identifiable {
        let id: Int
        let name: String
        let defaultColor: String
        var group: String? = nil
    }

    struct LandcoverSource: Codable, Equatable, Identifiable {
        let name: String
        let year: Int
        let role: String
        let license: String
        let url: String

        var id: String { "\(name)-\(year)" }
    }

    let version: Int
    let name: String
    let crs: String
    let bounds: [Double]
    let tileSize: Int
    let elevationBorder: Int
    let minZoom: Int
    let maxZoom: Int
    let elevationMin: Double
    let elevationMax: Double
    let compression: String
    let levels: [Level]
    let classes: [LandClass]
    var landcoverYears: [LandcoverYear]? = nil
    var landcoverProduct: LandcoverProduct? = nil
    var sources: [LandcoverSource]? = nil

    var left: Double { bounds[0] }
    var bottom: Double { bounds[1] }
    var right: Double { bounds[2] }
    var top: Double { bounds[3] }
    var width: Double { right - left }
    var height: Double { top - bottom }
    var landcoverSuffix: String { landcoverProduct?.suffix ?? "land.z" }
    var hasLandcover2020: Bool {
        landcoverProduct == nil && landcoverYears?.contains(where: { $0.year == 2020 }) == true
    }

    func elevationTileSize(at level: Level) -> Int {
        level.elevationTileSize ?? tileSize
    }

    func validated() throws -> MapManifest {
        guard version == 1 else { throw ManifestError.unsupportedVersion(version) }
        guard bounds.count == 4, right > left, top > bottom else { throw ManifestError.invalidBounds }
        guard tileSize > 0, elevationBorder == 1 else { throw ManifestError.invalidTileLayout }
        guard compression == "zlib" else { throw ManifestError.unsupportedCompression(compression) }
        guard !levels.isEmpty, levels.map(\.z) == Array(minZoom...maxZoom) else {
            throw ManifestError.invalidLevels
        }
        guard (1...MapStyleDocument.colorCount).contains(classes.count),
              classes.map(\.id) == Array(0..<classes.count) else {
            throw ManifestError.invalidClasses
        }
        guard levels.allSatisfy({ elevationTileSize(at: $0) > 0 }) else {
            throw ManifestError.invalidTileLayout
        }
        return self
    }
}

enum ManifestError: LocalizedError {
    case unsupportedVersion(Int)
    case invalidBounds
    case invalidTileLayout
    case unsupportedCompression(String)
    case invalidLevels
    case invalidClasses

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version): "Unbekannte Kartendaten-Version \(version)."
        case .invalidBounds: "Die Kartengrenzen sind ungültig."
        case .invalidTileLayout: "Das Kachelformat ist ungültig."
        case .unsupportedCompression(let compression): "Kompression \(compression) wird nicht unterstützt."
        case .invalidLevels: "Die Zoomstufen sind unvollständig."
        case .invalidClasses: "Die Landklassen sind unvollständig."
        }
    }
}
