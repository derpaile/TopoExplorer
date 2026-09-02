import Foundation
import SwiftUI

enum AtlasCommand: CaseIterable, Equatable {
    case openPalette
    case focusSearch
    case nextLandscape
    case openDataCatalog
    case openCollection
    case toggleAreaAnalysis
    case toggleLandscapeProfile
    case exportMap
    case toggleSidebar
}

@MainActor
final class AtlasCommandCenter: ObservableObject {
    @Published private(set) var sequence = 0
    private(set) var command: AtlasCommand?

    func send(_ command: AtlasCommand) {
        self.command = command
        sequence &+= 1
    }
}

struct RenderLayers {
    let roads: Bool
    let roadKinds: UInt32
    let railways: Bool
    let railwayKinds: UInt32
    let energy: Bool
    let energyKinds: UInt32
    let waterways: Bool
    let boundaries: Bool
    let places: Bool
    let geonames: Bool
    let geonameKinds: UInt32
    let roadPreset: UInt32
    let railwayPreset: UInt32
    let waterwayPreset: UInt32
    let boundaryPreset: UInt32
    let energyPreset: UInt32
    let placeLabelPreset: UInt32
    let landscapeLabelPreset: UInt32

    init(
        roads: Bool, roadKinds: UInt32, railways: Bool, railwayKinds: UInt32,
        energy: Bool, energyKinds: UInt32, waterways: Bool, boundaries: Bool,
        places: Bool, geonames: Bool, geonameKinds: UInt32,
        roadPreset: UInt32 = 2, railwayPreset: UInt32 = 2,
        waterwayPreset: UInt32 = 2, boundaryPreset: UInt32 = 2,
        energyPreset: UInt32 = 2, placeLabelPreset: UInt32 = 2,
        landscapeLabelPreset: UInt32 = 2
    ) {
        self.roads = roads
        self.roadKinds = roadKinds
        self.railways = railways
        self.railwayKinds = railwayKinds
        self.energy = energy
        self.energyKinds = energyKinds
        self.waterways = waterways
        self.boundaries = boundaries
        self.places = places
        self.geonames = geonames
        self.geonameKinds = geonameKinds
        self.roadPreset = roadPreset
        self.railwayPreset = railwayPreset
        self.waterwayPreset = waterwayPreset
        self.boundaryPreset = boundaryPreset
        self.energyPreset = energyPreset
        self.placeLabelPreset = placeLabelPreset
        self.landscapeLabelPreset = landscapeLabelPreset
    }
}

enum VectorAppearancePreset: Int, CaseIterable, Identifiable {
    case leise, hell, ausgewogen, klar, kontrast

    var id: Int { rawValue }
    var title: String {
        switch self {
        case .leise: "Leise"
        case .hell: "Hell"
        case .ausgewogen: "Ausgewogen"
        case .klar: "Klar"
        case .kontrast: "Kontrast"
        }
    }
}

@MainActor
final class LayerSettings: ObservableObject {
    @Published var roads: Bool { didSet { save() } }
    @Published var roadKinds: UInt32 { didSet { save() } }
    @Published var railways: Bool { didSet { save() } }
    @Published var railwayKinds: UInt32 { didSet { save() } }
    @Published var energy: Bool { didSet { save() } }
    @Published var energyKinds: UInt32 { didSet { save() } }
    @Published var waterways: Bool { didSet { save() } }
    @Published var boundaries: Bool { didSet { save() } }
    @Published var places: Bool { didSet { save() } }
    @Published var geonames: Bool { didSet { save() } }
    @Published var geonameKinds: UInt32 { didSet { save() } }
    @Published var roadPreset: VectorAppearancePreset { didSet { save() } }
    @Published var railwayPreset: VectorAppearancePreset { didSet { save() } }
    @Published var waterwayPreset: VectorAppearancePreset { didSet { save() } }
    @Published var boundaryPreset: VectorAppearancePreset { didSet { save() } }
    @Published var energyPreset: VectorAppearancePreset { didSet { save() } }
    @Published var placeLabelPreset: VectorAppearancePreset { didSet { save() } }
    @Published var landscapeLabelPreset: VectorAppearancePreset { didSet { save() } }

    private static let key = "TopoExplorer.layers.v1"

