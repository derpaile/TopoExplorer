import Foundation
import SwiftUI

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
    let thematic: ThematicProbe?

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

struct MapBookmark: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    let centerX: Double
    let centerY: Double
    let metersPerPoint: Double
}

@MainActor
final class BookmarkStore: ObservableObject {
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

    func add(name proposedName: String, snapshot: ViewportSnapshot) {
        let trimmed = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.isEmpty ? "Lesezeichen \(bookmarks.count + 1)" : trimmed
        bookmarks.append(
            MapBookmark(
                id: UUID(), name: name, centerX: snapshot.centerX,
                centerY: snapshot.centerY, metersPerPoint: snapshot.metersPerPoint
            )
        )
        save()
    }

    func remove(_ bookmark: MapBookmark) {
        bookmarks.removeAll { $0.id == bookmark.id }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(bookmarks) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }
}
