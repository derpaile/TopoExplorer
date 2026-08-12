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
    private var didAttemptInitialLoad = false

    private static var isSandboxed: Bool {
        if ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil { return true }
        return FileManager.default.homeDirectoryForCurrentUser.path.contains("/Library/Containers/")
    }

    func loadDefaultIfAvailable() {
        guard manifest == nil, !didAttemptInitialLoad else { return }
        didAttemptInitialLoad = true
        var candidates: [URL] = []
        if let bookmark = UserDefaults.standard.data(forKey: Self.bookmarkKey) {
            var stale = false
            do {
                let resolved = try URL(
                    resolvingBookmarkData: bookmark,
                    options: [.withSecurityScope, .withoutUI],
                    relativeTo: nil,
                    bookmarkDataIsStale: &stale
                )
                if load(resolved), manifest != nil { return }
                UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
            } catch {
                UserDefaults.standard.removeObject(forKey: Self.bookmarkKey)
                errorMessage = "Die gespeicherte Ordnerfreigabe ist nicht mehr gültig. Bitte wähle den Kartendatenordner erneut."
            }
        }

        // A sandboxed release may only open a user-selected URL or a valid
        // security-scoped bookmark. A remembered plain path has no permission.
        if Self.isSandboxed {
            if errorMessage == nil {
                errorMessage = "Wähle einmal den Ordner MapData/Germany. macOS merkt sich diese Freigabe für spätere Starts."
            }
            isChoosingDirectory = true
            return
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

    @discardableResult
    func load(_ selectedURL: URL) -> Bool {
        let accessStarted = selectedURL.startAccessingSecurityScopedResource()
        var releaseNewAccess = accessStarted
        defer {
            if releaseNewAccess { selectedURL.stopAccessingSecurityScopedResource() }
        }

        if Self.isSandboxed && !accessStarted {
            errorMessage = "macOS hat den Zugriff nicht freigegeben. Bitte wähle den Ordner MapData/Germany erneut."
            return false
        }

        let directory: URL
        if FileManager.default.fileExists(atPath: selectedURL.appendingPathComponent("manifest.json").path) {
            directory = selectedURL
        } else if FileManager.default.fileExists(atPath: selectedURL.appendingPathComponent("Germany/manifest.json").path) {
            directory = selectedURL.appendingPathComponent("Germany", isDirectory: true)
        } else {
            errorMessage = "In diesem Ordner wurde keine manifest.json gefunden. Bitte wähle MapData/Germany."
            return false
        }

        do {
            let manifestURL = directory.appendingPathComponent("manifest.json")
            guard FileManager.default.isReadableFile(atPath: manifestURL.path) else {
                throw SessionError.accessDenied
            }
            let data = try Data(contentsOf: manifestURL)
            let decoded = try JSONDecoder().decode(MapManifest.self, from: data).validated()
            guard !FileManager.default.fileExists(atPath: directory.appendingPathComponent(".incomplete").path) else {
                throw SessionError.incomplete
            }

            let bookmark: Data?
            do {
                bookmark = try selectedURL.bookmarkData(
                    options: [.withSecurityScope, .securityScopeAllowOnlyReadAccess],
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
            } catch {
                if Self.isSandboxed { throw SessionError.bookmarkFailed }
                bookmark = nil
            }

            let previousAccess = securityScopedURL
            securityScopedURL = accessStarted ? selectedURL : nil
            releaseNewAccess = false
            previousAccess?.stopAccessingSecurityScopedResource()
            manifest = decoded
            dataDirectory = directory
            errorMessage = nil
            UserDefaults.standard.set(directory.path, forKey: Self.savedPathKey)
            if let bookmark {
                UserDefaults.standard.set(bookmark, forKey: Self.bookmarkKey)
            }
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func reportDirectorySelectionError(_ error: Error) {
        errorMessage = "Der Kartendatenordner konnte nicht gewählt werden: \(error.localizedDescription)"
    }
}

enum SessionError: LocalizedError {
    case incomplete
    case accessDenied
    case bookmarkFailed

    var errorDescription: String? {
        switch self {
        case .incomplete:
            "Die Kachelerzeugung ist noch nicht vollständig abgeschlossen."
        case .accessDenied:
            "macOS verweigert den Zugriff auf manifest.json. Bitte wähle den Ordner MapData/Germany erneut."
        case .bookmarkFailed:
            "Die dauerhafte Ordnerfreigabe konnte nicht gespeichert werden. Bitte wähle MapData/Germany erneut."
        }
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
    @Published private(set) var analysisSelection: MapSelection?
    @Published private(set) var analysisScreenRect: CGRect?
    @Published private(set) var areaStatistics: AreaStatistics?
    @Published private(set) var isAnalyzing = false
    @Published private(set) var analysisMessage: String?

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

    func updateAnalysisSelection(_ selection: MapSelection?, screenRect: CGRect?) {
        analysisSelection = selection
        analysisScreenRect = screenRect
        areaStatistics = nil
        analysisMessage = nil
        isAnalyzing = false
    }

    func beginAnalysis() {
        areaStatistics = nil
        analysisMessage = nil
        isAnalyzing = true
    }

    func updateAnalysisScreenRect(_ screenRect: CGRect?) {
        if analysisScreenRect != screenRect { analysisScreenRect = screenRect }
    }

    func finishAnalysis(_ statistics: AreaStatistics?, message: String? = nil) {
        areaStatistics = statistics
        analysisMessage = message
        isAnalyzing = false
    }

    func clearAnalysis() {
        analysisSelection = nil
        analysisScreenRect = nil
        areaStatistics = nil
        analysisMessage = nil
        isAnalyzing = false
    }
}
