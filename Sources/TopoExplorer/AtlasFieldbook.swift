import Foundation

enum ETRS89LAEA {
    private static let semiMajorAxis = 6_378_137.0
    private static let inverseFlattening = 298.257_222_101
    private static let falseEasting = 4_321_000.0
    private static let falseNorthing = 3_210_000.0
    private static let originLatitude = 52.0 * .pi / 180
    private static let originLongitude = 10.0 * .pi / 180
    private static let flattening = 1 / inverseFlattening
    private static let eccentricitySquared = 2 * flattening - flattening * flattening
    private static let eccentricity = sqrt(eccentricitySquared)
    private static let polarAuthalicQ = authalicQ(.pi / 2)
    private static let originAuthalicLatitude = asin(
        authalicQ(originLatitude) / polarAuthalicQ
    )
    private static let authalicRadius = semiMajorAxis * sqrt(polarAuthalicQ / 2)
    private static let originScale = {
        let sine = sin(originLatitude)
        let m = cos(originLatitude) / sqrt(1 - eccentricitySquared * sine * sine)
        return semiMajorAxis * m
            / (authalicRadius * cos(originAuthalicLatitude))
    }()

    static func toWGS84(easting: Double, northing: Double) -> (longitude: Double, latitude: Double)? {
        guard easting.isFinite, northing.isFinite else { return nil }
        let x = (easting - falseEasting) / originScale
        let y = (northing - falseNorthing) * originScale
        let radius = hypot(x, y)
        guard radius <= 2 * authalicRadius + 1 else { return nil }
        if radius < 1e-9 {
            return (originLongitude * 180 / .pi, originLatitude * 180 / .pi)
        }
        let angle = 2 * asin(min(1, radius / (2 * authalicRadius)))
        let sineAngle = sin(angle)
        let cosineAngle = cos(angle)
        let beta = asin(
            cosineAngle * sin(originAuthalicLatitude)
                + y * sineAngle * cos(originAuthalicLatitude) / radius
        )
        let longitude = originLongitude + atan2(
            x * sineAngle,
            radius * cos(originAuthalicLatitude) * cosineAngle
                - y * sin(originAuthalicLatitude) * sineAngle
        )
        guard let latitude = latitude(forAuthalicQ: polarAuthalicQ * sin(beta)) else {
            return nil
        }
        let result = (longitude * 180 / .pi, latitude * 180 / .pi)
        guard
            result.0.isFinite, result.1.isFinite,
            (-180...180).contains(result.0), (-90...90).contains(result.1)
        else { return nil }
        return result
    }

    static func fromWGS84(longitude: Double, latitude: Double) -> (easting: Double, northing: Double)? {
        guard
            longitude.isFinite, latitude.isFinite,
            (-180...180).contains(longitude), (-90...90).contains(latitude)
        else { return nil }
        let lambda = longitude * .pi / 180
        let phi = latitude * .pi / 180
        let beta = asin(authalicQ(phi) / polarAuthalicQ)
        let delta = lambda - originLongitude
        let denominator = 1
            + sin(originAuthalicLatitude) * sin(beta)
            + cos(originAuthalicLatitude) * cos(beta) * cos(delta)
        guard denominator > 0 else { return nil }
        let scale = authalicRadius * sqrt(2 / denominator)
        let easting = falseEasting
            + scale * originScale * cos(beta) * sin(delta)
        let northing = falseNorthing
            + scale / originScale
                * (cos(originAuthalicLatitude) * sin(beta)
                    - sin(originAuthalicLatitude) * cos(beta) * cos(delta))
        guard easting.isFinite, northing.isFinite else { return nil }
        return (easting, northing)
    }

    private static func authalicQ(_ latitude: Double) -> Double {
        let sine = sin(latitude)
        let eccentricSine = eccentricity * sine
        return (1 - eccentricitySquared) * (
            sine / (1 - eccentricitySquared * sine * sine)
                - log((1 - eccentricSine) / (1 + eccentricSine)) / (2 * eccentricity)
        )
    }

