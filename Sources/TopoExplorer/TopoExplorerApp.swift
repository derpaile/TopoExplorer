import AppKit
import SwiftUI

@main
struct TopoExplorerApp: App {
    @StateObject private var session = MapSession()
    @StateObject private var style = StyleSettings()
    @StateObject private var viewport = ViewportController()
    @StateObject private var layers = LayerSettings()
    @StateObject private var comparison = ComparisonSettings()
    @StateObject private var search = SearchController()
    @StateObject private var bookmarks = BookmarkStore()
    @StateObject private var export = MapExportController()
    @StateObject private var geoScience = GeoScienceSettings()

    init() {
        Self.installDockIcon()
    }

    private static func installDockIcon() {
        var candidates: [URL] = []
        if let bundled = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") {
            candidates.append(bundled)
        }
        candidates.append(
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
                .appendingPathComponent("app/AppIcon.icns")
        )
        var executable = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        for _ in 0..<6 {
            candidates.append(executable.appendingPathComponent("app/AppIcon.icns"))
            executable.deleteLastPathComponent()
        }
        if let iconURL = candidates.first(where: { FileManager.default.isReadableFile(atPath: $0.path) }),
           let icon = NSImage(contentsOf: iconURL)
        {
            NSApplication.shared.applicationIconImage = icon
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(session)
                .environmentObject(style)
                .environmentObject(viewport)
                .environmentObject(layers)
                .environmentObject(comparison)
                .environmentObject(search)
                .environmentObject(bookmarks)
                .environmentObject(export)
                .environmentObject(geoScience)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .sidebar) {
                Button("Deutschland einpassen") { viewport.fitGermany() }
                    .keyboardShortcut("0", modifiers: [])
                Button("Kartendaten wählen …") { session.isChoosingDirectory = true }
                    .keyboardShortcut("o", modifiers: .command)
            }
        }
    }
}
