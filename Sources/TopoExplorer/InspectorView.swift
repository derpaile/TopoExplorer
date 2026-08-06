import SwiftUI

struct InspectorView: View {
    let manifest: MapManifest
    @ObservedObject var style: StyleSettings
    @ObservedObject var session: MapSession
    @ObservedObject var layers: LayerSettings
    @ObservedObject var comparison: ComparisonSettings
    @ObservedObject var export: MapExportController
    @ObservedObject var viewport: ViewportController
    let onClose: () -> Void
    @State private var newStyleName = ""
    @State private var showAdvancedRelief = false
    @State private var showStyleManagement = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(Color.green.opacity(0.12))
                    Image(systemName: "slider.horizontal.3")
                        .foregroundStyle(Color(red: 0.18, green: 0.48, blue: 0.34))
                }
                .frame(width: 30, height: 30)

                VStack(alignment: .leading, spacing: 0) {
                    Text("Kartendarstellung")
                        .font(.headline)
                    Text(style.activeStyleName)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .bold))
                        .frame(width: 24, height: 24)
                        .background(Color.primary.opacity(0.07), in: Circle())
                }
                .buttonStyle(.plain)
                .help("Schließen")
            }
            .padding(14)

            Divider().opacity(0.55)

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    presetControls
                    paletteControls
                    reliefControls
                    exportControls
                    styleManagement
                    dataDetails
                }
                .padding(14)
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
        .alert("Kartenstil", isPresented: errorIsPresented) {
            Button("OK") { style.errorMessage = nil }
        } message: {
            Text(style.errorMessage ?? "Unbekannter Fehler")
        }
    }

    private var presetControls: some View {
        panelSection(title: "Stimmung", symbol: "circle.lefthalf.filled") {
            VStack(spacing: 6) {
                ForEach(StyleSettings.presets) { preset in
                    Button {
                        style.apply(preset)
                    } label: {
                        HStack(spacing: 9) {
                            HStack(spacing: -3) {
                                ForEach(StyleSettings.previewColorIndices, id: \.self) { index in
                                    Circle()
                                        .fill(preset.colors[index].color)
                                        .frame(width: 13, height: 13)
                                        .overlay(Circle().stroke(.white.opacity(0.55), lineWidth: 0.5))
                                }
                            }
                            VStack(alignment: .leading, spacing: 1) {
                                Text(preset.name)
                                    .font(.subheadline.weight(.medium))
                                Text(StyleSettings.description(for: preset))
                                    .font(.system(size: 9))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            Spacer()
                            if style.activeStyleName == preset.name {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundStyle(Color.accentColor)
                            }
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 7)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .background(
                        style.activeStyleName == preset.name
                            ? Color.accentColor.opacity(0.09)
                            : Color.primary.opacity(0.035),
                        in: RoundedRectangle(cornerRadius: 9)
                    )
                }

                Button {
                    style.resetToStandard()
                } label: {
                    Label("Erststart-Standard wiederherstellen", systemImage: "arrow.counterclockwise")
                        .font(.caption.weight(.medium))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
    }

    private var paletteControls: some View {
        panelSection(title: "Legende und Farben", symbol: "paintpalette.fill") {
            VStack(alignment: .leading, spacing: 8) {
                Text("Alle Oberflächen sind einzeln färbbar und nach Thema geordnet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(paletteGroups, id: \.name) { group in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(group.name)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        LazyVGrid(
                            columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 3),
                            spacing: 8
                        ) {
                            ForEach(group.classes) { landClass in
                                VStack(spacing: 4) {
                                    ColorPicker(
                                        landClass.name,
                                        selection: style.colorBinding(at: landClass.id),
                                        supportsOpacity: false
                                    )
                                    .labelsHidden()
                                    .frame(width: 28, height: 24)
                                    .help(landClass.name)

                                    Text(landClass.name)
                                        .font(.system(size: 9))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.center)
                                        .frame(maxWidth: .infinity, minHeight: 22)
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    private var reliefControls: some View {
        panelSection(title: "Relief", symbol: "mountain.2.fill") {
            VStack(alignment: .leading, spacing: 10) {
                Toggle("Gelände plastisch darstellen", isOn: $style.reliefEnabled)

                valueSlider(
                    "Stärke", value: $style.reliefOpacity,
                    range: 0...1, format: "%.0f %%", multiplier: 100
                )
                .disabled(!style.reliefEnabled)

                DisclosureGroup("Feinabstimmung", isExpanded: $showAdvancedRelief) {
                    VStack(spacing: 10) {
                        valueSlider("Überhöhung", value: $style.reliefExaggeration, range: 0...120, format: "%.0f×")
                        valueSlider("Kontrast", value: $style.reliefContrast, range: 0.5...5, format: "%.1f")
                        valueSlider(
                            "Grundlicht", value: $style.ambientLight,
                            range: 0...0.35, format: "%.0f %%", multiplier: 100
                        )
                        valueSlider(
                            "Sonne · \(compassDirection)", value: $style.sunAzimuthDegrees,
                            range: 0...360, format: "%.0f°"
                        )
                    }
                    .padding(.top, 8)
                }
                .font(.subheadline)
                .disabled(!style.reliefEnabled)
            }
        }
    }

    private var exportControls: some View {
        panelSection(title: "Karte teilen", symbol: "square.and.arrow.up") {
            VStack(alignment: .leading, spacing: 9) {
                Picker("Auflösung", selection: $export.scale) {
                    Text("1×").tag(1)
                    Text("2×").tag(2)
                    Text("4×").tag(4)
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                Toggle("Maßstab einzeichnen", isOn: $export.includeScaleBar)

                Button {
                    export.chooseDestination(
                        style: style,
                        layers: layers,
                        snapshot: viewport.snapshot,
                        labels: viewport.labels,
                        comparison: comparison,
                        sources: manifest.sources ?? []
                    )
                } label: {
                    Label("Sichtbaren Ausschnitt exportieren", systemImage: "photo")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewport.snapshot == nil)

                if let message = export.message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var styleManagement: some View {
        DisclosureGroup("Eigene Stile", isExpanded: $showStyleManagement) {
            VStack(alignment: .leading, spacing: 9) {
                if !style.customStyles.isEmpty {
                    ForEach(style.customStyles) { savedStyle in
                        HStack {
                            Button(savedStyle.name) { style.apply(savedStyle) }
                                .buttonStyle(.plain)
                                .lineLimit(1)
                            Spacer()
                            Button {
                                style.deleteCustomStyle(id: savedStyle.id)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                            .help("Stil löschen")
                        }
                        .font(.caption)
                    }
                }

                HStack(spacing: 6) {
                    TextField("Name", text: $newStyleName)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { saveCurrentStyle() }
                    Button("Sichern") { saveCurrentStyle() }
                        .disabled(newStyleName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                HStack(spacing: 6) {
                    Button("Importieren …") { style.importWithPanel() }
                    Button("Exportieren …") { style.exportWithPanel() }
                    Spacer()
                    Button("Auf Standard") { style.resetToStandard() }
                }
                .controlSize(.small)
            }
            .padding(.top, 9)
        }
        .font(.subheadline.weight(.medium))
    }

    private var dataDetails: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Kartengrundlage", systemImage: "externaldrive")
                .font(.caption.weight(.semibold))
            Text("\(manifest.levels.count) Zoomstufen · feinste Auflösung \(Int(manifest.levels.last?.resolution ?? 0)) m")
            if let sources = manifest.sources {
                ForEach(sources) { source in
                    Text("\(source.name) \(source.year) · \(source.role) · \(source.license)")
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else {
                Text("Historische Landbedeckung 2015/2020")
            }
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .padding(.top, 2)
    }

    private func panelSection<Content: View>(
        title: String,
        symbol: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.semibold))
            content()
        }
        .padding(11)
        .background(Color.primary.opacity(0.038), in: RoundedRectangle(cornerRadius: 12))
    }

    private var compassDirection: String {
        let names = ["N", "NO", "O", "SO", "S", "SW", "W", "NW"]
        let index = Int((style.sunAzimuthDegrees + 22.5).truncatingRemainder(dividingBy: 360) / 45)
        return names[min(max(index, 0), names.count - 1)]
    }

    private var paletteGroups: [(name: String, classes: [MapManifest.LandClass])] {
        let order = ["Grundlage", "Siedlung", "Natur", "Landwirtschaft", "Wald"]
        let grouped = Dictionary(grouping: manifest.classes) { $0.group ?? "Oberflächen" }
        let known = order.compactMap { name in
            grouped[name].map { (name: name, classes: $0) }
        }
        let remaining = grouped.keys.filter { !order.contains($0) }.sorted().map {
            (name: $0, classes: grouped[$0] ?? [])
        }
        return known + remaining
    }

    private var errorIsPresented: Binding<Bool> {
        Binding(
            get: { style.errorMessage != nil },
            set: { if !$0 { style.errorMessage = nil } }
        )
    }

    private func saveCurrentStyle() {
        let name = newStyleName.trimmingCharacters(in: .whitespacesAndNewlines)
        style.saveCurrent(named: name)
        if style.errorMessage == nil { newStyleName = "" }
    }

    private func valueSlider(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        format: String,
        multiplier: Double = 1
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title)
                    .font(.caption)
                Spacer()
                Text(String(format: format, value.wrappedValue * multiplier))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range)
        }
    }
}
