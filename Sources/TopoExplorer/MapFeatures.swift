import Foundation
import SwiftUI

struct RenderLayers {
    let roads: Bool
    let roadKinds: UInt32
    let railways: Bool
    let railwayKinds: UInt32
    let waterways: Bool
    let boundaries: Bool
    let places: Bool
    let geonames: Bool
    let geonameKinds: UInt32
}

@MainActor
final class LayerSettings: ObservableObject {
    @Published var roads: Bool { didSet { save() } }
    @Published var roadKinds: UInt32 { didSet { save() } }
    @Published var railways: Bool { didSet { save() } }
    @Published var railwayKinds: UInt32 { didSet { save() } }
    @Published var waterways: Bool { didSet { save() } }
    @Published var boundaries: Bool { didSet { save() } }
    @Published var places: Bool { didSet { save() } }
    @Published var geonames: Bool { didSet { save() } }
    @Published var geonameKinds: UInt32 { didSet { save() } }

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
        waterways = boolean("waterways")
        boundaries = boolean("boundaries")
        places = boolean("places")
        geonames = boolean("geonames")
        geonameKinds = mask("geonameKinds")
    }

    var renderLayers: RenderLayers {
        RenderLayers(
            roads: roads,
            roadKinds: roadKinds,
            railways: railways,
            railwayKinds: railwayKinds,
            waterways: waterways,
            boundaries: boundaries,
            places: places,
            geonames: geonames,
            geonameKinds: geonameKinds
        )
    }

    private func save() {
        UserDefaults.standard.set(
            ["roads": roads, "roadKinds": roadKinds,
             "railways": railways, "railwayKinds": railwayKinds,
             "waterways": waterways, "boundaries": boundaries,
             "places": places, "geonames": geonames, "geonameKinds": geonameKinds],
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
        case .year2020: "2020"
        case .comparison: "Vergleich"
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

    var summary: String {
        var parts = ["E (Int(worldX)) · N (Int(worldY))"]
        if let elevation { parts.append("\(elevation) m") }
        if let className { parts.append(className) }
        return parts.joined(separator: " · ")
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
