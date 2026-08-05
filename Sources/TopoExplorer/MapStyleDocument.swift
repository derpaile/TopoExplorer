import Foundation

struct MapStyleDocument: Codable, Equatable, Identifiable {
    static let formatIdentifier = "de.topo-explorer.style"
    static let currentVersion = 1

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
        guard colors.count == 8 else {
            throw MapStyleFileError.wrongColorCount(colors.count)
        }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MapStyleFileError.missingName
        }
        guard colors.allSatisfy(\.isFinite), relief.isFinite else {
            throw MapStyleFileError.invalidNumber
        }

        var result = self
        result.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        result.colors = colors.map(\.clamped)
        result.relief = relief.clamped
        return result
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
            return "Der Stil enthält \(count) statt 8 Landklassenfarben."
        case .missingName:
            return "Der Stil hat keinen Namen."
        case .invalidNumber:
            return "Der Stil enthält ungültige Zahlenwerte."
        }
    }
}

private extension RGBAColor {
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
