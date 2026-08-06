import Foundation

struct MapStyleDocument: Codable, Equatable, Identifiable {
    static let formatIdentifier = "de.topo-explorer.style"
    static let currentVersion = 2
    static let colorCount = 40

    var format: String
    var version: Int
    var id: String
    var name: String
    var colors: [RGBAColor]
    var relief: ReliefStyle

    init(
        id: String,
        name: String,
        colors: [RGBAColor],
        relief: ReliefStyle,
        format: String = Self.formatIdentifier,
        version: Int = Self.currentVersion
    ) {
        self.format = format
        self.version = version
        self.id = id
        self.name = name
        self.colors = colors
        self.relief = relief
    }

    func validated() throws -> MapStyleDocument {
        guard format == Self.formatIdentifier else {
            throw MapStyleFileError.wrongFormat
        }
        guard version > 0, version <= Self.currentVersion else {
            throw MapStyleFileError.unsupportedVersion(version)
        }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MapStyleFileError.missingName
        }
        guard colors.allSatisfy(\.isFinite), relief.isFinite else {
            throw MapStyleFileError.invalidNumber
        }

        var result = self
        result.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        result.colors = Self.richColors(from: colors).map(\.clamped)
        result.version = Self.currentVersion
        guard result.colors.count == Self.colorCount else {
            throw MapStyleFileError.wrongColorCount(colors.count)
        }
        result.relief = relief.clamped
        return result
    }

    private static func richColors(from colors: [RGBAColor]) -> [RGBAColor] {
        if colors.count == 8 {
            return richColors(from: [
                colors[0], colors[1], colors[2], colors[5],
                colors[5].mixed(with: colors[2]),
                colors[3], colors[4], colors[3].mixed(with: colors[4]),
                colors[4].mixed(with: colors[2]), colors[6], colors[7],
            ])
        }
        guard colors.count == 11 else { return colors }
        let snow = RGBAColor(red: 0.91, green: 0.94, blue: 0.92)
        return [
            colors[0], colors[1], colors[1], colors[1], colors[10],
            colors[2], colors[9], colors[9], colors[9].mixed(with: colors[10]),
            colors[9], snow, colors[3], colors[4],
            colors[3], colors[3], colors[3], colors[3], colors[3], colors[3],
            colors[3], colors[3], colors[3], colors[4], colors[4], colors[4],
            colors[4], colors[3], colors[3], colors[4], colors[4], colors[9],
            colors[6], colors[6], colors[6], colors[5], colors[5], colors[6],
            colors[5], colors[7], colors[8],
        ]
    }
}

struct ReliefStyle: Codable, Equatable {
    var enabled: Bool
    var opacity: Double
    var exaggeration: Double
    var contrast: Double
    var ambientLight: Double
    var sunAzimuthDegrees: Double

    var isFinite: Bool {
        opacity.isFinite && exaggeration.isFinite && contrast.isFinite &&
            ambientLight.isFinite && sunAzimuthDegrees.isFinite
    }

    var clamped: ReliefStyle {
        ReliefStyle(
            enabled: enabled,
            opacity: opacity.clamped(to: 0...1),
            exaggeration: exaggeration.clamped(to: 0...120),
            contrast: contrast.clamped(to: 0.5...5),
            ambientLight: ambientLight.clamped(to: 0...0.35),
            sunAzimuthDegrees: sunAzimuthDegrees.truncatingRemainder(dividingBy: 360).wrappedDegrees
        )
    }
}

enum MapStyleFile {
    static func read(from url: URL) throws -> MapStyleDocument {
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(MapStyleDocument.self, from: data).validated()
    }

    static func write(_ document: MapStyleDocument, to url: URL) throws {
        let document = try document.validated()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(document).write(to: url, options: .atomic)
    }
}

enum MapStyleFileError: LocalizedError {
    case wrongFormat
    case unsupportedVersion(Int)
    case wrongColorCount(Int)
    case missingName
    case invalidNumber

    var errorDescription: String? {
        switch self {
        case .wrongFormat:
            return "Die Datei ist kein TopoExplorer-Kartenstil."
        case let .unsupportedVersion(version):
            return "Stilversion \(version) wird von dieser App nicht unterstützt."
        case let .wrongColorCount(count):
            return "Der Stil enthält \(count) statt \(MapStyleDocument.colorCount) Landklassenfarben."
        case .missingName:
            return "Der Stil hat keinen Namen."
        case .invalidNumber:
            return "Der Stil enthält ungültige Zahlenwerte."
        }
    }
}

private extension RGBAColor {
    func mixed(with other: RGBAColor) -> RGBAColor {
        RGBAColor(
            red: (red + other.red) / 2,
            green: (green + other.green) / 2,
            blue: (blue + other.blue) / 2,
            alpha: (alpha + other.alpha) / 2
        )
    }

    var isFinite: Bool {
        red.isFinite && green.isFinite && blue.isFinite && alpha.isFinite
    }

    var clamped: RGBAColor {
        RGBAColor(
            red: red.clamped(to: 0...1),
            green: green.clamped(to: 0...1),
            blue: blue.clamped(to: 0...1),
            alpha: alpha.clamped(to: 0...1)
        )
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double {
        min(max(self, range.lowerBound), range.upperBound)
    }

    var wrappedDegrees: Double {
        self < 0 ? self + 360 : self
    }
}
