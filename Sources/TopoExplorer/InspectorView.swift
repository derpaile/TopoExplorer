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
    @State private var showStyleManagement = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(Color.green.opacity(0.12))
                    Image(systemName: "paintpalette")
                        .foregroundStyle(Color(red: 0.18, green: 0.48, blue: 0.34))
                }
                .frame(width: 30, height: 30)

                VStack(alignment: .leading, spacing: 0) {
                    Text("Stile & Export")
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

}
