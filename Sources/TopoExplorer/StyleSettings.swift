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
    private static let visibilityStorageKey = "TopoExplorer.surfaceVisibility.v1"
    private static let styleContentType = UTType(
        filenameExtension: "topostyle",
        conformingTo: .json
    ) ?? .json

    static let atlasColors = [
        "#101612", "#9E3544", "#C85862", "#D97972", "#39779B",
        "#B59B70", "#89985C", "#88AD69", "#5D9E91", "#A8AE83",
        "#E7EEE9", "#C7B474", "#D5C990", "#C69252", "#A97850",
        "#D6A34F", "#B78352", "#CEB06D", "#E3C83F", "#72AFC1",
        "#B98C78", "#D0A88E", "#9A6C3E", "#805132", "#AA7B56",
        "#B26670", "#D48372", "#D6B448", "#8C6F69", "#99A66B",
        "#A7BC72", "#3E6848", "#1F5135", "#315E3B", "#669664",
        "#779C65", "#3D6A49", "#79A875", "#50795A", "#947B55",
    ].map(RGBAColor.init(hex:))

    static let agricultureColors = [
        "#151611", "#9B5B5B", "#BC7772", "#D29A8C", "#3D7FA5",
        "#AA9B7C", "#87936D", "#91A876", "#6E9C90", "#A6A98C",
        "#E9EFEB", "#D7C884", "#E1D69E", "#E4A044", "#BD7744",
        "#F0B53F", "#C98B3D", "#DCB55D", "#F0D52F", "#63B4C7",
        "#C47F6B", "#D89F79", "#A86B37", "#884A2D", "#BD744C",
        "#B75268", "#E47161", "#E8BB22", "#87636A", "#95A950",
        "#A7C45A", "#56705A", "#385C47", "#48684E", "#778B70",
        "#849477", "#4B6952", "#839A7A", "#617568", "#8A765F",
    ].map(RGBAColor.init(hex:))

    static let forestColors = [
        "#111713", "#A54E56", "#C87676", "#DA9991", "#397CA4",
        "#B8A982", "#819A63", "#94AE72", "#5A9F8E", "#A6B187",
        "#EBF1ED", "#CBBB82", "#D5C797", "#C9A06E", "#BA9168",
        "#D0A76B", "#BD956C", "#C9A879", "#D6B965", "#76AFC0",
        "#BFA080", "#C9AA8B", "#9E754F", "#895F42", "#AA805E",
        "#AE7680", "#C08477", "#C7A74F", "#92797B", "#98A379",
        "#A5B886", "#5B7848", "#17492E", "#285C36", "#70A25F",
        "#8AAE69", "#326D45", "#83B67A", "#527C5E", "#A17B4E",
    ].map(RGBAColor.init(hex:))

    static let contrastColors = [
        "#080B0A", "#8F1730", "#DB3D4E", "#FF766D", "#1976B8",
        "#C79550", "#7F8B3B", "#73B45C", "#2C9B87", "#B5B879",
        "#F5FAF7", "#C6AE52", "#E6D478", "#E08A2E", "#B85E31",
        "#F0A82D", "#A66A32", "#D5A64D", "#F1CB16", "#43A8C1",
        "#B96D64", "#D08C71", "#8E5229", "#6D3420", "#A35D3A",
        "#A73F5C", "#DA5C52", "#D8A915", "#785761", "#88A142",
        "#9DBB4E", "#3F763E", "#063F24", "#1F5B2D", "#60A64F",
        "#80A94F", "#277043", "#69B26B", "#3D7A50", "#A56D36",
    ].map(RGBAColor.init(hex:))

    static let satelliteColors = [
        "#0C1110", "#824C47", "#A26658", "#C0846D", "#326A84",
        "#AB9068", "#687A50", "#7F995F", "#4D8076", "#859271",
        "#EDF1EE", "#C2AE69", "#B9A775", "#D0B874", "#C79F5C",
        "#B8954B", "#A98A46", "#D4C080", "#C0A44D", "#87A871",
        "#AD9653", "#C9B36E", "#9B7950", "#A87863", "#B08B62",
        "#9B7355", "#B98546", "#D1B94F", "#788B55", "#879963",
        "#8EA36B", "#657B42", "#173C2C", "#2B5035", "#5F824C",
        "#718947", "#234632", "#6E965D", "#486C4D", "#9A815B",
    ].map(RGBAColor.init(hex:))

    static let engravingColors = [
        "#E9DFC8", "#5E302C", "#7E4337", "#A05C48", "#63899A",
        "#C2A879", "#8C956A", "#A6AE79", "#718F83", "#9A9B72",
        "#F5F0E4", "#BFA96C", "#C8B784", "#D0B66C", "#C49B52",
        "#D7C383", "#AF8B45", "#CBB67D", "#B89347", "#9EA76A",
        "#BA9D55", "#CEB878", "#A98152", "#986747", "#B18A5F",
        "#9F7953", "#B27A48", "#C6A042", "#8B8D57", "#9A9B63",
        "#A6A86B", "#6E804F", "#354D37", "#455B3A", "#75825A",
        "#7D7B4B", "#3F5439", "#7F9365", "#627353", "#8D744E",
    ].map(RGBAColor.init(hex:))

    static let auroraColors = [
        "#071014", "#C23A63", "#E15A78", "#F48791", "#247CA0",
        "#896B62", "#456D68", "#4F8972", "#2B7E78", "#6B8D7B",
        "#D9EEF0", "#B99B55", "#8B7768", "#D6AE52", "#C48A4F",
        "#E4C966", "#B76D7C", "#D6A65D", "#C87750", "#4C9C8A",
        "#A77BBA", "#D0A35B", "#AA6C76", "#96619D", "#BC7A75",
        "#8E718C", "#DD875E", "#E3BA48", "#638F8B", "#769B78",
        "#83AA83", "#568C62", "#0E493E", "#1C5D4D", "#3C7B5A",
        "#578359", "#195144", "#4C936E", "#326F58", "#8B6F5C",
    ].map(RGBAColor.init(hex:))

    static let pastelColors = [
        "#F6F2EA", "#A96670", "#C98488", "#E3AAA5", "#70A8C2",
        "#D3B894", "#A7B28A", "#B7C998", "#86B6AD", "#BEC3A0",
        "#FFFFFC", "#DBCB8F", "#D7C7A7", "#E8C98A", "#DDB077",
        "#E7D39F", "#CDB982", "#E5C594", "#D9B477", "#B6C69D",
        "#C9B1D4", "#E0C69D", "#D1A692", "#C49DAE", "#D8B4A6",
        "#B7AAC7", "#E6AD8F", "#E5C75E", "#AAB99A", "#B4C4A4",
        "#AAC298", "#9CB68E", "#527B67", "#688B70", "#91AF82",
        "#A8B78C", "#5E8069", "#9CBE92", "#7DA887", "#B29A7B",
    ].map(RGBAColor.init(hex:))

    static let bauhausColors = [
        "#F1EBDD", "#B51D28", "#D74332", "#E86C4A", "#1768AC",
        "#C89031", "#7E8D35", "#55A64B", "#168F88", "#A2A64E",
        "#FFFFFF", "#E3B72C", "#B79A5B", "#F0C735", "#E59A24",
        "#D9B22D", "#C7762D", "#E4BC53", "#F29F26", "#5BA85B",
        "#2D9A9A", "#D49A2A", "#B96C30", "#8A552D", "#C57B50",
        "#A04A49", "#E1652E", "#E0C218", "#667C3E", "#78944A",
        "#8EAA55", "#5D852E", "#114B32", "#1E6137", "#3D7B3B",
        "#6B8232", "#19553A", "#4C954D", "#318448", "#9B6C3A",
    ].map(RGBAColor.init(hex:))

    static let standardPreset = MapStyleDocument(
        id: "builtin.atlas",
        name: "Standard · Erststart",
        colors: atlasColors,
        relief: ReliefStyle(
            enabled: true, opacity: 0.40, exaggeration: 34,
            contrast: 2.0, ambientLight: 0.09, sunAzimuthDegrees: 315
        )
    )

    static let presets = [
        standardPreset,
        MapStyleDocument(
            id: "builtin.agriculture",
            name: "Kulturarten",
            colors: agricultureColors,
            relief: ReliefStyle(
                enabled: true, opacity: 0.30, exaggeration: 26,
                contrast: 1.7, ambientLight: 0.11, sunAzimuthDegrees: 315
            )
        ),
        MapStyleDocument(
            id: "builtin.forest",
            name: "Waldarten",
            colors: forestColors,
            relief: ReliefStyle(
                enabled: true, opacity: 0.44, exaggeration: 38,
                contrast: 2.2, ambientLight: 0.08, sunAzimuthDegrees: 315
            )
        ),
        MapStyleDocument(
            id: "builtin.contrast",
            name: "Kontrastreich",
            colors: contrastColors,
            relief: ReliefStyle(
                enabled: true, opacity: 0.36, exaggeration: 32,
                contrast: 2.5, ambientLight: 0.06, sunAzimuthDegrees: 315
            )
        ),
        MapStyleDocument(
            id: "builtin.satellite",
            name: "Satellitisch",
            colors: satelliteColors,
            relief: ReliefStyle(
                enabled: true, opacity: 0.50, exaggeration: 42,
                contrast: 2.1, ambientLight: 0.07, sunAzimuthDegrees: 305
            )
        ),
        MapStyleDocument(
            id: "builtin.engraving",
            name: "Kupferstich",
            colors: engravingColors,
            relief: ReliefStyle(
                enabled: true, opacity: 0.27, exaggeration: 25,
                contrast: 2.7, ambientLight: 0.13, sunAzimuthDegrees: 300
            )
        ),
        MapStyleDocument(
            id: "builtin.aurora",
            name: "Nordlicht",
            colors: auroraColors,
            relief: ReliefStyle(
                enabled: true, opacity: 0.35, exaggeration: 36,
                contrast: 2.2, ambientLight: 0.06, sunAzimuthDegrees: 325
            )
        ),
        MapStyleDocument(
            id: "builtin.pastel",
            name: "Pastellfelder",
            colors: pastelColors,
            relief: ReliefStyle(
                enabled: true, opacity: 0.23, exaggeration: 22,
                contrast: 1.55, ambientLight: 0.14, sunAzimuthDegrees: 315
            )
        ),
        MapStyleDocument(
            id: "builtin.bauhaus",
            name: "Bauhaus",
            colors: bauhausColors,
            relief: ReliefStyle(
                enabled: true, opacity: 0.25, exaggeration: 24,
                contrast: 2.0, ambientLight: 0.10, sunAzimuthDegrees: 315
            )
        ),
    ]

    static let previewColorIndices = [1, 4, 13, 32, 34]

    static func description(for preset: MapStyleDocument) -> String {
        switch preset.id {
        case "builtin.atlas": "Unveränderte Darstellung beim ersten Start dieser Version."
        case "builtin.agriculture": "Kulturarten treten klarer als einzelne Felder hervor."
        case "builtin.forest": "Baumgattungen und Waldöffnungen sind besonders gut lesbar."
        case "builtin.contrast": "Kräftige Trennung für schwierige Licht- und Zoomstufen."
        case "builtin.satellite": "Naturnahe, dunkle Töne mit plastischem Gelände."
        case "builtin.engraving": "Warme Papierfarben wie eine historische Landesaufnahme."
        case "builtin.aurora": "Kühle Nachtkarte mit leuchtenden Kulturflächen."
        case "builtin.pastel": "Helle, ruhige Flächen für Beschriftung und Druck."
        case "builtin.bauhaus": "Reduzierte Primärfarben und starke Flächenrhythmen."
        default: ""
        }
    }

    @Published var colors: [RGBAColor] { didSet { propertyChanged() } }
    @Published private(set) var visibleClasses: [Bool] { didSet { visibilityChanged() } }
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
        let original = Self.standardPreset
        colors = original.colors
        let savedVisibility = UserDefaults.standard.array(forKey: Self.visibilityStorageKey) as? [Bool]
        visibleClasses = savedVisibility?.count == MapStyleDocument.colorCount
            ? savedVisibility!
            : Array(repeating: true, count: MapStyleDocument.colorCount)
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
            assign(Self.presets.first(where: { $0.id == saved.id }) ?? saved)
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

    func isClassVisible(_ index: Int) -> Bool {
        visibleClasses.indices.contains(index) ? visibleClasses[index] : true
    }

    func toggleClassVisibility(_ index: Int) {
        guard visibleClasses.indices.contains(index) else { return }
        visibleClasses[index].toggle()
    }

    func setClassVisibility(_ indices: [Int], visible: Bool) {
        var next = visibleClasses
        for index in indices where next.indices.contains(index) { next[index] = visible }
        visibleClasses = next
    }

    func isolateClass(_ index: Int, within availableIndices: [Int]) {
        var next = visibleClasses
        for candidate in availableIndices where next.indices.contains(candidate) {
            next[candidate] = candidate == index
        }
        visibleClasses = next
    }

    func setColor(_ color: RGBAColor, at index: Int) {
        guard colors.indices.contains(index) else { return }
        colors[index] = color
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

    func resetToStandard() {
        apply(Self.standardPreset)
    }

    var renderStyle: RenderStyle {
        RenderStyle(
            colors: colors.enumerated().map { index, color in
                var vector = color.vector
                vector.w = isClassVisible(index) ? 1 : 0
                return vector
            },
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

    private func visibilityChanged() {
        UserDefaults.standard.set(visibleClasses, forKey: Self.visibilityStorageKey)
        revision &+= 1
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
