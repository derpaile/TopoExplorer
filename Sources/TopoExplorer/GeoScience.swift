import SwiftUI

enum ThematicPresentation: Int, CaseIterable, Identifiable {
    case overlay
    case baseMap

    var id: Int { rawValue }
    var title: String { self == .overlay ? "Über Landbedeckung" : "Als Basiskarte" }
}

struct GeoScienceRenderOptions {
    let productID: String?
    let suffix: String?
    let qualitySuffix: String?
    let palette: [SIMD4<Float>]
    let opacity: Float
    let replacesBase: Bool

    static let disabled = GeoScienceRenderOptions(
        productID: nil,
        suffix: nil,
        qualitySuffix: nil,
        palette: Array(repeating: SIMD4<Float>(0, 0, 0, 0), count: 256),
        opacity: 0,
        replacesBase: false
    )
}

@MainActor
final class GeoScienceSettings: ObservableObject {
    @Published var selectedRasterID: String? { didSet { save() } }
    @Published var opacity: Double { didSet { save() } }
    @Published var presentation: ThematicPresentation { didSet { save() } }

    private static let key = "TopoExplorer.geoscience.v1"

    init() {
        let saved = UserDefaults.standard.dictionary(forKey: Self.key) ?? [:]
        selectedRasterID = saved["selectedRasterID"] as? String
        opacity = min(max((saved["opacity"] as? NSNumber)?.doubleValue ?? 0.72, 0), 1)
        presentation = ThematicPresentation(
            rawValue: (saved["presentation"] as? NSNumber)?.intValue ?? 0
        ) ?? .overlay
    }

    func product(in manifest: MapManifest) -> MapManifest.ThematicRaster? {
        guard let selectedRasterID else { return nil }
        return manifest.availableThematicRasters.first { $0.id == selectedRasterID }
    }

    func reconcile(with manifest: MapManifest) {
        guard selectedRasterID != nil, product(in: manifest) == nil else { return }
        selectedRasterID = nil
    }

    func renderOptions(in manifest: MapManifest) -> GeoScienceRenderOptions {
        guard let product = product(in: manifest) else {
            return GeoScienceRenderOptions(
                productID: nil,
                suffix: nil,
                qualitySuffix: nil,
                palette: GeoScienceRenderOptions.disabled.palette,
                opacity: 0,
                replacesBase: false
            )
        }
        return GeoScienceRenderOptions(
            productID: product.id,
            suffix: product.suffix,
            qualitySuffix: product.qualitySuffix,
            palette: product.palette,
            opacity: Float(opacity),
            replacesBase: presentation == .baseMap
        )
    }

    private func save() {
        var value: [String: Any] = [
            "opacity": opacity,
            "presentation": presentation.rawValue,
        ]
        value["selectedRasterID"] = selectedRasterID
        UserDefaults.standard.set(value, forKey: Self.key)
    }
}
