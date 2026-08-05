import SwiftUI

struct InspectorView: View {
    let manifest: MapManifest
    @ObservedObject var style: StyleSettings
    @ObservedObject var session: MapSession

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Farben")
                        .font(.title2.weight(.semibold))
                    Text("Ein Preset setzt Farben und Relief vollständig.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 6) {
                    ForEach(StyleSettings.presets) { preset in
                        Button(preset.name) { style.apply(preset) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }

                VStack(spacing: 8) {
                    ForEach(Array(manifest.classes.enumerated()), id: \.element.id) { index, landClass in
                        ColorPicker(
                            landClass.name,
                            selection: style.colorBinding(at: index),
                            supportsOpacity: false
                        )
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 12) {
                    Text("Relief")
                        .font(.title3.weight(.semibold))
                    valueSlider("Stärke", value: $style.reliefOpacity, range: 0...1, format: "%.0f %%", multiplier: 100)
                    valueSlider("Überhöhung", value: $style.reliefExaggeration, range: 0...120, format: "%.0f×")
                    valueSlider("Kontrast", value: $style.reliefContrast, range: 0.5...5, format: "%.1f")
                    valueSlider("Grundlicht", value: $style.ambientLight, range: 0...0.35, format: "%.0f %%", multiplier: 100)
                }

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
        .frame(minWidth: 290, idealWidth: 320, maxWidth: 360)
        .background(.regularMaterial)
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
