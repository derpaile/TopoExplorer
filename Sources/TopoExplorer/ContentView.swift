import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @EnvironmentObject private var session: MapSession
    @EnvironmentObject private var style: StyleSettings
    @EnvironmentObject private var viewport: ViewportController
    @EnvironmentObject private var layers: LayerSettings
    @EnvironmentObject private var comparison: ComparisonSettings
    @EnvironmentObject private var search: SearchController
    @EnvironmentObject private var bookmarks: BookmarkStore
    @EnvironmentObject private var export: MapExportController
    @EnvironmentObject private var geoScience: GeoScienceSettings
    @EnvironmentObject private var commands: AtlasCommandCenter
    @FocusState private var searchFocused: Bool
    @FocusState private var paletteFocused: Bool
    @State private var showSearchResults = false
    @State private var showHelp = false
    @State private var sidebarVisible = true
    @State private var activeDrawer: AtlasDrawer?
    @State private var surfaceQuery = ""
    @State private var selectedSurfaceID: Int?
    @State private var showHistoricalControls = false
    @State private var analysisMode = false
    @State private var profileMode = false
    @State private var catalogQuery = ""
    @State private var catalogCategory: MapManifest.DataCategory?
    @State private var comparisonBookmarkIDs: [UUID] = []
    @State private var fieldbookMessage: String?
    @State private var fieldbookMessageIsError = false
    @State private var showQuickPalette = false
    @State private var paletteQuery = ""
    @State private var paletteSelectionIndex = 0
    @State private var paletteNavigationSequence = 0

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
        .onChange(of: commands.sequence) { _, _ in
            if let command = commands.command { handleCommand(command) }
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
                    .frame(width: 304)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }

            mapArea(manifest: manifest, directory: directory)
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.28), value: sidebarVisible)
        .overlay {
            if showQuickPalette {
                quickPaletteOverlay(manifest: manifest)
                    .transition(
                        .scale(scale: reduceMotion ? 1 : 0.965, anchor: .top)
                            .combined(with: .opacity)
                    )
                    .zIndex(20)
            }
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.24), value: showQuickPalette)
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
            }
            .padding(.horizontal, 15)
            .padding(.top, 36)
            .padding(.bottom, 13)

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    surfaceStackSection(manifest: manifest)
                    thematicStackSection(manifest: manifest)
                    orientationStackSection
                    discoverySection
                    bookmarkSection
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

    private func surfaceStackSection(manifest: MapManifest) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            stackSectionTitle("Landoberfläche", detail: "Kartengrundlage")

            Button { toggleDrawer(.surface) } label: {
                HStack(spacing: 11) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [.green.opacity(0.50), .brown.opacity(0.42)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                        Image(systemName: "leaf.fill")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .frame(width: 38, height: 38)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Hochauflösende Gesamtkarte")
                            .font(.subheadline.weight(.semibold))
                        Text(
                            manifest.surfaceTexture == nil ? "Kultur · Wald · Natur · Siedlung"
                                : style.surfaceTextureEnabled
                                    ? "Reale Feinstruktur · \(style.surfaceTextureStrength.formatted(.percent.precision(.fractionLength(0))))"
                                    : "Oberflächentextur aus"
                        )
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.tertiary)
                }
                .padding(10)
                .contentShape(Rectangle())
            }
            .buttonStyle(AtlasStackButtonStyle(isSelected: activeDrawer == .surface))
            .atlasHoverGlow(tint: .green, cornerRadius: 13, lift: 1.5)

            AtlasCompactStackRow(
                title: "Geländerelief",
                detail: style.reliefEnabled ? "Plastische Schummerung aktiv" : "Ohne Schummerung",
                symbol: "mountain.2.fill",
                tint: .green,
                isOn: $style.reliefEnabled,
                isSelected: activeDrawer == .relief,
                action: { toggleDrawer(.relief) }
            )

            if comparison.mode != .year2015 {
                Button { toggleDrawer(.surface) } label: {
                    Label("Historische Ansicht aktiv", systemImage: "clock.arrow.circlepath")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background(.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func thematicStackSection(manifest: MapManifest) -> some View {
        let product = geoScience.product(in: manifest)
        return VStack(alignment: .leading, spacing: 8) {
            stackSectionTitle("Fachkarte", detail: "Maximal eine Rasterkarte")

            AtlasCompactStackRow(
                title: product?.name ?? "Fachkarte hinzufügen",
                detail: product.map { _ in
                    geoScience.presentation == .overlay
                        ? "Überlagert · \(geoScience.opacity.formatted(.percent.precision(.fractionLength(0))))"
                        : "Ersetzt die Kartengrundlage"
                } ?? "Boden · Gestein · Relief · Wasser",
                symbol: product.map(thematicSymbol) ?? "plus",
                tint: product.map(thematicTint) ?? .secondary,
                isOn: Binding(
                    get: { product != nil },
                    set: { enabled in
                        if enabled {
                            geoScience.selectedRasterID = manifest.availableThematicRasters.first?.id
                        } else {
                            geoScience.selectedRasterID = nil
                        }
                    }
                ),
                isSelected: activeDrawer == .thematic,
                action: { toggleDrawer(.thematic) }
            )
        }
    }

    private var orientationStackSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            stackSectionTitle("Orientierung", detail: "Kontext über der Oberfläche")

            AtlasCompactStackRow(
                title: "Namen & Naturorte",
                detail: layerStateText([layers.places, layers.geonames]),
                symbol: "textformat.abc", tint: .orange,
                isOn: Binding(
                    get: { layers.places || layers.geonames },
                    set: { layers.places = $0; layers.geonames = $0 }
                ),
                isSelected: activeDrawer == .labels,
                action: { toggleDrawer(.labels) }
            )
            AtlasCompactStackRow(
                title: "Verkehr",
                detail: layerStateText([layers.roads, layers.railways]),
                symbol: "point.bottomleft.forward.to.point.topright.scurvepath", tint: .red,
                isOn: Binding(
                    get: { layers.roads || layers.railways },
                    set: { layers.roads = $0; layers.railways = $0 }
                ),
                isSelected: activeDrawer == .transport,
                action: { toggleDrawer(.transport) }
            )
            AtlasCompactStackRow(
                title: "Gewässer & Grenzen",
                detail: layerStateText([layers.waterways, layers.boundaries]),
                symbol: "water.waves", tint: .blue,
                isOn: Binding(
                    get: { layers.waterways || layers.boundaries },
                    set: { layers.waterways = $0; layers.boundaries = $0 }
                ),
                isSelected: activeDrawer == .hydrography,
                action: { toggleDrawer(.hydrography) }
            )
            AtlasCompactStackRow(
                title: "Energie",
                detail: layers.energy ? "Netze und Erzeugungsanlagen" : "Ausgeblendet",
                symbol: "bolt.fill", tint: .yellow,
                isOn: $layers.energy,
                isSelected: activeDrawer == .energy,
                action: { toggleDrawer(.energy) }
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

    private func vectorPresetPicker(_ selection: Binding<VectorAppearancePreset>) -> some View {
        Picker("Farbe & Deckkraft", selection: selection) {
            ForEach(VectorAppearancePreset.allCases) { preset in
                Text(preset.title).tag(preset)
            }
        }
        .pickerStyle(.menu)
        .font(.caption)
    }

    private var landcoverSection: some View {
        AtlasInspectorPanel(title: "Historische Daten", symbol: "clock.arrow.circlepath") {
            DisclosureGroup(isExpanded: $showHistoricalControls) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Die hochauflösende Gesamtkarte ist der Standard. Ältere Zeitstände bleiben für gezielte Vergleiche verfügbar.")
                        .font(.caption2)
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
                                Text("Trennlinie")
                                Spacer()
                                Text("2020")
                            }
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        }
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .padding(.top, 9)
            } label: {
                HStack {
                    Text(comparison.mode == .year2015 ? "Ausgeblendet" : comparison.mode.title)
                    Spacer()
                    if comparison.mode != .year2015 {
                        Circle().fill(.orange).frame(width: 6, height: 6)
                    }
                }
                .font(.caption.weight(.medium))
            }
        }
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
                sidebarSectionTitle("Sammlung", systemImage: "bookmark.fill")
                if !bookmarks.bookmarks.isEmpty {
                    Text("\(bookmarks.bookmarks.count)")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.primary.opacity(0.06), in: Capsule())
                }
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
                Text("Fundstellen und spannende Ausschnitte lassen sich hier für später sammeln.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 7)
                    .padding(.bottom, 4)
            } else {
                ForEach(Array(bookmarks.bookmarks.suffix(3).reversed())) { bookmark in
                    HStack(spacing: 8) {
                        Button {
                            viewport.focus(
                                centerX: bookmark.centerX, centerY: bookmark.centerY,
                                metersPerPoint: bookmark.metersPerPoint, name: bookmark.name
                            )
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: bookmark.isComparable ? "mappin.and.ellipse" : "map")
                                    .font(.caption)
                                    .foregroundStyle(bookmark.isComparable ? Color.green : Color.secondary)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(bookmark.name)
                                        .font(.subheadline)
                                        .lineLimit(1)
                                    Text(bookmark.detail?.summary ?? bookmark.note ?? "Kartenansicht")
                                        .font(.system(size: 9))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)

                        Button {
                            comparisonBookmarkIDs.removeAll { $0 == bookmark.id }
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
                    .atlasHoverGlow(tint: .green, cornerRadius: 8, lift: 0.75)
                }

                Button { toggleDrawer(.collection) } label: {
                    HStack {
                        Label("Sammlung öffnen", systemImage: "rectangle.stack.fill")
                        Spacer()
                        Text("Vergleichen")
                            .foregroundStyle(.secondary)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.tertiary)
                    }
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 7)
                    .padding(.top, 3)
                    .contentShape(Rectangle())
                }
                .buttonStyle(AtlasPressButtonStyle(pressedScale: 0.985))
                .atlasHoverGlow(tint: .teal, cornerRadius: 8, lift: 0.75)
            }
        }
    }

    private var discoverySection: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                Text("ENTDECKEN")
                    .font(.system(size: 9, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    if let reference = MapReference.next(after: viewport.activeReference) {
                        viewport.show(reference)
                    }
                } label: {
                    Label(
                        viewport.activeReference == nil ? "Fund wählen" : "Weiterstöbern",
                        systemImage: "arrow.right"
                    )
                    .font(.system(size: 9, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .help("Zur nächsten kuratierten Landschaft springen")
            }
            .padding(.horizontal, 5)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 8) {
                    ForEach(MapReference.all) { reference in
                        Button { viewport.show(reference) } label: {
                            AtlasDiscoveryCard(
                                reference: reference,
                                isSelected: viewport.activeReference == reference
                            )
                        }
                        .buttonStyle(AtlasPressButtonStyle(pressedScale: 0.975))
                        .help("\(reference.name) erkunden · \(reference.subtitle)")
                    }
                }
                .padding(.horizontal, 1)
            }

            if let reference = viewport.activeReference {
                Button { toggleDrawer(.discovery) } label: {
                    HStack(spacing: 6) {
                        Label("Du erkundest \(reference.name)", systemImage: "location.fill")
                        Spacer()
                        Text("Landschaft lesen")
                        Image(systemName: "chevron.right")
                            .font(.system(size: 8, weight: .bold))
                    }
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(RGBAColor(hex: reference.accentHex).color)
                    .padding(.horizontal, 6)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .transition(.opacity)
            } else {
                Text("Kuratiere Ausschnitte zeigen, wie verschieden Landschaft gelesen werden kann.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 6)
            }
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: viewport.activeReference)
    }

    private func sidebarFooter(manifest: MapManifest) -> some View {
        VStack(spacing: 9) {
            Divider().opacity(0.55)

            Button { toggleDrawer(.catalog) } label: {
                HStack(spacing: 9) {
                    Image(systemName: "books.vertical.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.green)
                        .frame(width: 28, height: 28)
                        .background(.green.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Datenatlas")
                            .font(.caption.weight(.semibold))
                        Text("Quellen, Lizenzen & Kartenbezug")
                            .font(.system(size: 9))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("\(manifest.dataCatalog.count)")
                        .font(.caption.monospacedDigit().weight(.semibold))
                        .foregroundStyle(.secondary)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.tertiary)
                }
                .padding(7)
                .contentShape(Rectangle())
                .background(
                    activeDrawer == .catalog
                        ? Color.green.opacity(0.09) : Color.primary.opacity(0.025),
                    in: RoundedRectangle(cornerRadius: 10)
                )
            }
            .buttonStyle(AtlasPressButtonStyle(pressedScale: 0.985))
            .atlasHoverGlow(tint: .green, cornerRadius: 10, lift: 0.75)

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
                analysisMode: analysisMode,
                profileMode: profileMode,
                reduceMotion: reduceMotion
            )

            labelsOverlay

            if viewport.navigationArrivalToken > 0, !reduceMotion, !analysisMode, !profileMode {
                MapArrivalPulse(
                    color: viewport.activeReference.map {
                        RGBAColor(hex: $0.accentHex).color
                    } ?? .green
                )
                    .id(viewport.navigationArrivalToken)
                    .allowsHitTesting(false)
            }

            if let probe = viewport.pinnedProbe, !analysisMode, !profileMode {
                PinnedProbeMarker(
                    probe: probe,
                    snapshot: viewport.snapshot,
                    radiusMeters: viewport.landscapeContextRadius,
                    namedFeatures: viewport.landscapeContext?.namedFeatures ?? [],
                    color: probe.classID.flatMap { id in
                        probeColor(probe, landClassID: id, manifest: manifest)
                    } ?? .accentColor,
                    onNamedFeature: { feature in
                        let metersPerPoint = viewport.snapshot?.metersPerPoint ?? 40
                        viewport.clearPinnedProbe()
                        viewport.focus(
                            centerX: feature.worldX,
                            centerY: feature.worldY,
                            metersPerPoint: metersPerPoint,
                            name: feature.name
                        )
                    }
                )
                .transition(.scale(scale: 0.62).combined(with: .opacity))
            }

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

            if let line = viewport.profileScreenLine {
                ProfileSelectionOverlay(line: line)
                    .allowsHitTesting(false)
            }

            if manifest.hasLandcover2020 && comparison.mode == .comparison {
                comparisonOverlay
            }

            mapTopBar(manifest: manifest)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            mapBottomBar
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)

            if viewport.pinnedProbe == nil,
               let probe = viewport.probe,
               viewport.analysisSelection == nil,
               !analysisMode,
               !profileMode
            {
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

            if let probe = viewport.pinnedProbe, !analysisMode, !profileMode {
                PinnedProbePanel(
                    probe: probe,
                    thematicProduct: visibleGeoProduct(in: manifest),
                    baseSourceCount: manifest.sources?.count ?? 0,
                    showsElevation: style.reliefEnabled,
                    contentColor: probe.classID.flatMap { id in
                        probeColor(probe, landClassID: id, manifest: manifest)
                    },
                    classColors: style.colors.map(\.color),
                    landscapeContext: viewport.landscapeContext,
                    isReadingLandscapeContext: viewport.isReadingLandscapeContext,
                    landscapeContextMessage: viewport.landscapeContextMessage,
                    landscapeContextRadius: viewport.landscapeContextRadius,
                    onLandscapeContextRadiusChange: { radius in
                        viewport.requestLandscapeContext(radiusMeters: radius)
                    },
                    onNamedFeature: { feature in
                        let metersPerPoint = viewport.snapshot?.metersPerPoint ?? 40
                        viewport.clearPinnedProbe()
                        viewport.focus(
                            centerX: feature.worldX,
                            centerY: feature.worldY,
                            metersPerPoint: metersPerPoint,
                            name: feature.name
                        )
                    },
                    onCenter: {
                        viewport.focus(
                            centerX: probe.worldX,
                            centerY: probe.worldY,
                            metersPerPoint: viewport.snapshot?.metersPerPoint ?? 40,
                            name: probe.discoveryTitle
                        )
                    },
                    onBookmark: { name, note in
                        guard let snapshot = viewport.snapshot else { return }
                        bookmarks.add(
                            name: name,
                            snapshot: ViewportSnapshot(
                                centerX: probe.worldX,
                                centerY: probe.worldY,
                                metersPerPoint: snapshot.metersPerPoint,
                                visibleWidthMeters: snapshot.visibleWidthMeters,
                                visibleHeightMeters: snapshot.visibleHeightMeters
                            ),
                            probe: probe,
                            landscapeContext: viewport.landscapeContext,
                            note: note
                        )
                    },
                    onClose: { viewport.clearPinnedProbe() }
                )
                .id("\(probe.worldX)-\(probe.worldY)")
                .frame(width: 330)
                .padding(.top, 76)
                .padding(.leading, 14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .transition(.move(edge: .leading).combined(with: .opacity))
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

            if viewport.isProfiling
                || viewport.landscapeProfile != nil
                || viewport.profileMessage != nil
            {
                LandscapeProfilePanel(
                    profile: viewport.landscapeProfile,
                    isLoading: viewport.isProfiling,
                    message: viewport.profileMessage,
                    colors: style.colors,
                    thematicName: visibleGeoProduct(in: manifest)?.name,
                    onClose: { profileMode = false }
                )
                .frame(width: 560)
                .padding(.bottom, 58)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if let activeDrawer {
                drawer(activeDrawer, manifest: manifest)
                .frame(width: 354)
                .padding(.top, 62)
                .padding(.trailing, 12)
                .padding(.bottom, 58)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .clipped()
        .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: activeDrawer)
        .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: viewport.pinnedProbe != nil)
    }

    @ViewBuilder
    private func drawer(_ selection: AtlasDrawer, manifest: MapManifest) -> some View {
        if selection == .appearance {
            InspectorView(
                manifest: manifest,
                style: style,
                session: session,
                layers: layers,
                comparison: comparison,
                export: export,
                viewport: viewport,
                onClose: { activeDrawer = nil }
            )
        } else {
            AtlasContextDrawer(
                title: selection.title,
                subtitle: selection.subtitle,
                symbol: selection.symbol,
                tint: selection.tint,
                onClose: { activeDrawer = nil }
            ) {
                switch selection {
                case .surface:
                    surfaceDrawerContent(manifest: manifest)
                case .relief:
                    sidebarReliefSection
                case .thematic:
                    GeoScienceSidebar(
                        manifest: manifest,
                        settings: geoScience,
                        style: style,
                        showsHeader: false
                    )
                case .labels:
                    labelsDrawerContent
                case .transport:
                    transportDrawerContent
                case .hydrography:
                    hydrographyDrawerContent
                case .energy:
                    energyDrawerContent
                case .discovery:
                    discoveryDrawerContent(manifest: manifest)
                case .catalog:
                    dataCatalogDrawerContent(manifest: manifest)
                case .collection:
                    collectionDrawerContent(manifest: manifest)
                case .appearance:
                    EmptyView()
                }
            }
        }
    }

    private func surfaceDrawerContent(manifest: MapManifest) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            AtlasInspectorPanel(title: "Kartengrundlage", symbol: "leaf.fill") {
                VStack(alignment: .leading, spacing: 9) {
                    Text("Die hochauflösende Gesamtkarte bleibt die feste Basis für Kulturarten, Wälder, Naturflächen und Siedlungen.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    Button {
                        activeDrawer = .appearance
                    } label: {
                        HStack {
                            Label(style.activeStyleName, systemImage: "paintpalette.fill")
                            Spacer()
                            Text("Stil ändern")
                                .foregroundStyle(.secondary)
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.tertiary)
                        }
                        .font(.caption.weight(.medium))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }

            if let texture = manifest.surfaceTexture {
                surfaceTextureSection(texture)
            }

            surfaceEditorSection(manifest: manifest)

            if manifest.hasLandcover2020 {
                landcoverSection
            }
        }
    }

    private func surfaceTextureSection(_ texture: MapManifest.SurfaceTexture) -> some View {
        AtlasInspectorPanel(title: "Reale Feinstruktur", symbol: "square.3.layers.3d.down.right") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Sentinel-2-Detailkanal", isOn: $style.surfaceTextureEnabled)
                    .font(.subheadline.weight(.medium))

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Modulation")
                        Spacer()
                        Text(style.surfaceTextureStrength.formatted(.percent.precision(.fractionLength(0))))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                    Slider(value: $style.surfaceTextureStrength, in: 0...0.60)
                }
                .disabled(!style.surfaceTextureEnabled)

                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Kantenverstärkung")
                        Spacer()
                        Text(style.surfaceTextureEdgeStrength.formatted(.number.precision(.fractionLength(1))))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .font(.caption)
                    Slider(value: $style.surfaceTextureEdgeStrength, in: 0...2)
                }
                .disabled(!style.surfaceTextureEnabled)

                HStack(spacing: 4) {
                    ForEach([0.0, 0.20, 0.30, 0.40, 0.50, 0.60], id: \.self) { strength in
                        Button(strength.formatted(.percent.precision(.fractionLength(0)))) {
                            style.surfaceTextureStrength = strength
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.mini)
                        .tint(abs(style.surfaceTextureStrength - strength) < 0.001 ? .accentColor : .secondary)
                    }
                }

                Text("Wirkt in allen Farb- und Fachkarten gleichzeitig mit dem Relief. Landwirtschaft stark · Wald mittel bis stark · Siedlung schwach · Wasser ohne Textur. Niedrige Zoomstufen werden gefiltert und ausgeblendet.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let source = texture.sources.first, let url = URL(string: source.url) {
                    Link(source.name, destination: url)
                        .font(.caption2)
                }
            }
        }
    }

    private var labelsDrawerContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            AtlasInspectorPanel(title: "Orte", symbol: "building.2.fill") {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Städte und Siedlungen", isOn: $layers.places)
                        .font(.subheadline.weight(.medium))
                    vectorPresetPicker($layers.placeLabelPreset)
                }
            }

            AtlasInspectorPanel(title: "Natur- und Geländenamen", symbol: "mountain.2.fill") {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Naturorte anzeigen", isOn: $layers.geonames)
                        .font(.subheadline.weight(.medium))
                    vectorPresetPicker($layers.landscapeLabelPreset)
                    Divider().padding(.vertical, 3)
                    AtlasLayerSubheading("Relief")
                    layerKindRow("Gipfel & Höhenpunkte", kind: 7, mask: \.geonameKinds)
                    layerKindRow("Landschaften", kind: 8, mask: \.geonameKinds)
                    layerKindRow("Höhlen", kind: 12, mask: \.geonameKinds)
                    AtlasLayerSubheading("Wasser & Natur")
                    layerKindRow("Gewässer & Seen", kind: 9, mask: \.geonameKinds)
                    layerKindRow("Moore & Schutzgebiete", kind: 10, mask: \.geonameKinds)
                    layerKindRow("Inseln", kind: 11, mask: \.geonameKinds)
                }
            }
        }
    }

    private var transportDrawerContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            AtlasInspectorPanel(title: "Straßen", symbol: "road.lanes") {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Straßennetz anzeigen", isOn: $layers.roads)
                        .font(.subheadline.weight(.medium))
                    vectorPresetPicker($layers.roadPreset)
                    Divider().padding(.vertical, 3)
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
            }

            AtlasInspectorPanel(title: "Schienen", symbol: "tram.fill") {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Schienennetz anzeigen", isOn: $layers.railways)
                        .font(.subheadline.weight(.medium))
                    vectorPresetPicker($layers.railwayPreset)
                    Divider().padding(.vertical, 3)
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
            }
        }
    }

    private var hydrographyDrawerContent: some View {
        VStack(alignment: .leading, spacing: 14) {
            AtlasInspectorPanel(title: "Fließgewässer", symbol: "water.waves") {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Flüsse und Bäche anzeigen", isOn: $layers.waterways)
                        .font(.subheadline.weight(.medium))
                    vectorPresetPicker($layers.waterwayPreset)
                }
            }
            AtlasInspectorPanel(
                title: "Verwaltungsgrenzen",
                symbol: "point.topleft.down.to.point.bottomright.curvepath"
            ) {
                VStack(alignment: .leading, spacing: 4) {
                    Toggle("Bundes- und Landesgrenzen", isOn: $layers.boundaries)
                        .font(.subheadline.weight(.medium))
                    vectorPresetPicker($layers.boundaryPreset)
                }
            }
        }
    }

    private var energyDrawerContent: some View {
        AtlasInspectorPanel(title: "Energieinfrastruktur", symbol: "bolt.fill") {
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Energieebene anzeigen", isOn: $layers.energy)
                    .font(.subheadline.weight(.medium))
                vectorPresetPicker($layers.energyPreset)
                Divider().padding(.vertical, 3)
                AtlasLayerSubheading("Hochspannungsnetze")
                layerKindRow("380-kV-Netz", kind: 1, mask: \.energyKinds)
                layerKindRow("220-kV-Netz", kind: 2, mask: \.energyKinds)
                layerKindRow("110-kV-Netz", kind: 3, mask: \.energyKinds)
                AtlasLayerSubheading("Netzknoten")
                layerKindRow("Umspannwerke", kind: 4, mask: \.energyKinds)
                layerKindRow("Transformatoren", kind: 5, mask: \.energyKinds)
                AtlasLayerSubheading("Erzeugung")
                layerKindRow("Windenergieanlagen", kind: 6, mask: \.energyKinds)
                layerKindRow("Photovoltaik", kind: 7, mask: \.energyKinds)
                layerKindRow("Konventionelle Erzeuger", kind: 8, mask: \.energyKinds)
            }
        }
    }

    @ViewBuilder
    private func discoveryDrawerContent(manifest: MapManifest) -> some View {
        if let reference = viewport.activeReference {
            let tint = RGBAColor(hex: reference.accentHex).color
            VStack(alignment: .leading, spacing: 14) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 11) {
                        Image(systemName: reference.symbolName)
                            .font(.system(size: 22, weight: .semibold))
                            .foregroundStyle(tint)
                            .frame(width: 46, height: 46)
                            .background(tint.opacity(0.14), in: Circle())
                        VStack(alignment: .leading, spacing: 2) {
                            Text(reference.name)
                                .font(.title3.weight(.semibold))
                            Text(reference.subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(reference.story)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(13)
                .background(
                    LinearGradient(
                        colors: [tint.opacity(0.16), tint.opacity(0.035)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(tint.opacity(0.22), lineWidth: 0.8)
                }

                AtlasInspectorPanel(title: "Achte auf", symbol: "binoculars.fill") {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(reference.observations.enumerated()), id: \.element.id) { index, observation in
                            HStack(alignment: .top, spacing: 10) {
                                Image(systemName: observation.symbolName)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(tint)
                                    .frame(width: 26, height: 26)
                                    .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(observation.title)
                                        .font(.caption.weight(.semibold))
                                    Text(observation.detail)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            .padding(.vertical, 7)
                            if index < reference.observations.count - 1 { Divider().opacity(0.45) }
                        }
                    }
                }

                AtlasInspectorPanel(title: "Mit der Karte prüfen", symbol: "slider.horizontal.3") {
                    VStack(alignment: .leading, spacing: 9) {
                        Toggle("Geländerelief", isOn: $style.reliefEnabled)
                        Toggle("Natur- und Geländenamen", isOn: $layers.geonames)
                        Toggle("Flüsse und Gewässer", isOn: $layers.waterways)
                        if manifest.surfaceTexture != nil {
                            Toggle("Reale Oberflächenstruktur", isOn: $style.surfaceTextureEnabled)
                        }
                    }
                    .font(.caption)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                }

                discoverySources(manifest: manifest)

                Button {
                    if let next = MapReference.next(after: reference) { viewport.show(next) }
                } label: {
                    HStack {
                        Label("Weiterstöbern", systemImage: "arrow.right.circle.fill")
                        Spacer()
                        if let next = MapReference.next(after: reference) { Text(next.name) }
                    }
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 2)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.borderedProminent)
                .tint(tint)
            }
        } else {
            ContentUnavailableView(
                "Keine Landschaft gewählt",
                systemImage: "binoculars",
                description: Text("Wähle einen Landschaftsausschnitt in der Seitenleiste.")
            )
        }
    }

    private func discoverySources(manifest: MapManifest) -> some View {
        AtlasInspectorPanel(title: "Datenquellen dieser Ansicht", symbol: "checkmark.seal.fill") {
            VStack(alignment: .leading, spacing: 9) {
                ForEach(manifest.sources ?? []) { source in
                    AtlasSourceRow(
                        title: source.name,
                        detail: "\(source.role) · \(source.year)",
                        license: source.license,
                        url: source.url
                    )
                }
                if let texture = manifest.surfaceTexture, style.surfaceTextureEnabled {
                    ForEach(texture.sources) { source in
                        AtlasSourceRow(
                            title: source.name,
                            detail: source.role ?? "Oberflächenstruktur",
                            license: source.license,
                            url: source.url
                        )
                    }
                }
                Text("Die Quellenlinks führen direkt zu den veröffentlichten Datensätzen und Nutzungsbedingungen.")
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
        }
    }

    private func dataCatalogDrawerContent(manifest: MapManifest) -> some View {
        let allEntries = manifest.dataCatalog
        let query = catalogQuery
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
        let entries = allEntries.filter { entry in
            (catalogCategory == nil || entry.category == catalogCategory)
                && (query.isEmpty || entry.searchableText.contains(query))
        }
        return VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(allEntries.count)")
                        .font(.system(size: 32, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text("dokumentierte Quellen")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                Text("Jeder Datensatz bleibt mit Herkunft, Nutzungslizenz, Jahr und Kartenwirkung nachvollziehbar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                LinearGradient(
                    colors: [.green.opacity(0.16), .cyan.opacity(0.05)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(.green.opacity(0.18), lineWidth: 0.8)
            }

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextField("Quelle, Thema oder Lizenz", text: $catalogQuery)
                    .textFieldStyle(.plain)
                if !catalogQuery.isEmpty {
                    Button { catalogQuery = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .stroke(.primary.opacity(0.07), lineWidth: 0.8)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    catalogFilterChip("Alle", symbol: "square.grid.2x2", category: nil)
                    ForEach(MapManifest.DataCategory.allCases) { category in
                        catalogFilterChip(
                            category.title,
                            symbol: category.symbolName,
                            category: category
                        )
                    }
                }
                .padding(.horizontal, 1)
            }

            if entries.isEmpty {
                ContentUnavailableView(
                    "Keine Quelle gefunden",
                    systemImage: "magnifyingglass",
                    description: Text("Ändere Suche oder Themenfilter.")
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
            } else {
                ForEach(MapManifest.DataCategory.allCases) { category in
                    let categoryEntries = entries.filter { $0.category == category }
                    if !categoryEntries.isEmpty {
                        AtlasInspectorPanel(title: category.title, symbol: category.symbolName) {
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(Array(categoryEntries.enumerated()), id: \.element.id) { index, entry in
                                    CatalogDatasetRow(
                                        entry: entry,
                                        tint: catalogTint(category),
                                        isActive: catalogEntryIsActive(entry),
                                        actionTitle: catalogActionTitle(entry),
                                        action: { activateCatalogEntry(entry) }
                                    )
                                    .padding(.vertical, 7)
                                    if index < categoryEntries.count - 1 { Divider().opacity(0.45) }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private func collectionDrawerContent(manifest: MapManifest) -> some View {
        let selected = comparisonBookmarkIDs.compactMap { id in
            bookmarks.bookmarks.first { $0.id == id }
        }
        let comparableCount = bookmarks.bookmarks.filter(\.isComparable).count
        let landscapePortraitCount = bookmarks.bookmarks.filter {
            $0.detail?.hasLandscapeContext == true
        }.count
        return VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 7) {
                HStack(alignment: .firstTextBaseline) {
                    Text("\(bookmarks.bookmarks.count)")
                        .font(.system(size: 32, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                    Text(bookmarks.bookmarks.count == 1 ? "gemerkter Ort" : "gemerkte Orte")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                Text(
                    "\(comparableCount) Fundstellen sind vergleichbar · "
                        + "\(landscapePortraitCount) bewahren ein vollständiges Landschaftsbild."
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(13)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                LinearGradient(
                    colors: [.teal.opacity(0.16), .green.opacity(0.05)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(.teal.opacity(0.18), lineWidth: 0.8)
            }

            HStack(spacing: 8) {
                Button { exportFieldbook(manifest: manifest) } label: {
                    Label("GeoJSON exportieren", systemImage: "square.and.arrow.up")
                        .frame(maxWidth: .infinity)
                }
                .disabled(bookmarks.bookmarks.isEmpty)
                Button { importFieldbook(manifest: manifest) } label: {
                    Label("Importieren", systemImage: "square.and.arrow.down")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .font(.system(size: 9, weight: .semibold))

            if let fieldbookMessage {
                Label(
                    fieldbookMessage,
                    systemImage: fieldbookMessageIsError
                        ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
                )
                .font(.caption2)
                .foregroundStyle(fieldbookMessageIsError ? Color.orange : Color.teal)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 3)
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            if selected.count == 2 {
                BookmarkComparisonPanel(
                    comparison: MapBookmarkComparison(first: selected[0], second: selected[1]),
                    classColors: style.colors.map(\.color),
                    show: showBookmark
                )
            } else if comparableCount >= 2 {
                Label(
                    "Wähle zwei Fundstellen mit A und B für den Vergleich.",
                    systemImage: "arrow.left.arrow.right"
                )
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 4)
            }

            if bookmarks.bookmarks.isEmpty {
                ContentUnavailableView(
                    "Sammlung ist leer",
                    systemImage: "bookmark",
                    description: Text("Klicke auf die Karte und merke eine Fundstelle.")
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, 22)
            } else {
                AtlasInspectorPanel(title: "Gesammelte Orte", symbol: "rectangle.stack.fill") {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(bookmarks.bookmarks.reversed().enumerated()), id: \.element.id) { index, bookmark in
                            BookmarkCollectionRow(
                                bookmark: bookmark,
                                classColors: style.colors.map(\.color),
                                comparisonSlot: comparisonBookmarkIDs.firstIndex(of: bookmark.id),
                                onSelectComparison: { toggleBookmarkComparison(bookmark) },
                                onShow: { showBookmark(bookmark) },
                                onDelete: {
                                    comparisonBookmarkIDs.removeAll { $0 == bookmark.id }
                                    bookmarks.remove(bookmark)
                                }
                            )
                            .padding(.vertical, 7)
                            if index < bookmarks.bookmarks.count - 1 { Divider().opacity(0.45) }
                        }
                    }
                }
            }
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: fieldbookMessage)
    }

    private func toggleBookmarkComparison(_ bookmark: MapBookmark) {
        guard bookmark.isComparable else { return }
        if let index = comparisonBookmarkIDs.firstIndex(of: bookmark.id) {
            comparisonBookmarkIDs.remove(at: index)
        } else {
            if comparisonBookmarkIDs.count == 2 { comparisonBookmarkIDs.removeFirst() }
            comparisonBookmarkIDs.append(bookmark.id)
        }
    }

    private func showBookmark(_ bookmark: MapBookmark) {
        viewport.focus(
            centerX: bookmark.centerX,
            centerY: bookmark.centerY,
            metersPerPoint: bookmark.metersPerPoint,
            name: bookmark.name
        )
    }

    private func exportFieldbook(manifest: MapManifest) {
        let panel = NSSavePanel()
        panel.title = "Sammlung als GeoJSON-Feldbuch exportieren"
        panel.prompt = "GeoJSON exportieren"
        panel.allowedContentTypes = [
            UTType(filenameExtension: "geojson", conformingTo: .json) ?? .json,
        ]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = "TopoExplorer-Feldbuch.geojson"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let document = try AtlasFieldbookDocument(
                bookmarks: bookmarks.bookmarks,
                sources: manifest.dataCatalog
            )
            try AtlasFieldbookFile.write(document, to: url)
            fieldbookMessage = "\(bookmarks.bookmarks.count) Fundstellen als \(url.lastPathComponent) exportiert."
            fieldbookMessageIsError = false
        } catch {
            fieldbookMessage = error.localizedDescription
            fieldbookMessageIsError = true
        }
    }

    private func importFieldbook(manifest: MapManifest) {
        let panel = NSOpenPanel()
        panel.title = "GeoJSON-Feldbuch importieren"
        panel.prompt = "Zusammenführen"
        panel.allowedContentTypes = [
            UTType(filenameExtension: "geojson", conformingTo: .json) ?? .json,
            .json,
        ]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let imported = try AtlasFieldbookFile.read(from: url).importedBookmarks()
            let inside = imported.filter {
                $0.centerX >= manifest.left && $0.centerX <= manifest.right
                    && $0.centerY >= manifest.bottom && $0.centerY <= manifest.top
            }
            let outside = imported.count - inside.count
            guard !inside.isEmpty else {
                fieldbookMessage = "Keine Fundstelle liegt im verfügbaren Kartengebiet."
                fieldbookMessageIsError = true
                return
            }
            let result = bookmarks.mergeImported(inside)
            var parts = ["\(result.added) importiert"]
            if result.skipped > 0 { parts.append("\(result.skipped) bereits vorhanden") }
            if outside > 0 { parts.append("\(outside) außerhalb der Karte") }
            fieldbookMessage = parts.joined(separator: " · ") + "."
            fieldbookMessageIsError = false
        } catch {
            fieldbookMessage = error.localizedDescription
            fieldbookMessageIsError = true
        }
    }

    private func catalogFilterChip(
        _ title: String,
        symbol: String,
        category: MapManifest.DataCategory?
    ) -> some View {
        let isSelected = catalogCategory == category
        return Button { catalogCategory = category } label: {
            Label(title, systemImage: symbol)
                .font(.system(size: 9, weight: .semibold))
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .foregroundStyle(isSelected ? Color.white : Color.secondary)
                .background(
                    isSelected ? Color.accentColor : Color.primary.opacity(0.045),
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
    }

    private func catalogTint(_ category: MapManifest.DataCategory) -> Color {
        switch category {
        case .landscape: .green
        case .detail: .teal
        case .geoscience: .indigo
        case .orientation: .orange
        }
    }

    private func catalogEntryIsActive(_ entry: MapManifest.DataCatalogEntry) -> Bool {
        switch entry.activation {
        case .surface: true
        case .surfaceTexture: style.surfaceTextureEnabled
        case .thematic(let id): geoScience.selectedRasterID == id
        case .orientation:
            layers.roads || layers.railways || layers.waterways || layers.boundaries
                || layers.places || layers.energy
        case .geonames: layers.geonames
        }
    }

    private func catalogActionTitle(_ entry: MapManifest.DataCatalogEntry) -> String {
        switch entry.activation {
        case .surface: "Öffnen"
        default: catalogEntryIsActive(entry) ? "Aktiv" : "Anzeigen"
        }
    }

    private func activateCatalogEntry(_ entry: MapManifest.DataCatalogEntry) {
        switch entry.activation {
        case .surface:
            activeDrawer = .surface
        case .surfaceTexture:
            style.surfaceTextureEnabled = true
        case .thematic(let id):
            geoScience.selectedRasterID = id
        case .orientation:
            layers.roads = true
            layers.railways = true
            layers.waterways = true
            layers.boundaries = true
            layers.places = true
            layers.energy = true
        case .geonames:
            layers.geonames = true
        }
    }

    private func mapTopBar(manifest: MapManifest) -> some View {
        ViewThatFits(in: .horizontal) {
            mapToolbar(manifest: manifest, compact: false)
                .fixedSize(horizontal: true, vertical: false)
            mapToolbar(manifest: manifest, compact: true)
                .frame(maxWidth: .infinity)
        }
        .popover(isPresented: $showHelp, arrowEdge: .top) { mapHelpPopover }
        .padding(12)
    }

    private func mapToolbar(manifest: MapManifest, compact: Bool) -> some View {
        HStack(spacing: compact ? 6 : 8) {
            MapChromeButton(
                symbol: sidebarVisible ? "sidebar.left" : "sidebar.right",
                help: sidebarVisible ? "Seitenleiste ausblenden · ⇧⌘L" : "Seitenleiste einblenden · ⇧⌘L"
            ) { sidebarVisible.toggle() }

            mapLocationPill(compact: compact)

            Spacer(minLength: compact ? 4 : 12)

            if let product = geoScience.product(in: manifest) {
                thematicProductPill(product, compact: compact)
            }

            HStack(spacing: 1) {
                MapChromeButton(symbol: "minus", help: "Herauszoomen · −") { zoom(by: 1 / 1.55) }
                MapChromeButton(symbol: "plus", help: "Hineinzoomen · +") { zoom(by: 1.55) }
                MapChromeButton(symbol: "scope", help: "Deutschland einpassen · 0") { viewport.fitGermany() }
            }

            MapChromeButton(
                symbol: analysisMode ? "xmark" : "rectangle.dashed",
                help: analysisMode ? "Flächenanalyse beenden" : "Fläche analysieren · ⇧⌘A",
                isActive: analysisMode,
                tint: .cyan
            ) { toggleAreaAnalysis() }

            MapChromeButton(
                symbol: profileMode ? "xmark" : "chart.xyaxis.line",
                help: profileMode ? "Landschaftsprofil beenden" : "Landschaftsprofil ziehen · ⇧⌘P",
                isActive: profileMode,
                tint: .indigo
            ) { toggleLandscapeProfile() }

            if compact {
                mapUtilityMenu
            } else {
                MapChromeButton(
                    symbol: "sparkles",
                    help: "Stöberpalette · ⌘K",
                    isActive: showQuickPalette,
                    tint: .green
                ) { openQuickPalette() }
                MapChromeButton(symbol: "square.and.arrow.up", help: "Kartenausschnitt exportieren · ⇧⌘X") {
                    exportVisibleMap()
                }
                MapChromeButton(
                    symbol: "books.vertical",
                    help: "Datenatlas öffnen · ⇧⌘D",
                    isActive: activeDrawer == .catalog,
                    tint: .green
                ) {
                    toggleDrawer(.catalog)
                }
                if !bookmarks.bookmarks.isEmpty {
                    MapChromeButton(
                        symbol: "rectangle.stack",
                        help: "Sammlung öffnen · ⇧⌘M",
                        isActive: activeDrawer == .collection,
                        tint: .teal
                    ) {
                        toggleDrawer(.collection)
                    }
                }
                MapChromeButton(
                    symbol: "questionmark",
                    help: "Bedienung",
                    isActive: showHelp,
                    tint: .orange
                ) { showHelp.toggle() }
                MapChromeButton(
                    symbol: "paintpalette",
                    help: "Stile & Export",
                    isActive: activeDrawer == .appearance,
                    tint: .purple
                ) {
                    analysisMode = false
                    profileMode = false
                    toggleDrawer(.appearance)
                }
            }
        }
    }

    private func mapLocationPill(compact: Bool) -> some View {
        Button {
            if viewport.activeReference != nil { toggleDrawer(.discovery) }
        } label: {
            HStack(spacing: compact ? 6 : 9) {
                Image(systemName: viewport.activeReference?.symbolName ?? "map")
                    .foregroundStyle(
                        viewport.activeReference.map { RGBAColor(hex: $0.accentHex).color }
                            ?? Color(red: 0.18, green: 0.48, blue: 0.34)
                    )
                    .contentTransition(.symbolEffect(.replace))
                if compact {
                    Text(viewport.activeReference?.name ?? "Deutschland")
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .frame(maxWidth: 92)
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(viewport.activeReference?.name ?? "Deutschland")
                            .font(.subheadline.weight(.semibold))
                        Text(viewport.activeReference?.subtitle ?? "Topo Atlas")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    if viewport.activeReference != nil {
                        Image(systemName: "info.circle")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
        }
        .buttonStyle(AtlasPressButtonStyle(pressedScale: 0.975))
        .padding(.horizontal, compact ? 9 : 12)
        .padding(.vertical, compact ? 9 : 7)
        .atlasGlass(cornerRadius: 13)
        .atlasHoverGlow(
            tint: viewport.activeReference.map { RGBAColor(hex: $0.accentHex).color } ?? .green,
            cornerRadius: 13,
            lift: viewport.activeReference == nil ? 0 : 1
        )
        .help(viewport.activeReference == nil ? "Gesamtansicht Deutschland" : "Landschaft lesen")
    }

    @ViewBuilder
    private func thematicProductPill(
        _ product: MapManifest.ThematicRaster,
        compact: Bool
    ) -> some View {
        if compact {
            MapChromeButton(
                symbol: thematicSymbol(product),
                help: "\(product.name) einstellen",
                isActive: activeDrawer == .thematic,
                tint: thematicTint(product)
            ) {
                toggleDrawer(.thematic)
            }
        } else {
            Button { toggleDrawer(.thematic) } label: {
                HStack(spacing: 7) {
                    Circle()
                        .fill(thematicTint(product))
                        .frame(width: 7, height: 7)
                    Text(product.name)
                        .font(.caption.weight(.medium))
                        .lineLimit(1)
                    Image(systemName: "slider.horizontal.3")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
            }
            .buttonStyle(AtlasPressButtonStyle(pressedScale: 0.975))
            .atlasGlass(cornerRadius: 11)
            .atlasHoverGlow(tint: thematicTint(product), cornerRadius: 11, lift: 1)
            .help("Aktive Fachkarte einstellen")
        }
    }

    private var mapUtilityMenu: some View {
        Menu {
            Button { openQuickPalette() } label: {
                Label("Stöberpalette", systemImage: "sparkles")
            }
            Divider()
            Button { exportVisibleMap() } label: {
                Label("Kartenausschnitt exportieren", systemImage: "square.and.arrow.up")
            }
            Button { toggleDrawer(.catalog) } label: {
                Label("Datenatlas", systemImage: "books.vertical")
            }
            if !bookmarks.bookmarks.isEmpty {
                Button { toggleDrawer(.collection) } label: {
                    Label("Sammlung", systemImage: "rectangle.stack")
                }
            }
            Divider()
            Button {
                analysisMode = false
                profileMode = false
                toggleDrawer(.appearance)
            } label: {
                Label("Stile & Export", systemImage: "paintpalette")
            }
            Button { showHelp.toggle() } label: {
                Label("Bedienung", systemImage: "questionmark.circle")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 18, height: 18)
                .padding(7)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .atlasGlass(cornerRadius: 11)
        .help("Weitere Werkzeuge")
    }

    private var mapHelpPopover: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("Auf der Karte").font(.headline)
            Label("Ziehen zum Verschieben", systemImage: "hand.draw")
            Label("Mausrad oder Trackpad zum Zoomen", systemImage: "plus.magnifyingglass")
            Label("Doppelklick zum Hineinzoomen", systemImage: "cursorarrow.click.2")
            Label("Einmal klicken hält eine Fundstelle fest", systemImage: "mappin.and.ellipse")
            Label("Rechteck ziehen und Fläche auswerten", systemImage: "rectangle.dashed")
            Label("Linie ziehen und Landschaftswechsel lesen", systemImage: "chart.xyaxis.line")
            Divider()
            Text("Tastatur").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            HStack { Text("Stöberpalette"); Spacer(); Text("⌘K").monospaced() }
            HStack { Text("Suchen"); Spacer(); Text("⌘F").monospaced() }
            HStack { Text("Nächster Fund"); Spacer(); Text("⇧⌘E").monospaced() }
            HStack { Text("Datenatlas"); Spacer(); Text("⇧⌘D").monospaced() }
            HStack { Text("Fläche / Profil"); Spacer(); Text("⇧⌘A / ⇧⌘P").monospaced() }
        }
        .font(.subheadline)
        .padding(15)
        .frame(width: 300, alignment: .leading)
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
                MapStatusPill(status: viewport.status, snapshot: viewport.snapshot)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
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
        .animation(reduceMotion ? nil : .snappy(duration: 0.20), value: viewport.probe != nil)
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
                if label.kind == 13 || label.kind == 14 {
                    let width = max(20, CGFloat(label.name.count) * 5.2 + 7)
                    let rectangle = CGRect(
                        x: label.point.x - width / 2, y: label.point.y - 8,
                        width: width, height: 16
                    )
                    let shape = Path(roundedRect: rectangle, cornerRadius: 3)
                    let motorway = label.kind == 13
                    context.fill(
                        shape,
                        with: .color(motorway ? Color(red: 0.02, green: 0.30, blue: 0.62) : Color(red: 0.98, green: 0.78, blue: 0.05))
                    )
                    context.stroke(
                        shape,
                        with: .color(motorway ? .white.opacity(0.96) : .black.opacity(0.88)),
                        lineWidth: 0.8
                    )
                } else {
                    let palette = labelPalette(for: label)
                    let halo = mapLabelText(label, color: palette.halo)
                    let radius = palette.haloRadius
                    for offset in [
                        CGPoint(x: -radius, y: 0), CGPoint(x: radius, y: 0),
                        CGPoint(x: 0, y: -radius), CGPoint(x: 0, y: radius),
                        CGPoint(x: -radius, y: -radius), CGPoint(x: radius, y: -radius),
                        CGPoint(x: -radius, y: radius), CGPoint(x: radius, y: radius),
                    ] {
                        context.draw(
                            halo,
                            at: CGPoint(x: label.point.x + offset.x, y: label.point.y + offset.y),
                            anchor: .center
                        )
                    }
                }
                context.draw(mapLabelText(label), at: label.point, anchor: .center)
            }
        }
        .allowsHitTesting(false)
    }

    private func labelPalette(for label: MapLabel) -> (foreground: Color, halo: Color, haloRadius: CGFloat) {
        let preset = label.kind <= 6 ? layers.placeLabelPreset : layers.landscapeLabelPreset
        switch preset {
        case .leise: return (Color.white.opacity(0.70), Color.black.opacity(0.40), 0.7)
        case .hell: return (Color.white.opacity(0.98), Color.black.opacity(0.55), 0.8)
        case .ausgewogen: return (Color(red: 0.97, green: 0.95, blue: 0.89), Color.black.opacity(0.76), 1.0)
        case .klar: return (Color(red: 1.0, green: 0.91, blue: 0.62), Color.black.opacity(0.86), 1.1)
        case .kontrast: return (Color.black.opacity(0.94), Color.white.opacity(0.92), 1.1)
        }
    }

    private func mapLabelText(_ label: MapLabel, color override: Color? = nil) -> Text {
        let text = Text(label.kind == 7 ? "▲ \(label.name)" : label.name)
        let color = override ?? labelPalette(for: label).foreground
        switch label.kind {
        case 13:
            return text.font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundColor(.white)
        case 14:
            return text.font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundColor(.black.opacity(0.92))
        case 7:
            return text.font(.system(size: 12, weight: .light, design: .serif))
                .italic().foregroundColor(color)
        case 8:
            return text.font(.system(size: 15, weight: .light, design: .serif))
                .tracking(1.6).foregroundColor(color)
        case 9:
            return text.font(.system(size: 12, weight: .light, design: .rounded))
                .italic().foregroundColor(color)
        case 10:
            return text.font(.system(size: 11, weight: .light, design: .rounded))
                .foregroundColor(color)
        case 11:
            return text.font(.system(size: 12, weight: .light, design: .serif))
                .italic().foregroundColor(color)
        case 12:
            return text.font(.system(size: 10, weight: .light, design: .monospaced))
                .foregroundColor(color)
        default:
            return text.font(placeFont(population: label.prominence))
                .foregroundColor(color)
        }
    }

    private func placeFont(population: Double) -> Font {
        if population >= 1_000_000 { return .system(size: 17, weight: .bold, design: .rounded) }
        if population >= 500_000 { return .system(size: 16, weight: .bold, design: .rounded) }
        if population >= 100_000 { return .system(size: 14, weight: .semibold, design: .rounded) }
        if population >= 50_000 { return .system(size: 13, weight: .semibold, design: .rounded) }
        if population >= 10_000 { return .system(size: 12, weight: .semibold, design: .rounded) }
        return .system(size: 10, weight: .medium, design: .rounded)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(searchFocused ? Color.accentColor : Color.secondary)
                .scaleEffect(searchFocused && !reduceMotion ? 1.08 : 1)
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
                .transition(.scale(scale: 0.72).combined(with: .opacity))
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(
            searchFocused ? Color.accentColor.opacity(0.055) : Color.primary.opacity(0.055),
            in: RoundedRectangle(cornerRadius: 10)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(
                    searchFocused ? Color.accentColor.opacity(0.34) : Color.primary.opacity(0.07),
                    lineWidth: 1
                )
        }
        .shadow(color: Color.accentColor.opacity(searchFocused ? 0.12 : 0), radius: 9)
        .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: searchFocused)
        .animation(reduceMotion ? nil : .snappy(duration: 0.16), value: search.query.isEmpty)
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

    private func stackSectionTitle(_ title: String, detail: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(.secondary)
            Spacer()
            Text(detail)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 5)
    }

    private func layerStateText(_ states: [Bool]) -> String {
        let active = states.filter { $0 }.count
        if active == 0 { return "Ausgeblendet" }
        if active == states.count { return "Alle Inhalte aktiv" }
        return "\(active) von \(states.count) aktiv"
    }

    private func toggleDrawer(_ selection: AtlasDrawer) {
        analysisMode = false
        profileMode = false
        if viewport.analysisSelection != nil { viewport.clearAnalysis() }
        if viewport.profileSelection != nil { viewport.clearProfile() }
        activeDrawer = activeDrawer == selection ? nil : selection
    }

    private func handleCommand(_ command: AtlasCommand) {
        switch command {
        case .openPalette:
            openQuickPalette()
        case .focusSearch:
            if !sidebarVisible { sidebarVisible = true }
            searchFocused = true
        case .nextLandscape:
            if let reference = MapReference.next(after: viewport.activeReference) {
                viewport.show(reference)
            }
        case .openDataCatalog:
            toggleDrawer(.catalog)
        case .openCollection:
            if !bookmarks.bookmarks.isEmpty { toggleDrawer(.collection) }
        case .toggleAreaAnalysis:
            toggleAreaAnalysis()
        case .toggleLandscapeProfile:
            toggleLandscapeProfile()
        case .exportMap:
            exportVisibleMap()
        case .toggleSidebar:
            sidebarVisible.toggle()
        }
    }

    private func openQuickPalette() {
        if showQuickPalette {
            closeQuickPalette()
            return
        }
        paletteQuery = ""
        paletteSelectionIndex = 0
        showQuickPalette = true
        DispatchQueue.main.async { paletteFocused = true }
    }

    private func closeQuickPalette() {
        paletteFocused = false
        showQuickPalette = false
    }

    private func revealDrawer(_ selection: AtlasDrawer) {
        if activeDrawer != selection { toggleDrawer(selection) }
    }

    private func paletteMatches(_ values: [String]) -> Bool {
        let query = paletteQuery
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
        guard !query.isEmpty else { return true }
        return values.joined(separator: " ")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .contains(query)
    }

    private func performPaletteAction(_ action: AtlasPaletteAction) {
        closeQuickPalette()
        switch action {
        case .search:
            if !sidebarVisible { sidebarVisible = true }
            DispatchQueue.main.async { searchFocused = true }
        case .fitGermany:
            viewport.fitGermany()
        case .dataCatalog:
            revealDrawer(.catalog)
        case .collection:
            if !bookmarks.bookmarks.isEmpty { revealDrawer(.collection) }
        case .areaAnalysis:
            toggleAreaAnalysis()
        case .landscapeProfile:
            toggleLandscapeProfile()
        case .appearance:
            revealDrawer(.appearance)
        }
    }

    private func activatePaletteEntry(_ entry: MapManifest.DataCatalogEntry) {
        closeQuickPalette()
        activeDrawer = nil
        activateCatalogEntry(entry)
        switch entry.activation {
        case .surfaceTexture:
            revealDrawer(.surface)
        case .thematic:
            revealDrawer(.thematic)
        default:
            break
        }
    }

    private func movePaletteSelection(by offset: Int, itemCount: Int) {
        guard itemCount > 0 else { return }
        paletteSelectionIndex = (paletteSelectionIndex + offset + itemCount) % itemCount
        paletteNavigationSequence &+= 1
    }

    private func selectPaletteItem(
        at index: Int,
        actions: [AtlasPaletteAction],
        references: [MapReference],
        catalog: [MapManifest.DataCatalogEntry],
        showsAllSourcesItem: Bool
    ) {
        guard index >= 0 else { return }
        if index < actions.count {
            performPaletteAction(actions[index])
            return
        }
        let referenceIndex = index - actions.count
        if referenceIndex < references.count {
            closeQuickPalette()
            viewport.show(references[referenceIndex])
            return
        }
        let catalogIndex = referenceIndex - references.count
        if catalogIndex < catalog.count {
            activatePaletteEntry(catalog[catalogIndex])
        } else if showsAllSourcesItem && catalogIndex == catalog.count {
            closeQuickPalette()
            revealDrawer(.catalog)
        }
    }

    private func quickPaletteOverlay(manifest: MapManifest) -> some View {
        let actions = AtlasPaletteAction.allCases.filter {
            ($0 != .collection || !bookmarks.bookmarks.isEmpty)
                && paletteMatches([$0.title, $0.detail])
        }
        let references = MapReference.all.filter {
            paletteMatches([$0.name, $0.subtitle, $0.story])
        }
        let catalog = manifest.dataCatalog.filter {
            paletteMatches([
                $0.name, $0.role, $0.license, $0.productName ?? "", $0.category.title,
            ])
        }
        let visibleCatalog = paletteQuery.isEmpty ? Array(catalog.prefix(5)) : catalog
        let resultCount = actions.count + references.count + catalog.count
        let showsAllSourcesItem = paletteQuery.isEmpty && catalog.count > visibleCatalog.count
        let selectableCount = actions.count + references.count + visibleCatalog.count
            + (showsAllSourcesItem ? 1 : 0)
        let selectedIndex = selectableCount > 0
            ? min(paletteSelectionIndex, selectableCount - 1) : 0

        return ZStack(alignment: .top) {
            Color.black.opacity(0.16)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { closeQuickPalette() }

            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.green)
                        .contentTransition(.symbolEffect(.replace))
                    TextField("Landschaft, Datensatz oder Werkzeug", text: $paletteQuery)
                        .textFieldStyle(.plain)
                        .font(.system(size: 16, weight: .medium))
                        .focused($paletteFocused)
                        .onSubmit {
                            selectPaletteItem(
                                at: selectedIndex,
                                actions: actions,
                                references: references,
                                catalog: visibleCatalog,
                                showsAllSourcesItem: showsAllSourcesItem
                            )
                        }
                        .onKeyPress(.downArrow) {
                            movePaletteSelection(by: 1, itemCount: selectableCount)
                            return .handled
                        }
                        .onKeyPress(.upArrow) {
                            movePaletteSelection(by: -1, itemCount: selectableCount)
                            return .handled
                        }
                        .onChange(of: paletteQuery) { _, _ in paletteSelectionIndex = 0 }
                    if !paletteQuery.isEmpty {
                        Text("\(resultCount)")
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(.primary.opacity(0.055), in: Capsule())
                            .transition(.scale.combined(with: .opacity))
                        Button { paletteQuery = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.tertiary)
                        }
                        .buttonStyle(AtlasPressButtonStyle(pressedScale: 0.88))
                    }
                    Text("⌘K")
                        .font(.caption2.monospaced().weight(.medium))
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                        .background(.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 5))
                    Button { closeQuickPalette() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .frame(width: 22, height: 22)
                            .background(.primary.opacity(0.055), in: Circle())
                    }
                    .buttonStyle(AtlasPressButtonStyle(pressedScale: 0.88))
                    .help("Stöberpalette schließen")
                }
                .padding(.horizontal, 16)
                .frame(height: 54)

                Divider().opacity(0.55)

                if resultCount == 0 {
                    ContentUnavailableView(
                        "Nichts gefunden",
                        systemImage: "magnifyingglass",
                        description: Text("Versuche ein Thema wie Wald, Geologie, Wasser oder Relief.")
                    )
                    .frame(maxWidth: .infinity, minHeight: 230)
                } else {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 5) {
                                if !actions.isEmpty {
                                    AtlasPaletteSectionTitle(title: "Werkzeuge", count: actions.count)
                                    ForEach(Array(actions.enumerated()), id: \.element.id) { offset, action in
                                        Button { performPaletteAction(action) } label: {
                                            AtlasPaletteRow(
                                                title: action.title,
                                                detail: action.detail,
                                                symbol: action.symbol,
                                                tint: action.tint,
                                                isSelected: selectedIndex == offset,
                                                onHoverSelection: { paletteSelectionIndex = offset }
                                            )
                                        }
                                        .buttonStyle(AtlasPressButtonStyle(pressedScale: 0.99))
                                        .id("palette-\(offset)")
                                    }
                                }

                                if !references.isEmpty {
                                    AtlasPaletteSectionTitle(
                                        title: "Landschaftsfunde",
                                        count: references.count
                                    )
                                    ForEach(Array(references.enumerated()), id: \.element.id) { offset, reference in
                                        let index = actions.count + offset
                                        Button {
                                            closeQuickPalette()
                                            viewport.show(reference)
                                        } label: {
                                            AtlasPaletteRow(
                                                title: reference.name,
                                                detail: reference.subtitle,
                                                symbol: reference.symbolName,
                                                tint: RGBAColor(hex: reference.accentHex).color,
                                                trailing: "Auf Karte",
                                                isSelected: selectedIndex == index,
                                                onHoverSelection: { paletteSelectionIndex = index }
                                            )
                                        }
                                        .buttonStyle(AtlasPressButtonStyle(pressedScale: 0.99))
                                        .id("palette-\(index)")
                                    }
                                }

                                if !visibleCatalog.isEmpty {
                                    AtlasPaletteSectionTitle(
                                        title: paletteQuery.isEmpty ? "Freie Daten entdecken" : "Datensätze",
                                        count: catalog.count
                                    )
                                    ForEach(Array(visibleCatalog.enumerated()), id: \.element.id) { offset, entry in
                                        let index = actions.count + references.count + offset
                                        Button {
                                            activatePaletteEntry(entry)
                                        } label: {
                                            AtlasPaletteRow(
                                                title: entry.name,
                                                detail: entry.productName ?? entry.role,
                                                symbol: entry.category.symbolName,
                                                tint: catalogTint(entry.category),
                                                trailing: entry.license,
                                                isSelected: selectedIndex == index,
                                                onHoverSelection: { paletteSelectionIndex = index }
                                            )
                                        }
                                        .buttonStyle(AtlasPressButtonStyle(pressedScale: 0.99))
                                        .id("palette-\(index)")
                                    }
                                    if showsAllSourcesItem {
                                        let index = actions.count + references.count + visibleCatalog.count
                                        Button {
                                            closeQuickPalette()
                                            revealDrawer(.catalog)
                                        } label: {
                                            AtlasPaletteRow(
                                                title: "Alle \(catalog.count) Quellen",
                                                detail: "Vollständigen Datenatlas öffnen",
                                                symbol: "books.vertical.fill",
                                                tint: .green,
                                                trailing: "Datenatlas",
                                                isSelected: selectedIndex == index,
                                                onHoverSelection: { paletteSelectionIndex = index }
                                            )
                                        }
                                        .buttonStyle(AtlasPressButtonStyle(pressedScale: 0.99))
                                        .id("palette-\(index)")
                                    }
                                }
                            }
                            .padding(10)
                        }
                        .onChange(of: paletteNavigationSequence) { _, _ in
                            let scroll = { proxy.scrollTo("palette-\(selectedIndex)", anchor: .center) }
                            if reduceMotion { scroll() }
                            else { withAnimation(.snappy(duration: 0.18)) { scroll() } }
                        }
                    }
                    .frame(maxHeight: 480)
                }

                HStack {
                    Label(
                        "Tippen filtert alles gemeinsam",
                        systemImage: "line.3.horizontal.decrease.circle"
                    )
                    Spacer()
                    Text("↑↓ wählen · ↩ öffnen · esc schließen")
                }
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 15)
                .frame(height: 32)
                .background(.primary.opacity(0.025))
            }
            .frame(width: 570)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 19, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 19, style: .continuous)
                    .stroke(
                        LinearGradient(
                            colors: [.white.opacity(0.62), .green.opacity(0.18), .black.opacity(0.10)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.9
                    )
            }
            .overlay(alignment: .top) {
                Capsule()
                    .fill(.white.opacity(0.50))
                    .frame(width: 92, height: 1)
                    .padding(.top, 1)
            }
            .shadow(color: .black.opacity(0.26), radius: 34, y: 16)
            .padding(.top, 76)
            .onExitCommand { closeQuickPalette() }
        }
        .onAppear { DispatchQueue.main.async { paletteFocused = true } }
        .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: paletteQuery.isEmpty)
    }

    private func toggleAreaAnalysis() {
        let enabled = !analysisMode
        analysisMode = enabled
        profileMode = false
        viewport.clearProfile()
        if enabled {
            activeDrawer = nil
            viewport.clearAnalysis()
        }
    }

    private func toggleLandscapeProfile() {
        let enabled = !profileMode
        profileMode = enabled
        analysisMode = false
        viewport.clearAnalysis()
        if enabled {
            activeDrawer = nil
            viewport.clearProfile()
        }
    }

    private func thematicSymbol(_ product: MapManifest.ThematicRaster) -> String {
        switch product.id {
        case "substrate": "square.stack.3d.up.fill"
        case "geology": "fossil.shell.fill"
        case "geomorphography": "mountain.2.fill"
        case "groundwater-level": "drop.fill"
        default: "map.fill"
        }
    }

    private func thematicTint(_ product: MapManifest.ThematicRaster) -> Color {
        switch product.id {
        case "substrate": .brown
        case "geology": .purple
        case "geomorphography": .orange
        case "groundwater-level": .blue
        default: .secondary
        }
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

}

private struct GeoScienceSidebar: View {
    let manifest: MapManifest
    @ObservedObject var settings: GeoScienceSettings
    @ObservedObject var style: StyleSettings
    let showsHeader: Bool
    @State private var showAllClasses = false
    @State private var showSources = false
    @State private var showAdvancedDisplay = false

    private var product: MapManifest.ThematicRaster? {
        settings.product(in: manifest)
    }

    private var legendClasses: [MapManifest.LandClass] {
        product?.classes.filter { $0.id != 0 } ?? []
    }

    private var displayedClasses: [MapManifest.LandClass] {
        showAllClasses ? legendClasses : Array(legendClasses.prefix(6))
    }

    private var productGroups: [(name: String, products: [MapManifest.ThematicRaster])] {
        let products = manifest.availableThematicRasters
        let definitions: [(String, [String])] = [
            ("Boden", ["substrate"]),
            ("Gestein", ["geology"]),
            ("Reliefform", ["geomorphography"]),
            ("Wasser", ["groundwater-level"]),
        ]
        let known = Set(definitions.flatMap(\.1))
        var result = definitions.compactMap { name, ids in
            let matches = ids.compactMap { id in products.first { $0.id == id } }
            return matches.isEmpty ? nil : (name, matches)
        }
        let remaining = products.filter { !known.contains($0.id) }
        if !remaining.isEmpty { result.append(("Weitere", remaining)) }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if showsHeader {
                VStack(alignment: .leading, spacing: 2) {
                    Label("Fachkarten", systemImage: "square.3.layers.3d.top.filled")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text("Boden, Gestein, Relief und Wasser")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            if manifest.availableThematicRasters.isEmpty {
                panel {
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Keine geowissenschaftlichen Flächenkarten", systemImage: "externaldrive.badge.exclamationmark")
                            .font(.subheadline.weight(.medium))
                        Text("Erzeuge Boden-, Geologie-, Relief- und Grundwasserkarten mit der Geowissenschafts-Pipeline.")
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
                HStack {
                    sectionLabel("Kartenkatalog", symbol: "books.vertical.fill")
                    Spacer()
                    Text("eine aktiv")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Menu {
                    Button {
                        settings.selectedRasterID = nil
                    } label: {
                        if product == nil {
                            Label("Keine Fachkarte", systemImage: "checkmark")
                        } else {
                            Text("Keine Fachkarte")
                        }
                    }
                    Divider()
                    ForEach(productGroups, id: \.name) { group in
                        Section(group.name) {
                            ForEach(group.products) { item in
                                Button {
                                    settings.selectedRasterID = item.id
                                } label: {
                                    if settings.selectedRasterID == item.id {
                                        Label(item.name, systemImage: "checkmark")
                                    } else {
                                        Text(item.name)
                                    }
                                }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: product == nil ? "square.dashed" : "map.fill")
                            .foregroundStyle(product == nil ? .secondary : Color.accentColor)
                            .frame(width: 22)
                        Text(product?.name ?? "Fachkarte auswählen")
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                        Spacer()
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                    }
                    .padding(.horizontal, 9)
                    .frame(height: 36)
                    .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 9))
                }
                .menuStyle(.borderlessButton)
                .accessibilityLabel("Fachkarte")

                Text(product == nil ? "Die Landoberfläche bleibt unverändert sichtbar." : "Die Auswahl ersetzt automatisch die zuvor aktive Raster-Fachkarte.")
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
                    Text("Die Fachkarte ersetzt die Landoberfläche vollständig; das Geländerelief bleibt erhalten.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()

                DisclosureGroup(isExpanded: $showAdvancedDisplay) {
                    VStack(alignment: .leading, spacing: 8) {
                        Picker("Darstellung", selection: $settings.presentation) {
                            Text("Überlagern").tag(ThematicPresentation.overlay)
                            Text("Als Basiskarte").tag(ThematicPresentation.baseMap)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()

                        Text("„Als Basiskarte“ blendet die Landoberfläche unter gültigen Fachkartendaten aus.")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, 8)
                } label: {
                    Text("Erweiterte Darstellung")
                        .font(.caption.weight(.medium))
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

private enum AtlasDrawer: String, Equatable {
    case surface
    case relief
    case thematic
    case labels
    case transport
    case hydrography
    case energy
    case discovery
    case catalog
    case collection
    case appearance

    var title: String {
        switch self {
        case .surface: "Landoberfläche"
        case .relief: "Geländerelief"
        case .thematic: "Fachkarten"
        case .labels: "Namen & Naturorte"
        case .transport: "Verkehr"
        case .hydrography: "Gewässer & Grenzen"
        case .energy: "Energie"
        case .discovery: "Landschaft lesen"
        case .catalog: "Datenatlas"
        case .collection: "Meine Sammlung"
        case .appearance: "Stile & Export"
        }
    }

    var subtitle: String {
        switch self {
        case .surface: "Hochauflösende Kartengrundlage"
        case .relief: "Licht, Kontrast und Geländeform"
        case .thematic: "Eine Rasterkarte über der Oberfläche"
        case .labels: "Beschriftungen gezielt filtern"
        case .transport: "Straßen- und Schienennetze"
        case .hydrography: "Hydrographie und Verwaltung"
        case .energy: "Netze, Knoten und Erzeugung"
        case .discovery: "Beobachtungsimpulse & freie Daten"
        case .catalog: "Quellen, Lizenzen & Kartenbezug"
        case .collection: "Fundstellen bewahren & vergleichen"
        case .appearance: "Kartenstil, Ausgabe und Daten"
        }
    }

    var symbol: String {
        switch self {
        case .surface: "leaf.fill"
        case .relief: "mountain.2.fill"
        case .thematic: "square.3.layers.3d.top.filled"
        case .labels: "textformat.abc"
        case .transport: "point.bottomleft.forward.to.point.topright.scurvepath"
        case .hydrography: "water.waves"
        case .energy: "bolt.fill"
        case .discovery: "binoculars.fill"
        case .catalog: "books.vertical.fill"
        case .collection: "rectangle.stack.fill"
        case .appearance: "paintpalette.fill"
        }
    }

    var tint: Color {
        switch self {
        case .surface, .relief: .green
        case .thematic: .indigo
        case .labels: .orange
        case .transport: .red
        case .hydrography: .blue
        case .energy: .yellow
        case .discovery: .green
        case .catalog: .teal
        case .collection: .teal
        case .appearance: .purple
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

private struct ProfileSelectionOverlay: View {
    let line: MapScreenLine

    var body: some View {
        Canvas { context, _ in
            var path = Path()
            path.move(to: line.start)
            path.addLine(to: line.end)
            context.stroke(path, with: .color(.black.opacity(0.42)), lineWidth: 5)
            context.stroke(
                path,
                with: .color(.cyan.opacity(0.96)),
                style: StrokeStyle(lineWidth: 2.2, lineCap: .round, dash: [8, 5])
            )
            for (point, label) in [(line.start, "A"), (line.end, "B")] {
                let circle = Path(ellipseIn: CGRect(x: point.x - 10, y: point.y - 10, width: 20, height: 20))
                context.fill(circle, with: .color(.cyan))
                context.stroke(circle, with: .color(.white.opacity(0.94)), lineWidth: 1.3)
                context.draw(
                    Text(label).font(.system(size: 10, weight: .bold)).foregroundColor(.black),
                    at: point,
                    anchor: .center
                )
            }
        }
        .accessibilityHidden(true)
    }
}

private struct LandscapeProfilePanel: View {
    let profile: LandscapeProfile?
    let isLoading: Bool
    let message: String?
    let colors: [RGBAColor]
    let thematicName: String?
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "chart.xyaxis.line")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(.cyan)
                    .frame(width: 32, height: 32)
                    .background(.cyan.opacity(0.11), in: Circle())
                VStack(alignment: .leading, spacing: 0) {
                    Text("Landschaftsprofil")
                        .font(.headline)
                    Text("Gelände und Landoberfläche von A nach B")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 24, height: 24)
                        .background(.primary.opacity(0.07), in: Circle())
                }
                .buttonStyle(.plain)
                .help("Profil schließen")
            }
            .padding(12)

            Divider().opacity(0.55)

            if isLoading {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("Profil wird aus den 10-m-Kacheln gelesen …")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 150)
            } else if let profile {
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 7) {
                        profileMetric("Strecke", distance(profile.distanceMeters), symbol: "ruler")
                        profileMetric(
                            "Höhen",
                            elevationSpan(profile),
                            symbol: "mountain.2.fill"
                        )
                        profileMetric("Anstieg", "+\(profile.ascentMeters.formatted()) m", symbol: "arrow.up.right")
                        profileMetric("Abstieg", "−\(profile.descentMeters.formatted()) m", symbol: "arrow.down.right")
                    }

                    LandscapeProfileChart(profile: profile, colors: colors)
                        .frame(height: 146)

                    HStack(alignment: .top, spacing: 12) {
                        Label(
                            "\(profile.distinctLandClasses) Landklassen in \(profile.segments.count) Abschnitten",
                            systemImage: "square.3.layers.3d"
                        )
                        if let thematicName, profile.distinctThematicClasses > 0 {
                            Label(
                                "\(profile.distinctThematicClasses) Klassen · \(thematicName)",
                                systemImage: "fossil.shell.fill"
                            )
                        }
                        Spacer(minLength: 0)
                        Text("\(profile.samples.count) Messpunkte")
                            .monospacedDigit()
                    }
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)

                    let classes = uniqueClasses(profile)
                    HStack(spacing: 10) {
                        ForEach(classes, id: \.classID) { segment in
                            HStack(spacing: 4) {
                                Circle()
                                    .fill(color(for: segment.classID))
                                    .frame(width: 7, height: 7)
                                Text(segment.className)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                }
                .padding(12)
            } else {
                ContentUnavailableView(
                    "Profil nicht verfügbar",
                    systemImage: "chart.xyaxis.line",
                    description: Text(message ?? "Ziehe eine längere Linie innerhalb der Karte.")
                )
                .frame(maxWidth: .infinity, minHeight: 150)
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [.white.opacity(0.60), .cyan.opacity(0.22), .black.opacity(0.10)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.8
                )
        }
        .shadow(color: .black.opacity(0.24), radius: 24, y: 11)
    }

    private func profileMetric(_ title: String, _ value: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(title, systemImage: symbol)
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.weight(.semibold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 9))
    }

    private func distance(_ meters: Double) -> String {
        if meters < 1_000 { return "\(Int(meters.rounded()).formatted()) m" }
        return "\((meters / 1_000).formatted(.number.precision(.fractionLength(1)))) km"
    }

    private func elevationSpan(_ profile: LandscapeProfile) -> String {
        guard let minimum = profile.minimumElevation, let maximum = profile.maximumElevation else {
            return "–"
        }
        return "\(minimum.formatted())–\(maximum.formatted()) m"
    }

    private func uniqueClasses(_ profile: LandscapeProfile) -> [LandscapeProfileSegment] {
        var seen: Set<Int> = []
        return profile.segments.filter { seen.insert($0.classID).inserted }.prefix(5).map { $0 }
    }

    private func color(for classID: Int) -> Color {
        colors.indices.contains(classID) ? colors[classID].color : .secondary
    }
}

private struct LandscapeProfileChart: View {
    let profile: LandscapeProfile
    let colors: [RGBAColor]

    var body: some View {
        Canvas { context, size in
            let plot = CGRect(x: 10, y: 9, width: max(1, size.width - 20), height: max(1, size.height - 31))
            for fraction in [0.0, 0.5, 1.0] {
                let y = plot.minY + plot.height * fraction
                var grid = Path()
                grid.move(to: CGPoint(x: plot.minX, y: y))
                grid.addLine(to: CGPoint(x: plot.maxX, y: y))
                context.stroke(grid, with: .color(.secondary.opacity(0.15)), lineWidth: 0.7)
            }

            let minimum = Double(profile.minimumElevation ?? 0)
            let maximum = Double(profile.maximumElevation ?? Int(minimum + 1))
            let range = max(20, maximum - minimum)
            var line = Path()
            var area = Path()
            var started = false
            for sample in profile.samples {
                guard let elevation = sample.elevation else {
                    started = false
                    continue
                }
                let x = plot.minX + plot.width * sample.distanceMeters / max(1, profile.distanceMeters)
                let normalized = (Double(elevation) - minimum) / range
                let y = plot.maxY - plot.height * normalized
                let point = CGPoint(x: x, y: y)
                if started {
                    line.addLine(to: point)
                    area.addLine(to: point)
                } else {
                    line.move(to: point)
                    area.move(to: CGPoint(x: x, y: plot.maxY))
                    area.addLine(to: point)
                    started = true
                }
            }
            if let last = profile.samples.last {
                let x = plot.minX + plot.width * last.distanceMeters / max(1, profile.distanceMeters)
                area.addLine(to: CGPoint(x: x, y: plot.maxY))
                area.closeSubpath()
            }
            context.fill(
                area,
                with: .linearGradient(
                    Gradient(colors: [.cyan.opacity(0.30), .cyan.opacity(0.03)]),
                    startPoint: CGPoint(x: plot.midX, y: plot.minY),
                    endPoint: CGPoint(x: plot.midX, y: plot.maxY)
                )
            )
            context.stroke(line, with: .color(.cyan), style: StrokeStyle(lineWidth: 2, lineJoin: .round))

            let bandY = size.height - 16
            for segment in profile.segments {
                let startX = plot.minX + plot.width * segment.startMeters / max(1, profile.distanceMeters)
                let endX = plot.minX + plot.width * segment.endMeters / max(1, profile.distanceMeters)
                let rectangle = CGRect(x: startX, y: bandY, width: max(1, endX - startX), height: 9)
                context.fill(Path(roundedRect: rectangle, cornerRadius: 2), with: .color(color(segment.classID)))
            }
            context.draw(Text("A").font(.caption2.bold()), at: CGPoint(x: plot.minX, y: size.height - 3), anchor: .bottomLeading)
            context.draw(Text("B").font(.caption2.bold()), at: CGPoint(x: plot.maxX, y: size.height - 3), anchor: .bottomTrailing)
        }
        .background(.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 11))
        .overlay {
            RoundedRectangle(cornerRadius: 11)
                .stroke(.primary.opacity(0.06), lineWidth: 0.7)
        }
        .accessibilityLabel("Höhen- und Landoberflächenprofil von A nach B")
    }

    private func color(_ classID: Int) -> Color {
        colors.indices.contains(classID) ? colors[classID].color : .secondary
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

private struct BookmarkCollectionRow: View {
    let bookmark: MapBookmark
    let classColors: [Color]
    let comparisonSlot: Int?
    let onSelectComparison: () -> Void
    let onShow: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Button(action: onSelectComparison) {
                ZStack {
                    Circle()
                        .fill(comparisonSlot == 0 ? Color.teal : comparisonSlot == 1 ? Color.orange : Color.primary.opacity(0.055))
                    if let comparisonSlot {
                        Text(comparisonSlot == 0 ? "A" : "B")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                    } else {
                        Image(systemName: bookmark.isComparable ? "plus" : "map")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .disabled(!bookmark.isComparable)
            .help(bookmark.isComparable ? "Für Vergleich als A oder B wählen" : "Einfache Kartenansicht ohne Punktdaten")

            VStack(alignment: .leading, spacing: 3) {
                Text(bookmark.name)
                    .font(.caption.weight(.semibold))
                    .lineLimit(2)
                if let detail = bookmark.detail {
                    Text([detail.surfaceGroup, detail.surfaceName].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    if let thematic = detail.thematicClassName {
                        Label(thematic, systemImage: "fossil.shell.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.indigo)
                            .lineLimit(1)
                    }
                    if let context = detail.landscapeContext {
                        LandscapeFingerprintBar(context: context, classColors: classColors)
                            .frame(height: 7)
                            .padding(.vertical, 2)
                        Label(
                            "\(contextRadius(context)) · \(context.classes.count) Klassen · "
                                + elevationRange(context),
                            systemImage: "circle.dotted.and.circle"
                        )
                        .font(.system(size: 9))
                        .foregroundStyle(.teal)
                        .lineLimit(1)
                        if let nearbyNames = context.nearbyNames {
                            Label(nearbyNames, systemImage: "text.magnifyingglass")
                                .font(.system(size: 9))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                } else {
                    Text("Kartenansicht · \(bookmark.coordinateText)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if let note = bookmark.note, !note.isEmpty {
                    Text("„\(note)“")
                        .font(.system(size: 9))
                        .italic()
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                HStack(spacing: 8) {
                    Button("Zeigen", action: onShow)
                        .buttonStyle(.borderless)
                        .font(.system(size: 9, weight: .semibold))
                    Spacer()
                    Button(role: .destructive, action: onDelete) {
                        Image(systemName: "trash")
                            .font(.system(size: 9))
                    }
                    .buttonStyle(.borderless)
                    .help("Aus Sammlung löschen")
                }
            }
        }
    }

    private func contextRadius(_ context: LandscapeContext) -> String {
        "\((context.radiusMeters / 1_000).formatted(.number.precision(.fractionLength(0)))) km"
    }

    private func elevationRange(_ context: LandscapeContext) -> String {
        guard let range = context.elevationRange else { return "ohne Höhenwert" }
        return "\(range.formatted()) m Höhenraum"
    }
}

private struct BookmarkComparisonPanel: View {
    let comparison: MapBookmarkComparison
    let classColors: [Color]
    let show: (MapBookmark) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Direkter Vergleich", systemImage: "arrow.left.arrow.right")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                if let difference = comparison.elevationDifference {
                    Text(elevationDifference(difference))
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }

            HStack(alignment: .top, spacing: 8) {
                comparisonHeading("A", bookmark: comparison.first, color: .teal)
                comparisonHeading("B", bookmark: comparison.second, color: .orange)
            }

            if comparison.first.detail?.landscapeContext != nil
                || comparison.second.detail?.landscapeContext != nil
            {
                HStack(alignment: .top, spacing: 8) {
                    landscapePortrait(comparison.first.detail?.landscapeContext, tint: .teal)
                    landscapePortrait(comparison.second.detail?.landscapeContext, tint: .orange)
                }
                comparisonRow(
                    "Prägende Umgebung",
                    symbol: comparison.sharesDominantContextClass == true
                        ? "equal.circle.fill" : "circle.lefthalf.filled",
                    first: dominantContext(comparison.first),
                    second: dominantContext(comparison.second)
                )
                comparisonRow(
                    "Landschaftsmosaik",
                    symbol: "square.grid.3x3",
                    first: contextDiversity(comparison.first),
                    second: contextDiversity(comparison.second)
                )
                comparisonRow(
                    "Höhenraum",
                    symbol: "mountain.2",
                    first: contextElevation(comparison.first),
                    second: contextElevation(comparison.second)
                )
                comparisonRow(
                    "Relief",
                    symbol: "angle",
                    first: contextRelief(comparison.first),
                    second: contextRelief(comparison.second)
                )
                comparisonRow(
                    "Bevölkerung im Kreis",
                    symbol: "person.2",
                    first: contextPopulation(comparison.first),
                    second: contextPopulation(comparison.second)
                )
                comparisonRow(
                    "Benannte Nähe",
                    symbol: "text.magnifyingglass",
                    first: contextNames(comparison.first),
                    second: contextNames(comparison.second)
                )
            }

            comparisonRow(
                "Oberfläche",
                symbol: "leaf.fill",
                first: comparison.first.detail?.surfaceName,
                second: comparison.second.detail?.surfaceName
            )
            comparisonRow(
                "Landschaftsgruppe",
                symbol: comparison.sharesSurfaceGroup == true ? "equal.circle.fill" : "circle.lefthalf.filled",
                first: comparison.first.detail?.surfaceGroup,
                second: comparison.second.detail?.surfaceGroup
            )
            comparisonRow(
                "Höhe",
                symbol: "mountain.2.fill",
                first: comparison.first.detail?.elevation.map { "\($0.formatted()) m" },
                second: comparison.second.detail?.elevation.map { "\($0.formatted()) m" }
            )
            comparisonRow(
                "Hanglage",
                symbol: "angle",
                first: terrain(comparison.first),
                second: terrain(comparison.second)
            )
            if comparison.first.detail?.thematicClassName != nil
                || comparison.second.detail?.thematicClassName != nil
            {
                comparisonRow(
                    comparison.sharesThematicProduct
                        ? comparison.first.detail?.thematicProductName ?? "Fachkarte" : "Fachinformation",
                    symbol: "fossil.shell.fill",
                    first: comparison.first.detail?.thematicClassName,
                    second: comparison.second.detail?.thematicClassName
                )
            }

            HStack(spacing: 8) {
                Button { show(comparison.first) } label: {
                    Label("A zeigen", systemImage: "scope")
                        .frame(maxWidth: .infinity)
                }
                .tint(.teal)
                Button { show(comparison.second) } label: {
                    Label("B zeigen", systemImage: "scope")
                        .frame(maxWidth: .infinity)
                }
                .tint(.orange)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .font(.system(size: 9, weight: .semibold))
        }
        .padding(12)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [.teal.opacity(0.32), .orange.opacity(0.26)],
                        startPoint: .leading,
                        endPoint: .trailing
                    ),
                    lineWidth: 0.9
                )
        }
    }

    private func comparisonHeading(_ slot: String, bookmark: MapBookmark, color: Color) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Text(slot)
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.white)
                .frame(width: 23, height: 23)
                .background(color, in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(bookmark.name)
                    .font(.caption.weight(.semibold))
                    .lineLimit(2)
                Text(bookmark.coordinateText)
                    .font(.system(size: 8).monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func landscapePortrait(_ context: LandscapeContext?, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            if let context {
                HStack(alignment: .top, spacing: 7) {
                    LandscapeCompositionOrb(context: context)
                        .frame(width: 37, height: 37)
                    VStack(alignment: .leading, spacing: 4) {
                        LandscapeFingerprintBar(context: context, classColors: classColors)
                            .frame(height: 7)
                        Text(context.title)
                            .font(.system(size: 9, weight: .semibold))
                            .lineLimit(2)
                        Text(
                            "\((context.radiusMeters / 1_000).formatted(.number.precision(.fractionLength(0)))) km Radius"
                        )
                        .font(.system(size: 8).monospacedDigit())
                        .foregroundStyle(.secondary)
                    }
                }
            } else {
                Label("Nur Punktdaten", systemImage: "mappin")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, minHeight: 55, alignment: .topLeading)
        .background(tint.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
    }

    private func dominantContext(_ bookmark: MapBookmark) -> String? {
        guard let item = bookmark.detail?.landscapeContext?.classes.first else { return nil }
        return "\(item.name) · \(item.share.formatted(.percent.precision(.fractionLength(0))))"
    }

    private func contextDiversity(_ bookmark: MapBookmark) -> String? {
        guard let context = bookmark.detail?.landscapeContext else { return nil }
        return "\(context.classes.count) Klassen · \(context.distinctGroups) Gruppen"
    }

    private func contextElevation(_ bookmark: MapBookmark) -> String? {
        guard
            let context = bookmark.detail?.landscapeContext,
            let minimum = context.minimumElevation,
            let maximum = context.maximumElevation
        else { return nil }
        return "\(minimum.formatted())–\(maximum.formatted()) m · Δ \((maximum - minimum).formatted()) m"
    }

    private func contextRelief(_ bookmark: MapBookmark) -> String? {
        guard
            let context = bookmark.detail?.landscapeContext,
            let mean = context.meanSlopeDegrees,
            let maximum = context.maximumSlopeDegrees
        else { return nil }
        return "Ø \(mean.formatted(.number.precision(.fractionLength(1))))° · "
            + "max \(maximum.formatted(.number.precision(.fractionLength(1))))°"
    }

    private func contextPopulation(_ bookmark: MapBookmark) -> String? {
        guard
            let context = bookmark.detail?.landscapeContext,
            let population = context.population
        else { return nil }
        let count = population.formatted(.number.notation(.compactName))
        guard let density = context.populationDensity else { return count }
        return "\(count) · \(Int(density.rounded()).formatted())/km²"
    }

    private func contextNames(_ bookmark: MapBookmark) -> String? {
        bookmark.detail?.landscapeContext?.nearbyNames
    }

    private func terrain(_ bookmark: MapBookmark) -> String? {
        guard let slope = bookmark.detail?.slopeDegrees else { return nil }
        if slope < 0.5 { return "nahezu eben" }
        let direction = bookmark.detail?.aspectDegrees.map(aspectDirection)
        let value = slope.formatted(.number.precision(.fractionLength(1))) + "°"
        return direction.map { "\(value) nach \($0)" } ?? value
    }

    private func aspectDirection(_ degrees: Double) -> String {
        let directions = ["N", "NO", "O", "SO", "S", "SW", "W", "NW"]
        return directions[Int((degrees + 22.5) / 45) % directions.count]
    }

    private func comparisonRow(
        _ title: String,
        symbol: String,
        first: String?,
        second: String?
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: symbol)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
            HStack(alignment: .top, spacing: 8) {
                Text(first ?? "–")
                    .frame(maxWidth: .infinity, alignment: .leading)
                Divider()
                Text(second ?? "–")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.caption2)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(8)
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 9))
    }

    private func elevationDifference(_ difference: Int) -> String {
        if difference == 0 { return "gleiche Höhe" }
        return "B \(abs(difference).formatted()) m \(difference > 0 ? "höher" : "tiefer")"
    }
}

private struct MapArrivalPulse: View {
    let color: Color
    @State private var isFinished = false

    var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.12))
                .frame(width: 24, height: 24)
                .scaleEffect(isFinished ? 2.8 : 0.65)
                .opacity(isFinished ? 0 : 0.8)
            Circle()
                .stroke(color.opacity(0.72), lineWidth: 1.2)
                .frame(width: 18, height: 18)
                .scaleEffect(isFinished ? 1.65 : 0.72)
                .opacity(isFinished ? 0 : 1)
            Circle()
                .fill(color)
                .frame(width: 5, height: 5)
                .opacity(isFinished ? 0 : 0.9)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .onAppear {
            withAnimation(.easeOut(duration: 0.58)) { isFinished = true }
        }
        .accessibilityHidden(true)
    }
}

private struct LandscapeFingerprintBar: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let context: LandscapeContext
    let classColors: [Color]
    @State private var isRevealed = false

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 1) {
                ForEach(context.classes) { item in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(color(item.classID))
                        .frame(
                            width: max(
                                1,
                                geometry.size.width * item.share * (isRevealed ? 1 : 0) - 1
                            )
                        )
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 3))
        }
        .accessibilityLabel(
            "Landschaftsmosaik aus \(context.classes.count) Oberflächenklassen"
        )
        .onAppear {
            if reduceMotion {
                isRevealed = true
            } else {
                withAnimation(.smooth(duration: 0.42)) { isRevealed = true }
            }
        }
    }

    private func color(_ classID: Int) -> Color {
        classColors.indices.contains(classID) ? classColors[classID] : .secondary
    }
}

private struct LandscapeCompositionOrb: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let context: LandscapeContext
    @State private var reveal: CGFloat = 0
    @State private var isHovered = false

    var body: some View {
        GeometryReader { geometry in
            let groups = context.groupShares
            let diameter = min(geometry.size.width, geometry.size.height)
            ZStack {
                Circle()
                    .stroke(.primary.opacity(0.055), lineWidth: diameter * 0.14)
                ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                    let share = CGFloat(group.share)
                    let gap = min(0.006, share * 0.22)
                    Circle()
                        .trim(
                            from: segmentStart(index, groups: groups) + gap,
                            to: max(
                                segmentStart(index, groups: groups) + gap,
                                segmentStart(index, groups: groups) + share * reveal - gap
                            )
                        )
                        .stroke(
                            groupColor(group.name),
                            style: StrokeStyle(
                                lineWidth: diameter * 0.14,
                                lineCap: .round
                            )
                        )
                        .rotationEffect(.degrees(-90))
                }
                Circle()
                    .fill(.regularMaterial)
                    .frame(width: diameter * 0.61, height: diameter * 0.61)
                    .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
                if let dominant = groups.first {
                    if isHovered {
                        Text(dominant.share.formatted(.percent.precision(.fractionLength(0))))
                            .font(.system(size: diameter * 0.18, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .transition(.opacity.combined(with: .scale(scale: 0.82)))
                    } else {
                        Image(systemName: groupSymbol(dominant.name))
                            .font(.system(size: diameter * 0.24, weight: .semibold))
                            .foregroundStyle(groupColor(dominant.name))
                            .transition(.opacity.combined(with: .scale(scale: 0.82)))
                    }
                }
            }
            .frame(width: diameter, height: diameter)
            .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
            .scaleEffect(isHovered && !reduceMotion ? 1.045 : 1)
        }
        .onAppear {
            if reduceMotion {
                reveal = 1
            } else {
                withAnimation(.smooth(duration: 0.52)) { reveal = 1 }
            }
        }
        .onHover { isHovered = $0 }
        .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: isHovered)
        .animation(reduceMotion ? nil : .smooth(duration: 0.38), value: context.groupShares)
        .help(breakdownText)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Landschaftsgruppen: \(breakdownText)")
    }

    private func segmentStart(
        _ index: Int,
        groups: [LandscapeContextGroupShare]
    ) -> CGFloat {
        groups.prefix(index).reduce(0) { $0 + CGFloat($1.share) }
    }

    private func groupColor(_ group: String) -> Color {
        switch group {
        case "Siedlung": Color(red: 0.70, green: 0.36, blue: 0.31)
        case "Landwirtschaft": Color(red: 0.76, green: 0.59, blue: 0.24)
        case "Wald": Color(red: 0.20, green: 0.43, blue: 0.28)
        case "Natur": Color(red: 0.24, green: 0.52, blue: 0.59)
        default: .secondary
        }
    }

    private func groupSymbol(_ group: String) -> String {
        switch group {
        case "Siedlung": "building.2.fill"
        case "Landwirtschaft": "leaf.fill"
        case "Wald": "tree.fill"
        case "Natur": "water.waves"
        default: "circle.hexagongrid.fill"
        }
    }

    private var breakdownText: String {
        context.groupShares.map {
            "\($0.name) \($0.share.formatted(.percent.precision(.fractionLength(0))))"
        }.joined(separator: ", ")
    }
}

private struct PinnedProbeMarker: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let probe: MapProbe
    let snapshot: ViewportSnapshot?
    let radiusMeters: Double
    let namedFeatures: [LandscapeContextFeature]
    let color: Color
    let onNamedFeature: (LandscapeContextFeature) -> Void

    var body: some View {
        GeometryReader { geometry in
            if let snapshot {
                let x = geometry.size.width / 2
                    + CGFloat((probe.worldX - snapshot.centerX) / snapshot.metersPerPoint)
                let y = geometry.size.height / 2
                    - CGFloat((probe.worldY - snapshot.centerY) / snapshot.metersPerPoint)
                let isVisible = x >= -20 && x <= geometry.size.width + 20
                    && y >= -20 && y <= geometry.size.height + 20
                if isVisible {
                    let diameter = CGFloat(radiusMeters * 2 / snapshot.metersPerPoint)
                    if diameter > 2, diameter < 6_000 {
                        Circle()
                            .fill(color.opacity(0.035))
                            .overlay {
                                Circle().stroke(
                                    color.opacity(0.55),
                                    style: StrokeStyle(lineWidth: 1.2, dash: [7, 5])
                                )
                            }
                            .frame(width: diameter, height: diameter)
                            .position(x: x, y: y)
                            .allowsHitTesting(false)
                    }

                    if !namedFeatures.isEmpty {
                        Path { path in
                            for feature in namedFeatures {
                                let point = screenPoint(
                                    feature, snapshot: snapshot, size: geometry.size
                                )
                                path.move(to: CGPoint(x: x, y: y))
                                path.addLine(to: point)
                            }
                        }
                        .stroke(
                            color.opacity(0.18),
                            style: StrokeStyle(lineWidth: 0.7, dash: [2, 4])
                        )
                        .allowsHitTesting(false)

                        ForEach(Array(namedFeatures.enumerated()), id: \.element.id) { index, feature in
                            let point = screenPoint(
                                feature, snapshot: snapshot, size: geometry.size
                            )
                            if point.x >= -16, point.x <= geometry.size.width + 16,
                               point.y >= -16, point.y <= geometry.size.height + 16
                            {
                                MapNamedFeatureMarker(
                                    feature: feature,
                                    number: index + 1,
                                    delay: Double(index) * 0.045,
                                    color: color,
                                    action: { onNamedFeature(feature) }
                                )
                                .position(point)
                                .zIndex(100 - Double(index))
                            }
                        }
                    }

                    ZStack {
                        Circle()
                            .fill(color.opacity(0.16))
                            .frame(width: 32, height: 32)
                        Circle()
                            .stroke(color.opacity(0.72), lineWidth: 1.5)
                            .frame(width: 22, height: 22)
                        Circle()
                            .fill(color)
                            .frame(width: 9, height: 9)
                            .overlay(Circle().stroke(.white.opacity(0.92), lineWidth: 1.2))
                            .shadow(color: .black.opacity(0.28), radius: 4, y: 2)
                    }
                    .animation(reduceMotion ? nil : .smooth(duration: 0.3), value: radiusMeters)
                    .position(x: x, y: y)
                    .allowsHitTesting(false)
                }
            }
        }
    }

    private func screenPoint(
        _ feature: LandscapeContextFeature,
        snapshot: ViewportSnapshot,
        size: CGSize
    ) -> CGPoint {
        CGPoint(
            x: size.width / 2
                + CGFloat((feature.worldX - snapshot.centerX) / snapshot.metersPerPoint),
            y: size.height / 2
                - CGFloat((feature.worldY - snapshot.centerY) / snapshot.metersPerPoint)
        )
    }
}

private struct MapNamedFeatureMarker: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let feature: LandscapeContextFeature
    let number: Int
    let delay: Double
    let color: Color
    let action: () -> Void
    @State private var isRevealed = false
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            Text(number.formatted())
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .foregroundStyle(color)
                .frame(width: 19, height: 19)
                .background(.regularMaterial, in: Circle())
                .overlay(Circle().stroke(color.opacity(isHovered ? 0.92 : 0.62), lineWidth: 1))
                .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
                .scaleEffect(isHovered && !reduceMotion ? 1.12 : 1)
        }
        .buttonStyle(AtlasPressButtonStyle(pressedScale: 0.88))
        .onHover { isHovered = $0 }
        .overlay {
            if isHovered {
                HStack(spacing: 6) {
                    Image(systemName: feature.symbolName)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(color)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(feature.name)
                            .font(.system(size: 9, weight: .semibold))
                            .lineLimit(1)
                        Text("\(feature.kindTitle) · \(feature.proximityText)")
                            .font(.system(size: 7.5).monospacedDigit())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, 8)
                .frame(width: 164, height: 38, alignment: .leading)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(color.opacity(0.24), lineWidth: 0.8)
                }
                .shadow(color: .black.opacity(0.18), radius: 8, y: 4)
                .offset(calloutOffset)
                .transition(.opacity.combined(with: .scale(scale: 0.92)))
                .allowsHitTesting(false)
            }
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.17), value: isHovered)
        .accessibilityLabel(
            "Fund \(number), \(feature.name), \(feature.kindTitle), \(feature.proximityText)"
        )
        .accessibilityHint("Zur Fundstelle fliegen")
        .accessibilityAddTraits(.isButton)
        .compositingGroup()
        .scaleEffect(isRevealed ? 1 : 0.45)
        .opacity(isRevealed ? 1 : 0)
        .onAppear {
            if reduceMotion {
                isRevealed = true
            } else {
                withAnimation(.spring(duration: 0.32, bounce: 0.22).delay(delay)) {
                    isRevealed = true
                }
            }
        }
    }

    private var calloutOffset: CGSize {
        let radians = feature.directionDegrees * .pi / 180
        return CGSize(
            width: sin(radians) * 92,
            height: -cos(radians) * 42
        )
    }
}