    private static func latitude(forAuthalicQ target: Double) -> Double? {
        guard target.isFinite, abs(target) <= polarAuthalicQ + 1e-10 else { return nil }
        var latitude = asin(max(-1, min(1, target / 2)))
        for _ in 0..<12 {
            let sine = sin(latitude)
            let derivative = 2 * (1 - eccentricitySquared) * cos(latitude)
                / pow(1 - eccentricitySquared * sine * sine, 2)
            guard abs(derivative) > 1e-12 else { break }
            let correction = (target - authalicQ(latitude)) / derivative
            latitude += correction
            if abs(correction) < 1e-13 { return latitude }
        }
        return latitude.isFinite ? latitude : nil
    }
}

struct AtlasFieldbookDocument: Codable, Equatable {
    static let currentVersion = 1

    struct Metadata: Codable, Equatable {
        let format: String
        let version: Int
        let generator: String
        let exportedAt: Date
        let coordinateReferenceSystem: String
        let sourceCoordinateReferenceSystem: String
        let sources: [Source]

        enum CodingKeys: String, CodingKey {
            case format, version, generator, sources
            case exportedAt = "exported_at"
            case coordinateReferenceSystem = "coordinate_reference_system"
            case sourceCoordinateReferenceSystem = "source_coordinate_reference_system"
        }
    }

    struct Source: Codable, Equatable {
        let id: String
        let name: String
        let role: String
        let license: String
        let url: String
        let year: Int?
        let scale: Int?
        let category: String

        init(_ entry: MapManifest.DataCatalogEntry) {
            id = entry.id
            name = entry.name
            role = entry.role
            license = entry.license
            url = entry.url
            year = entry.year
            scale = entry.scale
            category = entry.category.rawValue
        }
    }

    struct Feature: Codable, Equatable {
        let type: String
        let id: String?
        let geometry: Geometry?
        let properties: Properties?
    }

    struct Geometry: Codable, Equatable {
        let type: String
        let coordinates: [Double]?

        enum CodingKeys: String, CodingKey { case type, coordinates }

        init(longitude: Double, latitude: Double) {
            type = "Point"
            coordinates = [longitude, latitude]
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            type = try container.decode(String.self, forKey: .type)
            coordinates = try? container.decode([Double].self, forKey: .coordinates)
        }
    }

    struct Properties: Codable, Equatable {
        let topoExplorerVersion: Int?
        let bookmarkID: String?
        let name: String?
        let note: String?
        let observedAt: Date?
        let easting: Double?
        let northing: Double?
        let metersPerPoint: Double?
        let surface: String?
        let surfaceGroup: String?
        let elevation: Int?
        let slopeDegrees: Double?
        let aspectDegrees: Double?
        let terrainResolutionMeters: Double?
        let thematicClass: String?
        let contextTitle: String?
        let contextRadiusMeters: Double?
        let contextClassCount: Int?
        let contextElevationMinimum: Int?
        let contextElevationMaximum: Int?
        let contextMeanSlopeDegrees: Double?
        let contextPopulation: Int?
        let contextPopulationDensity: Double?
        let contextNearbyNames: String?
        let detail: MapBookmarkDetail?

        enum CodingKeys: String, CodingKey {
            case name, note, surface, elevation, detail
            case topoExplorerVersion = "topo_explorer_version"
            case bookmarkID = "bookmark_id"
            case observedAt = "observed_at"
            case easting = "epsg3035_easting"
            case northing = "epsg3035_northing"
            case metersPerPoint = "view_meters_per_point"
            case surfaceGroup = "surface_group"
            case slopeDegrees = "slope_degrees"
            case aspectDegrees = "aspect_degrees"
            case terrainResolutionMeters = "terrain_resolution_m"
            case thematicClass = "thematic_class"
            case contextTitle = "context_title"
            case contextRadiusMeters = "context_radius_m"
            case contextClassCount = "context_class_count"
            case contextElevationMinimum = "context_elevation_min_m"
            case contextElevationMaximum = "context_elevation_max_m"
            case contextMeanSlopeDegrees = "context_mean_slope_degrees"
            case contextPopulation = "context_population"
            case contextPopulationDensity = "context_population_per_km2"
            case contextNearbyNames = "context_nearby_names"
        }

