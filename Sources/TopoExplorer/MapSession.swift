import Foundation

@MainActor
final class MapSession: ObservableObject {
    @Published private(set) var manifest: MapManifest?
    @Published private(set) var dataDirectory: URL?
    @Published private(set) var errorMessage: String?
    @Published var isChoosingDirectory = false

    private static let savedPathKey = "TopoExplorer.dataDirectory.v1"
    private static let bookmarkKey = "TopoExplorer.dataDirectoryBookmark.v1"
    private var securityScopedURL: URL?

    func loadDefaultIfAvailable() {
        guard manifest == nil else { return }
        var candidates: [URL] = []
        if let bookmark = UserDefaults.standard.data(forKey: Self.bookmarkKey) {
            var stale = false
            if let resolved = try? URL(
                resolvingBookmarkData: bookmark,
                options: [.withSecurityScope, .withoutUI],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ) {
                if stale { persistBookmark(for: resolved) }
                load(resolved)
                if manifest != nil { return }
            }
        }
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
        securityScopedURL?.stopAccessingSecurityScopedResource()
        securityScopedURL = nil
        if selectedURL.startAccessingSecurityScopedResource() {
            securityScopedURL = selectedURL
        }

        let directory: URL
        if FileManager.default.fileExists(atPath: selectedURL.appendingPathComponent("manifest.json").path) {
            directory = selectedURL
        } else if FileManager.default.fileExists(atPath: selectedURL.appendingPathComponent("Germany/manifest.json").path) {
            directory = selectedURL.appendingPathComponent("Germany", isDirectory: true)
        } else {
            securityScopedURL?.stopAccessingSecurityScopedResource()
            securityScopedURL = nil
            errorMessage = "In diesem Ordner wurde keine manifest.json gefunden."
            return
        }

        do {
            let data = try Data(contentsOf: directory.appendingPathComponent("manifest.json"))
            let decoded = try JSONDecoder().decode(MapManifest.self, from: data).validated()
            guard !FileManager.default.fileExists(atPath: directory.appendingPathComponent(".incomplete").path) else {
                throw SessionError.incomplete
            }
            manifest = decoded
            dataDirectory = directory
            errorMessage = nil
            UserDefaults.standard.set(directory.path, forKey: Self.savedPathKey)
            persistBookmark(for: selectedURL)
        } catch {
            manifest = nil
            dataDirectory = nil
            errorMessage = error.localizedDescription
        }
    }

    private func persistBookmark(for url: URL) {
        if let bookmark = try? url.bookmarkData(
            options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        ) {
            UserDefaults.standard.set(bookmark, forKey: Self.bookmarkKey)
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
    struct Target: Equatable {
        let centerX: Double
        let centerY: Double
        let metersPerPoint: Double
        let name: String?
    }

    @Published private(set) var fitToken = 0
    @Published private(set) var navigationToken = 0
    @Published private(set) var target: Target?
    @Published private(set) var activeReference: MapReference?
    @Published private(set) var status = ""
    @Published private(set) var labels: [MapLabel] = []
    @Published private(set) var probe: MapProbe?
    @Published private(set) var snapshot: ViewportSnapshot?

    func fitGermany() {
        activeReference = nil
        target = nil
        fitToken &+= 1
    }

    func show(_ reference: MapReference) {
        activeReference = reference
        focus(
            centerX: reference.centerX, centerY: reference.centerY,
            metersPerPoint: reference.metersPerPoint, name: reference.name
        )
    }

    func focus(centerX: Double, centerY: Double, metersPerPoint: Double, name: String? = nil) {
        if !MapReference.all.contains(where: { $0.name == name }) { activeReference = nil }
        target = Target(
            centerX: centerX, centerY: centerY,
            metersPerPoint: min(max(metersPerPoint, 5), 50_000), name: name
        )
        navigationToken &+= 1
    }

    func updateStatus(_ value: String) {
        if status != value { status = value }
    }

    func updateLabels(_ value: [MapLabel]) {
        if labels != value { labels = value }
    }

    func updateProbe(_ value: MapProbe?) {
        if probe != value { probe = value }
    }

    func updateSnapshot(_ value: ViewportSnapshot) {
        if snapshot != value { snapshot = value }
    }
}
