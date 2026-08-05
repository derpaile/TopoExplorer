import Foundation

struct MapManifest: Codable, Equatable {
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

        var id: Int { z }
    }

    struct LandClass: Codable, Equatable, Identifiable {
        let id: Int
        let name: String
        let defaultColor: String
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

    var left: Double { bounds[0] }
    var bottom: Double { bounds[1] }
    var right: Double { bounds[2] }
    var top: Double { bounds[3] }
    var width: Double { right - left }
    var height: Double { top - bottom }
    var hasLandcover2020: Bool { landcoverYears?.contains(where: { $0.year == 2020 }) == true }

    func validated() throws -> MapManifest {
        guard version == 1 else { throw ManifestError.unsupportedVersion(version) }
        guard bounds.count == 4, right > left, top > bottom else { throw ManifestError.invalidBounds }
        guard tileSize > 0, elevationBorder == 1 else { throw ManifestError.invalidTileLayout }
        guard compression == "zlib" else { throw ManifestError.unsupportedCompression(compression) }
        guard !levels.isEmpty, levels.map(\.z) == Array(minZoom...maxZoom) else {
            throw ManifestError.invalidLevels
        }
        guard classes.count == 8, classes.map(\.id) == Array(0...7) else {
            throw ManifestError.invalidClasses
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
        case .invalidClasses: "Die acht Landklassen sind unvollständig."
        }
    }
}
