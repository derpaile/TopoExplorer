#!/usr/bin/env python3
"""Merge mining and hydrocarbon GeoJSON into idempotent TVT2 vector tiles."""

from __future__ import annotations

import argparse
import json
import math
import struct
import zlib
from collections import defaultdict
from pathlib import Path

from rasterio.warp import transform_geom

from germany_vectors import BUFFER, EXTENT, clip_line, iter_feature_collection, simplify_line


TVT1_HEADER = struct.Struct("<4sHHHII")
TVT2_HEADER = struct.Struct("<4sHHHIII")
LINE_HEADER = struct.Struct("<BBBBHH")
PLACE_HEADER = struct.Struct("<BBHhhIH")
FEATURE_HEADER = struct.Struct("<BBBBHHH")
POINT = 1
LINE = 2
POLYGON = 3


def arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Bergbau- und KW-Vektoren als TVT2 ergänzen")
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--manifest", type=Path, default=Path("MapData/Germany/manifest.json"))
    parser.add_argument("--vectors", type=Path, default=Path("MapData/Germany/Vectors"))
    parser.add_argument("--compression", type=int, choices=range(1, 10), default=6)
    parser.add_argument("--dry-run", action="store_true")
    return parser.parse_args()


def lines(geometry: dict) -> list[tuple[int, list[tuple[float, float]]]]:
    kind = geometry["type"]
    coordinates = geometry["coordinates"]
    if kind == "Point":
        return [(POINT, [tuple(coordinates)])]
    if kind == "MultiPoint":
        return [(POINT, [tuple(point)]) for point in coordinates]
    if kind == "LineString":
        return [(LINE, [tuple(point) for point in coordinates])]
    if kind == "MultiLineString":
        return [(LINE, [tuple(point) for point in part]) for part in coordinates]
    if kind == "Polygon":
        return [(POLYGON, [tuple(point) for point in ring]) for ring in coordinates]
    if kind == "MultiPolygon":
        return [
            (POLYGON, [tuple(point) for point in ring])
            for polygon in coordinates for ring in polygon
        ]
    return []


def feature_record(
    layer: int,
    kind: int,
    geometry_type: int,
    minimum_zoom: int,
    points: list[tuple[int, int]],
    name: str,
    attributes: dict,
) -> bytes:
    encoded_name = name.encode("utf-8")[:65_535]
    encoded_attributes = json.dumps(
        attributes, ensure_ascii=False, separators=(",", ":"), default=str
    ).encode("utf-8")[:65_535]
    return (
        FEATURE_HEADER.pack(
            layer, kind, geometry_type, minimum_zoom,
            len(points), len(encoded_name), len(encoded_attributes),
        )
        + b"".join(struct.pack("<hh", x, y) for x, y in points)
        + encoded_name + encoded_attributes
    )


def append_source(records: dict[str, list[bytes]], source: dict, manifest: dict) -> int:
    total = 0
    left, bottom, right, top = manifest["bounds"]
    source_crs = source.get("crs", "EPSG:4326")
    for feature in iter_feature_collection(Path(source["path"])):
        if not feature.get("geometry"):
            continue
        projected = transform_geom(source_crs, "EPSG:3035", feature["geometry"])
        properties = feature.get("properties") or {}
        kind = int(properties.get(source.get("kindProperty", "_kind"), source.get("kind", 1)))
        minimum_zoom = int(properties.get(source.get("minZoomProperty", "_minZoom"), source.get("minZoom", 4)))
        name = str(properties.get(source.get("nameProperty", "name"), ""))
        for geometry_type, points in lines(projected):
            if not points:
                continue
            for level in manifest["levels"]:
                if level["z"] < minimum_zoom:
                    continue
                span = level["resolution"] * manifest["tileSize"]
                buffer_m = span * BUFFER / EXTENT
                xs = [point[0] for point in points]
                ys = [point[1] for point in points]
                first_x = max(0, math.floor((min(xs) - left - buffer_m) / span))
                last_x = min(level["tilesX"] - 1, math.floor((max(xs) - left + buffer_m) / span))
                first_y = max(0, math.floor((top - max(ys) - buffer_m) / span))
                last_y = min(level["tilesY"] - 1, math.floor((top - min(ys) + buffer_m) / span))
                if first_x > last_x or first_y > last_y:
                    continue
                simplified = simplify_line(points, level["resolution"] * 0.65) if len(points) > 1 else points
                for tile_y in range(first_y, last_y + 1):
                    tile_top = top - tile_y * span
                    for tile_x in range(first_x, last_x + 1):
                        tile_left = left + tile_x * span
                        complete_polygon = False
                        if geometry_type == POINT:
                            clipped_parts = [simplified] if (
                                tile_left <= simplified[0][0] <= tile_left + span
                                and tile_top - span <= simplified[0][1] <= tile_top
                            ) else []
                        else:
                            rectangle = (
                                tile_left - buffer_m, tile_top - span - buffer_m,
                                tile_left + span + buffer_m, tile_top + buffer_m,
                            )
                            ring = simplified
                            if geometry_type == POLYGON and ring[0] != ring[-1]:
                                ring = ring + [ring[0]]
                            complete_polygon = geometry_type == POLYGON and all(
                                rectangle[0] <= x <= rectangle[2]
                                and rectangle[1] <= y <= rectangle[3]
                                for x, y in ring
                            )
                            clipped_parts = [ring] if complete_polygon else list(clip_line(ring, rectangle))
                        for clipped in clipped_parts:
                            quantized = []
                            for x, y in clipped:
                                point = (
                                    min(EXTENT + BUFFER, max(-BUFFER, round((x - tile_left) / span * EXTENT))),
                                    min(EXTENT + BUFFER, max(-BUFFER, round((tile_top - y) / span * EXTENT))),
                                )
                                if not quantized or quantized[-1] != point:
                                    quantized.append(point)
                            if not quantized:
                                continue
                            local_type = POINT if geometry_type == POINT else (
                                POLYGON if complete_polygon else LINE
                            )
                            key = f"{level['z']}/{tile_x}_{tile_y}"
                            records[key].append(feature_record(
                                int(source["layer"]), kind, local_type, minimum_zoom,
                                quantized, name, properties,
                            ))
                            total += 1
    return total