private struct PinnedProbePanel: View {
    let probe: MapProbe
    let thematicProduct: MapManifest.ThematicRaster?
    let baseSourceCount: Int
    let showsElevation: Bool
    let contentColor: Color?
    let classColors: [Color]
    let landscapeContext: LandscapeContext?
    let isReadingLandscapeContext: Bool
    let landscapeContextMessage: String?
    let landscapeContextRadius: Double
    let onLandscapeContextRadiusChange: (Double) -> Void
    let onNamedFeature: (LandscapeContextFeature) -> Void
    let onCenter: () -> Void
    let onBookmark: (String, String) -> Void
    let onClose: () -> Void
    @State private var copied = false
    @State private var saved = false
    @State private var showSaveForm = false
    @State private var draftName = ""
    @State private var draftNote = ""
    @State private var showLandscapeContext = true

    private var accent: Color { contentColor ?? .accentColor }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "mappin.and.ellipse")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(accent)
                    .frame(width: 30, height: 30)
                    .background(accent.opacity(0.12), in: Circle())
                VStack(alignment: .leading, spacing: 0) {
                    Text("Fundstelle")
                        .font(.headline)
                    Text("Festgehaltener Kartenpunkt")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 24, height: 24)
                        .background(.primary.opacity(0.07), in: Circle())
                }
                .buttonStyle(.plain)
                .help("Fundstelle lösen")
            }
            .padding(13)

            Divider().opacity(0.55)

            VStack(alignment: .leading, spacing: 12) {
                if let thematicProduct {
                    probeSection(
                        eyebrow: thematicProduct.name,
                        name: probe.thematic?.className ?? "Keine Fachklassifikation",
                        symbol: "fossil.shell.fill",
                        detail: probe.thematic?.qualitySummary
                    )
                    Divider().opacity(0.45)
                }

                probeSection(
                    eyebrow: "Landoberfläche",
                    name: probe.className ?? "Keine Kartendaten",
                    symbol: "leaf.fill",
                    detail: probe.classGroup
                )

                if showsElevation, let elevation = probe.elevation {
                    HStack(spacing: 8) {
                        probeMetric(
                            title: "Höhe",
                            value: "\(elevation.formatted()) m",
                            symbol: "mountain.2.fill"
                        )
                        if let terrainSummary = probe.terrainSummary {
                            probeMetric(
                                title: "Gelände",
                                value: terrainSummary,
                                symbol: "angle"
                            )
                        }
                    }
                }
                probeMetric(
                    title: "EPSG:3035",
                    value: probe.coordinateText,
                    symbol: "scope"
                )

                DisclosureGroup(isExpanded: $showLandscapeContext) {
                    landscapeContextSection
                        .padding(.top, 9)
                } label: {
                    HStack(spacing: 7) {
                        Image(systemName: "circle.dotted.and.circle")
                            .foregroundStyle(accent)
                        Text("Umgebung lesen")
                            .font(.caption.weight(.semibold))
                        Spacer()
                        Text(radiusText(landscapeContextRadius))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
                .tint(accent)
                .padding(9)
                .background(accent.opacity(0.055), in: RoundedRectangle(cornerRadius: 11))

                if baseSourceCount > 0 {
                    Label(
                        "\(baseSourceCount) dokumentierte Quellen bilden die Kartengrundlage",
                        systemImage: "checkmark.seal"
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 6) {
                    probeAction("Zentrieren", symbol: "scope", action: onCenter)
                    probeAction(saved ? "Gemerkt" : "Merken", symbol: saved ? "bookmark.fill" : "bookmark") {
                        guard !saved else { return }
                        if draftName.isEmpty { draftName = probe.discoveryTitle }
                        showLandscapeContext = false
                        showSaveForm.toggle()
                    }
                    probeAction(copied ? "Kopiert" : "Koordinate", symbol: copied ? "checkmark" : "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(probe.copyText, forType: .string)
                        copied = true
                    }
                }

                if showSaveForm, !saved {
                    VStack(alignment: .leading, spacing: 7) {
                        Text("Fundstelle sammeln")
                            .font(.caption.weight(.semibold))
                        TextField("Eigener Name", text: $draftName)
                            .textFieldStyle(.roundedBorder)
                        TextField("Notiz – was ist hier interessant?", text: $draftNote, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .lineLimit(2...4)
                        HStack {
                            Button("Abbrechen") { showSaveForm = false }
                                .buttonStyle(.borderless)
                            Spacer()
                            Button("In Sammlung") {
                                onBookmark(draftName, draftNote)
                                saved = true
                                showSaveForm = false
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            .disabled(draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                    }
                    .padding(9)
                    .background(accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
                    .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .padding(13)
        }
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.regularMaterial)
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [accent.opacity(0.14), .clear, .black.opacity(0.025)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [.white.opacity(0.65), accent.opacity(0.22), .black.opacity(0.11)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.8
                )
        }
        .shadow(color: .black.opacity(0.22), radius: 22, y: 10)
        .accessibilityElement(children: .contain)
    }

    private func probeSection(
        eyebrow: String,
        name: String,
        symbol: String,
        detail: String?
    ) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Circle()
                .fill(accent)
                .frame(width: 11, height: 11)
                .overlay(Circle().stroke(.white.opacity(0.72), lineWidth: 0.8))
                .padding(.top, 4)
            VStack(alignment: .leading, spacing: 2) {
                Label(eyebrow, systemImage: symbol)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(name)
                    .font(.system(size: 18, weight: .semibold, design: .rounded))
                    .lineLimit(2)
                if let detail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var landscapeContextSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            Picker(
                "Radius",
                selection: Binding(
                    get: { landscapeContextRadius },
                    set: onLandscapeContextRadiusChange
                )
            ) {
                Text("1 km").tag(1_000.0)
                Text("3 km").tag(3_000.0)
                Text("10 km").tag(10_000.0)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.mini)

            if isReadingLandscapeContext {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Landschaft wird gelesen …")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 7)
            } else if let landscapeContext {
                HStack(alignment: .top, spacing: 10) {
                    LandscapeCompositionOrb(context: landscapeContext)
                        .frame(width: 54, height: 54)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(landscapeContext.title)
                            .font(.subheadline.weight(.semibold))
                            .fixedSize(horizontal: false, vertical: true)
                        Text(landscapeContext.narrative)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Text(groupSummary(landscapeContext))
                            .font(.system(size: 8.5).monospacedDigit())
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)
                    }
                }

                ForEach(landscapeContext.classes.prefix(3)) { item in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(item.name).lineLimit(1)
                            Spacer()
                            Text(item.share.formatted(.percent.precision(.fractionLength(0))))
                                .monospacedDigit()
                        }
                        .font(.caption2.weight(.medium))
                        GeometryReader { geometry in
                            ZStack(alignment: .leading) {
                                Capsule().fill(.primary.opacity(0.07))
                                Capsule()
                                    .fill(classColor(item.classID))
                                    .frame(width: max(3, geometry.size.width * item.share))
                            }
                        }
                        .frame(height: 5)
                    }
                }

                if let features = landscapeContext.namedFeatures, !features.isEmpty {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack {
                            Label("Namen im Kreis", systemImage: "text.magnifyingglass")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text("anklicken zum Anfliegen")
                                .font(.system(size: 8))
                                .foregroundStyle(.tertiary)
                        }
                        ScrollView(.horizontal, showsIndicators: false) {
                            LazyHStack(spacing: 6) {
                                ForEach(Array(features.enumerated()), id: \.element.id) { index, feature in
                                    LandscapeNamedFeatureButton(
                                        feature: feature,
                                        number: index + 1,
                                        tint: accent,
                                        action: { onNamedFeature(feature) }
                                    )
                                }
                            }
                            .padding(.vertical, 2)
                        }
                        .scrollClipDisabled()
                        .frame(height: 51)
                    }
                }

                HStack(spacing: 7) {
                    contextMetric(
                        title: "Höhenraum",
                        value: elevationText(landscapeContext),
                        symbol: "mountain.2"
                    )
                    contextMetric(
                        title: "Relief",
                        value: slopeText(landscapeContext),
                        symbol: "angle"
                    )
                }

                HStack(spacing: 7) {
                    if let population = landscapeContext.population {
                        contextMetric(
                            title: "Bevölkerung",
                            value: populationText(population, context: landscapeContext),
                            symbol: "person.2"
                        )
                    }
                    contextMetric(
                        title: "Mosaik",
                        value: "\(landscapeContext.classes.count) Klassen",
                        symbol: "square.grid.3x3"
                    )
                }

                if let thematicName = landscapeContext.thematicProductName,
                   let dominant = landscapeContext.thematicClasses.first
                {
                    Label(
                        "\(thematicName): \(dominant.name) dominiert · "
                            + "\(landscapeContext.thematicClasses.count) Klassen",
                        systemImage: "fossil.shell"
                    )
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }

                Text(
                    "\(landscapeContext.sampleCount) Messpunkte · etwa "
                        + "\(Int(landscapeContext.sampledResolution.rounded()).formatted()) m Abstand"
                )
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                if let populationSource = landscapeContext.populationSource {
                    Text("Bevölkerung: \(populationSource)")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            } else if let landscapeContextMessage {
                Label(landscapeContextMessage, systemImage: "exclamationmark.triangle")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func contextMetric(title: String, value: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Label(title, systemImage: symbol)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption2.monospacedDigit().weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .padding(7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }

    private func classColor(_ classID: Int) -> Color {
        classColors.indices.contains(classID) ? classColors[classID] : accent
    }

    private func elevationText(_ context: LandscapeContext) -> String {
        guard let minimum = context.minimumElevation, let maximum = context.maximumElevation else {
            return "–"
        }
        return "\(minimum.formatted())–\(maximum.formatted()) m"
    }

    private func slopeText(_ context: LandscapeContext) -> String {
        guard let mean = context.meanSlopeDegrees, let maximum = context.maximumSlopeDegrees else {
            return "–"
        }
        return "Ø \(mean.formatted(.number.precision(.fractionLength(1))))° · max "
            + "\(maximum.formatted(.number.precision(.fractionLength(1))))°"
    }

    private func populationText(_ population: Int, context: LandscapeContext) -> String {
        let count = population.formatted(.number.notation(.compactName))
        guard let density = context.populationDensity else { return count }
        return "\(count) · \(Int(density.rounded()).formatted())/km²"
    }

    private func groupSummary(_ context: LandscapeContext) -> String {
        context.groupShares.prefix(4).map {
            "\($0.name) \($0.share.formatted(.percent.precision(.fractionLength(0))))"
        }.joined(separator: " · ")
    }

    private func radiusText(_ radius: Double) -> String {
        radius >= 1_000
            ? "\((radius / 1_000).formatted(.number.precision(.fractionLength(0)))) km"
            : "\(Int(radius.rounded()).formatted()) m"
    }

    private func probeMetric(title: String, value: String, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(title, systemImage: symbol)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.monospacedDigit().weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 9))
    }

    private func probeAction(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 9, weight: .semibold))
                .lineLimit(1)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
    }
}

private struct LandscapeNamedFeatureButton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let feature: LandscapeContextFeature
    let number: Int
    let tint: Color
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: feature.symbolName)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 25, height: 25)
                    .background(tint.opacity(0.10), in: Circle())
                    .scaleEffect(isHovered && !reduceMotion ? 1.08 : 1)
                    .overlay(alignment: .topTrailing) {
                        Text(number.formatted())
                            .font(.system(size: 6, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                            .frame(width: 11, height: 11)
                            .background(tint, in: Circle())
                            .offset(x: 3, y: -3)
                    }
                VStack(alignment: .leading, spacing: 1) {
                    Text(feature.name)
                        .font(.system(size: 9, weight: .semibold))
                        .lineLimit(1)
                    Text(feature.proximityText)
                        .font(.system(size: 8).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Image(systemName: "location.north.fill")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(tint.opacity(0.70))
                    .rotationEffect(.degrees(feature.directionDegrees))
            }
            .padding(.horizontal, 7)
            .frame(width: 144, height: 45, alignment: .leading)
            .background(
                isHovered ? tint.opacity(0.09) : Color.primary.opacity(0.035),
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(tint.opacity(isHovered ? 0.24 : 0.10), lineWidth: 0.7)
            }
        }
        .buttonStyle(AtlasPressButtonStyle(pressedScale: 0.97))
        .atlasHoverGlow(tint: tint, cornerRadius: 9, lift: 0.75)
        .onHover { isHovered = $0 }
        .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: isHovered)
        .help("\(feature.kindTitle) anfliegen")
        .accessibilityLabel(
            "Fund \(number), \(feature.name), \(feature.kindTitle), "
                + "\(feature.proximityText), anfliegen"
        )
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
                Label(terrainLine(elevation), systemImage: "mountain.2.fill")
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

    private func terrainLine(_ elevation: Int) -> String {
        guard let terrainSummary = probe.terrainSummary else {
            return "\(elevation.formatted()) m Höhe"
        }
        return "\(elevation.formatted()) m · \(terrainSummary)"
    }

    private var accessibilitySummary: String {
        var parts = [title, className]
        if let quality = probe.thematic?.qualitySummary, thematicProduct != nil {
            parts.append(quality)
        }
        if showsElevation, let elevation = probe.elevation { parts.append("\(elevation) Meter Höhe") }
        if let terrainSummary = probe.terrainSummary { parts.append(terrainSummary) }
        return parts.joined(separator: ", ")
    }
}

