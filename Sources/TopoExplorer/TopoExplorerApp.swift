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
