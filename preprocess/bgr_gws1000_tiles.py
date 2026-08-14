#!/usr/bin/env python3
"""Build TopoExplorer tiles from the official BGR GWS1000_250 raster."""

from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
import warnings
import zipfile
import zlib
from pathlib import Path

import numpy as np
import rasterio
from rasterio.enums import Resampling
from rasterio.shutil import copy as rio_copy
from rasterio.transform import Affine
from rasterio.vrt import WarpedVRT

warnings.filterwarnings(
    "ignore",
    message="Setting the shape on a NumPy array has been deprecated.*",
    category=DeprecationWarning,
)

DOWNLOAD_URL = "https://download.bgr.de/bgr/boden/GWS1000/geotiff/GWS1000_250.zip"
METADATA_URL = "https://gdk.gdi-de.org/geonetwork/srv/api/records/33b088ba-49e9-4186-a9ef-80dee2f92586"
ARCHIVE_SHA256 = "8d71cd3725d0929044f37ba6892a2c4c377e8056bb076acec160c6af61a7a6e6"
SOURCE_LEVEL = 4
TILE_SIZE = 512

# App class id, source code, official BGR legend label, color, legend group.
CLASSES = [
    (0, None, "Keine Daten", "#000000", "Grundlage"),
    (1, 1, "GWS 1 · 0–<4 dm", "#0080A6", "Grundwasserbeeinflusst"),
    (2, 2, "GWS 2 · 4–<8 dm", "#40BFCC", "Grundwasserbeeinflusst"),
    (3, 3, "GWS 3 · 8–<13 dm", "#B3E6FF", "Grundwasserbeeinflusst"),
    (4, 4, "GWS 4 · 13–<16 dm", "#CCFF66", "Grundwasserbeeinflusst"),
    (6, 6, "GWS 6 · ≥20 dm", "#FFE666", "Grundwasserfern"),
]


def arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Amtliche BGR-GWS1000_250-Kacheln erzeugen")
    parser.add_argument("--manifest", type=Path, default=Path("MapData/Germany/manifest.json"))
    parser.add_argument(
        "--source", type=Path,
        default=Path("Data/Raw/Geoscience/BGR/GWS1000/GWS1000_250.tif"),
    )
    parser.add_argument("--compression", type=int, choices=range(1, 10), default=6)
    parser.add_argument("--force-download", action="store_true")
    return parser.parse_args()


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        while chunk := source.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def ensure_source(path: Path, force: bool) -> None:
    if path.exists() and not force:
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    archive = path.parent / "GWS1000_250.zip"
    temporary = archive.with_suffix(".zip.download")
    subprocess.run(
        ["curl", "-sL", "--fail", "--max-time", "180", "-o", str(temporary), DOWNLOAD_URL],
        check=True,
    )
    if sha256(temporary) != ARCHIVE_SHA256:
        temporary.unlink(missing_ok=True)
        raise SystemExit("Prüfsumme des GWS1000_250-Archivs stimmt nicht")
    temporary.replace(archive)
    with zipfile.ZipFile(archive) as packed:
        with packed.open("GWS1000_250.tif") as source, path.open("wb") as target:
            while chunk := source.read(1024 * 1024):
                target.write(chunk)


def remap(source: np.ndarray) -> np.ndarray:
    result = np.zeros(source.shape, dtype=np.uint8)
    for class_id, source_code, *_ in CLASSES[1:]:
        result[source == source_code] = class_id
    return result


