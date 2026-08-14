#!/usr/bin/env python3
"""Validate backward-compatible TVT1 and geoscience-capable TVT2 tiles."""

from __future__ import annotations

import argparse
import json
import struct
import sys
import zlib
from pathlib import Path


TILE_HEADER = struct.Struct("<4sHHHII")
TILE2_HEADER = struct.Struct("<4sHHHIII")
LINE_HEADER = struct.Struct("<BBBBHH")
PLACE_HEADER = struct.Struct("<BBHhhIH")
FEATURE_HEADER = struct.Struct("<BBBBHHH")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="TopoExplorer-Vektorkacheln vollständig prüfen")
    parser.add_argument("root", type=Path, nargs="?", default=Path("MapData/Germany/Vectors"))
    return parser.parse_args()


def require(condition: bool, message: str) -> None:
    if not condition:
        raise RuntimeError(message)


def verify_tile(
    path: Path,
    zoom: int,
    extent: int,
    buffer: int,
    kind_limits: dict[int, int],
) -> tuple[int, int, int, dict[int, int]]:
    try:
        payload = zlib.decompress(path.read_bytes())
    except zlib.error as error:
        raise RuntimeError(f"Defekte zlib-Kachel {path}: {error}") from error
    require(len(payload) >= TILE_HEADER.size, f"Kachelkopf fehlt: {path}")
    magic = payload[:4]
    if magic == b"TVT2":
        magic, version, tile_extent, tile_buffer, line_count, place_count, feature_count = TILE2_HEADER.unpack_from(payload)
        offset = TILE2_HEADER.size
        require(version == 2, f"Unbekannte TVT2-Version: {path}")
    else:
        magic, version, tile_extent, tile_buffer, line_count, place_count = TILE_HEADER.unpack_from(payload)
        feature_count = 0
        offset = TILE_HEADER.size
        require(magic == b"TVT1" and version == 1, f"Unbekanntes Format: {path}")
    require(tile_extent == extent and tile_buffer == buffer, f"Abweichende Quantisierung: {path}")
    layer_counts = {layer: 0 for layer in kind_limits}
    for _ in range(line_count):
        require(offset + LINE_HEADER.size <= len(payload), f"Abgeschnittener Linienkopf: {path}")
        layer, kind, min_zoom, flags, point_count, name_size = LINE_HEADER.unpack_from(payload, offset)
        offset += LINE_HEADER.size
        require(layer in kind_limits, f"Unbekannter Layer {layer}: {path}")
        require(1 <= kind <= kind_limits[layer], f"Unbekannter Untertyp {layer}/{kind}: {path}")
        require(min_zoom <= zoom, f"Linie vor minZoom in z{zoom}: {path}")
        require(flags & ~3 == 0, f"Unbekannte Linienflags {flags}: {path}")
        require(point_count >= 2, f"Linie mit weniger als zwei Punkten: {path}")
        point_bytes = point_count * 4
        end = offset + point_bytes + name_size
        require(end <= len(payload), f"Abgeschnittene Linie: {path}")
        for point_offset in {offset, offset + (point_count // 2) * 4, offset + (point_count - 1) * 4}:
            x, y = struct.unpack_from("<hh", payload, point_offset)
            require(-buffer <= x <= extent + buffer, f"x außerhalb Kachelpuffer: {path}")
            require(-buffer <= y <= extent + buffer, f"y außerhalb Kachelpuffer: {path}")
        payload[offset + point_bytes : end].decode("utf-8")
        offset = end
        layer_counts[layer] += 1
    for _ in range(place_count):
        require(offset + PLACE_HEADER.size <= len(payload), f"Abgeschnittener Ortskopf: {path}")
        kind, min_zoom, reserved, x, y, population, name_size = PLACE_HEADER.unpack_from(payload, offset)
        offset += PLACE_HEADER.size
        require(1 <= kind <= 12, f"Unbekannte Namensart {kind}: {path}")
        require(min_zoom <= zoom, f"Ort vor minZoom in z{zoom}: {path}")
        require(reserved == 0, f"Reserviertes Ortsfeld belegt: {path}")
        require(0 <= x <= extent and 0 <= y <= extent, f"Ort außerhalb der Kachel: {path}")
        end = offset + name_size
        require(end <= len(payload), f"Abgeschnittener Ortsname: {path}")
        require(bool(payload[offset:end].decode("utf-8")), f"Leerer Ortsname: {path}")
        offset = end
    for _ in range(feature_count):
        require(offset + FEATURE_HEADER.size <= len(payload), f"Abgeschnittener Featurekopf: {path}")
        layer, kind, geometry, min_zoom, point_count, name_size, attribute_size = FEATURE_HEADER.unpack_from(payload, offset)
        offset += FEATURE_HEADER.size
        require(layer in {5, 6, 7}, f"Unbekannter TVT2-Layer {layer}: {path}")
        require(kind > 0 and geometry in {1, 2, 3}, f"Ungültiges TVT2-Feature: {path}")
        require(min_zoom <= zoom and point_count > 0, f"Ungültige TVT2-Geometrie: {path}")
        point_bytes = point_count * 4
        end = offset + point_bytes + name_size + attribute_size
        require(end <= len(payload), f"Abgeschnittenes TVT2-Feature: {path}")
        for point_offset in {offset, offset + (point_count - 1) * 4}:
            x, y = struct.unpack_from("<hh", payload, point_offset)
            require(-buffer <= x <= extent + buffer and -buffer <= y <= extent + buffer, f"TVT2-Punkt außerhalb Kachelpuffer: {path}")
        payload[offset + point_bytes : offset + point_bytes + name_size].decode("utf-8")
        json.loads(payload[offset + point_bytes + name_size : end] or b"{}")
        offset = end
    require(offset == len(payload), f"{len(payload) - offset} unerwartete Bytes am Kachelende: {path}")
    return line_count, place_count, feature_count, layer_counts


def main() -> int:
    root = parse_args().root
    manifest_path = root / "vector-manifest.json"
    if not manifest_path.is_file():
        raise SystemExit(f"Vektormanifest fehlt: {manifest_path}")
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    tile_format = manifest["tileFormat"]
    extent = int(tile_format["extent"])
    buffer = int(tile_format["buffer"])
    kind_limits = {int(layer["id"]): len(layer["kinds"]) for layer in manifest["layers"]}
    total_tiles = total_lines = total_places = total_features = 0
    total_layers = {layer: 0 for layer in kind_limits}
    for level in manifest["levels"]:
        z = int(level["z"])
        tiles = lines = places = features = 0
        for path in sorted((root / f"z{z}").glob("*.vector.z")):
            line_count, place_count, feature_count, layer_counts = verify_tile(path, z, extent, buffer, kind_limits)
            tiles += 1
            lines += line_count
            places += place_count
            features += feature_count
            for layer, count in layer_counts.items():
                total_layers[layer] += count
        require(tiles >= level["tilesWithData"], f"Kachelzahl z{z}: {tiles} statt mindestens {level['tilesWithData']}")
        require(lines == level["lineRecords"], f"Linienzahl z{z}: {lines} statt {level['lineRecords']}")
        require(places == level["placeRecords"], f"Ortszahl z{z}: {places} statt {level['placeRecords']}")
        print(f"z{z}: {tiles:,} Kacheln · {lines:,} Linien · {places:,} Orte · {features:,} Fachobjekte")
        total_tiles += tiles
        total_lines += lines
        total_places += places
        total_features += features

    expected_layers = {int(layer): count for layer, count in manifest["counts"]["tileRecordsByLayer"].items()}
    require(total_layers == expected_layers, f"Layerzählung weicht ab: {total_layers} statt {expected_layers}")
    index_payload = zlib.decompress((root / manifest["places"]["index"]).read_bytes())
    index = json.loads(index_payload)
    require(index["version"] == 1 and index["crs"] == "EPSG:3035", "Ungültiger Ortsindex")
    require(index["fields"] == manifest["places"]["fields"], "Ortsindex-Felder weichen ab")
    require(len(index["places"]) == manifest["places"]["count"], "Ortsindex-Zahl weicht ab")
    populations: dict[str, int] = {}
    for place in index["places"]:
        require(len(place) == 6 and bool(place[0]), "Ungültiger Eintrag im Ortsindex")
        name, kind, population, x, y, min_zoom = place
        require(isinstance(name, str), "Ungültiger Ortsname im Ortsindex")
        require(isinstance(kind, int) and 1 <= kind <= 12, f"Ungültige Namensart: {name}")
        require(isinstance(population, int) and 0 <= population <= 20_000_000, f"Ungültige Bevölkerung: {name}")
        require(isinstance(x, (int, float)) and isinstance(y, (int, float)), f"Ungültige Koordinate: {name}")
        require(isinstance(min_zoom, int) and 0 <= min_zoom <= 20, f"Ungültige Zoomstufe: {name}")
        populations[name] = max(populations.get(name, 0), population)
    for name, minimum, maximum in (
        ("Berlin", 3_000_000, 5_000_000),
        ("Hannover", 400_000, 800_000),
        ("Braunschweig", 150_000, 400_000),
    ):
        require(name in populations, f"Pflichtort fehlt im Suchindex: {name}")
        require(minimum <= populations[name] <= maximum, f"Unplausible Bevölkerung für {name}: {populations[name]}")
    print(
        f"Vollständig: {total_tiles:,} Kacheln · {total_lines:,} Linienrecords · "
        f"{total_places:,} Ortsrecords · {total_features:,} Fachobjekte · {len(index['places']):,} Suchorte"
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (RuntimeError, UnicodeDecodeError, json.JSONDecodeError) as error:
        print(f"Fehler: {error}", file=sys.stderr)
        raise SystemExit(1)
