import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var session: MapSession
    @EnvironmentObject private var style: StyleSettings
    @EnvironmentObject private var viewport: ViewportController
    @EnvironmentObject private var layers: LayerSettings
    @EnvironmentObject private var comparison: ComparisonSettings
    @EnvironmentObject private var search: SearchController
    @EnvironmentObject private var bookmarks: BookmarkStore
    @EnvironmentObject private var export: MapExportController
    @FocusState private var searchFocused: Bool
    @State private var showSearchResults = false

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            content
        }
        .frame(minWidth: 980, minHeight: 680)
        .onAppear {
            session.loadDefaultIfAvailable()
            search.load(from: session.dataDirectory)
        }
        .onChange(of: session.dataDirectory?.path) { _, _ in
            search.load(from: session.dataDirectory)
        }
        .fileImporter(
            isPresented: $session.isChoosingDirectory,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first { session.load(url) }
            case .failure(let error):
                if (error as NSError).code != NSUserCancelledError {
                    session.reportDirectorySelectionError(error)
                }
            }
        }
    }

    private var controls: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text("TopoExplorer")
                    .font(.headline)
                if let manifest = session.manifest {
                    Text(manifest.name)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Menu {
                    ForEach(MapReference.all) { reference in
                        Button(reference.name) { viewport.show(reference) }
                    }
                } label: {
                    Label(viewport.activeReference?.name ?? "Referenzen", systemImage: "viewfinder")
                }
                .disabled(session.manifest == nil)
                Button {
                    viewport.fitGermany()
                } label: {
                    Label("Deutschland", systemImage: "arrow.down.left.and.arrow.up.right")
                }
                .disabled(session.manifest == nil)
                Button {
                    session.isChoosingDirectory = true
                } label: {
                    Label("Kartendaten", systemImage: "folder")
                }
            }
            .frame(height: 38)

            HStack(spacing: 10) {
                searchField
                if session.manifest?.hasLandcover2020 == true {
                    Picker("Jahr", selection: $comparison.mode) {
                        ForEach(LandcoverMode.allCases) { mode in Text(mode.title).tag(mode) }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 190)
                }
                layerMenu
                bookmarkMenu
                Spacer()
                Text(viewport.status)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(height: 34)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 3)
        .background(.bar)
    }

    @ViewBuilder
    private var content: some View {
        if let manifest = session.manifest, let directory = session.dataDirectory {
            HSplitView {
                ZStack(alignment: .bottomLeading) {
                    MetalMapView(
                        manifest: manifest,
                        dataDirectory: directory,
                        style: style,
                        layers: layers,
                        comparison: comparison,
                        export: export,
                        viewport: viewport
                    )
                    labelsOverlay
                    VStack(alignment: .trailing, spacing: 2) {
                        Link(
                            "Land: DLR/EOC 2015 · CC BY-NC 4.0",
                            destination: URL(string: "https://geoservice.dlr.de/data-assets/1ccmlap3mn39.html")!
                        )
                        Link(
                            "Land: mundialis 2020 · DL-DE/BY-2.0",
                            destination: URL(string: "https://www.mundialis.de/deutschland-2020-landbedeckung-auf-basis-von-sentinel-2-daten/")!
                        )
                        Link(
                            "Vektor: © OpenStreetMap contributors · ODbL",
                            destination: URL(string: "https://www.openstreetmap.org/copyright")!
                        )
                    }
                    .font(.caption2)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 7))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .padding(10)
                    if comparison.mode == .comparison {
                        GeometryReader { geometry in
                            Rectangle()
                                .fill(.white.opacity(0.85))
                                .shadow(color: .black.opacity(0.7), radius: 1)
                                .frame(width: 2)
                                .position(
                                    x: geometry.size.width * comparison.splitPosition,
                                    y: geometry.size.height / 2
                                )
                        }
                        .allowsHitTesting(false)
                    }
                    Text("Ziehen: verschieben   ·   Mausrad: zoomen   ·   Referenzen: feste Prüfgebiete   ·   0: Deutschland")
                        .font(.caption)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(12)
                    if let probe = viewport.probe {
                        Text(probe.summary)
                            .font(.caption.monospacedDigit())
                            .padding(.horizontal, 9)
                            .padding(.vertical, 6)
                            .background(.ultraThinMaterial, in: Capsule())
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                            .padding(12)
                            .allowsHitTesting(false)
                    }
                }
                InspectorView(
                    manifest: manifest, style: style, session: session,
                    layers: layers, comparison: comparison, export: export,
                    viewport: viewport
                )
            }
        } else {
            VStack(spacing: 16) {
                Image(systemName: "map")
                    .font(.system(size: 56, weight: .light))
                    .foregroundStyle(.secondary)
                Text("Deutschland-Kartendaten fehlen")
                    .font(.title2.weight(.semibold))
                Text(session.errorMessage ?? "Wähle den fertigen Ordner MapData/Germany. Beim ersten Start benötigt macOS dafür deine Freigabe.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 560)
                Button("Kartendaten wählen") { session.isChoosingDirectory = true }
                    .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var searchField: some View {
        TextField("Ort oder E/N", text: $search.query)
            .textFieldStyle(.roundedBorder)
            .frame(width: 180)
            .focused($searchFocused)
            .onSubmit {
                if let reference = MapReference.all.first(where: {
                    $0.name.compare(
                        search.query.trimmingCharacters(in: .whitespacesAndNewlines),
                        options: [.caseInsensitive, .diacriticInsensitive]
                    ) == .orderedSame
                }) {
                    viewport.show(reference)
                    showSearchResults = false
                    searchFocused = false
                } else if let coordinate = parsedCoordinate(search.query) {
                    viewport.focus(
                        centerX: coordinate.x, centerY: coordinate.y,
                        metersPerPoint: 40, name: "Koordinate"
                    )
                    showSearchResults = false
                    searchFocused = false
                } else if let first = search.results.first {
                    select(first)
                }
            }
            .onChange(of: search.results) { _, results in
                showSearchResults = searchFocused && !results.isEmpty
            }
            .onChange(of: searchFocused) { _, focused in
                showSearchResults = focused && !search.results.isEmpty
            }
            .popover(isPresented: $showSearchResults, arrowEdge: .top) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(search.results) { result in
                        Button {
                            select(result)
                        } label: {
                            HStack {
                                Text(result.name)
                                Spacer()
                                if result.population > 0 {
                                    Text(result.population.formatted())
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .frame(width: 270)
                            .padding(.vertical, 4)
                        }
                        .buttonStyle(.plain)
                        Divider()
                    }
                }
                .padding(8)
            }
    }

    private var layerMenu: some View {
        Menu {
            Toggle("Straßen", isOn: $layers.roads)
            Toggle("Eisenbahnen", isOn: $layers.railways)
            Toggle("Flüsse", isOn: $layers.waterways)
            Toggle("Grenzen", isOn: $layers.boundaries)
            Toggle("Orte", isOn: $layers.places)
        } label: {
            Label("Ebenen", systemImage: "square.3.layers.3d")
        }
    }

    private var bookmarkMenu: some View {
        Menu {
            if let snapshot = viewport.snapshot {
                Button("Aktuelle Ansicht merken") {
                    bookmarks.add(
                        name: viewport.activeReference?.name ?? "Kartenansicht",
                        snapshot: snapshot
                    )
                }
            }
            if !bookmarks.bookmarks.isEmpty {
                Divider()
                ForEach(bookmarks.bookmarks) { bookmark in
                    Button(bookmark.name) {
                        viewport.focus(
                            centerX: bookmark.centerX, centerY: bookmark.centerY,
                            metersPerPoint: bookmark.metersPerPoint, name: bookmark.name
                        )
                    }
                }
                Divider()
                Menu("Lesezeichen löschen") {
                    ForEach(bookmarks.bookmarks) { bookmark in
                        Button(bookmark.name, role: .destructive) { bookmarks.remove(bookmark) }
                    }
                }
            }
        } label: {
            Label("Lesezeichen", systemImage: "bookmark")
        }
    }

    private var labelsOverlay: some View {
        ZStack {
            ForEach(viewport.labels) { label in
                Text(label.name)
                    .font(.system(size: label.prominence >= 100_000 ? 13 : 11, weight: .semibold))
                    .foregroundStyle(.white)
                    .shadow(color: .black, radius: 1.5)
                    .padding(.horizontal, 3)
                    .background(.black.opacity(0.22), in: RoundedRectangle(cornerRadius: 3))
                    .position(label.point)
            }
        }
        .allowsHitTesting(false)
    }

    private func select(_ result: PlaceSearchRecord) {
        let metersPerPoint = result.population >= 500_000 ? 90.0
            : result.population >= 100_000 ? 65.0
            : result.population >= 20_000 ? 45.0 : 25.0
        viewport.focus(
            centerX: result.worldX, centerY: result.worldY,
            metersPerPoint: metersPerPoint, name: result.name
        )
        search.query = result.name
        showSearchResults = false
        searchFocused = false
    }

    private func parsedCoordinate(_ value: String) -> (x: Double, y: Double)? {
        let parts = value
            .replacingOccurrences(of: ";", with: " ")
            .replacingOccurrences(of: ",", with: " ")
            .split(whereSeparator: { $0.isWhitespace })
        guard
            parts.count == 2,
            let x = Double(parts[0]),
            let y = Double(parts[1]),
            let manifest = session.manifest,
            x >= manifest.left, x <= manifest.right,
            y >= manifest.bottom, y <= manifest.top
        else { return nil }
        return (x, y)
    }
}
