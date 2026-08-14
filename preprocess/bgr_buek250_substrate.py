#!/usr/bin/env python3
"""Rasterize BÜK250 V6.0 + BÜK250-DB V1.0 to an understandable substrate layer."""

from __future__ import annotations

import argparse
import json
import sqlite3
import struct
import zlib
from pathlib import Path

import numpy as np
import rasterio
from rasterio.features import rasterize
from rasterio.shutil import copy as rio_copy
from rasterio.transform import Affine
from rasterio.warp import transform_geom

SOURCE_LEVEL = 5
TILE_SIZE = 512

CLASSES = [
    (0, "Keine Daten", "#000000", "Grundlage"),
    (1, "Sand", "#E8D59A", "Lockersediment"),
    (2, "Kies / Schotter", "#C5A66A", "Lockersediment"),
    (3, "Schluff", "#CDBA8D", "Lockersediment"),
    (4, "Lehm", "#AF8B67", "Lockersediment"),
    (5, "Ton", "#8E6B62", "Lockersediment"),
    (6, "Löss", "#E5C97F", "Äolisches Sediment"),
    (7, "Lösslehm", "#C7A96C", "Äolisches Sediment"),
    (8, "Geschiebelehm / -mergel", "#9D927D", "Glaziales Sediment"),
    (9, "Auenablagerungen", "#A9B985", "Flusssediment"),
    (10, "Torf", "#57483B", "Organisches Sediment"),
    (11, "Organische Sedimente", "#75614C", "Organisches Sediment"),
    (12, "Verwitterungslehm", "#A87859", "Verwitterungsdecke"),
    (13, "Schutt / Hangsediment", "#8C8275", "Hangsediment"),
    (14, "Fluss- / Terrassenablagerungen", "#B9AA78", "Flusssediment"),
    (15, "Glaziale Sedimente", "#A8A291", "Glaziales Sediment"),
    (16, "Karbonat- / Mergelverwitterung", "#91A7A0", "Verwitterungsdecke"),
    (17, "Festgesteinszersatz", "#837871", "Verwitterungsdecke"),
    (18, "Künstliche Aufschüttung", "#777777", "Anthropogen"),
    (19, "Sonstiges Substrat", "#8B8977", "Sonstige"),
]


def arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="BÜK250-Substratkacheln erzeugen")
    parser.add_argument("--manifest", type=Path, default=Path("MapData/Germany/manifest.json"))
    parser.add_argument("--gpkg", type=Path, default=Path("Data/Raw/Geoscience/BGR/BUEK250/buek250_mgm_utm_v60.gpkg"))
    parser.add_argument("--database", type=Path, default=Path("Data/Raw/Geoscience/BGR/BUEK250/buek250_sachdatenbank_v10.sqlite"))
    parser.add_argument("--compression", type=int, choices=range(1, 10), default=6)
    return parser.parse_args()


def classify(text: str) -> int:
    value = (text or "").casefold().replace("/", " ")
    if any(word in value for word in ("aufschütt", "künst", "siedlung", "kippe")): return 18
    if "lösslehm" in value or "lößlehm" in value: return 7
    if "löss" in value or "löß" in value: return 6
    if "geschiebe" in value: return 8
    if any(word in value for word in ("auensediment", "auenlehm", "auenschluff", "auenton", "auensand")): return 9
    if any(word in value for word in ("torf", "hochmoor", "niedermoor")): return 10
    if any(word in value for word in ("mudde", "organisch")): return 11
    if any(word in value for word in ("hangschutt", "hangsediment", "schutt", "kolluv", "fließerde")): return 13
    if any(word in value for word in ("verwitterungslehm", "zersatzlehm")): return 12
    if any(word in value for word in ("kalkstein", "dolomit", "mergel")): return 16
    if any(word in value for word in ("zersatz", "festgestein", "sandstein", "tonstein", "schiefer", "granit", "gneis", "basalt")): return 17
    if any(word in value for word in ("glazial", "moräne", "moränen", "gletscher")): return 15
    if any(word in value for word in ("terrassen", "fluss", "bach", "talablager")): return 14
    if "kies" in value or "schotter" in value: return 2
    if "sand" in value: return 1
    if "schluff" in value: return 3
    if "lehm" in value: return 4
    if "ton" in value: return 5
    return 19