private struct AtlasContextDrawer<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let title: String
    let subtitle: String
    let symbol: String
    let tint: Color
    let onClose: () -> Void
    let content: Content

    init(
        title: String,
        subtitle: String,
        symbol: String,
        tint: Color,
        onClose: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.symbol = symbol
        self.tint = tint
        self.onClose = onClose
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(tint.opacity(0.13))
                    Image(systemName: symbol)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(tint)
                        .contentTransition(.symbolEffect(.replace))
                }
                .frame(width: 32, height: 32)

                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(.headline)
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 24, height: 24)
                        .background(.primary.opacity(0.07), in: Circle())
                }
                .buttonStyle(AtlasPressButtonStyle(pressedScale: 0.88))
                .atlasHoverGlow(tint: tint, cornerRadius: 12, lift: 1)
                .help("Schließen")
            }
            .padding(14)

            Divider().opacity(0.55)

            ScrollView {
                content
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [.white.opacity(0.55), .white.opacity(0.10), .black.opacity(0.10)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.8
                )
        }
        .shadow(color: .black.opacity(0.22), radius: 22, y: 10)
        .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: symbol)
    }
}

private struct AtlasInspectorPanel<Content: View>: View {
    let title: String
    let symbol: String
    let content: Content

    init(
        title: String,
        symbol: String,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.symbol = symbol
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            content
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.primary.opacity(0.038), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct AtlasCompactStackRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let title: String
    let detail: String
    let symbol: String
    let tint: Color
    @Binding var isOn: Bool
    let isSelected: Bool
    let action: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 5) {
            Button(action: action) {
                HStack(spacing: 9) {
                    Image(systemName: symbol)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(isOn ? tint : .secondary)
                        .frame(width: 28, height: 28)
                        .background(tint.opacity(isOn ? 0.11 : 0.04), in: RoundedRectangle(cornerRadius: 8))
                        .scaleEffect(isHovered && !reduceMotion ? 1.045 : 1)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(title)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(1)
                        Text(detail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 2)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.tertiary)
                        .offset(x: isHovered && !reduceMotion ? 2 : 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(AtlasPressButtonStyle(pressedScale: 0.985))

            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(
            isSelected ? Color.accentColor.opacity(0.09) : Color.primary.opacity(0.025),
            in: RoundedRectangle(cornerRadius: 10)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(isSelected ? Color.accentColor.opacity(0.18) : .primary.opacity(0.045), lineWidth: 0.7)
        }
        .atlasHoverGlow(tint: tint, cornerRadius: 10, lift: 1)
        .onHover { isHovered = $0 }
        .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: isHovered)
        .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: isSelected)
    }
}

