#!/usr/bin/env python3
"""Convert a census GeoTIFF into compact, non-visual analysis tiles."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import zlib
from datetime import datetime, timezone
from pathlib import Path

import numpy as np
import rasterio
from rasterio.windows import Window


TARGET_CRS = "EPSG:3035"
TILE_SIZE = 512
FORMAT_VERSION = 1


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Zensus-Bevölkerung für Flächenanalysen kacheln")
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--map-data", type=Path, default=Path("MapData/Germany"))
    parser.add_argument("--compression", type=int, choices=range(1, 10), default=6)
    return parser.parse_args()


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        while chunk := source.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def write_tile(path: Path, values: np.ndarray, compression: int) -> None:
    packed = zlib.compress(values.astype("<u2", copy=False).tobytes(order="C"), compression)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_bytes(packed)
    temporary.replace(path)


def main() -> None:
    args = parse_args()
    if not args.source.is_file():
        raise SystemExit(f"Bevölkerungsraster fehlt: {args.source}")
    manifest_path = args.map_data / "manifest.json"
    if not manifest_path.is_file():
        raise SystemExit(f"Kartenmanifest fehlt: {manifest_path}")
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if manifest.get("crs") != TARGET_CRS:
        raise SystemExit(f"Nicht unterstütztes Karten-KBS: {manifest.get('crs')}")

    output = args.map_data / "Analysis"
    output.mkdir(parents=True, exist_ok=True)
    incomplete = output / ".population-incomplete"
    incomplete.write_text("in Arbeit\n", encoding="utf-8")

    with rasterio.open(args.source) as dataset:
        if dataset.crs is None or dataset.crs.to_epsg() != 3035:
            raise SystemExit(f"Bevölkerungsraster muss EPSG:3035 sein, ist aber {dataset.crs}")
        transform = dataset.transform
        if transform.b != 0 or transform.d != 0 or transform.a <= 0 or transform.e >= 0:
            raise SystemExit("Gedrehte oder gespiegelte Bevölkerungsraster werden nicht unterstützt.")
        if not math.isclose(transform.a, -transform.e, rel_tol=0, abs_tol=1e-6):
            raise SystemExit("Bevölkerungszellen müssen quadratisch sein.")

        tiles_x = math.ceil(dataset.width / TILE_SIZE)
        tiles_y = math.ceil(dataset.height / TILE_SIZE)
        total_population = 0
        populated_cells = 0
        tile_sums: dict[str, int] = {}
        for tile_y in range(tiles_y):
            for tile_x in range(tiles_x):
                x = tile_x * TILE_SIZE
                y = tile_y * TILE_SIZE
                width = min(TILE_SIZE, dataset.width - x)
                height = min(TILE_SIZE, dataset.height - y)
                source = dataset.read(1, window=Window(x, y, width, height), masked=False)
                valid = np.isfinite(source) & (source >= 0)
                rounded = np.zeros(source.shape, dtype=np.uint16)
                if np.any(valid):
                    maximum = float(np.max(source[valid]))
                    if maximum > np.iinfo(np.uint16).max:
                        raise SystemExit(f"Einwohnerwert {maximum} überschreitet UInt16.")
                    rounded[valid] = np.rint(source[valid]).astype(np.uint16)
                    tile_population = int(rounded.sum(dtype=np.uint64))
                    total_population += tile_population
                    populated_cells += int(np.count_nonzero(rounded))
                else:
                    tile_population = 0
                tile_sums[f"{tile_x}_{tile_y}"] = tile_population
                tile = np.zeros((TILE_SIZE, TILE_SIZE), dtype=np.uint16)
                tile[:height, :width] = rounded
                write_tile(
                    output / f"{tile_x}_{tile_y}.population.u16.z",
                    tile,
                    args.compression,
                )

        metadata = {
            "version": FORMAT_VERSION,
            "source": "Zensus Bevölkerung (100-m-Gitter)",
            "sourceFile": args.source.name,
            "sourceSHA256": sha256(args.source),
            "crs": TARGET_CRS,
            "bounds": [
                dataset.bounds.left,
                dataset.bounds.bottom,
                dataset.bounds.right,
                dataset.bounds.top,
            ],
            "resolution": transform.a,
            "width": dataset.width,
            "height": dataset.height,
            "tileSize": TILE_SIZE,
            "tilesX": tiles_x,
            "tilesY": tiles_y,
            "suffix": "population.u16.z",
            "encoding": "little-endian uint16, zlib; 0 = keine ausgewiesene Bevölkerung",
            "totalPopulation": total_population,
            "populatedCells": populated_cells,
            "tileSums": tile_sums,
            "generatedAt": datetime.now(timezone.utc).isoformat(),
        }
        temporary = output / "population.json.tmp"
        temporary.write_text(json.dumps(metadata, indent=2) + "\n", encoding="utf-8")
        temporary.replace(output / "population.json")

    incomplete.unlink(missing_ok=True)
    print(
        f"Bevölkerungsanalyse: {tiles_x * tiles_y} Kacheln, "
        f"{total_population:,} Einwohner, {populated_cells:,} belegte Zellen"
    )


if __name__ == "__main__":
    main()