    init() {
        let saved = UserDefaults.standard.dictionary(forKey: Self.key) ?? [:]
        func boolean(_ key: String) -> Bool {
            (saved[key] as? NSNumber)?.boolValue ?? true
        }
        func mask(_ key: String) -> UInt32 {
            guard let number = saved[key] as? NSNumber else { return .max }
            return number.uint32Value
        }
        roads = boolean("roads")
        roadKinds = mask("roadKinds")
        railways = boolean("railways")
        railwayKinds = mask("railwayKinds")
        energy = boolean("energy")
        energyKinds = mask("energyKinds")
        waterways = boolean("waterways")
        boundaries = boolean("boundaries")
        places = boolean("places")
        geonames = boolean("geonames")
        geonameKinds = mask("geonameKinds")
        func preset(_ key: String) -> VectorAppearancePreset {
            VectorAppearancePreset(rawValue: (saved[key] as? NSNumber)?.intValue ?? 2) ?? .ausgewogen
        }
        roadPreset = preset("roadPreset")
        railwayPreset = preset("railwayPreset")
        waterwayPreset = preset("waterwayPreset")
        boundaryPreset = preset("boundaryPreset")
        energyPreset = preset("energyPreset")
        placeLabelPreset = preset("placeLabelPreset")
        landscapeLabelPreset = preset("landscapeLabelPreset")
    }

    var renderLayers: RenderLayers {
        RenderLayers(
            roads: roads,
            roadKinds: roadKinds,
            railways: railways,
            railwayKinds: railwayKinds,
            energy: energy,
            energyKinds: energyKinds,
            waterways: waterways,
            boundaries: boundaries,
            places: places,
            geonames: geonames,
            geonameKinds: geonameKinds,
            roadPreset: UInt32(roadPreset.rawValue),
            railwayPreset: UInt32(railwayPreset.rawValue),
            waterwayPreset: UInt32(waterwayPreset.rawValue),
            boundaryPreset: UInt32(boundaryPreset.rawValue),
            energyPreset: UInt32(energyPreset.rawValue),
            placeLabelPreset: UInt32(placeLabelPreset.rawValue),
            landscapeLabelPreset: UInt32(landscapeLabelPreset.rawValue)
        )
    }

    private func save() {
        UserDefaults.standard.set(
            ["roads": roads, "roadKinds": roadKinds,
             "railways": railways, "railwayKinds": railwayKinds,
             "energy": energy, "energyKinds": energyKinds,
             "waterways": waterways, "boundaries": boundaries,
             "places": places, "geonames": geonames, "geonameKinds": geonameKinds,
             "roadPreset": roadPreset.rawValue, "railwayPreset": railwayPreset.rawValue,
             "waterwayPreset": waterwayPreset.rawValue, "boundaryPreset": boundaryPreset.rawValue,
             "energyPreset": energyPreset.rawValue,
             "placeLabelPreset": placeLabelPreset.rawValue,
             "landscapeLabelPreset": landscapeLabelPreset.rawValue],
            forKey: Self.key
        )
    }
}

enum LandcoverMode: Int, CaseIterable, Identifiable {
    case year2015
    case year2020
    case comparison

    var id: Int { rawValue }
    var title: String {
        switch self {
        case .year2015: "Gesamtkarte"
        case .year2020: "Archiv 2020"
        case .comparison: "Vergleichen"
        }
    }
}

struct RenderComparison {
    let mode: UInt32
    let splitPosition: Float
}

@MainActor
final class ComparisonSettings: ObservableObject {
    @Published var mode: LandcoverMode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "TopoExplorer.landcoverMode.v1") }
    }
    @Published var splitPosition: Double {
        didSet { UserDefaults.standard.set(splitPosition, forKey: "TopoExplorer.splitPosition.v1") }
    }

    init() {
        mode = .year2015
        let savedSplit = UserDefaults.standard.double(forKey: "TopoExplorer.splitPosition.v1")
        splitPosition = savedSplit == 0 ? 0.5 : min(max(savedSplit, 0.1), 0.9)
    }

    var renderComparison: RenderComparison {
        RenderComparison(mode: UInt32(mode.rawValue), splitPosition: Float(splitPosition))
    }
}

struct MapLabel: Identifiable, Equatable {
    let id: String
    let name: String
    let point: CGPoint
    let prominence: Double
    let kind: UInt8
    let angleDegrees: Double
}

