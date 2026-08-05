import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject private var session: MapSession
    @EnvironmentObject private var style: StyleSettings
    @EnvironmentObject private var viewport: ViewportController

    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            content
        }
        .frame(minWidth: 980, minHeight: 680)
        .onAppear { session.loadDefaultIfAvailable() }
        .fileImporter(
            isPresented: $session.isChoosingDirectory,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                session.load(url)
            }
        }
    }

    private var controls: some View {
        HStack(spacing: 12) {
            Text("TopoExplorer")
                .font(.headline)
            if let manifest = session.manifest {
                Text(manifest.name)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(viewport.status)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Menu {
                ForEach(MapReference.all) { reference in
                    Button(reference.name) { viewport.show(reference) }
                }
            } label: {
                Label(viewport.activeReference?.name ?? "Referenzansichten", systemImage: "viewfinder")
            }
            .disabled(session.manifest == nil)
            Button {
                viewport.fitGermany()
            } label: {
                Label("Deutschland einpassen", systemImage: "arrow.down.left.and.arrow.up.right")
            }
            .disabled(session.manifest == nil)
            Button {
                session.isChoosingDirectory = true
            } label: {
                Label("Kartendaten wählen", systemImage: "folder")
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .padding(.horizontal, 12)
        .frame(height: 44)
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
                        viewport: viewport
                    )
                    Text("Ziehen: verschieben   ·   Mausrad: zoomen   ·   Referenzen: feste Prüfgebiete   ·   0: Deutschland")
                        .font(.caption)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(12)
                }
                InspectorView(manifest: manifest, style: style, session: session)
            }
        } else {
            VStack(spacing: 16) {
                Image(systemName: "map")
                    .font(.system(size: 56, weight: .light))
                    .foregroundStyle(.secondary)
                Text("Deutschland-Kartendaten fehlen")
                    .font(.title2.weight(.semibold))
                Text(session.errorMessage ?? "Zuerst ./scripts/preprocess_germany.sh ausführen oder einen fertigen Datenordner wählen.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 560)
                Button("Kartendaten wählen") { session.isChoosingDirectory = true }
                    .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}
