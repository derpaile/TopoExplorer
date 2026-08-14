#!/usr/bin/env python3
"""Build real TopoExplorer geology tiles from the official BGR GÜK250 service."""

from __future__ import annotations

import argparse
import json
import subprocess
import time
import warnings
import zlib
from concurrent.futures import ThreadPoolExecutor, as_completed
from pathlib import Path
from urllib.parse import urlencode

import numpy as np
import rasterio
from rasterio.io import MemoryFile
from rasterio.shutil import copy as rio_copy
from rasterio.transform import Affine
from rasterio.errors import NotGeoreferencedWarning

warnings.filterwarnings("ignore", category=NotGeoreferencedWarning)


SERVICE = "https://services.bgr.de/arcgis/rest/services/geologie/guek250/MapServer"
SOURCE_LEVEL = 5  # 80 m grid: honest for 1:250k and compact; parents serve deeper zooms.
TILE_SIZE = 512

CLASSES = [
    (0, "Keine Daten", "#000000", "Grundlage"),
    (1, "Kalkstein / Dolomit", "#B8C8D2", "Sedimentgestein"),
    (2, "Mergel", "#AAB89A", "Sedimentgestein"),
    (3, "Sandstein / klastisches Festgestein", "#D39B68", "Sedimentgestein"),
    (4, "Ton- / Schluffstein", "#8E6D68", "Sedimentgestein"),
    (5, "Konglomerat / Brekzie", "#8A7968", "Sedimentgestein"),
    (6, "Schiefer / Meta-Sediment", "#5F6871", "Metamorphit"),
    (7, "Granit / Plutonit", "#D48B91", "Magmatit"),
    (8, "Basalt / Vulkanit", "#655A69", "Magmatit"),
    (9, "Gneis / hochgradiger Metamorphit", "#B98DA4", "Metamorphit"),
    (10, "Sonstige Metamorphite", "#987A9D", "Metamorphit"),
    (11, "Sand / Kies / Lockergestein", "#E7D59D", "Lockergestein"),
    (12, "Schluff / Ton / Diamikt", "#C4AA83", "Lockergestein"),
    (13, "Torf / Kohle / organisch", "#594A3E", "Organisch"),
    (14, "Salz- / Sulfatgestein", "#E4D7DE", "Salzgestein"),
    (15, "Sonstiges Festgestein", "#77736D", "Festgestein"),
]


def arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Amtliche BGR-GÜK250-Kacheln erzeugen")
    parser.add_argument("--manifest", type=Path, default=Path("MapData/Germany/manifest.json"))
    parser.add_argument("--workers", type=int, default=6)
    parser.add_argument("--compression", type=int, choices=range(1, 10), default=6)
    parser.add_argument("--force", action="store_true")
    return parser.parse_args()


def request_bytes(url: str, parameters: dict | None = None, attempts: int = 6) -> bytes:
    for attempt in range(attempts):
        try:
            command = ["curl", "-sL", "--fail", "--max-time", "90", "-A", "TopoExplorer/1.0"]
            if parameters is not None:
                command += ["--data", urlencode(parameters)]
            command.append(url)
            result = subprocess.run(command, check=True, capture_output=True).stdout
            if result:
                return result
        except Exception:
            if attempt + 1 == attempts:
                raise
            time.sleep(min(12, 1.5 ** attempt))
    raise RuntimeError(f"Leere Antwort: {url}")


def rgb(hex_color: str) -> list[int]:
    value = hex_color.removeprefix("#")
    return [int(value[index:index + 2], 16) for index in (0, 2, 4)]


def classify(abbreviation: str, description: str) -> int:
    first = abbreviation.replace("–", "-").split(",", 1)[0].split("-", 1)[0].split("/", 1)[0]
    if first in {"Pfl", "Ko", "Kost"}: return 13
    if first.startswith("lpel") or first in {"lDm", "lsc"}: return 12
    if first.startswith(("lpsa", "lpse", "lsk", "ls")): return 11
    if first.startswith(("Cst", "fsc")): return 1
    if first.startswith("SOst") or first.startswith("fss"): return 14
    if first.startswith("fpsa") or first.startswith("fsk") or first.startswith("fsi"): return 3
    if first.startswith("fpel"): return 4
    if first.startswith("fpse"): return 5
    if first.startswith(("fmts", "fmtb", "fmt", "fmg", "mmag")): return 7
    if first.startswith(("fmv", "fvp", "fvk", "vft", "lvp")): return 8
    if first.startswith("fuhs") or first == "Mig": return 9
    if first.startswith(("fus", "fu", "fut", "fub", "fuv", "fuh", "fum", "fun")): return 10
    if first in {"ft", "fk", "shl", "fui", "f"}: return 15
    lower = description.casefold()
    if "karbonat" in lower: return 1
    if "plutonit" in lower or "ganggestein" in lower: return 7
    if "vulkan" in lower or "pyroklast" in lower or "tuff" in lower: return 8
    if "metamorph" in lower or "meta-" in lower: return 10
    if "lockergestein" in lower: return 11
    if "festgestein" in lower: return 15
    return 0


