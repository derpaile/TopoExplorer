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
    @StateObject private var commands = AtlasCommandCenter()

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
                .environmentObject(commands)
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(after: .sidebar) {
                Button("Deutschland einpassen") { viewport.fitGermany() }
                    .keyboardShortcut("0", modifiers: [])
                Button("Kartendaten wählen …") { session.isChoosingDirectory = true }
                    .keyboardShortcut("o", modifiers: .command)
            }
            CommandMenu("Atlas") {
                Button("Stöberpalette …") { commands.send(.openPalette) }
                    .keyboardShortcut("k", modifiers: .command)
                    .disabled(session.manifest == nil)
                Divider()
                Button("Suchen") { commands.send(.focusSearch) }
                    .keyboardShortcut("f", modifiers: .command)
                Button("Nächster Fund") { commands.send(.nextLandscape) }
                    .keyboardShortcut("e", modifiers: [.command, .shift])
                Divider()
                Button("Datenatlas") { commands.send(.openDataCatalog) }
                    .keyboardShortcut("d", modifiers: [.command, .shift])
                Button("Sammlung") { commands.send(.openCollection) }
                    .keyboardShortcut("m", modifiers: [.command, .shift])
                    .disabled(bookmarks.bookmarks.isEmpty)
                Divider()
                Button("Flächenanalyse") { commands.send(.toggleAreaAnalysis) }
                    .keyboardShortcut("a", modifiers: [.command, .shift])
                Button("Landschaftsprofil") { commands.send(.toggleLandscapeProfile) }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                Button("Kartenausschnitt exportieren") { commands.send(.exportMap) }
                    .keyboardShortcut("x", modifiers: [.command, .shift])
                Divider()
                Button("Seitenleiste ein-/ausblenden") { commands.send(.toggleSidebar) }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
            }
        }
    }
}