def bag_by_gen(database: Path) -> dict[int, tuple[int, str]]:
    connection = sqlite3.connect(database)
    rows = connection.execute("""
        SELECT le.GEN_ID, bag.BAG_FT_TXTK
        FROM buek250_Legendeneinheit__v10_tbl le
        JOIN buek250_GL_Einheit_v10_tbl gl ON gl.GL_ID = le.GL_ID
        JOIN buek250_GL_BAGFlaechentyp_v10_tbl bag ON bag.BAG_FT_ID = gl.BAG_FT_ID
    """).fetchall()
    connection.close()
    return {int(gen_id): (classify(text), text) for gen_id, text in rows}


def gpkg_wkb(blob: bytes) -> bytes:
    if blob[:2] != b"GP":
        raise ValueError("Ungültige GeoPackage-Geometrie")
    envelope = (blob[3] >> 1) & 0x07
    doubles = {0: 0, 1: 4, 2: 6, 3: 6, 4: 8}.get(envelope)
    if doubles is None:
        raise ValueError("Unbekannter GeoPackage-Envelope")
    return blob[8 + doubles * 8:]


def read_uint(data: bytes, offset: int, endian: str) -> tuple[int, int]:
    return struct.unpack_from(endian + "I", data, offset)[0], offset + 4


def read_geometry(data: bytes, offset: int = 0) -> tuple[dict, int]:
    little = data[offset] == 1
    endian = "<" if little else ">"
    geometry_type, offset = read_uint(data, offset + 1, endian)
    base_type = geometry_type % 1000
    dimensions = 3 if 1000 <= geometry_type < 2000 else 2
    if base_type == 3:
        ring_count, offset = read_uint(data, offset, endian)
        rings = []
        for _ in range(ring_count):
            point_count, offset = read_uint(data, offset, endian)
            ring = []
            for _ in range(point_count):
                values = struct.unpack_from(endian + "d" * dimensions, data, offset)
                offset += dimensions * 8
                ring.append([values[0], values[1]])
            rings.append(ring)
        return {"type": "Polygon", "coordinates": rings}, offset
    if base_type == 6:
        count, offset = read_uint(data, offset, endian)
        polygons = []
        for _ in range(count):
            polygon, offset = read_geometry(data, offset)
            polygons.append(polygon["coordinates"])
        return {"type": "MultiPolygon", "coordinates": polygons}, offset
    raise ValueError(f"Nicht unterstützter WKB-Typ {geometry_type}")


def shapes(gpkg: Path, lookup: dict[int, tuple[int, str]]):
    connection = sqlite3.connect(gpkg)
    cursor = connection.execute("SELECT Shape, GEN_ID FROM buek250_mgm_utm_v60_poly")
    missing = set()
    for blob, gen_id in cursor:
        if gen_id is None:
            continue
        item = lookup.get(int(gen_id))
        if item is None:
            missing.add(int(gen_id)); continue
        geometry, _ = read_geometry(gpkg_wkb(blob))
        yield transform_geom("EPSG:25832", "EPSG:3035", geometry, precision=1), item[0]
    connection.close()
    if missing:
        print(f"Warnung: {len(missing)} GEN_ID ohne Sachdatensatz")


