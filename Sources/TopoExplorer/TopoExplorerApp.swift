import SwiftUI

@main
struct TopoExplorerApp: App {
    @StateObject private var session = MapSession()
    @StateObject private var style = StyleSettings()
    @StateObject private var viewport = ViewportController()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(session)
                .environmentObject(style)
                .environmentObject(viewport)
        }
        .windowStyle(.titleBar)
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