struct MapProbe: Equatable {
    let worldX: Double
    let worldY: Double
    let elevation: Int?
    let classID: Int?
    let className: String?
    let classGroup: String?
    let thematic: ThematicProbe?
    let slopeDegrees: Double?
    let aspectDegrees: Double?
    let terrainResolutionMeters: Double?

    init(
        worldX: Double,
        worldY: Double,
        elevation: Int?,
        classID: Int?,
        className: String?,
        classGroup: String?,
        thematic: ThematicProbe?,
        slopeDegrees: Double? = nil,
        aspectDegrees: Double? = nil,
        terrainResolutionMeters: Double? = nil
    ) {
        self.worldX = worldX
        self.worldY = worldY
        self.elevation = elevation
        self.classID = classID
        self.className = className
        self.classGroup = classGroup
        self.thematic = thematic
        self.slopeDegrees = slopeDegrees
        self.aspectDegrees = aspectDegrees
        self.terrainResolutionMeters = terrainResolutionMeters
    }

    var discoveryTitle: String {
        thematic?.className ?? className ?? "Fundstelle"
    }

    var coordinateText: String {
        "\(Int(worldX.rounded())) · \(Int(worldY.rounded()))"
    }

    var copyText: String {
        "EPSG:3035 \(Int(worldX.rounded())) \(Int(worldY.rounded()))"
    }

    var aspectDirection: String? {
        guard let aspectDegrees else { return nil }
        let directions = ["N", "NO", "O", "SO", "S", "SW", "W", "NW"]
        return directions[Int((aspectDegrees + 22.5) / 45).quotientAndRemainder(dividingBy: 8).remainder]
    }

    var terrainSummary: String? {
        guard let slopeDegrees else { return nil }
        if slopeDegrees < 0.5 { return "nahezu eben" }
        let slope = slopeDegrees.formatted(.number.precision(.fractionLength(1)))
        return aspectDirection.map { "\(slope)° nach \($0)" } ?? "\(slope)° geneigt"
    }
}

struct ThematicProbe: Equatable {
    let productID: String
    let productName: String
    let classID: Int
    let className: String
    let sourceName: String?
    let sourceScale: Int?

    var qualitySummary: String? {
        guard let sourceName else { return nil }
        if let sourceScale { return "\(sourceName) · Maßstab 1:\(sourceScale.formatted())" }
        return sourceName
    }
}

struct LandscapeContextClass: Codable, Identifiable, Equatable {
    let classID: Int
    let name: String
    let group: String
    let share: Double

    var id: Int { classID }
}

struct LandscapeContextThematicClass: Codable, Identifiable, Equatable {
    let classID: Int
    let name: String
    let share: Double

    var id: Int { classID }
}

struct LandscapeContextFeature: Codable, Identifiable, Equatable {
    let name: String
    let kind: Int
    let population: Int?
    let worldX: Double
    let worldY: Double
    let distanceMeters: Double
    let directionDegrees: Double

    var id: String { "\(kind)|\(name)|\(worldX)|\(worldY)" }

    var kindTitle: String {
        switch kind {
        case 7: "Gipfel oder Höhe"
        case 8: "Landschaft"
        case 9: "Gewässer"
        case 10: "Naturgebiet"
        case 11: "Insel"
        case 12: "Höhle"
        default: "Ort"
        }
    }

    var symbolName: String {
        switch kind {
        case 7: "mountain.2.fill"
        case 8: "map.fill"
        case 9: "water.waves"
        case 10: "leaf.fill"
        case 11: "globe.europe.africa.fill"
        case 12: "triangle.fill"
        default: "mappin.circle.fill"
        }
    }

    var directionName: String {
        let directions = ["N", "NO", "O", "SO", "S", "SW", "W", "NW"]
        return directions[Int((directionDegrees + 22.5) / 45) % directions.count]
    }

    var proximityText: String {
        let distance = distanceMeters < 1_000
            ? "\(Int(distanceMeters.rounded()).formatted()) m"
            : "\((distanceMeters / 1_000).formatted(.number.precision(.fractionLength(1)))) km"
        return "\(distance) · \(directionName)"
    }
}

struct LandscapeContextGroupShare: Identifiable, Equatable {
    let name: String
    let share: Double

