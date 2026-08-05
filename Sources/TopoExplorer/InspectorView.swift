import SwiftUI

struct InspectorView: View {
    let manifest: MapManifest
    @ObservedObject var style: StyleSettings
    @ObservedObject var session: MapSession
    @ObservedObject var layers: LayerSettings
    @ObservedObject var comparison: ComparisonSettings
    @ObservedObject var export: MapExportController
    @ObservedObject var viewport: ViewportController
    @State private var newStyleName = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                styleManagement

                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    Text("Farben")
                        .font(.title3.weight(.semibold))
                    ForEach(Array(manifest.classes.enumerated()), id: \.element.id) { index, landClass in
                        ColorPicker(
                            landClass.name,
                            selection: style.colorBinding(at: index),
                            supportsOpacity: false
                        )
                    }
                }

                Divider()

                reliefControls

                Divider()

                layerControls

                if manifest.hasLandcover2020 {
                    Divider()
                    comparisonControls
                }

                Divider()

                exportControls

                Divider()

                Button("Originalwerte wiederherstellen") { style.resetAll() }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Kartendaten")
                        .font(.headline)
                    Text("\(manifest.levels.count) Zoomstufen · feinste Auflösung \(Int(manifest.levels.last?.resolution ?? 0)) m")
                    Text(session.dataDirectory?.path ?? "")
                        .lineLimit(3)
                        .textSelection(.enabled)
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(16)
        }
        .frame(minWidth: 300, idealWidth: 330, maxWidth: 380)
        .background(.regularMaterial)
        .alert("Kartenstil", isPresented: errorIsPresented) {
            Button("OK") { style.errorMessage = nil }
        } message: {
            Text(style.errorMessage ?? "Unbekannter Fehler")
        }
    }

    private var exportControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Export")
                .font(.title3.weight(.semibold))
            Picker("Größe", selection: $export.scale) {
                Text("Bildschirm").tag(1)
                Text("2×").tag(2)
                Text("4×").tag(4)
            }
            .pickerStyle(.segmented)
            Toggle("Maßstab einzeichnen", isOn: $export.includeScaleBar)
            Button("Sichtbaren Ausschnitt als PNG …") {
                export.chooseDestination(
                    style: style, layers: layers, snapshot: viewport.snapshot,
                    labels: viewport.labels, comparison: comparison
                )
            }
            if let message = export.message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            Text("2015-Daten: CC BY-NC 4.0; Exporte mit 2015-Landbedeckung sind nicht für kommerzielle Nutzung freigegeben.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    private var layerControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ebenen")
                .font(.title3.weight(.semibold))
            Toggle("Straßen", isOn: $layers.roads)
            Toggle("Eisenbahnen", isOn: $layers.railways)
            Toggle("Flüsse", isOn: $layers.waterways)
            Toggle("Grenzen", isOn: $layers.boundaries)
            Toggle("Orte und Namen", isOn: $layers.places)
        }
    }

    private var comparisonControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Landbedeckung")
                .font(.title3.weight(.semibold))
            Picker("Ansicht", selection: $comparison.mode) {
                ForEach(LandcoverMode.allCases) { mode in Text(mode.title).tag(mode) }
            }
            .pickerStyle(.segmented)
            if comparison.mode == .comparison {
                valueSlider(
                    "Trennlinie", value: $comparison.splitPosition,
                    range: 0.1...0.9, format: "%.0f %%", multiplier: 100
                )
                Text("Links 2015 · rechts 2020")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var styleManagement: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Kartenstil")
                    .font(.title2.weight(.semibold))
                Text(style.activeStyleName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Menu("Stil auswählen") {
                Section("Mitgeliefert") {
                    ForEach(StyleSettings.presets) { preset in
                        Button(preset.name) { style.apply(preset) }
                    }
                }
                if !style.customStyles.isEmpty {
                    Section("Eigene Stile") {
                        ForEach(style.customStyles) { savedStyle in
                            Button(savedStyle.name) { style.apply(savedStyle) }
                        }
                    }
                }
            }
            .menuStyle(.borderlessButton)

            HStack(spacing: 6) {
                TextField("Name für eigenen Stil", text: $newStyleName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { saveCurrentStyle() }
                Button("Speichern") { saveCurrentStyle() }
                    .disabled(newStyleName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if !style.customStyles.isEmpty {
                VStack(spacing: 4) {
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
                    }
                }
                .font(.caption)
            }

            HStack(spacing: 8) {
                Button("Importieren …") { style.importWithPanel() }
                Button("Exportieren …") { style.exportWithPanel() }
            }
            .controlSize(.small)
        }
    }

    private var reliefControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("Relief anzeigen", isOn: $style.reliefEnabled)
                .font(.title3.weight(.semibold))

            Group {
                valueSlider("Stärke", value: $style.reliefOpacity, range: 0...1, format: "%.0f %%", multiplier: 100)
                valueSlider("Überhöhung", value: $style.reliefExaggeration, range: 0...120, format: "%.0f×")
                valueSlider("Kontrast", value: $style.reliefContrast, range: 0.5...5, format: "%.1f")
                valueSlider("Grundlicht", value: $style.ambientLight, range: 0...0.35, format: "%.0f %%", multiplier: 100)
                valueSlider("Sonnenrichtung \(compassDirection)", value: $style.sunAzimuthDegrees, range: 0...360, format: "%.0f°")
            }
            .disabled(!style.reliefEnabled)
        }
    }

    private var compassDirection: String {
        let names = ["N", "NO", "O", "SO", "S", "SW", "W", "NW"]
        let index = Int((style.sunAzimuthDegrees + 22.5).truncatingRemainder(dividingBy: 360) / 45)
        return names[min(max(index, 0), names.count - 1)]
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
        if style.errorMessage == nil {
            newStyleName = ""
        }
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
                Spacer()
                Text(String(format: format, value.wrappedValue * multiplier))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Slider(value: value, in: range)
        }
    }
}
