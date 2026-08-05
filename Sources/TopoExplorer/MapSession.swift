import Foundation

@MainActor
final class MapSession: ObservableObject {
    @Published private(set) var manifest: MapManifest?
    @Published private(set) var dataDirectory: URL?
    @Published private(set) var errorMessage: String?
    @Published var isChoosingDirectory = false

    private static let savedPathKey = "TopoExplorer.dataDirectory.v1"
    private var securityScopedURL: URL?

    func loadDefaultIfAvailable() {
        guard manifest == nil else { return }
        var candidates: [URL] = []
        if let saved = UserDefaults.standard.string(forKey: Self.savedPathKey) {
            candidates.append(URL(fileURLWithPath: saved, isDirectory: true))
        }
        candidates.append(
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
                .appendingPathComponent("MapData/Germany", isDirectory: true)
        )

        var executable = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        for _ in 0..<6 {
            candidates.append(executable.appendingPathComponent("MapData/Germany", isDirectory: true))
            executable.deleteLastPathComponent()
        }

        for candidate in candidates where FileManager.default.fileExists(atPath: candidate.appendingPathComponent("manifest.json").path) {
            load(candidate)
            return
        }
    }

    func load(_ selectedURL: URL) {
        let directory: URL
        if FileManager.default.fileExists(atPath: selectedURL.appendingPathComponent("manifest.json").path) {
            directory = selectedURL
        } else if FileManager.default.fileExists(atPath: selectedURL.appendingPathComponent("Germany/manifest.json").path) {
            directory = selectedURL.appendingPathComponent("Germany", isDirectory: true)
        } else {
            errorMessage = "In diesem Ordner wurde keine manifest.json gefunden."
            return
        }

        do {
            securityScopedURL?.stopAccessingSecurityScopedResource()
            if directory.startAccessingSecurityScopedResource() {
                securityScopedURL = directory
            }
            let data = try Data(contentsOf: directory.appendingPathComponent("manifest.json"))
            let decoded = try JSONDecoder().decode(MapManifest.self, from: data).validated()
            guard !FileManager.default.fileExists(atPath: directory.appendingPathComponent(".incomplete").path) else {
                throw SessionError.incomplete
            }
            manifest = decoded
            dataDirectory = directory
            errorMessage = nil
            UserDefaults.standard.set(directory.path, forKey: Self.savedPathKey)
        } catch {
            manifest = nil
            dataDirectory = nil
            errorMessage = error.localizedDescription
        }
    }
}

enum SessionError: LocalizedError {
    case incomplete

    var errorDescription: String? {
        "Die Kachelerzeugung ist noch nicht vollständig abgeschlossen."
    }
}

@MainActor
final class ViewportController: ObservableObject {
    @Published private(set) var fitToken = 0
    @Published private(set) var referenceToken = 0
    @Published private(set) var activeReference: MapReference?
    @Published private(set) var status = ""

    func fitGermany() {
        activeReference = nil
        fitToken &+= 1
    }

    func show(_ reference: MapReference) {
        activeReference = reference
        referenceToken &+= 1
    }

    func updateStatus(_ value: String) {
        if status != value { status = value }
    }
}
