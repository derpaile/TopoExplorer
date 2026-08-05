#!/usr/bin/env python3
"""Add the 2020 land-cover raster to an existing TopoExplorer pyramid."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import time
import zlib
from pathlib import Path

import numpy as np
import rasterio
from rasterio.enums import Resampling
from rasterio.transform import Affine
from rasterio.vrt import WarpedVRT

from germany_tiles import TILE_SIZE, read_padded, write_compressed


YEAR = 2020
SUFFIX = "land2020.z"
CLASS_MAP = {10: 4, 20: 6, 30: 7, 40: 1, 50: 2, 60: 3, 255: 0}
PIPELINE_VERSION = 2


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Landbedeckung 2020 ergänzen")
    parser.add_argument(
        "--source",
        type=Path,
        default=Path("Data/Raw/LandCover/classification_map_germany_2020_v02.tif"),
    )
    parser.add_argument("--output", type=Path, default=Path("MapData/Germany"))
    parser.add_argument("--force", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    return parser.parse_args()


def map_classes(values: np.ndarray) -> np.ndarray:
    lookup = np.zeros(256, dtype=np.uint8)
    for source, target in CLASS_MAP.items():
        lookup[source] = target
    unknown = np.setdiff1d(np.unique(values), np.fromiter(CLASS_MAP, dtype=np.uint8))
    if unknown.size:
        raise RuntimeError(f"Unbekannte 2020-Klassen: {unknown.tolist()}")
    return np.ascontiguousarray(lookup[values])


def read_tile(path: Path) -> np.ndarray:
    payload = zlib.decompress(path.read_bytes())
    if len(payload) != TILE_SIZE * TILE_SIZE:
        raise RuntimeError(f"Defekte Landkachel: {path}")
    return np.frombuffer(payload, dtype=np.uint8).reshape(TILE_SIZE, TILE_SIZE)


def derive_tile(output: Path, child_z: int, tile_x: int, tile_y: int) -> np.ndarray:
    children = np.zeros((TILE_SIZE * 2, TILE_SIZE * 2), dtype=np.uint8)
    for offset_y in range(2):
        for offset_x in range(2):
            path = output / f"z{child_z}" / f"{tile_x * 2 + offset_x}_{tile_y * 2 + offset_y}.{SUFFIX}"
            if path.exists():
                children[
                    offset_y * TILE_SIZE : (offset_y + 1) * TILE_SIZE,
                    offset_x * TILE_SIZE : (offset_x + 1) * TILE_SIZE,
                ] = read_tile(path)
    return np.ascontiguousarray(children[1::2, 1::2])


def stable_grid_hash(manifest: dict) -> str:
    grid = {key: manifest[key] for key in ("crs", "bounds", "tileSize", "levels")}
    payload = json.dumps(grid, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return hashlib.sha256(payload).hexdigest()


def source_signature(source: Path, manifest: dict) -> dict:
    stat = source.stat()
    return {
        "pipelineVersion": PIPELINE_VERSION,
        "pipelineSHA256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        "gridSHA256": stable_grid_hash(manifest),
        str(source): {"size": stat.st_size, "modifiedNs": stat.st_mtime_ns},
    }


def tiles_complete(output: Path, levels: list[dict]) -> bool:
    return all(
        (output / f"z{int(level['z'])}" / f"{tile_x}_{tile_y}.{SUFFIX}").is_file()
        for level in levels
        for tile_y in range(int(level["tilesY"]))
        for tile_x in range(int(level["tilesX"]))
    )


def main() -> int:
    args = parse_args()
    if not args.source.is_file():
        raise SystemExit(f"Quelldatei fehlt: {args.source}")
    output = args.output.resolve()
    manifest_path = output / "manifest.json"
    if not manifest_path.is_file():
        raise SystemExit("Zuerst die 2015-/Relief-Kacheln erzeugen.")
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    levels = manifest["levels"]
    signature = source_signature(args.source, manifest)
    total = sum(int(level["tilesX"]) * int(level["tilesY"]) for level in levels)
    print(f"Landbedeckung {YEAR}: {len(levels)} Zoomstufen, {total:,} Kacheln")
    if args.dry_run:
        return 0

    if (
        not args.force
        and manifest.get("landcover2020Signature") == signature
        and not (output / f".incomplete-landcover-{YEAR}").exists()
        and tiles_complete(output, levels)
    ):
        print(f"Bereits vollständig: {output}")
        return 0

    if args.force or manifest.get("landcover2020Signature") != signature:
        if not args.force:
            print("Quelle, Grundraster oder Pipeline wurde verändert; 2020-Kacheln werden neu aufgebaut.")
        for path in output.glob(f"z*/*.{SUFFIX}"):
            path.unlink()
    incomplete = output / f".incomplete-landcover-{YEAR}"
    incomplete.write_text("Kachelerzeugung läuft\n", encoding="utf-8")
    compression = 6
    started = time.time()
    completed = 0
    left, bottom, right, top = map(float, manifest["bounds"])
    finest = levels[-1]
    finest_z = int(finest["z"])
    finest_transform = Affine(float(finest["resolution"]), 0, left, 0, -float(finest["resolution"]), top)

    with rasterio.open(args.source) as source, WarpedVRT(
        source,
        crs=manifest["crs"],
        transform=finest_transform,
        width=int(finest["width"]),
        height=int(finest["height"]),
        resampling=Resampling.nearest,
        nodata=255,
        dtype="uint8",
    ) as vrt:
        directory = output / f"z{finest_z}"
        for tile_y in range(int(finest["tilesY"])):
            for tile_x in range(int(finest["tilesX"])):
                path = directory / f"{tile_x}_{tile_y}.{SUFFIX}"
                if not path.exists():
                    values = read_padded(
                        vrt,
                        tile_x * TILE_SIZE,
                        tile_y * TILE_SIZE,
                        TILE_SIZE,
                        TILE_SIZE,
                        255,
                    ).astype(np.uint8, copy=False)
                    mapped = map_classes(values)
                    write_compressed(path, mapped.tobytes(order="C"), compression)
                completed += 1

    for level in reversed(levels[:-1]):
        z = int(level["z"])
        directory = output / f"z{z}"
        for tile_y in range(int(level["tilesY"])):
            for tile_x in range(int(level["tilesX"])):
                path = directory / f"{tile_x}_{tile_y}.{SUFFIX}"
                if not path.exists():
                    mapped = derive_tile(output, z + 1, tile_x, tile_y)
                    write_compressed(path, mapped.tobytes(order="C"), compression)
                completed += 1

    manifest["landcoverYears"] = [
        {"year": 2015, "suffix": "land.z"},
        {"year": YEAR, "suffix": SUFFIX},
    ]
    source_info = manifest.setdefault("source", {})
    source_info["landcover2020"] = str(args.source)
    manifest["landcover2020GeneratedAt"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    manifest["landcover2020Signature"] = signature
    temporary = manifest_path.with_suffix(".json.tmp")
    temporary.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    temporary.replace(manifest_path)
    incomplete.unlink(missing_ok=True)
    print(f"Fertig: {completed:,} Kacheln in {(time.time() - started) / 60:.1f} min")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
