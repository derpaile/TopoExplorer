import XCTest
import zlib
@testable import TopoExplorer

final class TopoExplorerTests: XCTestCase {
    func testMapCameraFlightPreservesEndpointsAndCreatesSpatialArc() {
        let start = MapCameraState(centerX: 0, centerY: 0, pixelsPerMeter: 0.01)
        let destination = MapCameraState(
            centerX: 500_000, centerY: 250_000, pixelsPerMeter: 0.01
        )
        let flight = MapCameraFlight(
            start: start, destination: destination,
            viewportSize: CGSize(width: 1_200, height: 800)
        )
        XCTAssertEqual(flight.state(at: 0), start)
        let end = flight.state(at: 1)
        XCTAssertEqual(end.centerX, destination.centerX, accuracy: 0.000_001)
        XCTAssertEqual(end.centerY, destination.centerY, accuracy: 0.000_001)
        XCTAssertEqual(end.pixelsPerMeter, destination.pixelsPerMeter, accuracy: 0.000_000_001)
        XCTAssertLessThan(flight.state(at: 0.5).pixelsPerMeter, start.pixelsPerMeter)
        XCTAssertGreaterThanOrEqual(flight.duration, 0.38)
        XCTAssertLessThanOrEqual(flight.duration, 0.68)
    }

    func testAtlasCommandsRemainCompleteAndOrdered() {
        XCTAssertEqual(AtlasCommand.allCases, [
            .openPalette, .focusSearch, .nextLandscape, .openDataCatalog, .openCollection,
            .toggleAreaAnalysis, .toggleLandscapeProfile, .exportMap, .toggleSidebar,
        ])
    }

    func testDiscoveryReferencesAreCompleteAndLoop() {
        XCTAssertEqual(Set(MapReference.all.map(\.id)).count, MapReference.all.count)
        XCTAssertTrue(MapReference.all.allSatisfy {
            !$0.subtitle.isEmpty && !$0.story.isEmpty && !$0.symbolName.isEmpty
                && $0.observations.count == 3
                && Set($0.observations.map(\.id)).count == $0.observations.count
        })
        XCTAssertEqual(MapReference.next(after: nil), MapReference.all.first)
        XCTAssertEqual(MapReference.next(after: MapReference.all.last), MapReference.all.first)
    }

    func testProbeDiscoveryMetadata() {
        let probe = MapProbe(
            worldX: 4_302_748.3,
            worldY: 3_251_760.0,
            elevation: 55,
            classID: 3,
            className: "Dichte Siedlung",
            classGroup: "Siedlung",
            thematic: nil,
            slopeDegrees: 7.25,
            aspectDegrees: 231,
            terrainResolutionMeters: 100
        )
        XCTAssertEqual(probe.discoveryTitle, "Dichte Siedlung")
        XCTAssertEqual(probe.coordinateText, "4302748 · 3251760")
        XCTAssertEqual(probe.copyText, "EPSG:3035 4302748 3251760")
        XCTAssertEqual(probe.aspectDirection, "SW")
        XCTAssertTrue(probe.terrainSummary?.contains("SW") == true)
    }

