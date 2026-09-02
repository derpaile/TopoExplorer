import Foundation

struct MapReference: Identifiable, Equatable {
    struct Observation: Identifiable, Equatable {
        let title: String
        let detail: String
        let symbolName: String

        var id: String { title }
    }

    let id: String
    let name: String
    let subtitle: String
    let story: String
    let observations: [Observation]
    let symbolName: String
    let accentHex: String
    let centerX: Double
    let centerY: Double
    let metersPerPoint: Double

    static let all: [MapReference] = [
        MapReference(
            id: "harz", name: "Harz", subtitle: "Wald & Mittelgebirge",
            story: "Der Harz hebt sich als großer, dunkler Waldkörper aus dem kleinteiligen Kulturland ab. Relief, Täler und Siedlungsränder machen sichtbar, wie stark Gelände und Nutzung zusammenhängen.",
            observations: [
                Observation(title: "Waldkörper", detail: "Verfolge, wo geschlossene Waldflächen in Felder und Offenland übergehen.", symbolName: "tree.fill"),
                Observation(title: "Täler im Relief", detail: "Schalte die Schummerung ein und suche die radialen Kerben im Gebirge.", symbolName: "mountain.2.fill"),
                Observation(title: "Siedlungsrand", detail: "Vergleiche Orte im Gebirge mit den dichteren Bändern am Harzrand.", symbolName: "building.2.fill"),
            ],
            symbolName: "mountain.2.fill", accentHex: "#315F48",
            centerX: 4_363_816.460, centerY: 3_182_365.642, metersPerPoint: 100
        ),
        MapReference(
            id: "alpen", name: "Alpen", subtitle: "Hochgebirge & Täler",
            story: "In den Alpen ordnen Höhenzüge, Täler und Seen die gesamte Landschaft. Die Karte zeigt besonders klar, wie Siedlung und Verkehr den Talräumen folgen und Wald an steilen Hängen Raum gewinnt.",
            observations: [
                Observation(title: "Höhenstufen", detail: "Lies den Wechsel von Talboden, Waldgürtel und offenem Hochgebirge.", symbolName: "arrow.up.right"),
                Observation(title: "Talachsen", detail: "Achte auf langgestreckte Siedlungs- und Verkehrsformen zwischen den Höhenzügen.", symbolName: "point.bottomleft.forward.to.point.topright.scurvepath"),
                Observation(title: "Seen als Formgeber", detail: "Vergleiche Ufer, Siedlungen und steile Reliefkanten rund um die Seen.", symbolName: "water.waves"),
            ],
            symbolName: "mountain.2", accentHex: "#697A70",
            centerX: 4_418_818.672, centerY: 2_721_568.390, metersPerPoint: 100
        ),
        MapReference(
            id: "kueste", name: "Küste", subtitle: "Meer, Marsch & Häfen",
            story: "An der Küste treffen Wasser, flaches Land und menschliche Ordnung unmittelbar aufeinander. Inseln, Marschen, Entwässerung und Häfen erzeugen ein Kartenbild, das sich deutlich vom Binnenland unterscheidet.",
            observations: [
                Observation(title: "Land–Wasser-Kante", detail: "Folge Inseln, Buchten und den feinen Übergängen zwischen Watt und Festland.", symbolName: "water.waves"),
                Observation(title: "Geordnete Marsch", detail: "Suche die regelmäßigen Agrarformen im sehr flachen Küstenhinterland.", symbolName: "square.grid.3x3.fill"),
                Observation(title: "Hafenlandschaft", detail: "Erkenne Becken, Verkehrsachsen und dichte Siedlung als zusammenhängendes System.", symbolName: "ferry.fill"),
            ],
            symbolName: "water.waves", accentHex: "#347D96",
            centerX: 4_458_876.725, centerY: 3_426_992.276, metersPerPoint: 100
        ),
        MapReference(
            id: "ruhrgebiet", name: "Ruhrgebiet", subtitle: "Städte & Industrie",
            story: "Das Ruhrgebiet erscheint nicht als einzelne Stadt, sondern als dicht verflochtene Stadtlandschaft. Zwischen Siedlungsflächen bleiben Flüsse, Wälder und Grünzüge als überraschend starke Orientierungslinien lesbar.",
            observations: [
                Observation(title: "Viele Zentren", detail: "Suche die Übergänge, an denen benachbarte Städte nahezu zusammenwachsen.", symbolName: "building.2.crop.circle.fill"),
                Observation(title: "Blaue Achsen", detail: "Verfolge Rhein, Ruhr, Emscher und Kanäle durch das Siedlungsgewebe.", symbolName: "water.waves"),
                Observation(title: "Grüne Zwischenräume", detail: "Achte auf Waldinseln und Freiräume zwischen den urbanen Bändern.", symbolName: "leaf.fill"),
            ],
            symbolName: "building.2.crop.circle.fill", accentHex: "#A54E43",
            centerX: 4_122_935.894, centerY: 3_152_671.123, metersPerPoint: 100
        ),
        MapReference(
            id: "flachland", name: "Flachland", subtitle: "Felder & Siedlungen",
            story: "Im Flachland fehlen dominante Höhenzüge – dadurch treten Nutzungsmuster umso deutlicher hervor. Feldgrößen, Waldinseln, Gewässer und verstreute Orte erzählen hier die Landschaft.",
            observations: [
                Observation(title: "Feldmosaik", detail: "Vergleiche große Schläge mit kleineren, unregelmäßigen Nutzungsflächen.", symbolName: "square.grid.3x3.fill"),
                Observation(title: "Waldinseln", detail: "Beobachte Form und Lage isolierter Wälder im offenen Agrarraum.", symbolName: "tree.fill"),
                Observation(title: "Leise Topografie", detail: "Verstärke das Relief und entdecke selbst schwache Geländeformen.", symbolName: "sun.max.fill"),
            ],
            symbolName: "leaf.fill", accentHex: "#9B7B36",
            centerX: 4_439_293.455, centerY: 3_289_314.249, metersPerPoint: 100
        ),
        MapReference(
            id: "hannover", name: "Hannover", subtitle: "Stadt, Wald & Feld im Detail",
            story: "Hannover bündelt auf engem Raum dichte Stadt, große Stadtwälder, Seen, Flussräume und Ackerland. Die Feinstruktur macht den Übergang vom einzelnen Quartier zur regionalen Landschaft sichtbar.",
            observations: [
                Observation(title: "Stadt und Eilenriede", detail: "Vergleiche die feine Siedlungstextur mit dem großen Waldkörper östlich des Zentrums.", symbolName: "tree.fill"),
                Observation(title: "Leine und Maschsee", detail: "Lies Gewässer und Freiräume als durchgehendes blau-grünes Band.", symbolName: "drop.fill"),
                Observation(title: "Stadtrand", detail: "Folge Straßen und Bebauung bis zu den klar gezeichneten Feldstrukturen.", symbolName: "building.2.fill"),
            ],
            symbolName: "square.3.layers.3d.down.right", accentHex: "#5C7150",
            centerX: 4_302_748.3, centerY: 3_251_760.0, metersPerPoint: 20
        ),
    ]

    static func next(after current: MapReference?) -> MapReference? {
        guard !all.isEmpty else { return nil }
        guard let current, let index = all.firstIndex(of: current) else { return all[0] }
        return all[(index + 1) % all.count]
    }
}
