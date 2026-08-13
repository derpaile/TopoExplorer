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
    @EnvironmentObject private var geoScience: GeoScienceSettings
    @FocusState private var searchFocused: Bool
    @State private var showSearchResults = false
    @State private var showInspector = false
    @State private var showHelp = false
    @State private var sidebarVisible = true
    @State private var sidebarMode = SidebarMode.explore
    @State private var surfaceQuery = ""
    @State private var selectedSurfaceID: Int?
    @State private var analysisMode = false

    var body: some View {
        Group {
            if let manifest = session.manifest, let directory = session.dataDirectory {
                explorer(manifest: manifest, directory: directory)
            } else {
                welcomeView
            }
        }
        .frame(minWidth: 1_060, minHeight: 700)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            session.loadDefaultIfAvailable()
            search.load(from: session.dataDirectory)
        }
        .onChange(of: session.dataDirectory?.path) { _, _ in
            search.load(from: session.dataDirectory)
        }
        .onChange(of: session.manifest) { _, manifest in
            if let manifest { geoScience.reconcile(with: manifest) }
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

    private func explorer(manifest: MapManifest, directory: URL) -> some View {
        HStack(spacing: 0) {
            if sidebarVisible {
                sidebar(manifest: manifest)
                    .frame(width: 286)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }

            mapArea(manifest: manifest, directory: directory)
        }
        .animation(.snappy(duration: 0.28), value: sidebarVisible)
    }

    private func sidebar(manifest: MapManifest) -> some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    ZStack {
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [Color(red: 0.18, green: 0.48, blue: 0.34),
                                             Color(red: 0.08, green: 0.26, blue: 0.20)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                        Image(systemName: "globe.europe.africa.fill")
                            .foregroundStyle(.white)
                            .font(.system(size: 17, weight: .medium))
                    }
                    .frame(width: 34, height: 34)
                    .shadow(color: .black.opacity(0.16), radius: 7, y: 3)

                    VStack(alignment: .leading, spacing: 0) {
                        Text("Topo Atlas")
                            .font(.system(size: 16, weight: .semibold, design: .rounded))
                        Text("Deutschland entdecken")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }

                searchField

                Picker("Seitenleiste", selection: $sidebarMode) {
                    ForEach(SidebarMode.allCases) { mode in
                        Label(mode.title, systemImage: mode.symbol).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            .padding(.horizontal, 15)
            .padding(.top, 36)
            .padding(.bottom, 13)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    if sidebarMode == .explore {
                        layerSection
                        if manifest.hasLandcover2020 { landcoverSection }
                        bookmarkSection
                    } else if sidebarMode == .surfaces {
                        surfaceEditorSection(manifest: manifest)
                    } else if sidebarMode == .geoscience {
                        geoScienceSection(manifest: manifest)
                    } else {
                        sidebarReliefSection
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }

            sidebarFooter(manifest: manifest)
        }
        .background {
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                LinearGradient(
                    colors: [Color.white.opacity(0.06), Color.green.opacity(0.025), .clear],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        }
        .overlay(alignment: .trailing) {
            Rectangle().fill(.primary.opacity(0.09)).frame(width: 1)
        }
    }

    private var discoverSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            sidebarSectionTitle("Entdecken", systemImage: "sparkles")

            Button {
                viewport.fitGermany()
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "map.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color(red: 0.18, green: 0.48, blue: 0.34))
                        .frame(width: 28, height: 28)
                        .background(Color.green.opacity(0.11), in: RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Deutschland")
                            .font(.subheadline.weight(.medium))
                        Text("Die ganze Karte im Überblick")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(8)
                .contentShape(Rectangle())
            }
            .buttonStyle(AtlasRowButtonStyle(isSelected: viewport.activeReference == nil))

            Text("ATLASORTE")
                .font(.system(size: 9, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(.tertiary)
                .padding(.top, 5)
                .padding(.leading, 7)

            ForEach(MapReference.all) { reference in
                Button {
                    viewport.show(reference)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: referenceSymbol(reference))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(referenceColor(reference))
                            .frame(width: 26)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(reference.name)
                                .font(.subheadline.weight(.medium))
                            Text(referenceDescription(reference))
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        if viewport.activeReference == reference {
                            Circle()
                                .fill(Color.accentColor)
                                .frame(width: 6, height: 6)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(AtlasRowButtonStyle(isSelected: viewport.activeReference == reference))
            }
        }
    }

    private var layerSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                sidebarSectionTitle("Kartenebenen", systemImage: "square.3.layers.3d")
                Spacer()
                Text("6 Datensätze")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.bottom, 2)

            AtlasLayerRow(
                title: "Orte & Namen", detail: "Städte und Siedlungen",
                symbol: "building.2.fill", tint: .orange, isOn: $layers.places
            )
            AtlasLayerGroup(
                title: "Natur & Gelände", detail: "Nach Themen filtern",
                symbol: "mountain.2.fill", tint: .green, isOn: $layers.geonames
            ) {
                AtlasLayerSubheading("Relief")
                layerKindRow("Gipfel & Höhenpunkte", kind: 7, mask: \.geonameKinds)
                layerKindRow("Landschaften", kind: 8, mask: \.geonameKinds)
                layerKindRow("Höhlen", kind: 12, mask: \.geonameKinds)
                AtlasLayerSubheading("Wasser & Natur")
                layerKindRow("Gewässer & Seen", kind: 9, mask: \.geonameKinds)
                layerKindRow("Moore & Schutzgebiete", kind: 10, mask: \.geonameKinds)
                layerKindRow("Inseln", kind: 11, mask: \.geonameKinds)
            }
            AtlasLayerGroup(
                title: "Straßen", detail: "Nach Straßenklasse filtern",
                symbol: "road.lanes", tint: .red, isOn: $layers.roads
            ) {
                AtlasLayerSubheading("Überregional")
                layerKindRow("Autobahnen", kind: 1, mask: \.roadKinds)
                layerKindRow("Fernstraßen", kind: 2, mask: \.roadKinds)
                layerKindRow("Bundesstraßen", kind: 3, mask: \.roadKinds)
                AtlasLayerSubheading("Regional")
                layerKindRow("Landesstraßen", kind: 4, mask: \.roadKinds)
                layerKindRow("Kreisstraßen", kind: 5, mask: \.roadKinds)
                AtlasLayerSubheading("Lokal")
                layerKindRow("Ortsstraßen", kind: 6, mask: \.roadKinds)
                layerKindRow("Erschließungswege", kind: 7, mask: \.roadKinds)
                layerKindRow("Feldwege", kind: 8, mask: \.roadKinds)
            }
            AtlasLayerGroup(
                title: "Schienen", detail: "Nach Verkehrssystem filtern",
                symbol: "tram.fill", tint: .purple, isOn: $layers.railways
            ) {
                AtlasLayerSubheading("Fern & regional")
                layerKindRow("Eisenbahn", kind: 1, mask: \.railwayKinds)
                layerKindRow("Schmalspurbahn", kind: 2, mask: \.railwayKinds)
                AtlasLayerSubheading("Stadtverkehr")
                layerKindRow("Stadtbahn", kind: 3, mask: \.railwayKinds)
                layerKindRow("U-Bahn", kind: 4, mask: \.railwayKinds)
                layerKindRow("Straßenbahn", kind: 5, mask: \.railwayKinds)
                AtlasLayerSubheading("Sonderverkehr")
                layerKindRow("Sonderbahnen", kind: 6, mask: \.railwayKinds)
                layerKindRow("Im Bau", kind: 7, mask: \.railwayKinds)
            }
            AtlasLayerRow(
                title: "Flüsse", detail: "Fließgewässer",
                symbol: "water.waves", tint: .blue, isOn: $layers.waterways
            )
            AtlasLayerRow(
                title: "Grenzen", detail: "Bundes- und Landesgrenzen",
                symbol: "point.topleft.down.to.point.bottomright.curvepath", tint: .secondary,
                isOn: $layers.boundaries
            )
        }
    }

    private func layerKindRow(
        _ title: String,
        kind: UInt8,
        mask keyPath: ReferenceWritableKeyPath<LayerSettings, UInt32>
    ) -> some View {
        let bit = UInt32(1) << UInt32(kind)
        return AtlasLayerKindRow(
            title: title,
            isOn: Binding(
                get: { (layers[keyPath: keyPath] & bit) != 0 },
                set: { enabled in
                    if enabled { layers[keyPath: keyPath] |= bit }
                    else { layers[keyPath: keyPath] &= ~bit }
                }
            ),
            isolate: { layers[keyPath: keyPath] = bit }
        )
    }

    private var landcoverSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sidebarSectionTitle("Land im Wandel", systemImage: "square.split.2x1")
            Text("Landbedeckung zweier Zeitstände direkt vergleichen.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Picker("Zeitstand", selection: $comparison.mode) {
                ForEach(LandcoverMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if comparison.mode == .comparison {
                VStack(spacing: 4) {
                    Slider(value: $comparison.splitPosition, in: 0.1...0.9)
                    HStack {
                        Text("2015")
                        Spacer()
                        Text("Trennlinie verschieben")
                        Spacer()
                        Text("2020")
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(10)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12))
    }

    private func surfaceEditorSection(manifest: MapManifest) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    sidebarSectionTitle("Farben & Sichtbarkeit", systemImage: "paintpalette.fill")
                    Text("Farbfeld wählen oder Klassen ausgrauen")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextField("Nutzpflanze oder Baumart", text: $surfaceQuery)
                    .textFieldStyle(.plain)
                if !surfaceQuery.isEmpty {
                    Button { surfaceQuery = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 9)
            .frame(height: 32)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 9))
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .stroke(.primary.opacity(0.08), lineWidth: 0.7)
            }

            HStack(spacing: 6) {
                Button("Alle farbig") {
                    style.setClassVisibility(manifest.classes.map(\.id), visible: true)
                }
                Button("Alle grau") {
                    style.setClassVisibility(manifest.classes.map(\.id), visible: false)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            ForEach(surfaceGroups(for: manifest), id: \.name) { group in
                SurfaceGroupEditor(
                    name: group.name,
                    classes: group.classes,
                    allClassIDs: manifest.classes.map(\.id),
                    query: surfaceQuery,
                    style: style,
                    selectedID: $selectedSurfaceID
                )
            }
        }
    }

    private func geoScienceSection(manifest: MapManifest) -> some View {
        GeoScienceSidebar(manifest: manifest, settings: geoScience, style: style)
    }

    private var sidebarReliefSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sidebarSectionTitle("Relief", systemImage: "mountain.2.fill")

            Toggle("Gelände plastisch darstellen", isOn: $style.reliefEnabled)
                .font(.subheadline.weight(.medium))

            Group {
                reliefSlider(
                    "Stärke", value: $style.reliefOpacity,
                    range: 0...1, format: "%.0f %%", multiplier: 100
                )
                reliefSlider(
                    "Überhöhung", value: $style.reliefExaggeration,
                    range: 0...120, format: "%.0f×"
                )
                reliefSlider(
                    "Kontrast", value: $style.reliefContrast,
                    range: 0.5...5, format: "%.1f"
                )
                reliefSlider(
                    "Grundlicht", value: $style.ambientLight,
                    range: 0...0.35, format: "%.0f %%", multiplier: 100
                )
                reliefSlider(
                    "Sonne · \(compassDirection)", value: $style.sunAzimuthDegrees,
                    range: 0...360, format: "%.0f°"
                )
            }
            .disabled(!style.reliefEnabled)

            Text("Die Änderungen erscheinen ohne Dialog direkt auf der Karte.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(.white.opacity(0.22), lineWidth: 0.7)
        }
    }

    private var bookmarkSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                sidebarSectionTitle("Gemerkte Orte", systemImage: "bookmark.fill")
                Spacer()
                if let snapshot = viewport.snapshot {
                    Button {
                        bookmarks.add(
                            name: viewport.activeReference?.name ?? "Kartenansicht",
                            snapshot: snapshot
                        )
                    } label: {
                        Image(systemName: "plus")
                    }
                    .buttonStyle(.borderless)
                    .help("Aktuelle Ansicht merken")
                }
            }

            if bookmarks.bookmarks.isEmpty {
                Text("Spannende Ausschnitte lassen sich hier für später sammeln.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 7)
                    .padding(.bottom, 4)
            } else {
                ForEach(bookmarks.bookmarks) { bookmark in
                    HStack(spacing: 8) {
                        Button {
                            viewport.focus(
                                centerX: bookmark.centerX, centerY: bookmark.centerY,
                                metersPerPoint: bookmark.metersPerPoint, name: bookmark.name
                            )
                        } label: {
                            Label(bookmark.name, systemImage: "mappin")
                                .font(.subheadline)
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        Button {
                            bookmarks.remove(bookmark)
                        } label: {
                            Image(systemName: "xmark")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(.plain)
                        .help("Lesezeichen löschen")
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 6)
                    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                }
            }
        }
    }

    private func sidebarFooter(manifest: MapManifest) -> some View {
        VStack(spacing: 9) {
            Divider().opacity(0.55)

            Button {
                exportVisibleMap()
            } label: {
                Label("Kartenausschnitt exportieren", systemImage: "square.and.arrow.up")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(viewport.snapshot == nil)

            Button {
                session.isChoosingDirectory = true
            } label: {
                HStack {
                    Image(systemName: "externaldrive.fill")
                        .foregroundStyle(.secondary)
                    Text(manifest.name)
                        .lineLimit(1)
                    Spacer()
                    Text("Kartendaten")
                        .foregroundStyle(.tertiary)
                }
                .font(.caption)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 12)
    }

    private func mapArea(manifest: MapManifest, directory: URL) -> some View {
        ZStack {
            MetalMapView(
                manifest: manifest,
                dataDirectory: directory,
                style: style,
                layers: layers,
                comparison: comparison,
                geoScience: geoScience,
                export: export,
                viewport: viewport,
                analysisMode: analysisMode
            )

            labelsOverlay

            if let rect = viewport.analysisScreenRect, rect.width > 0, rect.height > 0 {
                RoundedRectangle(cornerRadius: 3)
                    .fill(Color.cyan.opacity(0.14))
                    .overlay {
                        RoundedRectangle(cornerRadius: 3)
                            .stroke(Color.cyan, style: StrokeStyle(lineWidth: 2, dash: [7, 4]))
                    }
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                    .allowsHitTesting(false)
            }

            if manifest.hasLandcover2020 && comparison.mode == .comparison {
                comparisonOverlay
            }

            mapTopBar(manifest: manifest)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            mapBottomBar
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)

            if let probe = viewport.probe, viewport.analysisSelection == nil {
                CursorInfoGlassOverlay(
                    probe: probe,
                    thematicProduct: visibleGeoProduct(in: manifest),
                    showsElevation: style.reliefEnabled,
                    contentColor: probe.classID.flatMap { id in
                        probeColor(probe, landClassID: id, manifest: manifest)
                    }
                )
                .padding(.top, 76)
                .padding(.leading, 14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .transition(.move(edge: .top).combined(with: .opacity))
                .allowsHitTesting(false)
            }

            if viewport.analysisSelection != nil {
                AreaStatisticsPanel(
                    statistics: viewport.areaStatistics,
                    isLoading: viewport.isAnalyzing,
                    message: viewport.analysisMessage,
                    onClose: { analysisMode = false }
                )
                .frame(width: 380)
                .padding(.top, 76)
                .padding(.trailing, 14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }

            if showInspector {
                InspectorView(
                    manifest: manifest,
                    style: style,
                    session: session,
                    layers: layers,
                    comparison: comparison,
                    export: export,
                    viewport: viewport,
                    onClose: { showInspector = false }
                )
                .frame(width: 326)
                .padding(.top, 62)
                .padding(.trailing, 12)
                .padding(.bottom, 58)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .clipped()
        .animation(.snappy(duration: 0.25), value: showInspector)
    }

    private func mapTopBar(manifest: MapManifest) -> some View {
        HStack(spacing: 8) {
            MapChromeButton(
                symbol: sidebarVisible ? "sidebar.left" : "sidebar.right",
                help: sidebarVisible ? "Seitenleiste ausblenden" : "Seitenleiste einblenden"
            ) {
                sidebarVisible.toggle()
            }

            HStack(spacing: 9) {
                Image(systemName: viewport.activeReference.map(referenceSymbol) ?? "map")
                    .foregroundStyle(Color(red: 0.18, green: 0.48, blue: 0.34))
                VStack(alignment: .leading, spacing: 0) {
                    Text(viewport.activeReference?.name ?? "Deutschland")
                        .font(.subheadline.weight(.semibold))
                    Text(viewport.activeReference.map(referenceDescription) ?? "Topo Atlas")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .atlasGlass(cornerRadius: 13)

            Spacer()

            HStack(spacing: 1) {
                MapChromeButton(symbol: "minus", help: "Herauszoomen") { zoom(by: 1 / 1.55) }
                MapChromeButton(symbol: "plus", help: "Hineinzoomen") { zoom(by: 1.55) }
                MapChromeButton(symbol: "scope", help: "Deutschland einpassen") { viewport.fitGermany() }
            }

            MapChromeButton(symbol: "questionmark", help: "Bedienung") {
                showHelp.toggle()
            }
            .popover(isPresented: $showHelp, arrowEdge: .top) {
                VStack(alignment: .leading, spacing: 9) {
                    Text("Auf der Karte")
                        .font(.headline)
                    Label("Ziehen zum Verschieben", systemImage: "hand.draw")
                    Label("Mausrad oder Trackpad zum Zoomen", systemImage: "plus.magnifyingglass")
                    Label("Doppelklick zum Hineinzoomen", systemImage: "cursorarrow.click.2")
                    Label("Mauszeiger erklärt die sichtbare Kartenklasse", systemImage: "info.circle")
                    Label("Analyseknopf: Rechteck ziehen und Fläche auswerten", systemImage: "rectangle.dashed")
                }
                .font(.subheadline)
                .padding(15)
                .frame(width: 285, alignment: .leading)
            }


            MapChromeButton(
                symbol: analysisMode ? "xmark" : "rectangle.dashed",
                help: analysisMode ? "Flächenanalyse beenden" : "Fläche analysieren"
            ) {
                analysisMode.toggle()
                if analysisMode {
                    showInspector = false
                    viewport.clearAnalysis()
                }
            }

            MapChromeButton(symbol: "paintpalette", help: "Stile & Export") {
                if !showInspector { analysisMode = false }
                showInspector.toggle()
            }
        }
        .padding(12)
    }

    private func probeColor(
        _ probe: MapProbe,
        landClassID: Int,
        manifest: MapManifest
    ) -> Color? {
        if let product = visibleGeoProduct(in: manifest) {
            guard let thematic = probe.thematic,
                  let item = product.classes.first(where: { $0.id == thematic.classID })
            else { return nil }
            return RGBAColor(hex: item.defaultColor).color
        }
        return style.colors.indices.contains(landClassID) ? style.colors[landClassID].color : nil
    }

    private func visibleGeoProduct(in manifest: MapManifest) -> MapManifest.ThematicRaster? {
        guard geoScience.presentation == .baseMap || geoScience.opacity > 0 else { return nil }
        return geoScience.product(in: manifest)
    }

    private var mapBottomBar: some View {
        HStack(alignment: .bottom, spacing: 10) {
            if !viewport.status.isEmpty {
                Text(viewport.status)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .atlasGlass(cornerRadius: 10)
            }

            Spacer()

            HStack(spacing: 6) {
                Link("DLR", destination: URL(string: "https://geoservice.dlr.de/data-assets/1ccmlap3mn39.html")!)
                Text("·")
                Link("mundialis", destination: URL(string: "https://www.mundialis.de/deutschland-2020-landbedeckung-auf-basis-von-sentinel-2-daten/")!)
                Text("·")
                Link("© OpenStreetMap", destination: URL(string: "https://www.openstreetmap.org/copyright")!)
                Text("·")
                Link("© BKG", destination: URL(string: "https://gdz.bkg.bund.de/index.php/default/geographische-namen-1-250-000-gn250.html")!)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .atlasGlass(cornerRadius: 9)
        }
        .padding(12)
        .animation(.snappy(duration: 0.20), value: viewport.probe != nil)
    }

    private var comparisonOverlay: some View {
        GeometryReader { geometry in
            let splitX = geometry.size.width * comparison.splitPosition
            ZStack {
                Rectangle()
                    .fill(.white.opacity(0.9))
                    .shadow(color: .black.opacity(0.45), radius: 1)
                    .frame(width: 2)
                    .position(
                        x: splitX,
                        y: geometry.size.height / 2
                    )

                Text("2015")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .atlasGlass(cornerRadius: 9)
                    .position(x: max(34, splitX - 40), y: 78)

                Text("2020")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .atlasGlass(cornerRadius: 9)
                    .position(x: min(geometry.size.width - 34, splitX + 40), y: 78)
            }
        }
        .allowsHitTesting(false)
    }

    private var labelsOverlay: some View {
        Canvas(rendersAsynchronously: true) { context, _ in
            for label in viewport.labels {
                context.draw(mapLabelText(label), at: label.point, anchor: .center)
            }
        }
        .allowsHitTesting(false)
    }

    private func mapLabelText(_ label: MapLabel) -> Text {
        let text = Text(label.kind == 7 ? "▲ \(label.name)" : label.name)
        switch label.kind {
        case 7:
            return text.font(.system(size: 12, weight: .light, design: .serif))
                .italic().foregroundColor(.white.opacity(0.96))
        case 8:
            return text.font(.system(size: 15, weight: .light, design: .serif))
                .tracking(1.6).foregroundColor(.white.opacity(0.96))
        case 9:
            return text.font(.system(size: 12, weight: .light, design: .rounded))
                .italic().foregroundColor(.white.opacity(0.96))
        case 10:
            return text.font(.system(size: 11, weight: .light, design: .rounded))
                .foregroundColor(.white.opacity(0.96))
        case 11:
            return text.font(.system(size: 12, weight: .light, design: .serif))
                .italic().foregroundColor(.white.opacity(0.96))
        case 12:
            return text.font(.system(size: 10, weight: .light, design: .monospaced))
                .foregroundColor(.white.opacity(0.96))
        default:
            return text.font(placeFont(population: label.prominence))
                .foregroundColor(.white.opacity(0.96))
        }
    }

    private func placeFont(population: Double) -> Font {
        if population >= 1_000_000 { return .system(size: 17, weight: .light, design: .rounded) }
        if population >= 500_000 { return .system(size: 16, weight: .light, design: .rounded) }
        if population >= 100_000 { return .system(size: 14, weight: .light, design: .rounded) }
        if population >= 50_000 { return .system(size: 13, weight: .light, design: .rounded) }
        if population >= 10_000 { return .system(size: 12, weight: .light, design: .rounded) }
        return .system(size: 10, weight: .light, design: .rounded)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            TextField("Ort oder Koordinate", text: $search.query)
                .textFieldStyle(.plain)
                .focused($searchFocused)
                .onSubmit { submitSearch() }
            if !search.query.isEmpty {
                Button {
                    search.query = ""
                    showSearchResults = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(Color.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.primary.opacity(searchFocused ? 0.16 : 0.07), lineWidth: 1)
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
                        HStack(spacing: 10) {
                            Image(systemName: result.symbolName)
                                .foregroundStyle(Color(red: 0.18, green: 0.48, blue: 0.34))
                            VStack(alignment: .leading, spacing: 1) {
                                Text(result.name)
                                if result.population > 0 {
                                    Text("\(result.population.formatted()) Einwohner")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                } else if result.kind > 6 {
                                    Text(result.kindTitle)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                        }
                        .frame(width: 255)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 7)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    if result != search.results.last { Divider() }
                }
            }
            .padding(6)
        }
    }

    private var welcomeView: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 0.89, green: 0.93, blue: 0.89),
                    Color(red: 0.78, green: 0.87, blue: 0.86),
                    Color(red: 0.90, green: 0.89, blue: 0.79),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            Circle()
                .fill(.white.opacity(0.30))
                .frame(width: 520, height: 520)
                .blur(radius: 20)
                .offset(x: -340, y: -230)

            VStack(spacing: 22) {
                ZStack {
                    Circle().fill(.thinMaterial)
                    Image(systemName: "globe.europe.africa.fill")
                        .font(.system(size: 46, weight: .light))
                        .foregroundStyle(Color(red: 0.12, green: 0.36, blue: 0.25))
                }
                .frame(width: 92, height: 92)
                .shadow(color: .black.opacity(0.12), radius: 20, y: 10)

                VStack(spacing: 7) {
                    Text("Willkommen im Topo Atlas")
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                    Text("Landschaften lesen, Zusammenhänge entdecken und Deutschland neu betrachten.")
                        .font(.title3)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 590)
                }

                HStack(spacing: 18) {
                    WelcomeFeature(symbol: "mountain.2.fill", title: "Relief", detail: "Gelände plastisch lesen")
                    WelcomeFeature(symbol: "square.3.layers.3d", title: "Ebenen", detail: "Netze einzeln erkunden")
                    WelcomeFeature(symbol: "leaf.fill", title: "Gesamtkarte", detail: "Komplementäre Landklassen vereint")
                }

                VStack(spacing: 8) {
                    Button {
                        session.isChoosingDirectory = true
                    } label: {
                        Label("Deutschland-Kartendaten wählen", systemImage: "folder.fill")
                            .font(.headline)
                            .padding(.horizontal, 7)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .tint(Color(red: 0.13, green: 0.38, blue: 0.27))

                    Text(session.errorMessage ?? "Wähle den fertigen Ordner MapData/Germany.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(42)
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28))
            .overlay {
                RoundedRectangle(cornerRadius: 28)
                    .stroke(.white.opacity(0.48), lineWidth: 1)
            }
            .shadow(color: .black.opacity(0.14), radius: 36, y: 18)
        }
    }

    private func sidebarSectionTitle(_ title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
    }

    private func surfaceGroups(
        for manifest: MapManifest
    ) -> [(name: String, classes: [MapManifest.LandClass])] {
        let order = ["Grundlage", "Siedlung", "Natur", "Landwirtschaft", "Wald"]
        let grouped = Dictionary(grouping: manifest.classes) { $0.group ?? "Oberflächen" }
        let known = order.compactMap { name in
            grouped[name].map { (name: name, classes: $0) }
        }
        return known + grouped.keys.filter { !order.contains($0) }.sorted().map {
            (name: $0, classes: grouped[$0] ?? [])
        }
    }

    private var compassDirection: String {
        let names = ["N", "NO", "O", "SO", "S", "SW", "W", "NW"]
        let index = Int((style.sunAzimuthDegrees + 22.5).truncatingRemainder(dividingBy: 360) / 45)
        return names[min(max(index, 0), names.count - 1)]
    }

    private func reliefSlider(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        format: String,
        multiplier: Double = 1
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.caption)
                Spacer()
                Text(String(format: format, value.wrappedValue * multiplier))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
        }
    }

    private func submitSearch() {
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

    private func zoom(by factor: Double) {
        guard let snapshot = viewport.snapshot else { return }
        viewport.focus(
            centerX: snapshot.centerX,
            centerY: snapshot.centerY,
            metersPerPoint: snapshot.metersPerPoint / factor,
            name: viewport.activeReference?.name
        )
    }

    private func exportVisibleMap() {
        export.chooseDestination(
            style: style,
            layers: layers,
            snapshot: viewport.snapshot,
            labels: viewport.labels,
            comparison: comparison,
            sources: session.manifest?.sources ?? []
        )
    }

    private func referenceSymbol(_ reference: MapReference) -> String {
        switch reference.id {
        case "harz": "mountain.2.fill"
        case "alpen": "mountain.2"
        case "kueste": "water.waves"
        case "ruhrgebiet": "building.2.crop.circle.fill"
        default: "leaf.fill"
        }
    }

    private func referenceColor(_ reference: MapReference) -> Color {
        switch reference.id {
        case "harz": .green
        case "alpen": .indigo
        case "kueste": .blue
        case "ruhrgebiet": .orange
        default: Color(red: 0.48, green: 0.58, blue: 0.24)
        }
    }

    private func referenceDescription(_ reference: MapReference) -> String {
        switch reference.id {
        case "harz": "Wald & Mittelgebirge"
        case "alpen": "Hochgebirge & Täler"
        case "kueste": "Meer, Marsch & Häfen"
        case "ruhrgebiet": "Städte & Industrie"
        default: "Felder & Siedlungen"
        }
    }
}

private struct GeoScienceSidebar: View {
    let manifest: MapManifest
    @ObservedObject var settings: GeoScienceSettings
    @ObservedObject var style: StyleSettings
    @State private var showAllClasses = false
    @State private var showSources = false

    private var product: MapManifest.ThematicRaster? {
        settings.product(in: manifest)
    }

    private var legendClasses: [MapManifest.LandClass] {
        product?.classes.filter { $0.id != 0 } ?? []
    }

    private var displayedClasses: [MapManifest.LandClass] {
        showAllClasses ? legendClasses : Array(legendClasses.prefix(6))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Label("Geowissenschaften", systemImage: "fossil.shell.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("Untergrund und Gesteinsarten")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }

            if manifest.availableThematicRasters.isEmpty {
                panel {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Keine geologischen Flächenkarten", systemImage: "externaldrive.badge.exclamationmark")
                            .font(.subheadline.weight(.medium))
                        Text("Erzeuge Substrat und Geologie mit der Geowissenschafts-Pipeline.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else {
                layerSelection

                if let product {
                    displayControls
                    legend(for: product)
                    if !product.sources.isEmpty { sources(for: product) }
                }
            }
        }
        .onChange(of: settings.selectedRasterID) { _, _ in
            showAllClasses = false
            showSources = false
        }
    }

    private var layerSelection: some View {
        panel {
            VStack(alignment: .leading, spacing: 7) {
                sectionLabel("Flächenkarte", symbol: "square.3.layers.3d")
                Picker("Flächenkarte", selection: $settings.selectedRasterID) {
                    Text("Landbedeckung").tag(String?.none)
                    Divider()
                    ForEach(manifest.availableThematicRasters) { product in
                        Text(product.name).tag(Optional(product.id))
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("Flächenkarte")

                Text(product == nil ? "Die normale Atlas-Karte bleibt sichtbar." : "Die gewählte Karte wird direkt im Atlas dargestellt.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var displayControls: some View {
        panel {
            VStack(alignment: .leading, spacing: 10) {
                sectionLabel("Darstellung", symbol: "circle.lefthalf.filled")

                Picker("Darstellung", selection: $settings.presentation) {
                    Text("Überlagern").tag(ThematicPresentation.overlay)
                    Text("Basiskarte").tag(ThematicPresentation.baseMap)
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Divider()

                Toggle(isOn: $style.reliefEnabled) {
                    Label("Geländerelief", systemImage: "mountain.2.fill")
                        .font(.caption.weight(.medium))
                }
                .toggleStyle(.switch)
                .controlSize(.small)

                if style.reliefEnabled {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text("Reliefstärke")
                            Spacer()
                            Text(style.reliefOpacity.formatted(.percent.precision(.fractionLength(0))))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption)
                        Slider(value: $style.reliefOpacity, in: 0...1)
                    }
                }

                if settings.presentation == .overlay {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Text("Deckkraft")
                            Spacer()
                            Text(settings.opacity.formatted(.percent.precision(.fractionLength(0))))
                                .monospacedDigit()
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption)
                        Slider(value: $settings.opacity, in: 0...1)
                    }
                } else {
                    Text("Landbedeckung wird vollständig durch die Flächenkarte ersetzt.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func legend(for product: MapManifest.ThematicRaster) -> some View {
        panel {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    sectionLabel("Legende", symbol: "list.bullet.rectangle")
                    Spacer()
                    Text("\(legendClasses.count) Klassen")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }

                VStack(spacing: 6) {
                    ForEach(displayedClasses) { item in
                        HStack(spacing: 8) {
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(RGBAColor(hex: item.defaultColor).color)
                                .frame(width: 20, height: 13)
                                .overlay {
                                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                                        .stroke(.white.opacity(0.35), lineWidth: 0.5)
                                }
                            Text(item.name)
                                .font(.caption)
                                .lineLimit(1)
                            Spacer(minLength: 0)
                        }
                    }
                }

                if legendClasses.count > 6 {
                    Button {
                        withAnimation(.snappy(duration: 0.2)) { showAllClasses.toggle() }
                    } label: {
                        HStack {
                            Text(showAllClasses ? "Weniger anzeigen" : "Alle Klassen anzeigen")
                            Spacer()
                            Image(systemName: "chevron.down")
                                .font(.caption2.weight(.bold))
                                .rotationEffect(.degrees(showAllClasses ? 180 : 0))
                        }
                        .font(.caption.weight(.medium))
                        .foregroundStyle(Color.accentColor)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .padding(.top, 2)
                }
            }
        }
    }

    private func sources(for product: MapManifest.ThematicRaster) -> some View {
        panel {
            DisclosureGroup(isExpanded: $showSources) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(product.sources) { source in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(source.name)
                                .font(.caption.weight(.medium))
                            Text(source.scale.map { "Maßstab 1:\($0.formatted()) · \(source.license)" } ?? source.license)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.top, 8)
            } label: {
                sectionLabel("Datenquellen", symbol: "checkmark.seal")
            }
        }
    }

    private func sectionLabel(_ title: String, symbol: String) -> some View {
        Label(title, systemImage: symbol)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    private func panel<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(.white.opacity(0.20), lineWidth: 0.7)
            }
    }
}

private enum SidebarMode: String, CaseIterable, Identifiable {
    case explore
    case surfaces
    case geoscience
    case relief

    var id: String { rawValue }
    var title: String {
        switch self {
        case .explore: "Karte"
        case .surfaces: "Flächen"
        case .geoscience: "Geologie"
        case .relief: "Relief"
        }
    }
    var symbol: String {
        switch self {
        case .explore: "square.3.layers.3d"
        case .surfaces: "paintpalette.fill"
        case .geoscience: "fossil.shell.fill"
        case .relief: "mountain.2.fill"
        }
    }
}

private struct SurfaceGroupEditor: View {
    let name: String
    let classes: [MapManifest.LandClass]
    let allClassIDs: [Int]
    let query: String
    @ObservedObject var style: StyleSettings
    @Binding var selectedID: Int?
    @State private var isExpanded: Bool

    init(
        name: String,
        classes: [MapManifest.LandClass],
        allClassIDs: [Int],
        query: String,
        style: StyleSettings,
        selectedID: Binding<Int?>
    ) {
        self.name = name
        self.classes = classes
        self.allClassIDs = allClassIDs
        self.query = query
        self.style = style
        _selectedID = selectedID
        _isExpanded = State(initialValue: name == "Landwirtschaft" || name == "Wald")
    }

    private var filteredClasses: [MapManifest.LandClass] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return classes }
        return classes.filter {
            $0.name.range(
                of: needle,
                options: [.caseInsensitive, .diacriticInsensitive]
            ) != nil
        }
    }

    private var visibleCount: Int {
        classes.reduce(0) { $0 + (style.isClassVisible($1.id) ? 1 : 0) }
    }

    private var visibilitySymbol: String {
        visibleCount == classes.count ? "checkmark.square.fill"
            : visibleCount == 0 ? "square" : "minus.square.fill"
    }

    var body: some View {
        if !filteredClasses.isEmpty {
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 7) {
                    Button {
                        style.setClassVisibility(
                            classes.map(\.id), visible: visibleCount != classes.count
                        )
                    } label: {
                        Image(systemName: visibilitySymbol)
                            .foregroundStyle(visibleCount == 0 ? .secondary : Color.accentColor)
                    }
                    .buttonStyle(.plain)
                    .help(visibleCount == classes.count ? "Gruppe ausgrauen" : "Gruppe farbig zeigen")

                    Button {
                        withAnimation(.snappy(duration: 0.2)) { isExpanded.toggle() }
                    } label: {
                        HStack {
                            Text(name).font(.caption.weight(.semibold))
                            Spacer()
                            Text("\(visibleCount)/\(classes.count)")
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.tertiary)
                                .rotationEffect(.degrees(isExpanded || !query.isEmpty ? 90 : 0))
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                if isExpanded || !query.isEmpty {
                    VStack(spacing: 3) {
                        ForEach(filteredClasses) { landClass in
                            SurfaceClassEditor(
                                landClass: landClass,
                                allClassIDs: allClassIDs,
                                style: style,
                                isSelected: selectedID == landClass.id,
                                onSelect: {
                                    withAnimation(.snappy(duration: 0.18)) {
                                        selectedID = selectedID == landClass.id ? nil : landClass.id
                                    }
                                }
                            )
                        }
                    }
                }
            }
            .padding(9)
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(.white.opacity(0.20), lineWidth: 0.7)
            }
        }
    }
}

private struct SurfaceClassEditor: View {
    let landClass: MapManifest.LandClass
    let allClassIDs: [Int]
    @ObservedObject var style: StyleSettings
    let isSelected: Bool
    let onSelect: () -> Void

    private static let quickColors = [
        "#E8DFA8", "#D8C67A", "#E3C83F", "#D6A34F", "#C69252", "#9A6C3E",
        "#A7BC72", "#779C65", "#50795A", "#315E3B", "#1F5135", "#5D9E91",
        "#39779B", "#72AFC1", "#D97972", "#B26670", "#9E3544", "#8C6F69",
    ].map(RGBAColor.init(hex:))

    private var isVisible: Bool { style.isClassVisible(landClass.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Button { style.toggleClassVisibility(landClass.id) } label: {
                    Image(systemName: isVisible ? "checkmark.square.fill" : "square")
                        .foregroundStyle(isVisible ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .help(isVisible ? "Ausgrauen" : "Farbig zeigen")

                Button(action: onSelect) {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isVisible ? style.colors[landClass.id].color : Color.secondary.opacity(0.28))
                        .frame(width: 21, height: 18)
                        .overlay {
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .stroke(.white.opacity(0.52), lineWidth: 0.7)
                        }
                        .shadow(color: .black.opacity(0.10), radius: 2, y: 1)
                }
                .buttonStyle(.plain)
                .help("Farbe direkt ändern")

                Button(action: onSelect) {
                    Text(landClass.name)
                        .font(.caption)
                        .foregroundStyle(isVisible ? .primary : .secondary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.plain)

                if isSelected {
                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 5)
            .frame(minHeight: 27)
            .background(
                isSelected ? Color.accentColor.opacity(0.09) : .clear,
                in: RoundedRectangle(cornerRadius: 7)
            )

            if isSelected {
                VStack(alignment: .leading, spacing: 7) {
                    LazyVGrid(
                        columns: Array(repeating: GridItem(.fixed(22), spacing: 7), count: 7),
                        alignment: .leading,
                        spacing: 7
                    ) {
                        ForEach(Array(Self.quickColors.enumerated()), id: \.offset) { _, color in
                            Button { style.setColor(color, at: landClass.id) } label: {
                                Circle()
                                    .fill(color.color)
                                    .frame(width: 21, height: 21)
                                    .overlay {
                                        Circle().stroke(.white.opacity(0.65), lineWidth: 0.8)
                                    }
                            }
                            .buttonStyle(.plain)
                        }
                    }

                    HStack(spacing: 8) {
                        Button("Nur diese") {
                            style.isolateClass(landClass.id, within: allClassIDs)
                        }
                        Button("Standard") {
                            style.setColor(RGBAColor(hex: landClass.defaultColor), at: landClass.id)
                        }
                        Spacer()
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .font(.caption2)
                }
                .padding(.horizontal, 5)
                .padding(.bottom, 5)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }
}

private struct AreaStatisticsPanel: View {
    let statistics: AreaStatistics?
    let isLoading: Bool
    let message: String?
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Label("Flächenanalyse", systemImage: "chart.bar.xaxis")
                    .font(.headline)
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.bold))
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
            }

            if isLoading {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Einwohner und Flächen werden berechnet …")
                        .foregroundStyle(.secondary)
                }
                .font(.subheadline)
                .padding(.vertical, 8)
            } else if let statistics {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 9) {
                    metric(
                        "Einwohner",
                        statistics.population?.formatted(.number) ?? "—",
                        symbol: "person.3.fill"
                    )
                    metric(
                        "Einwohner / km²",
                        statistics.populationDensity.map { Int($0.rounded()).formatted(.number) } ?? "—",
                        symbol: "building.2.fill"
                    )
                    metric(
                        "Auswahl",
                        area(statistics.selection.squareKilometers),
                        symbol: "square.dashed"
                    )
                    metric(
                        "Rasteranalyse",
                        "≈ \(Int(statistics.sampledResolution)) m",
                        symbol: "square.grid.3x3"
                    )
                }

                if statistics.subjectName == "Landbedeckung" {
                    VStack(spacing: 6) {
                        groupRow("Landwirtschaft", value: statistics.squareKilometers(in: "Landwirtschaft"), color: .yellow)
                        groupRow("Wald", value: statistics.squareKilometers(in: "Wald"), color: .green)
                        groupRow("Siedlung", value: statistics.squareKilometers(in: "Siedlung"), color: .red)
                        groupRow("Natur", value: statistics.squareKilometers(in: "Natur"), color: .blue)
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 7) {
                    Text("Vorkommende Klassen · \(statistics.subjectName)")
                        .font(.subheadline.weight(.semibold))
                    Text("Anteile beziehen sich auf die ausgewählte Fläche und die angegebene Rasterabtastung.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    ScrollView {
                        LazyVStack(spacing: 5) {
                            ForEach(statistics.classes) { item in
                                HStack(spacing: 8) {
                                    Circle()
                                        .fill(groupColor(item.group))
                                        .frame(width: 7, height: 7)
                                    VStack(alignment: .leading, spacing: 0) {
                                        Text(item.name).lineLimit(1)
                                        Text(item.group)
                                            .font(.caption2)
                                            .foregroundStyle(.tertiary)
                                    }
                                    Spacer()
                                    Text("\(area(item.squareKilometers)) · \(item.share.formatted(.percent.precision(.fractionLength(1))))")
                                        .font(.caption.monospacedDigit())
                                        .foregroundStyle(.secondary)
                                }
                                .font(.caption)
                            }
                        }
                    }
                    .frame(maxHeight: 205)
                }

                HStack(spacing: 5) {
                    Image(systemName: statistics.population == nil ? "exclamationmark.triangle" : "checkmark.circle")
                    Text(populationNote(statistics))
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            } else {
                Label(message ?? "Auf der Karte ein Rechteck ziehen.", systemImage: "cursorarrow.motionlines")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 8)
            }
        }
        .padding(15)
        .atlasGlass(cornerRadius: 17)
        .shadow(color: .black.opacity(0.18), radius: 18, y: 8)
    }

    private func metric(_ title: String, _ value: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(title, systemImage: symbol)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(9)
        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
    }

    private func groupRow(_ title: String, value: Double, color: Color) -> some View {
        HStack {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(title)
            Spacer()
            Text(area(value)).monospacedDigit().foregroundStyle(.secondary)
        }
        .font(.caption)
    }

    private func groupColor(_ group: String) -> Color {
        switch group {
        case "Landwirtschaft": .yellow
        case "Wald": .green
        case "Siedlung": .red
        case "Natur": .blue
        default: .secondary
        }
    }

    private func area(_ squareKilometers: Double) -> String {
        if squareKilometers < 1 {
            return "\(Int((squareKilometers * 100).rounded()).formatted(.number)) ha"
        }
        return "\(squareKilometers.formatted(.number.precision(.fractionLength(1)))) km²"
    }

    private func populationNote(_ statistics: AreaStatistics) -> String {
        guard let source = statistics.populationSource else {
            return "Bevölkerungsraster fehlt im Kartendatenordner."
        }
        if statistics.populationCoverage < 0.999 {
            return "\(source) deckt \(statistics.populationCoverage.formatted(.percent.precision(.fractionLength(0)))) der Auswahl ab."
        }
        return source
    }
}

private struct CursorInfoGlassOverlay: View {
    let probe: MapProbe
    let thematicProduct: MapManifest.ThematicRaster?
    let showsElevation: Bool
    let contentColor: Color?

    private var accent: Color { contentColor ?? .secondary }
    private var title: String { thematicProduct?.name ?? "Oberfläche" }
    private var symbol: String { thematicProduct == nil ? "leaf.fill" : "fossil.shell.fill" }
    private var className: String {
        thematicProduct == nil
            ? probe.className ?? "Keine Kartendaten"
            : probe.thematic?.className ?? "Keine Geologiedaten"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Circle()
                    .fill(accent)
                    .frame(width: 11, height: 11)
                    .overlay(Circle().stroke(.white.opacity(0.65), lineWidth: 0.7))
                    .shadow(color: accent.opacity(0.35), radius: 3)
                Label(title, systemImage: symbol)
                    .font(.caption.weight(.semibold))
                    .lineLimit(1)
                    .foregroundStyle(.secondary)
            }

            Text(className)
                .font(.system(size: 19, weight: .semibold, design: .rounded))
                .lineLimit(2)
                .contentTransition(.interpolate)

            if thematicProduct != nil, let thematic = probe.thematic {
                if let quality = thematic.qualitySummary {
                    Label(quality, systemImage: "checkmark.seal")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } else if thematicProduct != nil {
                Text("Für diesen Kartenpunkt liegt keine Klassifikation vor.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            if showsElevation, let elevation = probe.elevation {
                Label("\(elevation.formatted()) m Höhe", systemImage: "mountain.2.fill")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
        }
        .frame(width: 286, alignment: .leading)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.ultraThinMaterial)
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [accent.opacity(0.17), .clear, .black.opacity(0.025)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [.white.opacity(0.72), accent.opacity(0.20), .black.opacity(0.12)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.8
                )
        }
        .overlay(alignment: .topLeading) {
            Capsule()
                .fill(.white.opacity(0.38))
                .frame(width: 74, height: 1)
                .padding(.leading, 18)
        }
        .shadow(color: .black.opacity(0.18), radius: 16, y: 7)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    private var accessibilitySummary: String {
        var parts = [title, className]
        if let quality = probe.thematic?.qualitySummary, thematicProduct != nil {
            parts.append(quality)
        }
        if showsElevation, let elevation = probe.elevation { parts.append("\(elevation) Meter Höhe") }
        return parts.joined(separator: ", ")
    }
}

private struct AtlasLayerRow: View {
    let title: String
    let detail: String
    let symbol: String
    let tint: Color
    @Binding var isOn: Bool

    var body: some View {
        HStack(spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isOn ? tint : .secondary)
                .frame(width: 28, height: 28)
                .background(tint.opacity(isOn ? 0.12 : 0.05), in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 0) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}

private struct AtlasLayerGroup<Content: View>: View {
    let title: String
    let detail: String
    let symbol: String
    let tint: Color
    @Binding var isOn: Bool
    let content: Content

    init(
        title: String, detail: String, symbol: String, tint: Color,
        isOn: Binding<Bool>, @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.detail = detail
        self.symbol = symbol
        self.tint = tint
        _isOn = isOn
        self.content = content()
    }

    var body: some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 2) {
                content
            }
            .padding(.leading, 19)
            .padding(.bottom, 5)
        } label: {
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isOn ? tint : .secondary)
                    .frame(width: 28, height: 28)
                    .background(tint.opacity(isOn ? 0.12 : 0.05), in: RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 0) {
                    Text(title).font(.subheadline.weight(.medium))
                    Text(detail).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Toggle(title, isOn: $isOn)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
            }
            .padding(.vertical, 4)
        }
        .padding(.horizontal, 7)
    }
}

private struct AtlasLayerSubheading: View {
    let title: String

    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title.uppercased())
            .font(.system(size: 8, weight: .bold))
            .tracking(0.7)
            .foregroundStyle(.tertiary)
            .padding(.top, 5)
    }
}

private struct AtlasLayerKindRow: View {
    let title: String
    @Binding var isOn: Bool
    let isolate: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Toggle(title, isOn: $isOn)
                .toggleStyle(.checkbox)
                .font(.caption)
            Spacer()
            Button("Nur", action: isolate)
                .buttonStyle(.borderless)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(minHeight: 22)
    }
}

private struct MapChromeButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 18, height: 18)
                .padding(7)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .atlasGlass(cornerRadius: 11)
        .help(help)
    }
}

private struct AtlasRowButtonStyle: ButtonStyle {
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.primary)
            .background(
                isSelected
                    ? Color.accentColor.opacity(configuration.isPressed ? 0.15 : 0.09)
                    : Color.primary.opacity(configuration.isPressed ? 0.065 : 0),
                in: RoundedRectangle(cornerRadius: 9)
            )
    }
}

private struct WelcomeFeature: View {
    let symbol: String
    let title: String
    let detail: String

    var body: some View {
        VStack(spacing: 7) {
            Image(systemName: symbol)
                .font(.title2)
                .foregroundStyle(Color(red: 0.13, green: 0.38, blue: 0.27))
            Text(title)
                .font(.subheadline.weight(.semibold))
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(width: 150)
        .padding(.vertical, 14)
        .background(.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 14))
    }
}

extension View {
    func atlasGlass(cornerRadius: CGFloat) -> some View {
        background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [.white.opacity(0.48), .white.opacity(0.08), .black.opacity(0.08)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.7
                    )
            }
            .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
    }
}