private struct AtlasDiscoveryCard: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let reference: MapReference
    let isSelected: Bool
    @State private var isHovered = false

    private var tint: Color { RGBAColor(hex: reference.accentHex).color }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: reference.symbolName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(tint)
                    .frame(width: 30, height: 30)
                    .background(tint.opacity(0.13), in: Circle())
                    .scaleEffect(isHovered && !reduceMotion ? 1.07 : 1)
                Spacer()
                Image(systemName: isSelected ? "location.fill" : "arrow.up.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(isSelected ? tint : Color.secondary.opacity(0.55))
                    .offset(
                        x: isHovered && !isSelected && !reduceMotion ? 2 : 0,
                        y: isHovered && !isSelected && !reduceMotion ? -2 : 0
                    )
            }

            Spacer(minLength: 10)

            Text(reference.name)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            Text(reference.subtitle)
                .font(.system(size: 9))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
        .padding(10)
        .frame(width: 132, height: 94, alignment: .leading)
        .background(
            LinearGradient(
                colors: [tint.opacity(isSelected ? 0.20 : 0.10), .primary.opacity(0.025)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 13, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(isSelected ? tint.opacity(0.46) : .primary.opacity(0.07), lineWidth: isSelected ? 1.1 : 0.7)
        }
        .contentShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .atlasHoverGlow(tint: tint, cornerRadius: 13, lift: 2)
        .onHover { isHovered = $0 }
        .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: isHovered)
        .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: isSelected)
    }
}

