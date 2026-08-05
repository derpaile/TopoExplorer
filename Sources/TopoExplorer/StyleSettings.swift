import AppKit
import SwiftUI

struct RGBAColor: Codable, Equatable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double = 1

    init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    init(hex: String) {
        let value = UInt64(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0
        red = Double((value >> 16) & 0xff) / 255
        green = Double((value >> 8) & 0xff) / 255
        blue = Double(value & 0xff) / 255
        alpha = 1
    }

    init(color: Color) {
        let converted = NSColor(color).usingColorSpace(.sRGB) ?? .black
        red = converted.redComponent
        green = converted.greenComponent
        blue = converted.blueComponent
        alpha = converted.alphaComponent
    }

    var color: Color {
        Color(.sRGB, red: red, green: green, blue: blue, opacity: alpha)
    }

    var vector: SIMD4<Float> {
        SIMD4(Float(red), Float(green), Float(blue), Float(alpha))
    }
}

struct RenderStyle {
    let colors: [SIMD4<Float>]
    let reliefOpacity: Float
    let reliefExaggeration: Float
    let reliefContrast: Float
    let ambientLight: Float
}

@MainActor
final class StyleSettings: ObservableObject {
    struct Saved: Codable {
        let colors: [RGBAColor]
        let reliefOpacity: Double
        let reliefExaggeration: Double
        let reliefContrast: Double
        let ambientLight: Double
    }

    struct Preset: Identifiable {
        let id: String
        let name: String
        let colors: [RGBAColor]
        let reliefOpacity: Double
        let reliefExaggeration: Double
        let reliefContrast: Double
        let ambientLight: Double
    }

    private static let storageKey = "TopoExplorer.style.v1"

    static let originalColors = [
        "#000000", "#FF1111", "#FFD700", "#228B22",
        "#006400", "#98FB98", "#32CD32", "#0066CC",
    ].map(RGBAColor.init(hex:))

    static let sourceColors = [
        "#000000", "#CC0B1E", "#BBAE6C", "#15B667",
        "#067647", "#EFF2BE", "#B8E1A4", "#256FA8",
    ].map(RGBAColor.init(hex:))

    static let mutedColors = [
        "#101612", "#C84C55", "#C9A96E", "#6FAF7A",
        "#245C3A", "#B7CEA8", "#78A96D", "#39779B",
    ].map(RGBAColor.init(hex:))

    static let presets = [
        Preset(
            id: "original",
            name: "Original 2025",
            colors: originalColors,
            reliefOpacity: 0.50,
            reliefExaggeration: 45,
            reliefContrast: 2.5,
            ambientLight: 0.08
        ),
        Preset(
            id: "dataset",
            name: "Datensatz",
            colors: sourceColors,
            reliefOpacity: 0.42,
            reliefExaggeration: 34,
            reliefContrast: 2.0,
            ambientLight: 0.08
        ),
        Preset(
            id: "muted",
            name: "Gedämpft",
            colors: mutedColors,
            reliefOpacity: 0.36,
            reliefExaggeration: 28,
            reliefContrast: 1.8,
            ambientLight: 0.10
        ),
    ]

    @Published var colors: [RGBAColor] { didSet { changed() } }
    @Published var reliefOpacity: Double { didSet { changed() } }
    @Published var reliefExaggeration: Double { didSet { changed() } }
    @Published var reliefContrast: Double { didSet { changed() } }
    @Published var ambientLight: Double { didSet { changed() } }
    @Published private(set) var revision = 0

    init() {
        colors = Self.originalColors
        reliefOpacity = 0.50
        reliefExaggeration = 45
        reliefContrast = 2.5
        ambientLight = 0.08

        if
            let data = UserDefaults.standard.data(forKey: Self.storageKey),
            let saved = try? JSONDecoder().decode(Saved.self, from: data),
            saved.colors.count == 8
        {
            colors = saved.colors
            reliefOpacity = saved.reliefOpacity
            reliefExaggeration = saved.reliefExaggeration
            reliefContrast = saved.reliefContrast
            ambientLight = saved.ambientLight
        }
    }

    func colorBinding(at index: Int) -> Binding<Color> {
        Binding(
            get: { self.colors[index].color },
            set: { self.colors[index] = RGBAColor(color: $0) }
        )
    }

    func apply(_ preset: Preset) {
        colors = preset.colors
        reliefOpacity = preset.reliefOpacity
        reliefExaggeration = preset.reliefExaggeration
        reliefContrast = preset.reliefContrast
        ambientLight = preset.ambientLight
    }

    func resetAll() {
        colors = Self.originalColors
        reliefOpacity = 0.50
        reliefExaggeration = 45
        reliefContrast = 2.5
        ambientLight = 0.08
    }

    var renderStyle: RenderStyle {
        RenderStyle(
            colors: colors.map(\.vector),
            reliefOpacity: Float(reliefOpacity),
            reliefExaggeration: Float(reliefExaggeration),
            reliefContrast: Float(reliefContrast),
            ambientLight: Float(ambientLight)
        )
    }

    private func changed() {
        revision &+= 1
        let saved = Saved(
            colors: colors,
            reliefOpacity: reliefOpacity,
            reliefExaggeration: reliefExaggeration,
            reliefContrast: reliefContrast,
            ambientLight: ambientLight
        )
        if let data = try? JSONEncoder().encode(saved) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }
}