        init(_ bookmark: MapBookmark) {
            let context = bookmark.detail?.landscapeContext
            topoExplorerVersion = AtlasFieldbookDocument.currentVersion
            bookmarkID = bookmark.id.uuidString
            name = bookmark.name
            note = bookmark.note
            observedAt = bookmark.createdAt
            easting = bookmark.centerX
            northing = bookmark.centerY
            metersPerPoint = bookmark.metersPerPoint
            surface = bookmark.detail?.surfaceName
            surfaceGroup = bookmark.detail?.surfaceGroup
            elevation = bookmark.detail?.elevation
            slopeDegrees = bookmark.detail?.slopeDegrees
            aspectDegrees = bookmark.detail?.aspectDegrees
            terrainResolutionMeters = bookmark.detail?.terrainResolutionMeters
            thematicClass = bookmark.detail?.thematicClassName
            contextTitle = context?.title
            contextRadiusMeters = context?.radiusMeters
            contextClassCount = context?.classes.count
            contextElevationMinimum = context?.minimumElevation
            contextElevationMaximum = context?.maximumElevation
            contextMeanSlopeDegrees = context?.meanSlopeDegrees
            contextPopulation = context?.population
            contextPopulationDensity = context?.populationDensity
            contextNearbyNames = context?.namedFeatures?.map(\.name).joined(separator: "; ")
            detail = bookmark.detail
        }
    }

    let type: String
    let name: String?
    let topoExplorer: Metadata?
    let features: [Feature]

    enum CodingKeys: String, CodingKey {
        case type, name, features
        case topoExplorer = "topo_explorer"
    }

    init(
        bookmarks: [MapBookmark],
        sources: [MapManifest.DataCatalogEntry],
        exportedAt: Date = Date()
    ) throws {
        type = "FeatureCollection"
        name = "TopoExplorer Feldbuch"
        topoExplorer = Metadata(
            format: "de.topo-explorer.fieldbook", version: Self.currentVersion,
            generator: "TopoExplorer", exportedAt: exportedAt,
            coordinateReferenceSystem: "OGC:CRS84 (WGS84 longitude, latitude)",
            sourceCoordinateReferenceSystem: "EPSG:3035",
            sources: sources.map(Source.init)
        )
        features = try bookmarks.map { bookmark in
            guard let coordinate = ETRS89LAEA.toWGS84(
                easting: bookmark.centerX, northing: bookmark.centerY
            ) else { throw AtlasFieldbookError.invalidProjectedCoordinate }
            return Feature(
                type: "Feature", id: bookmark.id.uuidString,
                geometry: Geometry(
                    longitude: coordinate.longitude, latitude: coordinate.latitude
                ),
                properties: Properties(bookmark)
            )
        }
    }

    func importedBookmarks() throws -> [MapBookmark] {
        guard type == "FeatureCollection" else { throw AtlasFieldbookError.wrongType }
        if let metadata = topoExplorer, metadata.version > Self.currentVersion {
            throw AtlasFieldbookError.unsupportedVersion(metadata.version)
        }
        guard features.count <= 10_000 else { throw AtlasFieldbookError.tooManyFeatures }
        var result: [MapBookmark] = []
        for feature in features where feature.type == "Feature" {
            guard
                let geometry = feature.geometry,
                geometry.type == "Point",
                let coordinates = geometry.coordinates,
                coordinates.count >= 2,
                coordinates[0].isFinite, coordinates[1].isFinite,
                (-180...180).contains(coordinates[0]),
                (-90...90).contains(coordinates[1])
            else { continue }
            let properties = feature.properties
            let exact = properties.flatMap { properties -> (Double, Double)? in
                guard
                    let easting = properties.easting,
                    let northing = properties.northing,
                    easting.isFinite, northing.isFinite
                else { return nil }
                return (easting, northing)
            }
            let projected = exact.map { (easting: $0.0, northing: $0.1) }
                ?? ETRS89LAEA.fromWGS84(
                    longitude: coordinates[0], latitude: coordinates[1]
                )
            guard let projected else { continue }
            let rawName = properties?.name?.trimmingCharacters(in: .whitespacesAndNewlines)
            let fallback = "Importierter Ort \(result.count + 1)"
            let chosenName = rawName.flatMap { $0.isEmpty ? nil : $0 } ?? fallback
            let importedName = String(chosenName.prefix(200))
            let note = properties?.note.map { String($0.prefix(20_000)) }
            let detail = try validated(properties?.detail)
            let requestedID = properties?.bookmarkID ?? feature.id
            result.append(
                MapBookmark(
                    id: requestedID.flatMap(UUID.init(uuidString:)) ?? UUID(),
                    name: importedName,
                    centerX: projected.easting,
                    centerY: projected.northing,
                    metersPerPoint: min(max(properties?.metersPerPoint ?? 100, 5), 50_000),
                    note: note?.isEmpty == false ? note : nil,
                    createdAt: properties?.observedAt,
                    detail: detail
                )
            )
        }
        guard !result.isEmpty else { throw AtlasFieldbookError.noPointFeatures }
        return result
    }