private struct AtlasSourceRow: View {
    let title: String
    let detail: String
    let license: String
    let url: String

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: "database.fill")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.green)
                .frame(width: 24, height: 24)
                .background(.green.opacity(0.09), in: RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 1) {
                if let destination = URL(string: url) {
                    Link(destination: destination) {
                        HStack(spacing: 4) {
                            Text(title)
                                .lineLimit(2)
                            Image(systemName: "arrow.up.right")
                                .font(.system(size: 8, weight: .bold))
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.caption.weight(.semibold))
                } else {
                    Text(title).font(.caption.weight(.semibold))
                }
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Text(license)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

private struct CatalogDatasetRow: View {
    let entry: MapManifest.DataCatalogEntry
    let tint: Color
    let isActive: Bool
    let actionTitle: String
    let action: () -> Void

    private var metadata: String {
        var parts: [String] = []
        if let year = entry.year { parts.append(String(year)) }
        if let scale = entry.scale { parts.append("1:\(scale.formatted())") }
        parts.append(entry.license)
        return parts.joined(separator: " · ")
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: entry.category.symbolName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(tint.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 4) {
                if let productName = entry.productName {
                    Text(productName.uppercased())
                        .font(.system(size: 8, weight: .bold))
                        .tracking(0.55)
                        .foregroundStyle(tint)
                        .lineLimit(1)
                }
                Text(entry.name)
                    .font(.caption.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(entry.role)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(metadata)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 6) {
                    if let destination = URL(string: entry.url) {
                        Link(destination: destination) {
                            Label("Quelle", systemImage: "arrow.up.right")
                                .font(.system(size: 9, weight: .semibold))
                        }
                        .buttonStyle(.borderless)
                    }
                    Spacer()
                    Button(action: action) {
                        Label(
                            actionTitle,
                            systemImage: isActive ? "checkmark.circle.fill" : "eye.fill"
                        )
                        .font(.system(size: 9, weight: .semibold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                    .tint(isActive ? .green : tint)
                    .disabled(isActive && entry.activation != .surface)
                }
                .padding(.top, 2)
            }
        }
    }
}

private struct AtlasStackButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let isSelected: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.primary)
            .background(
                isSelected
                    ? Color.accentColor.opacity(configuration.isPressed ? 0.15 : 0.09)
                    : Color.primary.opacity(configuration.isPressed ? 0.065 : 0.035),
                in: RoundedRectangle(cornerRadius: 13)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 13)
                    .stroke(isSelected ? Color.accentColor.opacity(0.20) : .primary.opacity(0.055), lineWidth: 0.7)
            }
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .animation(reduceMotion ? nil : .snappy(duration: 0.14), value: configuration.isPressed)
    }
}

