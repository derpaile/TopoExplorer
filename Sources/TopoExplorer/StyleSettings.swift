import AppKit
import SwiftUI
import UniformTypeIdentifiers

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
    let sunAzimuthRadians: Float

    init(
        colors: [SIMD4<Float>],
        reliefOpacity: Float,
        reliefExaggeration: Float,
        reliefContrast: Float,
        ambientLight: Float,
        sunAzimuthRadians: Float = 5.4977871438
    ) {
        self.colors = colors
        self.reliefOpacity = reliefOpacity
        self.reliefExaggeration = reliefExaggeration
        self.reliefContrast = reliefContrast
        self.ambientLight = ambientLight
        self.sunAzimuthRadians = sunAzimuthRadians
    }
}

@MainActor
final class StyleSettings: ObservableObject {
    typealias Preset = MapStyleDocument

    private struct LegacySaved: Codable {
        let colors: [RGBAColor]
        let reliefOpacity: Double
        let reliefExaggeration: Double
        let reliefContrast: Double
        let ambientLight: Double
    }

    private static let legacyStorageKey = "TopoExplorer.style.v1"
    private static let currentStorageKey = "TopoExplorer.style.v2"
    private static let customStorageKey = "TopoExplorer.customStyles.v1"
    private static let styleContentType = UTType(
        filenameExtension: "topostyle",
        conformingTo: .json
    ) ?? .json

    static let originalColors = [
        "#000000", "#FF1111", "#FFD700", "#98FB98",
        "#E6B94A", "#228B22", "#006400", "#277A45",
        "#9A774A", "#32CD32", "#0066CC",
    ].map(RGBAColor.init(hex:))

    static let sourceColors = [
        "#000000", "#CC0B1E", "#BBAE6C", "#EFF2BE",
        "#D4B86F", "#15B667", "#067647", "#4B8F67",
        "#957B57", "#B8E1A4", "#256FA8",
    ].map(RGBAColor.init(hex:))

    static let mutedColors = [
        "#101612", "#C84C55", "#C9A96E", "#B7CEA8",
        "#D6BE78", "#6FAF7A", "#245C3A", "#47785A",
        "#927A55", "#78A96D", "#39779B",
    ].map(RGBAColor.init(hex:))

    static let presets = [
        MapStyleDocument(
            id: "builtin.original",
            name: "Original 2025",
            colors: originalColors,
            relief: ReliefStyle(
                enabled: true, opacity: 0.50, exaggeration: 45,
                contrast: 2.5, ambientLight: 0.08, sunAzimuthDegrees: 315
            )
        ),
        MapStyleDocument(
            id: "builtin.dataset",
            name: "Datensatz",
            colors: sourceColors,
            relief: ReliefStyle(
                enabled: true, opacity: 0.42, exaggeration: 34,
                contrast: 2.0, ambientLight: 0.08, sunAzimuthDegrees: 315
            )
        ),
        MapStyleDocument(
            id: "builtin.muted",
            name: "Gedämpft",
            colors: mutedColors,
            relief: ReliefStyle(
                enabled: true, opacity: 0.36, exaggeration: 28,
                contrast: 1.8, ambientLight: 0.10, sunAzimuthDegrees: 315
            )
        ),
    ]

    @Published var colors: [RGBAColor] { didSet { propertyChanged() } }
    @Published var reliefEnabled: Bool { didSet { propertyChanged() } }
    @Published var reliefOpacity: Double { didSet { propertyChanged() } }
    @Published var reliefExaggeration: Double { didSet { propertyChanged() } }
    @Published var reliefContrast: Double { didSet { propertyChanged() } }
    @Published var ambientLight: Double { didSet { propertyChanged() } }
    @Published var sunAzimuthDegrees: Double { didSet { propertyChanged() } }
    @Published private(set) var customStyles: [MapStyleDocument]
    @Published private(set) var activeStyleName: String
    @Published var errorMessage: String?
    @Published private(set) var revision = 0

    private var activeStyleID: String?
    private var isApplying = false

    init() {
        let original = Self.presets[0]
        colors = original.colors
        reliefEnabled = original.relief.enabled
        reliefOpacity = original.relief.opacity
        reliefExaggeration = original.relief.exaggeration
        reliefContrast = original.relief.contrast
        ambientLight = original.relief.ambientLight
        sunAzimuthDegrees = original.relief.sunAzimuthDegrees
        activeStyleName = original.name
        activeStyleID = original.id
        errorMessage = nil

        if
            let data = UserDefaults.standard.data(forKey: Self.customStorageKey),
            let decoded = try? JSONDecoder().decode([MapStyleDocument].self, from: data)
        {
            customStyles = decoded.compactMap { try? $0.validated() }
        } else {
            customStyles = []
        }

        if
            let data = UserDefaults.standard.data(forKey: Self.currentStorageKey),
            let saved = try? JSONDecoder().decode(MapStyleDocument.self, from: data),
            let saved = try? saved.validated()
        {
            isApplying = true
            assign(saved)
            isApplying = false
        } else if
            let data = UserDefaults.standard.data(forKey: Self.legacyStorageKey),
            let saved = try? JSONDecoder().decode(LegacySaved.self, from: data),
            saved.colors.count == 8,
            let migrated = try? MapStyleDocument(
                id: "current",
                name: "Übernommener Stil",
                colors: saved.colors,
                relief: ReliefStyle(
                    enabled: saved.reliefOpacity > 0,
                    opacity: saved.reliefOpacity,
                    exaggeration: saved.reliefExaggeration,
                    contrast: saved.reliefContrast,
                    ambientLight: saved.ambientLight,
                    sunAzimuthDegrees: 315
                )
            ).validated()
        {
            isApplying = true
            assign(migrated)
            isApplying = false
            persistCurrent()
        }
    }

