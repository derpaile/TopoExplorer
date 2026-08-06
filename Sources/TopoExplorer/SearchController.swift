import Foundation

struct PlaceSearchRecord: Decodable, Identifiable, Equatable {
    let name: String
    let kind: Int
    let population: Int
    let worldX: Double
    let worldY: Double
    let minZoom: Int

    var id: String { "\(name)|\(worldX)|\(worldY)" }

    var kindTitle: String {
        switch kind {
        case 7: "Berg"
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

    init(from decoder: Decoder) throws {
        var values = try decoder.unkeyedContainer()
        name = try values.decode(String.self)
        kind = try values.decode(Int.self)
        population = try values.decode(Int.self)
        worldX = try values.decode(Double.self)
        worldY = try values.decode(Double.self)
        minZoom = try values.decode(Int.self)
    }
}

private struct PlaceSearchIndex: Decodable {
    let places: [PlaceSearchRecord]
}

@MainActor
final class SearchController: ObservableObject {
    @Published var query = "" {
        didSet { updateResults() }
    }
    @Published private(set) var results: [PlaceSearchRecord] = []
    @Published private(set) var isLoading = false

    private var records: [PlaceSearchRecord] = []
    private var generation = 0

    func load(from dataDirectory: URL?) {
        generation &+= 1
        let requestedGeneration = generation
        records = []
        results = []
        guard let dataDirectory else { return }
        isLoading = true
        let url = dataDirectory.appendingPathComponent("Vectors/places-index.json.z")
        DispatchQueue.global(qos: .userInitiated).async {
            let decoded: [PlaceSearchRecord]
            if
                let packed = try? Data(contentsOf: url, options: .mappedIfSafe),
                let data = ZlibDecoder.decodeUnknown(packed),
                let value = try? JSONDecoder().decode(PlaceSearchIndex.self, from: data)
            {
                decoded = value.places
            } else {
                decoded = []
            }
            Task { @MainActor [weak self] in
                guard let self, self.generation == requestedGeneration else { return }
                self.records = decoded
                self.isLoading = false
                self.updateResults()
            }
        }
    }

    private func updateResults() {
        let needle = normalized(query.trimmingCharacters(in: .whitespacesAndNewlines))
        guard needle.count >= 2 else {
            results = []
            return
        }
        results = records.compactMap { record -> (PlaceSearchRecord, Int)? in
            let candidate = normalized(record.name)
            guard let range = candidate.range(of: needle) else { return nil }
            let rank = candidate.distance(from: candidate.startIndex, to: range.lowerBound)
            return (record, rank)
        }
        .sorted {
            if $0.1 != $1.1 { return $0.1 < $1.1 }
            if $0.0.population != $1.0.population { return $0.0.population > $1.0.population }
            return $0.0.name.localizedCaseInsensitiveCompare($1.0.name) == .orderedAscending
        }
        .prefix(12)
        .map(\.0)
    }

    private func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}