private struct AtlasPressButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let pressedScale: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? pressedScale : 1)
            .opacity(configuration.isPressed ? 0.78 : 1)
            .animation(reduceMotion ? nil : .snappy(duration: 0.14), value: configuration.isPressed)
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

private enum AtlasPaletteAction: String, CaseIterable, Identifiable {
    case search
    case fitGermany
    case dataCatalog
    case collection
    case areaAnalysis
    case landscapeProfile
    case appearance

    var id: String { rawValue }

    var title: String {
        switch self {
        case .search: "Ort oder Koordinate suchen"
        case .fitGermany: "Deutschland einpassen"
        case .dataCatalog: "Datenatlas öffnen"
        case .collection: "Sammlung öffnen"
        case .areaAnalysis: "Fläche untersuchen"
        case .landscapeProfile: "Landschaftsprofil ziehen"
        case .appearance: "Kartenbild gestalten"
        }
    }

    var detail: String {
        switch self {
        case .search: "Ortsnamen und EPSG:3035-Koordinaten"
        case .fitGermany: "Zur ruhigen Gesamtansicht zurückkehren"
        case .dataCatalog: "Quellen, Lizenzen und Kartenwirkung"
        case .collection: "Fundstellen ansehen und vergleichen"
        case .areaAnalysis: "Rechteck aufziehen und Landschaft zählen"
        case .landscapeProfile: "Höhe und Landklassen entlang einer Linie"
        case .appearance: "Relief, Farben, Vergleich und Export"
        }
    }