def write_tile(path: Path, values: np.ndarray, compression: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_bytes(zlib.compress(np.ascontiguousarray(values).tobytes(), compression))
    temporary.replace(path)


def downsample_mode(values: np.ndarray, candidates: list[int]) -> np.ndarray:
    height, width = values.shape
    padded = np.pad(values, ((0, height % 2), (0, width % 2)), constant_values=0)
    samples = [padded[y::2, x::2] for y in range(2) for x in range(2)]
    best = np.zeros(samples[0].shape, dtype=np.uint8)
    best_count = np.zeros(samples[0].shape, dtype=np.uint8)
    for item in candidates:
        count = sum(sample == item for sample in samples)
        replace = count > best_count
        best[replace] = item
        best_count[replace] = count[replace]
    return best


def write_level(values: np.ndarray, level: dict, output: Path, compression: int) -> None:
    for tile_y in range(level["tilesY"]):
        for tile_x in range(level["tilesX"]):
            start_x, start_y = tile_x * TILE_SIZE, tile_y * TILE_SIZE
            end_x = min(start_x + TILE_SIZE, values.shape[1])
            end_y = min(start_y + TILE_SIZE, values.shape[0])
            tile = np.zeros((TILE_SIZE, TILE_SIZE), dtype=np.uint8)
            tile[:end_y - start_y, :end_x - start_x] = values[start_y:end_y, start_x:end_x]
            directory = output / f"z{level['z']}"
            write_tile(directory / f"{tile_x}_{tile_y}.substrate.z", tile, compression)
            write_tile(directory / f"{tile_x}_{tile_y}.substrate.quality.z", (tile != 0).astype(np.uint8), compression)


def write_master(values: np.ndarray, level: dict, manifest: dict, output: Path) -> None:
    directory = output / "Masters/Geoscience"
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / "substrate-buek250-80m.cog.tif"
    temporary = path.with_suffix(".tmp.tif")
    transform = Affine(level["resolution"], 0, manifest["bounds"][0], 0, -level["resolution"], manifest["bounds"][3])
    with rasterio.open(temporary, "w", driver="GTiff", width=values.shape[1], height=values.shape[0], count=1, dtype="uint8", crs=manifest["crs"], nodata=0, transform=transform, tiled=True, blockxsize=512, blockysize=512, compress="DEFLATE") as dataset:
        dataset.write(values, 1)
        dataset.update_tags(SOURCE="BÜK250 V6.0 + BÜK250-DB V1.0, © BGR 2024", SOURCE_SCALE="1:250000", GRID_RESOLUTION="80 m; keine fachliche 80-m-Genauigkeit")
    rio_copy(temporary, path, driver="COG", compress="DEFLATE", blocksize=512, overview_resampling="MODE")
    temporary.unlink()


def update_manifest(path: Path, manifest: dict) -> None:
    product = {
        "id": "substrate", "name": "Oberflächensubstrat",
        "suffix": "substrate.z", "qualitySuffix": "substrate.quality.z",
        "classes": [{"id": item[0], "name": item[1], "defaultColor": item[2], "group": item[3]} for item in CLASSES],
        "sources": [{
            "id": "bgr-buek250", "name": "BGR BÜK250 V6.0 / Datenbank V1.0",
            "license": "© BGR 2024", "url": "https://www.bgr.bund.de/DE/Themen/Boden/Projekte/Informationsgrundlagen-laufend/BUEK250/BUEK250.html",
            "scale": 250000, "role": "Bundesweiter Fallback",
        }],
    }
    products = [item for item in manifest.get("thematicRasters", []) if item.get("id") != "substrate"]
    products.insert(0, product)
    manifest["thematicRasters"] = products
    temporary = path.with_suffix(".json.tmp")
    temporary.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    temporary.replace(path)


def main() -> int:
    args = arguments()
    manifest = json.loads(args.manifest.read_text(encoding="utf-8"))
    level = next(item for item in manifest["levels"] if item["z"] == SOURCE_LEVEL)
    transform = Affine(level["resolution"], 0, manifest["bounds"][0], 0, -level["resolution"], manifest["bounds"][3])
    lookup = bag_by_gen(args.database)
    print(f"BÜK250: {len(lookup)} Legendeneinheiten klassifiziert")
    values = rasterize(shapes(args.gpkg, lookup), out_shape=(level["height"], level["width"]), transform=transform, fill=0, dtype="uint8")
    output = args.manifest.parent
    write_level(values, level, output, args.compression)
    current = values
    for zoom in range(SOURCE_LEVEL - 1, -1, -1):
        current = downsample_mode(current, [item[0] for item in CLASSES])
        target = next(item for item in manifest["levels"] if item["z"] == zoom)
        current = current[:target["height"], :target["width"]]
        write_level(current, target, output, args.compression)
    write_master(values, level, manifest, output)
    update_manifest(args.manifest, manifest)
    print(f"Fertig: {np.count_nonzero(values) / values.size:.1%} Substratabdeckung · z0–z{SOURCE_LEVEL}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
