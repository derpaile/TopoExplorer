import Foundation

struct MapManifest: Codable, Equatable {
    struct GeoSource: Codable, Equatable, Identifiable {
        let id: String
        let name: String
        let license: String
        let url: String
        var scale: Int? = nil
        var role: String? = nil
        var year: Int? = nil
    }

    enum DataCategory: String, CaseIterable, Identifiable, Hashable {
        case landscape
        case detail
        case geoscience
        case orientation

        var id: String { rawValue }
        var title: String {
            switch self {
            case .landscape: "Land & Relief"
            case .detail: "Feinstruktur"
            case .geoscience: "Fachkarten"
            case .orientation: "Orientierung"
            }
        }
        var symbolName: String {
            switch self {
            case .landscape: "leaf.fill"
            case .detail: "square.3.layers.3d.down.right"
            case .geoscience: "fossil.shell.fill"
            case .orientation: "point.bottomleft.forward.to.point.topright.scurvepath"
            }
        }
    }

    enum DataActivation: Equatable {
        case surface
        case surfaceTexture
        case thematic(String)
        case orientation
        case geonames
    }

    struct DataCatalogEntry: Identifiable, Equatable {
        let id: String
        let name: String
        let role: String
        let license: String
        let url: String
        let year: Int?
        let scale: Int?
        let category: DataCategory
        let productName: String?
        let activation: DataActivation

        var searchableText: String {
            [name, role, license, productName ?? "", year.map { String($0) } ?? ""]
                .joined(separator: " ")
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                .lowercased()
        }
    }

    struct ThematicRaster: Codable, Equatable, Identifiable {
        let id: String
        let name: String
        let suffix: String
        let qualitySuffix: String
        let classes: [LandClass]
        var sources: [GeoSource] = []

        var palette: [SIMD4<Float>] {
            var result = Array(repeating: SIMD4<Float>(0, 0, 0, 0), count: 256)
            for item in classes where result.indices.contains(item.id) {
                result[item.id] = RGBAColor(hex: item.defaultColor).vector
            }
            return result
        }
    }

    struct LandcoverProduct: Codable, Equatable {
        let name: String
        let suffix: String
    }

    struct LandcoverYear: Codable, Equatable, Identifiable {
        let year: Int
        let suffix: String
        var id: Int { year }
    }

    struct SurfaceTexture: Codable, Equatable {
        let suffix: String
        let minZoom: Int
        let maxZoom: Int
        let defaultStrength: Double
        let fullStrengthResolution: Double
        let hiddenResolution: Double
        let classWeights: [Double]
        var sources: [GeoSource] = []
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
    var thematicRasters: [ThematicRaster]? = nil
    var surfaceTexture: SurfaceTexture? = nil
    var vectorSources: [GeoSource]? = nil

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
    var availableThematicRasters: [ThematicRaster] {
        (thematicRasters ?? []).filter { $0.id != "resources" }
    }
    var surfaceClassWeights: [Float] {
        surfaceTexture?.classWeights.map(Float.init)
            ?? Array(repeating: 0, count: classes.count)
    }

    var dataCatalog: [DataCatalogEntry] {
        var entries = (sources ?? []).map { source in
            DataCatalogEntry(
                id: "land:\(source.id)", name: source.name, role: source.role,
                license: source.license, url: source.url, year: source.year, scale: nil,
                category: .landscape, productName: landcoverProduct?.name,
                activation: .surface
            )
        }
        if let surfaceTexture {
            entries += surfaceTexture.sources.map { source in
                DataCatalogEntry(
                    id: "detail:\(source.id)", name: source.name,
                    role: source.role ?? "Oberflächenstruktur", license: source.license,
                    url: source.url, year: source.year, scale: source.scale,
                    category: .detail, productName: "Reale Feinstruktur",
                    activation: .surfaceTexture
                )
            }
        }
        for product in availableThematicRasters {
            entries += product.sources.map { source in
                DataCatalogEntry(
                    id: "thematic:\(product.id):\(source.id)", name: source.name,
                    role: source.role ?? product.name, license: source.license,
                    url: source.url, year: source.year, scale: source.scale,
                    category: .geoscience, productName: product.name,
                    activation: .thematic(product.id)
                )
            }
        }
        entries += (vectorSources ?? []).map { source in
            DataCatalogEntry(
                id: "vector:\(source.id)", name: source.name,
                role: source.role ?? "Orientierung", license: source.license,
                url: source.url, year: source.year, scale: source.scale,
                category: .orientation, productName: nil,
                activation: source.id == "bkg-gn250" ? .geonames : .orientation
            )
        }
        return entries
    }