    func testLandscapeContextBuildsNarrativeAndShares() {
        func probe(
            classID: Int, name: String, group: String, elevation: Int, slope: Double
        ) -> MapProbe {
            MapProbe(
                worldX: 1, worldY: 2, elevation: elevation,
                classID: classID, className: name, classGroup: group,
                thematic: ThematicProbe(
                    productID: "substrate", productName: "Substrat",
                    classID: classID, className: name,
                    sourceName: "BÜK", sourceScale: 200_000
                ),
                slopeDegrees: slope, aspectDegrees: 225, terrainResolutionMeters: 100
            )
        }
        let context = LandscapeContext(
            centerX: 1, centerY: 2, radiusMeters: 3_000,
            sampledResolution: 250, plannedSampleCount: 4,
            probes: [
                probe(classID: 2, name: "Wald", group: "Wald", elevation: 10, slope: 2),
                probe(classID: 2, name: "Wald", group: "Wald", elevation: 20, slope: 4),
                probe(classID: 1, name: "Wiese", group: "Natur", elevation: 40, slope: 8),
            ],
            population: 12_000,
            populationSource: "Zensus Bevölkerung (100-m-Gitter)",
            namedFeatures: [
                LandscapeContextFeature(
                    name: "Waldsee", kind: 9, population: nil,
                    worldX: 1_501, worldY: 2_501,
                    distanceMeters: 708, directionDegrees: 45
                ),
            ]
        )
        XCTAssertEqual(context.sampleCount, 3)
        XCTAssertEqual(context.coverage, 0.75)
        XCTAssertEqual(context.classes.count, 2)
        XCTAssertEqual(context.classes.first?.share ?? 0, 2.0 / 3.0, accuracy: 0.0001)
        XCTAssertEqual(context.elevationRange, 30)
        XCTAssertEqual(context.meanElevation, 23)
        XCTAssertEqual(context.elevationStandardDeviation ?? 0, 12.472, accuracy: 0.001)
        XCTAssertEqual(context.meanSlopeDegrees ?? 0, 14.0 / 3.0, accuracy: 0.001)
        XCTAssertEqual(context.maximumSlopeDegrees, 8)
        XCTAssertEqual(context.population, 12_000)
        XCTAssertEqual(context.populationDensity ?? 0, 424.413, accuracy: 0.001)
        XCTAssertEqual(context.terrainCharacter, "wellig")
        XCTAssertEqual(context.namedFeatures?.first?.kindTitle, "Gewässer")
        XCTAssertEqual(context.namedFeatures?.first?.directionName, "NO")
        XCTAssertEqual(context.nearbyNames, "Waldsee")
        XCTAssertEqual(context.distinctGroups, 2)
        XCTAssertEqual(context.groupShares.map(\.name), ["Wald", "Natur"])
        XCTAssertEqual(context.groupShares.reduce(0) { $0 + $1.share }, 1, accuracy: 0.0001)
        XCTAssertEqual(context.thematicClasses.count, 2)
        XCTAssertTrue(context.title.contains("Wald"))
        XCTAssertTrue(context.narrative.contains("Höhenmeter"))

        let detail = MapBookmarkDetail(
            probe: probe(classID: 2, name: "Wald", group: "Wald", elevation: 20, slope: 4),
            landscapeContext: context
        )
        let roundTrip = try? JSONDecoder().decode(
            MapBookmarkDetail.self, from: JSONEncoder().encode(detail)
        )
        XCTAssertEqual(roundTrip, detail)
        XCTAssertEqual(roundTrip?.landscapeContext?.classes.first?.name, "Wald")
    }