    var id: String { name }
}

struct LandscapeContext: Codable, Equatable {
    let centerX: Double
    let centerY: Double
    let radiusMeters: Double
    let sampledResolution: Double
    let sampleCount: Int
    let plannedSampleCount: Int
    let classes: [LandscapeContextClass]
    let thematicProductName: String?
    let thematicClasses: [LandscapeContextThematicClass]
    let minimumElevation: Int?
    let maximumElevation: Int?
    let meanElevation: Int?
    let elevationStandardDeviation: Double?
    let meanSlopeDegrees: Double?
    let maximumSlopeDegrees: Double?
    let population: Int?
    let populationSource: String?
    let namedFeatures: [LandscapeContextFeature]?

    init(
        centerX: Double,
        centerY: Double,
        radiusMeters: Double,
        sampledResolution: Double,
        plannedSampleCount: Int,
        probes: [MapProbe],
        population: Int? = nil,
        populationSource: String? = nil,
        namedFeatures: [LandscapeContextFeature] = []
    ) {
        self.centerX = centerX
        self.centerY = centerY
        self.radiusMeters = radiusMeters
        self.sampledResolution = sampledResolution
        self.plannedSampleCount = plannedSampleCount
        let valid = probes.filter { $0.classID != nil }
        sampleCount = valid.count

        var surfaceCounts: [Int: (name: String, group: String, count: Int)] = [:]
        for probe in valid {
            guard let classID = probe.classID, let name = probe.className else { continue }
            let current = surfaceCounts[classID]
            surfaceCounts[classID] = (
                name, probe.classGroup ?? "Sonstige", (current?.count ?? 0) + 1
            )
        }
        classes = surfaceCounts.map { classID, value in
            LandscapeContextClass(
                classID: classID, name: value.name, group: value.group,
                share: valid.isEmpty ? 0 : Double(value.count) / Double(valid.count)
            )
        }.sorted { first, second in
            first.share == second.share ? first.classID < second.classID : first.share > second.share
        }

        let thematic = probes.compactMap(\.thematic)
        thematicProductName = thematic.first?.productName
        var thematicCounts: [Int: (name: String, count: Int)] = [:]
        for item in thematic {
            let current = thematicCounts[item.classID]
            thematicCounts[item.classID] = (item.className, (current?.count ?? 0) + 1)
        }
        thematicClasses = thematicCounts.map { classID, value in
            LandscapeContextThematicClass(
                classID: classID, name: value.name,
                share: thematic.isEmpty ? 0 : Double(value.count) / Double(thematic.count)
            )
        }.sorted { first, second in
            first.share == second.share ? first.classID < second.classID : first.share > second.share
        }

        let elevations = valid.compactMap(\.elevation)
        minimumElevation = elevations.min()
        maximumElevation = elevations.max()
        meanElevation = elevations.isEmpty
            ? nil : Int((Double(elevations.reduce(0, +)) / Double(elevations.count)).rounded())
        if elevations.isEmpty {
            elevationStandardDeviation = nil
        } else {
            let mean = Double(elevations.reduce(0, +)) / Double(elevations.count)
            elevationStandardDeviation = sqrt(
                elevations.reduce(0) { $0 + pow(Double($1) - mean, 2) }
                    / Double(elevations.count)
            )
        }
        let slopes = valid.compactMap(\.slopeDegrees)
        meanSlopeDegrees = slopes.isEmpty ? nil : slopes.reduce(0, +) / Double(slopes.count)
        maximumSlopeDegrees = slopes.max()
        self.population = population
        self.populationSource = populationSource
        self.namedFeatures = namedFeatures
    }

    var coverage: Double {
        plannedSampleCount > 0 ? Double(sampleCount) / Double(plannedSampleCount) : 0
    }

    var elevationRange: Int? {
        guard let minimumElevation, let maximumElevation else { return nil }
        return maximumElevation - minimumElevation
    }

    var populationDensity: Double? {
        guard let population, radiusMeters > 0 else { return nil }
        return Double(population) / (Double.pi * pow(radiusMeters / 1_000, 2))
    }

    var terrainCharacter: String? {
        guard let meanSlopeDegrees else { return nil }
        switch meanSlopeDegrees {
        case ..<1: return "weitgehend eben"
        case ..<3: return "sanft bewegt"
        case ..<7: return "wellig"
        case ..<15: return "stark bewegt"
        default: return "steil reliefiert"
        }
    }