    var symbol: String {
        switch self {
        case .search: "magnifyingglass"
        case .fitGermany: "scope"
        case .dataCatalog: "books.vertical.fill"
        case .collection: "rectangle.stack.fill"
        case .areaAnalysis: "rectangle.dashed"
        case .landscapeProfile: "chart.xyaxis.line"
        case .appearance: "paintpalette.fill"
        }
    }

    var tint: Color {
        switch self {
        case .search, .fitGermany, .dataCatalog: .green
        case .collection: .teal
        case .areaAnalysis: .cyan
        case .landscapeProfile: .indigo
        case .appearance: .purple
        }
    }
}

private struct AtlasPaletteSectionTitle: View {
    let title: String
    let count: Int

    var body: some View {
        HStack {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .bold))
                .tracking(0.75)
            Spacer()
            Text("\(count)")
                .monospacedDigit()
        }
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 8)
        .padding(.top, 9)
        .padding(.bottom, 3)
    }
}

private struct AtlasPaletteRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let title: String
    let detail: String
    let symbol: String
    let tint: Color
    var trailing: String? = nil
    let isSelected: Bool
    let onHoverSelection: () -> Void
    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 30, height: 30)
                .background(tint.opacity(0.11), in: RoundedRectangle(cornerRadius: 8))
                .scaleEffect(isHovered && !reduceMotion ? 1.045 : 1)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            if let trailing {
                Text(trailing)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .frame(maxWidth: 115, alignment: .trailing)
            }
            Image(systemName: "arrow.up.right")
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(isSelected ? tint : Color.secondary.opacity(0.55))
                .offset(
                    x: isHovered && !reduceMotion ? 2 : 0,
                    y: isHovered && !reduceMotion ? -2 : 0
                )
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 9)
        .padding(.vertical, 7)
        .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        .background(
            isSelected ? tint.opacity(0.10) : Color.primary.opacity(isHovered ? 0.045 : 0.018),
            in: RoundedRectangle(cornerRadius: 11)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(isSelected ? tint.opacity(0.25) : Color.clear, lineWidth: 0.8)
        }
        .atlasHoverGlow(tint: tint, cornerRadius: 11, lift: 0.75)
        .onHover {
            isHovered = $0
            if $0 { onHoverSelection() }
        }
        .animation(reduceMotion ? nil : .snappy(duration: 0.17), value: isHovered)
        .animation(reduceMotion ? nil : .snappy(duration: 0.17), value: isSelected)
    }
}

