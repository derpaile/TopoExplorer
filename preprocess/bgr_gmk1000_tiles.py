#!/usr/bin/env python3
"""Build TopoExplorer tiles from the official BGR GMK1000R raster."""

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
from rasterio.windows import Window

warnings.filterwarnings(
    "ignore",
    message="Setting the shape on a NumPy array has been deprecated.*",
    category=DeprecationWarning,
)


DOWNLOAD_URL = "https://download.bgr.de/bgr/Boden/GMK1000/geotiff/gmk1000_250.zip"
METADATA_URL = "https://numis.niedersachsen.de/trefferanzeige?docuuid=60ab5e4e-9493-44b0-9cae-d9ce603de742"
ARCHIVE_SHA256 = "a854d04be3936bb6193dc8bee95589553203bd81ff6174c23f14ea7707a03551"
SOURCE_LEVEL = 4  # 160-m App grid; source information remains the official 250-m raster.
TILE_SIZE = 512

# App class id, source code, official BGR legend label, color, legend group.
CLASSES = [
    (0, None, "Keine Daten", "#000000", "Grundlage"),
    (1, 111, "Tiefenbereich mit sehr hoher Bodenfeuchte", "#00008A", "Tiefenbereiche"),
    (2, 112, "Tiefenbereich mit hoher Bodenfeuchte", "#0000CC", "Tiefenbereiche"),
    (3, 113, "Tiefenbereich mit mittlerer Bodenfeuchte", "#4040FE", "Tiefenbereiche"),
    (4, 114, "Tiefenbereich mit geringer Bodenfeuchte", "#6161FE", "Tiefenbereiche"),
    (5, 115, "Tiefenbereich mit sehr geringer Bodenfeuchte", "#9393FE", "Tiefenbereiche"),
    (6, 116, "Mittel geneigter Tiefenbereich", "#BCBCFE", "Tiefenbereiche"),
    (7, 1011, "Sehr gering geneigter Unterhang", "#FEFEAB", "Norddeutsches Tiefland"),
    (8, 1012, "Gering geneigter Unterhang", "#FEE58A", "Norddeutsches Tiefland"),
    (9, 1021, "Mittel geneigter Mittelhang", "#00DD00", "Norddeutsches Tiefland"),
    (10, 1022, "Mittel geneigter Oberhang", "#00AB00", "Norddeutsches Tiefland"),
    (11, 2011, "Gering bis mäßig geneigter Unterhang", "#FEFEAB", "Alpenvorland"),
    (12, 2012, "Mäßig geneigter Unterhang", "#FEE58A", "Alpenvorland"),
    (13, 2021, "Mäßig geneigter Mittelhang", "#00DD00", "Alpenvorland"),
    (14, 2022, "Mäßig geneigter Oberhang", "#00AB00", "Alpenvorland"),
    (15, 3211, "Sehr gering geneigter Hang", "#FEFE61", "Bergland"),
    (16, 3212, "Gering geneigter Hang", "#FECC00", "Bergland"),
    (17, 3213, "Mäßig geneigter Hang", "#FE8A00", "Bergland"),
    (18, 3214, "Stark geneigter Hang", "#FE0000", "Bergland"),
    (19, 3290, "Sehr gering bis gering geneigter Oberhang", "#9B9B61", "Bergland"),
    (20, 3311, "Scheitelbereich in Hochlagen der Mittelgebirge", "#CCCCCC", "Bergland"),
    (21, 3312, "Scheitelbereich der Mittelgebirge", "#939393", "Bergland"),
    (22, 3313, "Scheitelbereich von Hügeln", "#616161", "Bergland"),
    (23, 4211, "Stark geneigter Hang", "#DC3030", "Alpen"),
    (24, 4212, "Sehr stark geneigter Hang", "#B30000", "Alpen"),
    (25, 4310, "Scheitelbereich", "#494949", "Alpen"),
]


def arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Amtliche BGR-GMK1000R-Kacheln erzeugen")
    parser.add_argument("--manifest", type=Path, default=Path("MapData/Germany/manifest.json"))
    parser.add_argument(
        "--source", type=Path,
        default=Path("Data/Raw/Geoscience/BGR/GMK1000/gmk1000_250.tif"),
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
    archive = path.parent / "gmk1000_250.zip"
    temporary = archive.with_suffix(".zip.download")
    subprocess.run(
        ["curl", "-sL", "--fail", "--max-time", "180", "-o", str(temporary), DOWNLOAD_URL],
        check=True,
    )
    if sha256(temporary) != ARCHIVE_SHA256:
        temporary.unlink(missing_ok=True)
        raise SystemExit("Prüfsumme des GMK1000R-Archivs stimmt nicht")
    temporary.replace(archive)
    with zipfile.ZipFile(archive) as packed:
        with packed.open("gmk1000_250.tif") as source, path.open("wb") as target:
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
            write_tile(directory / f"{tile_x}_{tile_y}.geomorphography.z", tile, compression)
            write_tile(
                directory / f"{tile_x}_{tile_y}.geomorphography.quality.z",
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
            resampling=Resampling.nearest, src_nodata=dataset.nodata, nodata=32767,
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
    path = directory / "geomorphography-gmk1000r-160m.cog.tif"
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
            SOURCE="GMK1000R V2.0, (C) BGR, Hannover, 2006",
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
        "id": "geomorphography",
        "name": "Geomorphographische Einheiten",
        "suffix": "geomorphography.z",
        "qualitySuffix": "geomorphography.quality.z",
        "classes": [
            {"id": item[0], "name": item[2], "defaultColor": item[3], "group": item[4]}
            for item in CLASSES
        ],
        "sources": [{
            "id": "bgr-gmk1000r-v2",
            "name": "BGR GMK1000R V2.0",
            "license": "Datenquelle: GMK1000R V2.0, (C) BGR, Hannover, 2006",
            "url": METADATA_URL,
            "scale": 1_000_000,
            "role": "Bundesweite Reliefklassifikation, 250-m-Raster",
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
        f"GMK1000R: {np.count_nonzero(mosaic) / mosaic.size:.1%} Rasterabdeckung · "
        f"25 Klassen · z0–z{SOURCE_LEVEL}; feinere Zoomstufen nutzen Elternkacheln."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