    var nearbyNames: String? {
        guard let namedFeatures, !namedFeatures.isEmpty else { return nil }
        return namedFeatures.prefix(3).map(\.name).joined(separator: ", ")
    }

    var distinctGroups: Int { Set(classes.map(\.group)).count }

    var groupShares: [LandscapeContextGroupShare] {
        Dictionary(grouping: classes, by: \.group)
            .map { group, classes in
                LandscapeContextGroupShare(
                    name: group,
                    share: classes.reduce(0) { $0 + $1.share }
                )
            }
            .sorted {
                $0.share == $1.share
                    ? $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                    : $0.share > $1.share
            }
    }

    var dominantGroup: String? {
        groupShares.first?.name
    }

    var title: String {
        guard let first = classes.first else { return "Keine Umgebung lesbar" }
        if first.share >= 0.60 { return "\(first.name) prägt die Umgebung" }
        if classes.count > 1 { return "\(first.name) trifft auf \(classes[1].name)" }
        return first.name
    }

    var narrative: String {
        guard !classes.isEmpty else {
            return "Der gewählte Kreis liegt außerhalb der verfügbaren Landschaftsdaten."
        }
        let texture: String
        switch classes.count {
        case 1: texture = "eine sehr geschlossene Landschaft"
        case 2...4: texture = "eine klar gegliederte Landschaft"
        case 5...8: texture = "ein abwechslungsreiches Landschaftsmosaik"
        default: texture = "ein feingliedriges Landschaftsmosaik"
        }
        var result = "Hier zeigt sich \(texture) aus \(classes.count) Oberflächenklassen"
        if let dominantGroup { result += ", überwiegend aus der Gruppe \(dominantGroup)" }
        if let elevationRange {
            result += ". Das Gelände überspannt \(elevationRange.formatted()) Höhenmeter"
        }
        if let terrainCharacter {
            result += " und wirkt \(terrainCharacter)"
        }
        return result + "."
    }
}

struct MapProfileSelection: Equatable {
    let startX: Double
    let startY: Double
    let endX: Double
    let endY: Double

    var distanceMeters: Double { hypot(endX - startX, endY - startY) }

    func point(at fraction: Double) -> (x: Double, y: Double) {
        (
            startX + (endX - startX) * fraction,
            startY + (endY - startY) * fraction
        )
    }
}

struct MapScreenLine: Equatable {
    let start: CGPoint
    let end: CGPoint
}

struct LandscapeProfileSample: Equatable {
    let distanceMeters: Double
    let elevation: Int?
    let classID: Int?
    let className: String?
    let classGroup: String?
    let thematicClassName: String?
}

struct LandscapeProfileSegment: Equatable, Identifiable {
    let id: Int
    let startMeters: Double
    let endMeters: Double
    let classID: Int
    let className: String
    let classGroup: String?
}

struct LandscapeProfile: Equatable {
    let selection: MapProfileSelection
    let samples: [LandscapeProfileSample]
    let segments: [LandscapeProfileSegment]
    let minimumElevation: Int?
    let maximumElevation: Int?
    let ascentMeters: Int
    let descentMeters: Int

    init(selection: MapProfileSelection, samples: [LandscapeProfileSample]) {
        self.selection = selection
        self.samples = samples
        let elevations = samples.compactMap(\.elevation)
        minimumElevation = elevations.min()
        maximumElevation = elevations.max()
        var ascent = 0
        var descent = 0
        for pair in zip(elevations, elevations.dropFirst()) {
            let difference = pair.1 - pair.0
            if difference > 0 { ascent += difference } else { descent -= difference }
        }
        ascentMeters = ascent
        descentMeters = descent

        var built: [LandscapeProfileSegment] = []
        var currentID: Int?
        var currentName = ""
        var currentGroup: String?
        var start = 0.0
        for sample in samples {
            guard let classID = sample.classID, let className = sample.className else {
                if let currentID {
                    built.append(
                        LandscapeProfileSegment(
                            id: built.count, startMeters: start,
                            endMeters: sample.distanceMeters, classID: currentID,
                            className: currentName, classGroup: currentGroup
                        )
                    )
                }
                currentID = nil
                continue
            }
            if currentID != classID {
                if let currentID {
                    built.append(
                        LandscapeProfileSegment(
                            id: built.count, startMeters: start,
                            endMeters: sample.distanceMeters, classID: currentID,
                            className: currentName, classGroup: currentGroup
                        )
                    )
                }
                currentID = classID
                currentName = className
                currentGroup = sample.classGroup
                start = sample.distanceMeters
            }
        }
        if let currentID, let last = samples.last {
            built.append(
                LandscapeProfileSegment(
                    id: built.count, startMeters: start,
                    endMeters: last.distanceMeters, classID: currentID,
                    className: currentName, classGroup: currentGroup
                )
            )
        }
        segments = built
    }