private struct MapChromeButton: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let symbol: String
    let help: String
    let isActive: Bool
    let tint: Color
    let action: () -> Void
    @State private var isHovered = false

    init(
        symbol: String,
        help: String,
        isActive: Bool = false,
        tint: Color = .accentColor,
        action: @escaping () -> Void
    ) {
        self.symbol = symbol
        self.help = help
        self.isActive = isActive
        self.tint = tint
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(isActive ? tint : Color.primary)
                .frame(width: 18, height: 18)
                .padding(7)
                .contentShape(Rectangle())
                .scaleEffect(isHovered && !reduceMotion ? 1.08 : 1)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(AtlasPressButtonStyle(pressedScale: 0.9))
        .background(
            isActive ? tint.opacity(0.13) : Color.clear,
            in: RoundedRectangle(cornerRadius: 11, style: .continuous)
        )
        .atlasGlass(cornerRadius: 11)
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(isActive ? tint.opacity(0.46) : Color.clear, lineWidth: 1)
        }
        .atlasHoverGlow(tint: tint, cornerRadius: 11, lift: 1.5)
        .onHover { isHovered = $0 }
        .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: isHovered)
        .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: isActive)
        .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: symbol)
        .accessibilityValue(isActive ? "Aktiv" : "")
        .help(help)
    }
}

private struct MapStatusPill: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let status: String
    let snapshot: ViewportSnapshot?
    @State private var isHovered = false

    private var parts: [String] {
        status.components(separatedBy: " · ")
    }

    private var zoom: String { parts.first ?? "Karte" }
    private var resolution: String { parts.count > 1 ? parts[1] : status }

    private var visibleExtent: String? {
        guard let width = snapshot?.visibleWidthMeters else { return nil }
        if width >= 10_000 {
            return "\((width / 1_000).formatted(.number.precision(.fractionLength(0)))) km breit"
        }
        if width >= 1_000 {
            return "\((width / 1_000).formatted(.number.precision(.fractionLength(1)))) km breit"
        }
        return "\(width.formatted(.number.precision(.fractionLength(0)))) m breit"
    }

    private var pendingCount: Int {
        guard let loading = parts.last, loading.hasSuffix(" lädt") else { return 0 }
        return Int(loading.split(separator: " ").first ?? "0") ?? 0
    }

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "viewfinder")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.green)

            Text(resolution)
                .font(.caption.monospacedDigit().weight(.medium))

            if pendingCount > 0 {
                Circle()
                    .fill(.orange)
                    .frame(width: 5, height: 5)
                Text("\(pendingCount) lädt")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }

            if isHovered {
                Capsule()
                    .fill(.primary.opacity(0.13))
                    .frame(width: 1, height: 13)
                    .transition(.scale.combined(with: .opacity))
                Text([zoom, visibleExtent].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .fixedSize(horizontal: true, vertical: false)
        .atlasGlass(cornerRadius: 10)
        .atlasHoverGlow(tint: .green, cornerRadius: 10, lift: 1)
        .onHover { isHovered = $0 }
        .animation(reduceMotion ? nil : .snappy(duration: 0.22), value: isHovered)
        .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: pendingCount > 0)
        .help("Kartentechnik · \(status)")
        .accessibilityLabel("Kartenauflösung \(resolution), \(visibleExtent ?? zoom)")
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

    func atlasHoverGlow(
        tint: Color,
        cornerRadius: CGFloat,
        lift: CGFloat = 1
    ) -> some View {
        modifier(AtlasHoverGlowModifier(tint: tint, cornerRadius: cornerRadius, lift: lift))
    }
}

private struct AtlasHoverGlowModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let tint: Color
    let cornerRadius: CGFloat
    let lift: CGFloat
    @State private var hoverLocation: CGPoint?
    @State private var isHovered = false

    func body(content: Content) -> some View {
        content
            .overlay {
                GeometryReader { geometry in
                    if let hoverLocation {
                        let width = max(geometry.size.width, 1)
                        let height = max(geometry.size.height, 1)
                        RadialGradient(
                            colors: [tint.opacity(0.16), tint.opacity(0)],
                            center: UnitPoint(
                                x: min(max(hoverLocation.x / width, 0), 1),
                                y: min(max(hoverLocation.y / height, 0), 1)
                            ),
                            startRadius: 0,
                            endRadius: max(width, height) * 0.72
                        )
                        .clipShape(
                            RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        )
                        .allowsHitTesting(false)
                        .transition(.opacity)
                    }
                }
            }
            .offset(y: isHovered && !reduceMotion ? -lift : 0)
            .shadow(
                color: tint.opacity(isHovered ? 0.10 : 0),
                radius: isHovered ? 10 : 0,
                y: isHovered ? 4 : 0
            )
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    hoverLocation = location
                    isHovered = true
                case .ended:
                    hoverLocation = nil
                    isHovered = false
                }
            }
            .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: isHovered)
    }
}