def write_tile(path: Path, values: np.ndarray, compression: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_bytes(zlib.compress(np.ascontiguousarray(values).tobytes(), compression))
    temporary.replace(path)


def write_level(values: np.ndarray, level: dict, output: Path, compression: int) -> None:
    directory = output / f"z{level['z']}"
    for tile_y in range(level["tilesY"]):
        for tile_x in range(level["tilesX"]):
            tile = np.zeros((TILE_SIZE, TILE_SIZE), dtype=np.uint8)
            start_x, start_y = tile_x * TILE_SIZE, tile_y * TILE_SIZE
            part = values[
                start_y:min(start_y + TILE_SIZE, values.shape[0]),
                start_x:min(start_x + TILE_SIZE, values.shape[1]),
            ]
            tile[:part.shape[0], :part.shape[1]] = part
            write_tile(directory / f"{tile_x}_{tile_y}.groundwater.z", tile, compression)
            write_tile(
                directory / f"{tile_x}_{tile_y}.groundwater.quality.z",
                (tile != 0).astype(np.uint8), compression,
            )


def downsample_mode(values: np.ndarray) -> np.ndarray:
    height, width = values.shape
    padded = np.pad(values, ((0, height % 2), (0, width % 2)), constant_values=0)
    samples = [padded[y::2, x::2] for y in range(2) for x in range(2)]
    best = np.zeros(samples[0].shape, dtype=np.uint8)
    best_count = np.zeros(samples[0].shape, dtype=np.uint8)
    for class_id, *_ in CLASSES:
        count = sum(sample == class_id for sample in samples)
        replace = count > best_count
        best[replace] = class_id
        best_count[replace] = count[replace]
    return best


def source_level(source: Path, manifest: dict, level: dict) -> np.ndarray:
    transform = Affine(
        level["resolution"], 0, manifest["bounds"][0],
        0, -level["resolution"], manifest["bounds"][3],
    )
    result = np.zeros((level["height"], level["width"]), dtype=np.uint8)
    with rasterio.open(source) as dataset:
        with WarpedVRT(
            dataset, crs=manifest["crs"], transform=transform,
            width=level["width"], height=level["height"],
            resampling=Resampling.nearest, src_nodata=dataset.nodata, nodata=127,
        ) as vrt:
            for _, window in vrt.block_windows(1):
                values = vrt.read(1, window=window)
                rows = slice(int(window.row_off), int(window.row_off + window.height))
                columns = slice(int(window.col_off), int(window.col_off + window.width))
                result[rows, columns] = remap(values)
    return result


def write_master(values: np.ndarray, level: dict, manifest: dict, output: Path) -> None:
    directory = output / "Masters/Geoscience"
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / "groundwater-gws1000-160m.cog.tif"
    temporary = path.with_suffix(".tmp.tif")
    profile = {
        "driver": "GTiff", "width": values.shape[1], "height": values.shape[0],
        "count": 1, "dtype": "uint8", "crs": manifest["crs"], "nodata": 0,
        "transform": Affine(
            level["resolution"], 0, manifest["bounds"][0],
            0, -level["resolution"], manifest["bounds"][3],
        ),
        "tiled": True, "blockxsize": TILE_SIZE, "blockysize": TILE_SIZE,
        "compress": "DEFLATE",
    }
    with rasterio.open(temporary, "w", **profile) as dataset:
        dataset.write(values, 1)
        dataset.update_tags(
            SOURCE="GWS1000_250 V1.0, (c) BGR, Hannover, 2015",
            SOURCE_SCALE="1:1000000",
            SOURCE_GRID="250 m; App-Kachelraster 160 m ohne zusätzliche Fachgenauigkeit",
        )
    rio_copy(
        temporary, path, driver="COG", compress="DEFLATE", blocksize=TILE_SIZE,
        overview_resampling="MODE",
    )
    temporary.unlink()


def update_manifest(path: Path, manifest: dict) -> None:
    product = {
        "id": "groundwater-level",
        "name": "Grundwasserflurabstand",
        "suffix": "groundwater.z",
        "qualitySuffix": "groundwater.quality.z",
        "classes": [
            {"id": item[0], "name": item[2], "defaultColor": item[3], "group": item[4]}
            for item in CLASSES
        ],
        "sources": [{
            "id": "bgr-gws1000-250-v1",
            "name": "BGR GWS1000_250 V1.0",
            "license": "Datenquelle: GWS1000_250 V1.0, (c) BGR, Hannover, 2015",
            "url": METADATA_URL,
            "scale": 1_000_000,
            "role": "Bundesweite Grundwasserstufen, 250-m-Raster",
        }],
    }
    products = [
        item for item in manifest.get("thematicRasters", [])
        if item.get("id") != product["id"]
    ]
    products.append(product)
    manifest["thematicRasters"] = products
    temporary = path.with_suffix(".json.tmp")
    temporary.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    temporary.replace(path)


def main() -> int:
    args = arguments()
    ensure_source(args.source, args.force_download)
    manifest = json.loads(args.manifest.read_text(encoding="utf-8"))
    if manifest["crs"] != "EPSG:3035":
        raise SystemExit("Manifest muss EPSG:3035 verwenden")
    level = next(item for item in manifest["levels"] if item["z"] == SOURCE_LEVEL)
    output = args.manifest.parent
    mosaic = source_level(args.source, manifest, level)
    write_level(mosaic, level, output, args.compression)
    current = mosaic
    for zoom in range(SOURCE_LEVEL - 1, -1, -1):
        current = downsample_mode(current)
        target = next(item for item in manifest["levels"] if item["z"] == zoom)
        current = current[:target["height"], :target["width"]]
        write_level(current, target, output, args.compression)
    write_master(mosaic, level, manifest, output)
    update_manifest(args.manifest, manifest)
    print(
        f"GWS1000_250: {np.count_nonzero(mosaic) / mosaic.size:.1%} Rasterabdeckung · "
        f"5 Klassen · z0–z{SOURCE_LEVEL}; feinere Zoomstufen nutzen Elternkacheln."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
