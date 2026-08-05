import Foundation
import SwiftUI

struct RenderLayers {
    let roads: Bool
    let railways: Bool
    let waterways: Bool
    let boundaries: Bool
    let places: Bool
}

@MainActor
final class LayerSettings: ObservableObject {
    @Published var roads: Bool { didSet { save() } }
    @Published var railways: Bool { didSet { save() } }
    @Published var waterways: Bool { didSet { save() } }
    @Published var boundaries: Bool { didSet { save() } }
    @Published var places: Bool { didSet { save() } }

    private static let key = "TopoExplorer.layers.v1"

    init() {
        let saved = UserDefaults.standard.dictionary(forKey: Self.key) as? [String: Bool] ?? [:]
        roads = saved["roads"] ?? true
        railways = saved["railways"] ?? true
        waterways = saved["waterways"] ?? true
        boundaries = saved["boundaries"] ?? true
        places = saved["places"] ?? true
    }

    var renderLayers: RenderLayers {
        RenderLayers(
            roads: roads,
            railways: railways,
            waterways: waterways,
            boundaries: boundaries,
            places: places
        )
    }

    private func save() {
        UserDefaults.standard.set(
            ["roads": roads, "railways": railways, "waterways": waterways,
             "boundaries": boundaries, "places": places],
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
        case .year2015: "2015"
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
        mode = LandcoverMode(
            rawValue: UserDefaults.standard.integer(forKey: "TopoExplorer.landcoverMode.v1")
        ) ?? .year2015
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
}

struct MapProbe: Equatable {
    let worldX: Double
    let worldY: Double
    let elevation: Int?
    let className: String?

    var summary: String {
        var parts = ["E (Int(worldX)) · N (Int(worldY))"]
        if let elevation { parts.append("\(elevation) m") }
        if let className { parts.append(className) }
        return parts.joined(separator: " · ")
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