def base_records(data: bytes) -> tuple[int, int, int, int, bytes]:
    magic = data[:4]
    if magic == b"TVT1":
        _, version, extent, buffer, line_count, place_count = TVT1_HEADER.unpack_from(data)
        if version != 1:
            raise ValueError("Unbekannte TVT1-Version")
        return extent, buffer, line_count, place_count, data[TVT1_HEADER.size:]
    if magic != b"TVT2":
        raise ValueError("Unbekannte Vektorkachel")
    _, version, extent, buffer, line_count, place_count, _ = TVT2_HEADER.unpack_from(data)
    if version != 2:
        raise ValueError("Unbekannte TVT2-Version")
    offset = TVT2_HEADER.size
    for _ in range(line_count):
        _, _, _, _, point_count, name_length = LINE_HEADER.unpack_from(data, offset)
        offset += LINE_HEADER.size + point_count * 4 + name_length
    for _ in range(place_count):
        *_, name_length = PLACE_HEADER.unpack_from(data, offset)
        offset += PLACE_HEADER.size + name_length
    return extent, buffer, line_count, place_count, data[TVT2_HEADER.size:offset]


def main() -> int:
    args = arguments()
    manifest = json.loads(args.manifest.read_text(encoding="utf-8"))
    config = json.loads(args.config.read_text(encoding="utf-8"))
    records: dict[str, list[bytes]] = defaultdict(list)
    total = 0
    for source in config["sources"]:
        total += append_source(records, source, manifest)
    print(f"{len(config['sources'])} Quellen · {total:,} gekachelte Features · TVT2")
    if args.dry_run:
        return 0
    args.vectors.mkdir(parents=True, exist_ok=True)
    vector_manifest_path = args.vectors / "vector-manifest.json"
    vector_manifest = json.loads(vector_manifest_path.read_text(encoding="utf-8")) if vector_manifest_path.exists() else {}
    old_keys = set(vector_manifest.get("geoscienceTileKeys", []))
    for key in set(records) | old_keys:
        features = records.get(key, [])
        z, filename = key.split("/")
        path = args.vectors / f"z{z}" / f"{filename}.vector.z"
        path.parent.mkdir(parents=True, exist_ok=True)
        if path.exists():
            extent, buffer, line_count, place_count, payload = base_records(zlib.decompress(path.read_bytes()))
        else:
            extent, buffer, line_count, place_count, payload = EXTENT, BUFFER, 0, 0, b""
        if not features and line_count == 0 and place_count == 0:
            path.unlink(missing_ok=True)
            continue
        raw = TVT2_HEADER.pack(
            b"TVT2", 2, extent, buffer, line_count, place_count, len(features)
        ) + payload + b"".join(features)
        temporary = path.with_suffix(".z.tmp")
        temporary.write_bytes(zlib.compress(raw, args.compression))
        temporary.replace(path)
    vector_manifest["format"] = "TVT2"
    vector_manifest["formatVersion"] = 2
    vector_manifest["geoscienceSources"] = config["sources"]
    vector_manifest["geoscienceTileKeys"] = sorted(records)
    vector_manifest_path.write_text(json.dumps(vector_manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    names = {5: "Abbau & Bergbau", 6: "Kohlenwasserstoffe", 7: "Pipelines"}
    products = []
    for layer in sorted({int(source["layer"]) for source in config["sources"]}):
        products.append({
            "id": {5: "mining", 6: "hydrocarbons", 7: "pipelines"}[layer],
            "name": names[layer],
            "layer": layer,
            "sources": [
                {
                    "id": source["id"], "name": source["name"],
                    "license": source["license"], "url": source.get("url", ""),
                    "role": source.get("role", "Fachobjekte"),
                }
                for source in config["sources"] if int(source["layer"]) == layer
            ],
        })
    manifest["geoscienceVectors"] = products
    temporary_manifest = args.manifest.with_suffix(".json.tmp")
    temporary_manifest.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    temporary_manifest.replace(args.manifest)
    print("TVT2-Kacheln vollständig.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