    func testGeoJSONFieldbookUsesWGS84AndRoundTripsAtlasData() throws {
        let point = MapProbe(
            worldX: 4_302_748.3, worldY: 3_251_760,
            elevation: 55, classID: 3, className: "Siedlung", classGroup: "Siedlung",
            thematic: nil, slopeDegrees: 1.5, aspectDegrees: 90,
            terrainResolutionMeters: 98.46
        )
        let context = LandscapeContext(
            centerX: point.worldX, centerY: point.worldY,
            radiusMeters: 3_000, sampledResolution: 250, plannedSampleCount: 2,
            probes: [point, point], population: 100_000, populationSource: "Zensus",
            namedFeatures: [
                LandscapeContextFeature(
                    name: "Maschsee", kind: 9, population: nil,
                    worldX: point.worldX + 1_000, worldY: point.worldY,
                    distanceMeters: 1_000, directionDegrees: 90
                ),
            ]
        )
        let bookmark = MapBookmark(
            id: UUID(), name: "Hannover", centerX: point.worldX, centerY: point.worldY,
            metersPerPoint: 20, note: "Stadtlandschaft",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            detail: MapBookmarkDetail(probe: point, landscapeContext: context)
        )
        let document = try AtlasFieldbookDocument(
            bookmarks: [bookmark], sources: [],
            exportedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let coordinate = try XCTUnwrap(document.features.first?.geometry?.coordinates)
        XCTAssertEqual(coordinate[0], 9.732, accuracy: 0.000_01)
        XCTAssertEqual(coordinate[1], 52.375, accuracy: 0.000_01)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(
            AtlasFieldbookDocument.self, from: encoder.encode(document)
        )
        XCTAssertEqual(try decoded.importedBookmarks(), [bookmark])
        let encoded = try encoder.encode(document)
        let text = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertTrue(text.contains("slope_degrees"))
        XCTAssertTrue(text.contains("context_population_per_km2"))
        XCTAssertTrue(text.contains("context_nearby_names"))

        let generic = """
        {"type":"FeatureCollection","features":[{"type":"Feature","geometry":{"type":"Point","coordinates":[9.732,52.375]},"properties":{"name":"Fremder Punkt"}}]}
        """.data(using: .utf8)!
        let imported = try decoder.decode(
            AtlasFieldbookDocument.self, from: generic
        ).importedBookmarks()
        XCTAssertEqual(imported.first?.name, "Fremder Punkt")
        XCTAssertEqual(imported.first?.centerX ?? 0, point.worldX, accuracy: 1)
        XCTAssertEqual(imported.first?.centerY ?? 0, point.worldY, accuracy: 1)
    }

    func testBookmarkMigrationAndComparison() throws {
        let legacy = """
        [{"id":"00000000-0000-0000-0000-000000000001","name":"Alt","centerX":1,"centerY":2,"metersPerPoint":3}]
        """.data(using: .utf8)!
        let migrated = try JSONDecoder().decode([MapBookmark].self, from: legacy)
        XCTAssertNil(migrated[0].detail)
        XCTAssertNil(migrated[0].note)

        let legacyPoint = """
        [{"id":"00000000-0000-0000-0000-000000000002","name":"Punkt","centerX":1,"centerY":2,"metersPerPoint":3,"detail":{"surfaceName":"Wald","surfaceGroup":"Wald","elevation":42,"thematicProductID":null,"thematicProductName":null,"thematicClassName":null,"thematicSourceSummary":null}}]
        """.data(using: .utf8)!
        let migratedPoint = try JSONDecoder().decode([MapBookmark].self, from: legacyPoint)
        XCTAssertEqual(migratedPoint.first?.detail?.surfaceName, "Wald")
        XCTAssertNil(migratedPoint.first?.detail?.surfaceClassID)
        XCTAssertNil(migratedPoint.first?.detail?.landscapeContext)
        XCTAssertNil(migratedPoint.first?.detail?.slopeDegrees)

        func bookmark(_ name: String, elevation: Int, group: String) -> MapBookmark {
            let probe = MapProbe(
                worldX: 1, worldY: 2, elevation: elevation, classID: 1,
                className: name, classGroup: group, thematic: nil
            )
            return MapBookmark(
                id: UUID(), name: name, centerX: 1, centerY: 2, metersPerPoint: 10,
                note: "Notiz", createdAt: Date(), detail: MapBookmarkDetail(probe: probe)
            )
        }
        let comparison = MapBookmarkComparison(
            first: bookmark("Stadt", elevation: 50, group: "Siedlung"),
            second: bookmark("Berg", elevation: 650, group: "Wald")
        )
        XCTAssertEqual(comparison.elevationDifference, 600)
        XCTAssertEqual(comparison.sharesSurfaceGroup, false)
        XCTAssertEqual(comparison.first.detail?.summary, "Stadt")
    }

    func testLandscapeProfileMetricsAndSegments() {
        let selection = MapProfileSelection(startX: 0, startY: 0, endX: 300, endY: 0)
        let profile = LandscapeProfile(
            selection: selection,
            samples: [
                LandscapeProfileSample(distanceMeters: 0, elevation: 10, classID: 1, className: "Stadt", classGroup: "Siedlung", thematicClassName: nil),
                LandscapeProfileSample(distanceMeters: 100, elevation: 30, classID: 1, className: "Stadt", classGroup: "Siedlung", thematicClassName: nil),
                LandscapeProfileSample(distanceMeters: 200, elevation: 20, classID: 2, className: "Wald", classGroup: "Wald", thematicClassName: "Sand"),
                LandscapeProfileSample(distanceMeters: 300, elevation: 25, classID: 2, className: "Wald", classGroup: "Wald", thematicClassName: "Lehm"),
            ]
        )
        XCTAssertEqual(profile.distanceMeters, 300)
        XCTAssertEqual(profile.minimumElevation, 10)
        XCTAssertEqual(profile.maximumElevation, 30)
        XCTAssertEqual(profile.elevationRange, 20)
        XCTAssertEqual(profile.ascentMeters, 25)
        XCTAssertEqual(profile.descentMeters, 10)
        XCTAssertEqual(profile.segments.count, 2)
        XCTAssertEqual(profile.distinctLandClasses, 2)
        XCTAssertEqual(profile.distinctThematicClasses, 2)
    }

    func testManifestValidation() throws {
        let levels = [
            MapManifest.Level(z: 0, resolution: 100, width: 10, height: 20, tilesX: 1, tilesY: 1),
            MapManifest.Level(z: 1, resolution: 50, width: 20, height: 40, tilesX: 1, tilesY: 1),
        ]
        let classes = (0...7).map { MapManifest.LandClass(id: $0, name: "Klasse \($0)", defaultColor: "#000000") }
        let manifest = MapManifest(
            version: 1,
            name: "Test",
            crs: "EPSG:3035",
            bounds: [0, 0, 100, 200],
            tileSize: 512,
            elevationBorder: 1,
            minZoom: 0,
            maxZoom: 1,
            elevationMin: -10,
            elevationMax: 3500,
            compression: "zlib",
            levels: levels,
            classes: classes
        )
        XCTAssertNoThrow(try manifest.validated())
    }

    func testHexColor() {
        let color = RGBAColor(hex: "#CC0B1E")
        XCTAssertEqual(color.red, 204.0 / 255.0, accuracy: 0.0001)
        XCTAssertEqual(color.green, 11.0 / 255.0, accuracy: 0.0001)
        XCTAssertEqual(color.blue, 30.0 / 255.0, accuracy: 0.0001)
    }

    func testSurfaceTextureManifestAndZoomFade() throws {
        let levels = [
            MapManifest.Level(z: 0, resolution: 320, width: 32, height: 32, tilesX: 1, tilesY: 1),
            MapManifest.Level(z: 1, resolution: 160, width: 64, height: 64, tilesX: 1, tilesY: 1),
            MapManifest.Level(z: 2, resolution: 80, width: 128, height: 128, tilesX: 1, tilesY: 1),
            MapManifest.Level(z: 3, resolution: 40, width: 256, height: 256, tilesX: 1, tilesY: 1),
            MapManifest.Level(z: 4, resolution: 20, width: 512, height: 512, tilesX: 1, tilesY: 1),
            MapManifest.Level(z: 5, resolution: 10, width: 1024, height: 1024, tilesX: 2, tilesY: 2),
        ]
        let classes = (0...7).map {
            MapManifest.LandClass(id: $0, name: "Klasse \($0)", defaultColor: "#000000")
        }
        var manifest = MapManifest(
            version: 1, name: "Test", crs: "EPSG:3035", bounds: [0, 0, 10_240, 10_240],
            tileSize: 512, elevationBorder: 1, minZoom: 0, maxZoom: 5,
            elevationMin: -10, elevationMax: 3500, compression: "zlib",
            levels: levels, classes: classes
        )
        manifest.surfaceTexture = MapManifest.SurfaceTexture(
            suffix: "surface.z", minZoom: 1, maxZoom: 5, defaultStrength: 0.08,
            fullStrengthResolution: 20, hiddenResolution: 320,
            classWeights: [0, 0.4, 0.4, 0.4, 0, 0.7, 0.6, 1]
        )
        XCTAssertNoThrow(try manifest.validated())
        XCTAssertEqual(manifest.surfaceZoomWeight(at: levels[0]), 0)
        XCTAssertGreaterThan(manifest.surfaceZoomWeight(at: levels[2]), 0)
        XCTAssertLessThan(manifest.surfaceZoomWeight(at: levels[2]), 1)
        XCTAssertEqual(manifest.surfaceZoomWeight(at: levels[4]), 1)
        XCTAssertEqual(manifest.surfaceZoomWeight(at: levels[5]), 1)
    }

    func testThematicManifestValidation() throws {
        let levels = [
            MapManifest.Level(z: 0, resolution: 10, width: 1, height: 1, tilesX: 1, tilesY: 1),
        ]
        let classes = (0...7).map {
            MapManifest.LandClass(id: $0, name: "Klasse \($0)", defaultColor: "#000000")
        }
        var manifest = MapManifest(
            version: 1, name: "Test", crs: "EPSG:3035", bounds: [0, 0, 10, 10],
            tileSize: 512, elevationBorder: 1, minZoom: 0, maxZoom: 0,
            elevationMin: -10, elevationMax: 3500, compression: "zlib",
            levels: levels, classes: classes
        )
        manifest.thematicRasters = [
            MapManifest.ThematicRaster(
                id: "geology", name: "Geologie", suffix: "geology.z",
                qualitySuffix: "geology.quality.z",
                classes: [
                    MapManifest.LandClass(id: 0, name: "Keine Daten", defaultColor: "#000000"),
                    MapManifest.LandClass(id: 1, name: "Kalkstein", defaultColor: "#CCDDEE"),
                ],
                sources: [
                    MapManifest.GeoSource(
                        id: "geology-source", name: "Geologiequelle", license: "CC BY 4.0",
                        url: "https://example.com/geology", scale: 250_000, role: "Fachkarte"
                    ),
                ]
            ),
        ]
        manifest.sources = [
            MapManifest.LandcoverSource(
                name: "Landquelle", year: 2021, role: "Grundbedeckung",
                license: "CC BY 4.0", url: "https://example.com/land"
            ),
        ]
        manifest.vectorSources = [
            MapManifest.GeoSource(
                id: "bkg-gn250", name: "Geonamen", license: "DL-DE/BY-2.0",
                url: "https://example.com/names", scale: 250_000, role: "Namen", year: 2026
            ),
        ]
        XCTAssertNoThrow(try manifest.validated())
        XCTAssertEqual(manifest.availableThematicRasters[0].palette.count, 256)
        XCTAssertEqual(manifest.dataCatalog.count, 3)
        XCTAssertEqual(Set(manifest.dataCatalog.map(\.category)), [.landscape, .geoscience, .orientation])
        XCTAssertTrue(manifest.dataCatalog.contains { $0.activation == .thematic("geology") })
    }

    func testTVT2RemovedFeatureLayerIsIgnored() throws {
        var raw = Data("TVT2".utf8)
        raw.appendLittleEndian(UInt16(2))
        raw.appendLittleEndian(UInt16(8192))
        raw.appendLittleEndian(UInt16(128))
        raw.appendLittleEndian(UInt32(0))
        raw.appendLittleEndian(UInt32(0))
        raw.appendLittleEndian(UInt32(1))
        raw.append(contentsOf: [5, 1, 1, 0])
        raw.appendLittleEndian(UInt16(1))
        raw.appendLittleEndian(UInt16(4))
        raw.appendLittleEndian(UInt16(2))
        raw.appendLittleEndian(Int16(100))
        raw.appendLittleEndian(Int16(200))
        raw.append(Data("Mine{}".utf8))

        let tile = VectorTileDecoder.decode(try compressed(raw))
        XCTAssertNotNil(tile)
        XCTAssertTrue(tile?.layers.isEmpty == true)
    }

    func testEnergyMarkerDecoding() throws {
        var raw = Data("TVT1".utf8)
        raw.appendLittleEndian(UInt16(1))
        raw.appendLittleEndian(UInt16(8192))
        raw.appendLittleEndian(UInt16(128))
        raw.appendLittleEndian(UInt32(1))
        raw.appendLittleEndian(UInt32(0))
        raw.append(contentsOf: [8, 4, 5, 0])
        raw.appendLittleEndian(UInt16(2))
        raw.appendLittleEndian(UInt16(0))
        raw.appendLittleEndian(Int16(100))
        raw.appendLittleEndian(Int16(200))
        raw.appendLittleEndian(Int16(100))
        raw.appendLittleEndian(Int16(200))

        let tile = VectorTileDecoder.decode(try compressed(raw))
        XCTAssertEqual(tile?.layers[.energy]?.segmentCount, 1)
    }

    private func compressed(_ data: Data) throws -> Data {
        var result = Data(count: Int(compressBound(uLong(data.count))))
        var size = uLongf(result.count)
        let status = result.withUnsafeMutableBytes { destination in
            data.withUnsafeBytes { source in
                compress2(
                    destination.bindMemory(to: UInt8.self).baseAddress!, &size,
                    source.bindMemory(to: UInt8.self).baseAddress!, uLong(data.count), 6
                )
            }
        }
        XCTAssertEqual(status, Z_OK)
        result.count = Int(size)
        return result
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