    var distanceMeters: Double { selection.distanceMeters }
    var elevationRange: Int? {
        guard let minimumElevation, let maximumElevation else { return nil }
        return maximumElevation - minimumElevation
    }
    var distinctLandClasses: Int { Set(segments.map(\.classID)).count }
    var distinctThematicClasses: Int {
        Set(samples.compactMap(\.thematicClassName)).count
    }
}

struct MapSelection: Equatable {
    let minX: Double
    let minY: Double
    let maxX: Double
    let maxY: Double

    init(x1: Double, y1: Double, x2: Double, y2: Double) {
        minX = min(x1, x2)
        minY = min(y1, y2)
        maxX = max(x1, x2)
        maxY = max(y1, y2)
    }

    var width: Double { maxX - minX }
    var height: Double { maxY - minY }
    var squareKilometers: Double { width * height / 1_000_000 }
}

struct AreaClassStatistic: Identifiable, Equatable {
    let classID: Int
    let name: String
    let group: String
    let squareKilometers: Double
    let share: Double

    var id: Int { classID }
}

struct AreaStatistics: Equatable {
    let selection: MapSelection
    let population: Int?
    let populationSource: String?
    let populationCoverage: Double
    let sampledResolution: Double
    let classes: [AreaClassStatistic]
    let subjectName: String

    var populationDensity: Double? {
        guard let population, selection.squareKilometers > 0 else { return nil }
        return Double(population) / selection.squareKilometers
    }

    func squareKilometers(in group: String) -> Double {
        classes.filter { $0.group == group }.reduce(0) { $0 + $1.squareKilometers }
    }
}

struct ViewportSnapshot: Equatable {
    let centerX: Double
    let centerY: Double
    let metersPerPoint: Double
    let visibleWidthMeters: Double
    let visibleHeightMeters: Double
}

struct MapBookmarkDetail: Codable, Equatable {
    let surfaceClassID: Int?
    let surfaceName: String?
    let surfaceGroup: String?
    let elevation: Int?
    let slopeDegrees: Double?
    let aspectDegrees: Double?
    let terrainResolutionMeters: Double?
    let thematicProductID: String?
    let thematicProductName: String?
    let thematicClassID: Int?
    let thematicClassName: String?
    let thematicSourceSummary: String?
    let landscapeContext: LandscapeContext?

    init(probe: MapProbe, landscapeContext: LandscapeContext? = nil) {
        surfaceClassID = probe.classID
        surfaceName = probe.className
        surfaceGroup = probe.classGroup
        elevation = probe.elevation
        slopeDegrees = probe.slopeDegrees
        aspectDegrees = probe.aspectDegrees
        terrainResolutionMeters = probe.terrainResolutionMeters
        thematicProductID = probe.thematic?.productID
        thematicProductName = probe.thematic?.productName
        thematicClassID = probe.thematic?.classID
        thematicClassName = probe.thematic?.className
        thematicSourceSummary = probe.thematic?.qualitySummary
        self.landscapeContext = landscapeContext
    }

    var summary: String {
        landscapeContext?.title ?? thematicClassName ?? surfaceName ?? "Kartenansicht"
    }

    var hasLandscapeContext: Bool { landscapeContext != nil }
}

struct MapBookmark: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    let centerX: Double
    let centerY: Double
    let metersPerPoint: Double
    var note: String? = nil
    var createdAt: Date? = nil
    var detail: MapBookmarkDetail? = nil

    var isComparable: Bool { detail != nil }
    var coordinateText: String {
        "\(Int(centerX.rounded())) · \(Int(centerY.rounded()))"
    }
}