def unique_values(layer: int) -> list[dict]:
    parameters = {
        "where": "1=1",
        "outFields": "gkart_legtxt_stat_kuerzel,gkart_legtxt_stat",
        "returnGeometry": "false",
        "returnDistinctValues": "true",
        "f": "json",
    }
    result = json.loads(request_bytes(f"{SERVICE}/{layer}/query", parameters))
    if result.get("error"):
        raise RuntimeError(result["error"])
    return [feature["attributes"] for feature in result.get("features", [])]


def symbol(class_id: int) -> dict:
    color = rgb(CLASSES[class_id][2]) + ([255] if class_id else [0])
    return {
        "type": "esriSFS", "style": "esriSFSSolid", "color": color,
        "outline": {"type": "esriSLS", "style": "esriSLSNull", "color": [0, 0, 0, 0], "width": 0},
    }


def dynamic_layer(layer: int, values: list[dict]) -> dict:
    infos = []
    for value in values:
        abbreviation = value.get("gkart_legtxt_stat_kuerzel") or ""
        description = value.get("gkart_legtxt_stat") or ""
        class_id = classify(abbreviation, description)
        infos.append({"value": abbreviation, "label": abbreviation, "symbol": symbol(class_id)})
    return {
        "id": layer,
        "source": {"type": "mapLayer", "mapLayerId": layer},
        "minScale": 0, "maxScale": 0,
        "drawingInfo": {
            "showLabels": False,
            "renderer": {
                "type": "uniqueValue", "field1": "gkart_legtxt_stat_kuerzel",
                "defaultSymbol": symbol(0), "uniqueValueInfos": infos,
            },
        },
    }


def export_tile(
    tile_x: int,
    tile_y: int,
    level: dict,
    bounds: list[float],
    dynamic_layers: list[dict],
) -> tuple[int, int, np.ndarray]:
    for attempt in range(5):
        try:
            return export_tile_once(tile_x, tile_y, level, bounds, dynamic_layers)
        except Exception:
            if attempt == 4:
                raise
            time.sleep(1.5 ** attempt)
    raise RuntimeError("Unerreichbar")


def export_tile_once(
    tile_x: int,
    tile_y: int,
    level: dict,
    bounds: list[float],
    dynamic_layers: list[dict],
) -> tuple[int, int, np.ndarray]:
    span = level["resolution"] * TILE_SIZE
    left = bounds[0] + tile_x * span
    top = bounds[3] - tile_y * span
    parameters = {
        "bbox": f"{left},{top - span},{left + span},{top}",
        "bboxSR": "3035", "imageSR": "3035", "size": f"{TILE_SIZE},{TILE_SIZE}",
        "format": "png32", "transparent": "true", "dpi": "96",
        "dynamicLayers": json.dumps(dynamic_layers, separators=(",", ":")),
        "f": "image",
    }
    packed = request_bytes(f"{SERVICE}/export", parameters)
    if packed.startswith(b"{"):
        raise RuntimeError(json.loads(packed))
    with MemoryFile(packed) as memory:
        with memory.open() as image:
            values = image.read()
    if values.shape[0] < 3:
        raise RuntimeError("BGR-Export besitzt keine RGB-Kanäle")
    result = np.zeros((TILE_SIZE, TILE_SIZE), dtype=np.uint8)
    for class_id, _, color, _ in CLASSES[1:]:
        expected = np.asarray(rgb(color), dtype=np.uint8)[:, None, None]
        result[np.all(values[:3] == expected, axis=0)] = class_id
    return tile_x, tile_y, result