    private func validated(_ detail: MapBookmarkDetail?) throws -> MapBookmarkDetail? {
        guard let detail else { return nil }
        guard
            detail.slopeDegrees.map({ $0.isFinite && (0...90).contains($0) }) ?? true,
            detail.aspectDegrees.map({ $0.isFinite && (0..<360).contains($0) }) ?? true,
            detail.terrainResolutionMeters.map({ $0.isFinite && $0 > 0 }) ?? true
        else { throw AtlasFieldbookError.invalidAtlasMetadata }
        if let context = detail.landscapeContext {
            guard
                context.radiusMeters.isFinite,
                (500...25_000).contains(context.radiusMeters),
                context.sampledResolution.isFinite,
                context.sampleCount >= 0,
                context.plannedSampleCount >= context.sampleCount,
                context.classes.count <= 256,
                context.thematicClasses.count <= 256,
                context.classes.allSatisfy({
                    $0.share.isFinite && (0...1).contains($0.share)
                        && !$0.name.isEmpty && !$0.group.isEmpty
                }),
                context.thematicClasses.allSatisfy({
                    $0.share.isFinite && (0...1).contains($0.share) && !$0.name.isEmpty
                }),
                context.elevationStandardDeviation.map({ $0.isFinite && $0 >= 0 }) ?? true,
                context.meanSlopeDegrees.map({ $0.isFinite && (0...90).contains($0) }) ?? true,
                context.maximumSlopeDegrees.map({ $0.isFinite && (0...90).contains($0) }) ?? true,
                context.population.map({ $0 >= 0 }) ?? true,
                (context.namedFeatures?.count ?? 0) <= 64,
                (context.namedFeatures?.allSatisfy({ feature in
                    !feature.name.isEmpty
                        && (0...12).contains(feature.kind)
                        && (feature.population.map({ $0 >= 0 }) ?? true)
                        && feature.worldX.isFinite
                        && feature.worldY.isFinite
                        && feature.distanceMeters.isFinite
                        && feature.distanceMeters >= 0
                        && feature.directionDegrees.isFinite
                        && (0..<360).contains(feature.directionDegrees)
                }) ?? true)
            else { throw AtlasFieldbookError.invalidAtlasMetadata }
        }
        return detail
    }
}

enum AtlasFieldbookFile {
    static func write(_ document: AtlasFieldbookDocument, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(document).write(to: url, options: .atomic)
    }

    static func read(from url: URL) throws -> AtlasFieldbookDocument {
        let data = try Data(contentsOf: url)
        guard data.count <= 50 * 1_024 * 1_024 else { throw AtlasFieldbookError.fileTooLarge }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(AtlasFieldbookDocument.self, from: data)
        } catch let error as AtlasFieldbookError {
            throw error
        } catch {
            throw AtlasFieldbookError.unreadable
        }
    }
}

enum AtlasFieldbookError: LocalizedError {
    case wrongType
    case unsupportedVersion(Int)
    case tooManyFeatures
    case fileTooLarge
    case noPointFeatures
    case invalidProjectedCoordinate
    case invalidAtlasMetadata
    case unreadable

    var errorDescription: String? {
        switch self {
        case .wrongType: "Die Datei ist keine GeoJSON-FeatureCollection."
        case .unsupportedVersion(let version): "Feldbuch-Version \(version) wird noch nicht unterstützt."
        case .tooManyFeatures: "Das Feldbuch enthält mehr als 10.000 Objekte."
        case .fileTooLarge: "Die GeoJSON-Datei ist größer als 50 MB."
        case .noPointFeatures: "Die GeoJSON-Datei enthält keine importierbaren Punkte."
        case .invalidProjectedCoordinate: "Eine Fundstelle besitzt keine gültige EPSG:3035-Koordinate."
        case .invalidAtlasMetadata: "Die eingebetteten Landschaftsdaten sind ungültig."
        case .unreadable: "Die GeoJSON-Datei ist beschädigt oder nicht lesbar."
        }
    }
}