    func colorBinding(at index: Int) -> Binding<Color> {
        Binding(
            get: { self.colors[index].color },
            set: { self.colors[index] = RGBAColor(color: $0) }
        )
    }

    func apply(_ document: MapStyleDocument) {
        guard let validated = try? document.validated() else { return }
        isApplying = true
        assign(validated)
        isApplying = false
        revision &+= 1
        persistCurrent()
    }

    func saveCurrent(named proposedName: String) {
        let name = proposedName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            errorMessage = "Bitte zuerst einen Stilnamen eingeben."
            return
        }

        let existing = customStyles.first { $0.name.compare(name, options: .caseInsensitive) == .orderedSame }
        var document = currentDocument(named: name, id: existing?.id ?? "custom.\(UUID().uuidString)")
        document.name = name
        if let index = customStyles.firstIndex(where: { $0.id == document.id }) {
            customStyles[index] = document
        } else {
            customStyles.append(document)
        }
        customStyles.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        activeStyleID = document.id
        activeStyleName = document.name
        persistCustomStyles()
        persistCurrent()
    }

    func deleteCustomStyle(id: String) {
        customStyles.removeAll { $0.id == id }
        if activeStyleID == id {
            activeStyleID = nil
            activeStyleName = "Angepasst"
            persistCurrent()
        }
        persistCustomStyles()
    }

    func importWithPanel() {
        let panel = NSOpenPanel()
        panel.title = "Kartenstil importieren"
        panel.prompt = "Importieren"
        panel.allowedContentTypes = [Self.styleContentType, .json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            var document = try MapStyleFile.read(from: url)
            document.id = "custom.\(UUID().uuidString)"
            if customStyles.contains(where: { $0.name.compare(document.name, options: .caseInsensitive) == .orderedSame }) {
                document.name += " (importiert)"
            }
            customStyles.append(document)
            customStyles.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
            persistCustomStyles()
            apply(document)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func exportWithPanel() {
        let panel = NSSavePanel()
        panel.title = "Kartenstil exportieren"
        panel.prompt = "Exportieren"
        panel.allowedContentTypes = [Self.styleContentType]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "\(safeFilename(activeStyleName)).topostyle"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try MapStyleFile.write(currentDocument(named: activeStyleName), to: url)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func resetAll() {
        apply(Self.presets[0])
    }

    var renderStyle: RenderStyle {
        RenderStyle(
            colors: colors.map(\.vector),
            reliefOpacity: reliefEnabled ? Float(reliefOpacity) : 0,
            reliefExaggeration: Float(reliefExaggeration),
            reliefContrast: Float(reliefContrast),
            ambientLight: Float(ambientLight),
            sunAzimuthRadians: Float(sunAzimuthDegrees * .pi / 180)
        )
    }

    var currentDocumentForExport: MapStyleDocument {
        currentDocument(named: activeStyleName)
    }

    private func assign(_ document: MapStyleDocument) {
        colors = document.colors
        reliefEnabled = document.relief.enabled
        reliefOpacity = document.relief.opacity
        reliefExaggeration = document.relief.exaggeration
        reliefContrast = document.relief.contrast
        ambientLight = document.relief.ambientLight
        sunAzimuthDegrees = document.relief.sunAzimuthDegrees
        activeStyleID = document.id == "current" ? nil : document.id
        activeStyleName = document.name
    }

    private func propertyChanged() {
        guard !isApplying else { return }
        activeStyleID = nil
        activeStyleName = "Angepasst"
        revision &+= 1
        persistCurrent()
    }

    private func currentDocument(named name: String, id: String? = nil) -> MapStyleDocument {
        MapStyleDocument(
            id: id ?? activeStyleID ?? "current",
            name: name,
            colors: colors,
            relief: ReliefStyle(
                enabled: reliefEnabled,
                opacity: reliefOpacity,
                exaggeration: reliefExaggeration,
                contrast: reliefContrast,
                ambientLight: ambientLight,
                sunAzimuthDegrees: sunAzimuthDegrees
            )
        )
    }

    private func persistCurrent() {
        if let data = try? JSONEncoder().encode(currentDocument(named: activeStyleName)) {
            UserDefaults.standard.set(data, forKey: Self.currentStorageKey)
        }
    }

    private func persistCustomStyles() {
        if let data = try? JSONEncoder().encode(customStyles) {
            UserDefaults.standard.set(data, forKey: Self.customStorageKey)
        }
    }

    private func safeFilename(_ name: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/:\\?%*|\"<>")
        let cleaned = name.components(separatedBy: forbidden).joined(separator: "-")
        return cleaned.isEmpty ? "Kartenstil" : cleaned
    }
}