struct MapBookmarkComparison: Equatable {
    let first: MapBookmark
    let second: MapBookmark

    var elevationDifference: Int? {
        guard let first = first.detail?.elevation, let second = second.detail?.elevation else {
            return nil
        }
        return second - first
    }

    var slopeDifference: Double? {
        guard let first = first.detail?.slopeDegrees, let second = second.detail?.slopeDegrees else {
            return nil
        }
        return second - first
    }

    var contextPopulationDifference: Int? {
        guard
            let first = first.detail?.landscapeContext?.population,
            let second = second.detail?.landscapeContext?.population
        else { return nil }
        return second - first
    }

    var sharesSurfaceGroup: Bool? {
        guard let first = first.detail?.surfaceGroup, let second = second.detail?.surfaceGroup else {
            return nil
        }
        return first == second
    }

    var sharesThematicProduct: Bool {
        guard let first = first.detail?.thematicProductID,
              let second = second.detail?.thematicProductID
        else { return false }
        return first == second
    }

    var sharesDominantContextClass: Bool? {
        guard
            let first = first.detail?.landscapeContext?.classes.first?.classID,
            let second = second.detail?.landscapeContext?.classes.first?.classID
        else { return nil }
        return first == second
    }

    var contextClassDifference: Int? {
        guard
            let first = first.detail?.landscapeContext?.classes.count,
            let second = second.detail?.landscapeContext?.classes.count
        else { return nil }
        return second - first
    }

    var contextElevationRangeDifference: Int? {
        guard
            let first = first.detail?.landscapeContext?.elevationRange,
            let second = second.detail?.landscapeContext?.elevationRange
        else { return nil }
        return second - first
    }
}

@MainActor
final class BookmarkStore: ObservableObject {
    struct ImportResult: Equatable {
        let added: Int
        let skipped: Int
    }

    @Published private(set) var bookmarks: [MapBookmark] = []
    private static let key = "TopoExplorer.bookmarks.v1"

    init() {
        if
            let data = UserDefaults.standard.data(forKey: Self.key),
            let decoded = try? JSONDecoder().decode([MapBookmark].self, from: data)
        {
            bookmarks = decoded
        }
    }

    func add(
        name proposedName: String,
        snapshot: ViewportSnapshot,
        probe: MapProbe? = nil,
        landscapeContext: LandscapeContext? = nil,
        note proposedNote: String? = nil
    ) {
        let trimmed = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? "Lesezeichen \(bookmarks.count + 1)" : trimmed
        let trimmedNote = proposedNote?.trimmingCharacters(in: .whitespacesAndNewlines)
        bookmarks.append(
            MapBookmark(
                id: UUID(), name: name, centerX: snapshot.centerX,
                centerY: snapshot.centerY, metersPerPoint: snapshot.metersPerPoint,
                note: trimmedNote?.isEmpty == false ? trimmedNote : nil,
                createdAt: Date(),
                detail: probe.map { MapBookmarkDetail(probe: $0, landscapeContext: landscapeContext) }
            )
        )
        save()
    }

    func remove(_ bookmark: MapBookmark) {
        bookmarks.removeAll { $0.id == bookmark.id }
        save()
    }

    func mergeImported(_ candidates: [MapBookmark]) -> ImportResult {
        var added = 0
        var skipped = 0
        for candidate in candidates {
            let duplicate = bookmarks.contains { existing in
                existing.id == candidate.id
                    || (hypot(existing.centerX - candidate.centerX, existing.centerY - candidate.centerY) < 0.5
                        && existing.name.compare(candidate.name, options: .caseInsensitive) == .orderedSame)
            }
            guard !duplicate else {
                skipped += 1
                continue
            }
            let id = bookmarks.contains(where: { $0.id == candidate.id }) ? UUID() : candidate.id
            bookmarks.append(
                MapBookmark(
                    id: id, name: candidate.name,
                    centerX: candidate.centerX, centerY: candidate.centerY,
                    metersPerPoint: candidate.metersPerPoint,
                    note: candidate.note, createdAt: candidate.createdAt,
                    detail: candidate.detail
                )
            )
            added += 1
        }
        if added > 0 { save() }
        return ImportResult(added: added, skipped: skipped)
    }

    private func save() {
        if let data = try? JSONEncoder().encode(bookmarks) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}