def write_tile(path: Path, values: np.ndarray, compression: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_bytes(zlib.compress(np.ascontiguousarray(values).tobytes(), compression))
    temporary.replace(path)


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


def write_level(values: np.ndarray, level: dict, output: Path, compression: int) -> None:
    for tile_y in range(level["tilesY"]):
        for tile_x in range(level["tilesX"]):
            tile = np.zeros((TILE_SIZE, TILE_SIZE), dtype=np.uint8)
            start_x, start_y = tile_x * TILE_SIZE, tile_y * TILE_SIZE
            part = values[start_y:min(start_y + TILE_SIZE, values.shape[0]), start_x:min(start_x + TILE_SIZE, values.shape[1])]
            tile[:part.shape[0], :part.shape[1]] = part
            directory = output / f"z{level['z']}"
            write_tile(directory / f"{tile_x}_{tile_y}.geology.z", tile, compression)
            write_tile(directory / f"{tile_x}_{tile_y}.geology.quality.z", (tile != 0).astype(np.uint8), compression)


def write_master(values: np.ndarray, level: dict, manifest: dict, output: Path) -> None:
    directory = output / "Masters/Geoscience"
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / "geology-guek250-80m.cog.tif"
    temporary = path.with_suffix(".tmp.tif")
    profile = {
        "driver": "GTiff", "width": values.shape[1], "height": values.shape[0],
        "count": 1, "dtype": "uint8", "crs": manifest["crs"], "nodata": 0,
        "transform": Affine(level["resolution"], 0, manifest["bounds"][0], 0, -level["resolution"], manifest["bounds"][3]),
        "tiled": True, "blockxsize": 512, "blockysize": 512, "compress": "DEFLATE",
    }
    with rasterio.open(temporary, "w", **profile) as dataset:
        dataset.write(values, 1)
        dataset.update_tags(
            SOURCE="BGR GÜK250 Petrographie, Basis- und Überlagerungslayer",
            SOURCE_SCALE="1:250000", GRID_RESOLUTION="80 m; keine fachliche 80-m-Genauigkeit",
        )
    rio_copy(temporary, path, driver="COG", compress="DEFLATE", blocksize=512, overview_resampling="MODE")
    temporary.unlink()


def update_manifest(path: Path, manifest: dict) -> None:
    source = {
        "id": "bgr-guek250", "name": "BGR GÜK250 Petrographie",
        "license": "© BGR 2026", "url": f"{SERVICE}", "scale": 250000,
        "role": "Bundesweiter Fallback",
    }
    product = {
        "id": "geology", "name": "Oberflächennahe Geologie",
        "suffix": "geology.z", "qualitySuffix": "geology.quality.z",
        "classes": [
            {"id": item[0], "name": item[1], "defaultColor": item[2], "group": item[3]}
            for item in CLASSES
        ],
        "sources": [source],
    }
    products = [item for item in manifest.get("thematicRasters", []) if item.get("id") != "geology"]
    products.append(product)
    manifest["thematicRasters"] = products
    temporary = path.with_suffix(".json.tmp")
    temporary.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    temporary.replace(path)


def main() -> int:
    args = arguments()
    manifest = json.loads(args.manifest.read_text(encoding="utf-8"))
    level = next(item for item in manifest["levels"] if item["z"] == SOURCE_LEVEL)
    output = args.manifest.parent
    values_by_layer = {layer: unique_values(layer) for layer in (8, 7)}
    dynamic_layers = [dynamic_layer(layer, values_by_layer[layer]) for layer in (8, 7)]
    mosaic = np.zeros((level["height"], level["width"]), dtype=np.uint8)
    jobs = []
    with ThreadPoolExecutor(max_workers=max(1, args.workers)) as executor:
        for tile_y in range(level["tilesY"]):
            for tile_x in range(level["tilesX"]):
                path = output / f"z{SOURCE_LEVEL}" / f"{tile_x}_{tile_y}.geology.z"
                if path.exists() and not args.force:
                    tile = np.frombuffer(zlib.decompress(path.read_bytes()), dtype=np.uint8).reshape(TILE_SIZE, TILE_SIZE)
                    end_y = min(level["height"], (tile_y + 1) * TILE_SIZE)
                    end_x = min(level["width"], (tile_x + 1) * TILE_SIZE)
                    mosaic[tile_y * TILE_SIZE:end_y, tile_x * TILE_SIZE:end_x] = tile[:end_y - tile_y * TILE_SIZE, :end_x - tile_x * TILE_SIZE]
                    continue
                jobs.append(executor.submit(export_tile, tile_x, tile_y, level, manifest["bounds"], dynamic_layers))
        completed = level["tilesX"] * level["tilesY"] - len(jobs)
        total = level["tilesX"] * level["tilesY"]
        for future in as_completed(jobs):
            tile_x, tile_y, tile = future.result()
            directory = output / f"z{SOURCE_LEVEL}"
            write_tile(directory / f"{tile_x}_{tile_y}.geology.z", tile, args.compression)
            write_tile(directory / f"{tile_x}_{tile_y}.geology.quality.z", (tile != 0).astype(np.uint8), args.compression)
            end_y = min(level["height"], (tile_y + 1) * TILE_SIZE)
            end_x = min(level["width"], (tile_x + 1) * TILE_SIZE)
            mosaic[tile_y * TILE_SIZE:end_y, tile_x * TILE_SIZE:end_x] = tile[:end_y - tile_y * TILE_SIZE, :end_x - tile_x * TILE_SIZE]
            completed += 1
            if completed % 20 == 0 or completed == total:
                print(f"\rGÜK250 z{SOURCE_LEVEL}: {completed}/{total}", end="", flush=True)
    print()
    current = mosaic
    for zoom in range(SOURCE_LEVEL - 1, -1, -1):
        current = downsample_mode(current)
        target = next(item for item in manifest["levels"] if item["z"] == zoom)
        current = current[:target["height"], :target["width"]]
        write_level(current, target, output, args.compression)
    write_master(mosaic, level, manifest, output)
    update_manifest(args.manifest, manifest)
    covered = int(np.count_nonzero(mosaic))
    print(f"Fertig: {covered / mosaic.size:.1%} Rasterabdeckung · z0–z{SOURCE_LEVEL}; z6–z8 nutzen Elternkacheln.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