    func elevationTileSize(at level: Level) -> Int {
        level.elevationTileSize ?? tileSize
    }

    func surfaceZoomWeight(at level: Level) -> Float {
        guard
            let surfaceTexture,
            (surfaceTexture.minZoom...surfaceTexture.maxZoom).contains(level.z)
        else { return 0 }
        let full = surfaceTexture.fullStrengthResolution
        let hidden = surfaceTexture.hiddenResolution
        if level.resolution <= full { return 1 }
        if level.resolution >= hidden { return 0 }
        let position = log2(level.resolution / full) / log2(hidden / full)
        let smooth = position * position * (3 - 2 * position)
        return Float(1 - smooth)
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
        if let surfaceTexture {
            guard
                !surfaceTexture.suffix.isEmpty,
                (minZoom...maxZoom).contains(surfaceTexture.minZoom),
                (surfaceTexture.minZoom...maxZoom).contains(surfaceTexture.maxZoom),
                (0...0.60).contains(surfaceTexture.defaultStrength),
                surfaceTexture.fullStrengthResolution > 0,
                surfaceTexture.hiddenResolution > surfaceTexture.fullStrengthResolution,
                surfaceTexture.classWeights.count == classes.count,
                surfaceTexture.classWeights.allSatisfy({ (0...1).contains($0) })
            else { throw ManifestError.invalidSurfaceTexture }
        }
        let thematic = availableThematicRasters
        guard Set(thematic.map(\.id)).count == thematic.count,
              thematic.allSatisfy({ product in
                  !product.id.isEmpty && !product.name.isEmpty
                      && !product.suffix.isEmpty && !product.qualitySuffix.isEmpty
                      && !product.classes.isEmpty
                      && Set(product.classes.map(\.id)).count == product.classes.count
                      && product.classes.allSatisfy { (0...255).contains($0.id) }
              })
        else { throw ManifestError.invalidThematicRasters }
        if let vectorSources {
            guard
                Set(vectorSources.map(\.id)).count == vectorSources.count,
                vectorSources.allSatisfy({
                    !$0.id.isEmpty && !$0.name.isEmpty && !$0.license.isEmpty
                        && $0.url.hasPrefix("http")
                })
            else { throw ManifestError.invalidSources }
        }
        guard
            Set(dataCatalog.map(\.id)).count == dataCatalog.count,
            dataCatalog.allSatisfy({ !$0.name.isEmpty && $0.url.hasPrefix("http") })
        else { throw ManifestError.invalidSources }
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
    case invalidThematicRasters
    case invalidSurfaceTexture
    case invalidSources

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version): "Unbekannte Kartendaten-Version \(version)."
        case .invalidBounds: "Die Kartengrenzen sind ungültig."
        case .invalidTileLayout: "Das Kachelformat ist ungültig."
        case .unsupportedCompression(let compression): "Kompression \(compression) wird nicht unterstützt."
        case .invalidLevels: "Die Zoomstufen sind unvollständig."
        case .invalidClasses: "Die Landklassen sind unvollständig."
        case .invalidThematicRasters: "Die geowissenschaftlichen Rasterprodukte sind ungültig."
        case .invalidSurfaceTexture: "Die Oberflächentextur ist ungültig."
        case .invalidSources: "Der Datenquellen-Katalog ist ungültig."
        }
    }
}
