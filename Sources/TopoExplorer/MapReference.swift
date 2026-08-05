import Foundation

struct MapReference: Identifiable, Equatable {
    let id: String
    let name: String
    let centerX: Double
    let centerY: Double
    let metersPerPoint: Double

    static let all: [MapReference] = [
        MapReference(id: "harz", name: "Harz", centerX: 4_363_816.460, centerY: 3_182_365.642, metersPerPoint: 100),
        MapReference(id: "alpen", name: "Alpen", centerX: 4_418_818.672, centerY: 2_721_568.390, metersPerPoint: 100),
        MapReference(id: "kueste", name: "Küste", centerX: 4_458_876.725, centerY: 3_426_992.276, metersPerPoint: 100),
        MapReference(id: "ruhrgebiet", name: "Ruhrgebiet", centerX: 4_122_935.894, centerY: 3_152_671.123, metersPerPoint: 100),
        MapReference(id: "flachland", name: "Flachland", centerX: 4_439_293.455, centerY: 3_289_314.249, metersPerPoint: 100),
    ]
}
