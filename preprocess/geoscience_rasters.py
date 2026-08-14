#!/usr/bin/env python3
"""Harmonize geoscience vectors into COG masters and TopoExplorer raster tiles."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import re
import shutil
import zlib
from urllib.request import urlopen
from pathlib import Path

import fiona
import numpy as np
import rasterio
from rasterio.enums import Resampling
from rasterio.features import rasterize
from rasterio.shutil import copy as rio_copy
from rasterio.transform import Affine
from rasterio.vrt import WarpedVRT
from rasterio.warp import transform_bounds, transform_geom
from rasterio.windows import Window, bounds as window_bounds


TARGET_CRS = "EPSG:3035"
TILE_SIZE = 512


def arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Geowissenschaftliche TopoExplorer-Raster erzeugen")
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("--manifest", type=Path, default=Path("MapData/Germany/manifest.json"))
    parser.add_argument("--work", type=Path, default=Path(".build/geoscience"))
    parser.add_argument("--resolution", type=float, default=10.0)
    parser.add_argument("--compression", type=int, choices=range(1, 10), default=6)
    parser.add_argument("--force", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    return parser.parse_args()


def safe_path(path: Path) -> Path:
    value = path.resolve()
    if value == Path(value.anchor) or len(value.parts) < 4:
        raise SystemExit(f"Unsicherer Pfad: {value}")
    return value


def compile_rules(product: dict) -> list[tuple[int, list[tuple[str, re.Pattern[str]]]]]:
    result = []
    for item in product["classes"]:
        tests = [
            (field, re.compile(pattern, re.IGNORECASE))
            for field, pattern in item.get("matches", {}).items()
        ]
        if item.get("pattern"):
            tests.append(("*", re.compile(item["pattern"], re.IGNORECASE)))
        if item["id"] and tests:
            result.append((int(item["id"]), tests))
    return result


def classify(properties: dict, rules: list[tuple[int, list[tuple[str, re.Pattern[str]]]]]) -> int:
    searchable = " | ".join(str(value) for value in properties.values())
    for class_id, tests in rules:
        if all(pattern.search(searchable if field == "*" else str(properties.get(field, ""))) for field, pattern in tests):
            return class_id
    return 0


def open_layer(source: dict):
    path = Path(source["path"])
    if not path.exists() and source.get("downloadURL"):
        path.parent.mkdir(parents=True, exist_ok=True)
        temporary = path.with_suffix(path.suffix + ".download")
        digest = hashlib.sha256()
        with urlopen(source["downloadURL"]) as response, temporary.open("wb") as output:
            while chunk := response.read(1024 * 1024):
                output.write(chunk)
                digest.update(chunk)
        expected = source.get("sha256")
        if expected and digest.hexdigest().lower() != expected.lower():
            temporary.unlink()
            raise SystemExit(f"Prüfsumme stimmt nicht: {source['id']}")
        temporary.replace(path)
    if not path.exists():
        raise SystemExit(f"Quelldatei fehlt: {path}")
    return fiona.open(path, layer=source.get("layer"))


def archive_sources(product: dict, target: Path) -> None:
    """Keep all original attributes while normalizing geometry to EPSG:3035."""
    if target.exists():
        target.unlink()
    for index, source in enumerate(product["sources"]):
        with open_layer(source) as collection:
            schema = dict(collection.schema)
            schema["properties"] = dict(schema["properties"])
            schema["properties"]["_source_id"] = "str:80"
            layer_name = re.sub(r"[^A-Za-z0-9_]", "_", source["id"])
            with fiona.open(
                target,
                mode="w",
                driver="GPKG",
                layer=layer_name,
                crs=TARGET_CRS,
                schema=schema,
                append_subdataset=index > 0,
            ) as output:
                for feature in collection:
                    if not feature.geometry:
                        continue
                    properties = dict(feature.properties)
                    properties["_source_id"] = source["id"]
                    output.write({
                        "type": "Feature",
                        "geometry": transform_geom(collection.crs, TARGET_CRS, feature.geometry),
                        "properties": properties,
                    })


def product_sources(product: dict) -> list[dict]:
    # Broad fallback first, precise state data last: the best available source wins.
    return sorted(product["sources"], key=lambda item: (-int(item["scale"]), int(item.get("priority", 0))))


def build_master(
    product: dict,
    manifest: dict,
    resolution: float,
    work: Path,
    force: bool,
) -> tuple[Path, Path]:
    product_id = product["id"]
    master = work / f"{product_id}-10m.tif"
    quality = work / f"{product_id}-quality-10m.tif"
    if master.exists() and quality.exists() and not force:
        return master, quality
    left, bottom, right, top = manifest["bounds"]
    width = math.ceil((right - left) / resolution)
    height = math.ceil((top - bottom) / resolution)
    transform = Affine(resolution, 0, left, 0, -resolution, top)
    profile = {
        "driver": "GTiff", "width": width, "height": height, "count": 1,
        "dtype": "uint8", "crs": TARGET_CRS, "transform": transform,
        "nodata": 0, "tiled": True, "blockxsize": TILE_SIZE, "blockysize": TILE_SIZE,
        "compress": "DEFLATE", "predictor": 1, "bigtiff": "YES",
    }
    rules = compile_rules(product)
    sources = product_sources(product)
    source_indexes = {item["id"]: product["sources"].index(item) + 1 for item in sources}
    opened = [(source, open_layer(source)) for source in sources]
    try:
        with rasterio.open(master, "w", **profile) as values, rasterio.open(quality, "w", **profile) as provenance:
            for _, window in values.block_windows(1):
                tile = np.zeros((int(window.height), int(window.width)), dtype=np.uint8)
                source_tile = np.zeros_like(tile)
                target_bbox = window_bounds(window, transform)
                window_transform = rasterio.windows.transform(window, transform)
                for source, collection in opened:
                    source_bbox = transform_bounds(TARGET_CRS, collection.crs, *target_bbox, densify_pts=8)
                    shapes = []
                    for feature in collection.filter(bbox=source_bbox):
                        class_id = classify(dict(feature.properties), rules)
                        if class_id and feature.geometry:
                            shapes.append((transform_geom(collection.crs, TARGET_CRS, feature.geometry), class_id))
                    if not shapes:
                        continue
                    burned = rasterize(
                        shapes, out_shape=tile.shape, transform=window_transform,
                        fill=0, dtype="uint8", all_touched=False,
                    )
                    valid = burned != 0
                    tile[valid] = burned[valid]
                    source_tile[valid] = source_indexes[source["id"]]
                values.write(tile, 1, window=window)
                provenance.write(source_tile, 1, window=window)
    finally:
        for _, collection in opened:
            collection.close()
    return master, quality


def create_cog(source: Path, target: Path) -> None:
    if target.exists():
        target.unlink()
    rio_copy(
        source, target, driver="COG", compress="DEFLATE", blocksize=TILE_SIZE,
        overview_resampling="MODE", BIGTIFF="YES",
    )


def write_tiles(
    source: Path,
    suffix: str,
    manifest: dict,
    output: Path,
    compression: int,
) -> None:
    with rasterio.open(source) as dataset:
        for level in manifest["levels"]:
            transform = Affine(
                level["resolution"], 0, manifest["bounds"][0],
                0, -level["resolution"], manifest["bounds"][3],
            )
            with WarpedVRT(
                dataset, crs=TARGET_CRS, transform=transform,
                width=level["width"], height=level["height"],
                resampling=Resampling.mode, nodata=0,
            ) as vrt:
                directory = output / f"z{level['z']}"
                directory.mkdir(parents=True, exist_ok=True)
                for tile_y in range(level["tilesY"]):
                    for tile_x in range(level["tilesX"]):
                        data = vrt.read(
                            1,
                            window=Window(tile_x * TILE_SIZE, tile_y * TILE_SIZE, TILE_SIZE, TILE_SIZE),
                            boundless=True, fill_value=0, out_dtype="uint8",
                        )
                        target = directory / f"{tile_x}_{tile_y}.{suffix}"
                        temporary = target.with_suffix(target.suffix + ".tmp")
                        temporary.write_bytes(zlib.compress(data.tobytes(order="C"), compression))
                        temporary.replace(target)


def manifest_product(product: dict) -> dict:
    return {
        "id": product["id"], "name": product["name"],
        "suffix": product.get("suffix", f"{product['id']}.z"),
        "qualitySuffix": product.get("qualitySuffix", f"{product['id']}.quality.z"),
        "classes": [
            {key: item[key] for key in ("id", "name", "defaultColor", "group") if key in item}
            for item in product["classes"]
        ],
        "sources": [
            {key: source[key] for key in ("id", "name", "license", "url", "scale", "role") if key in source}
            for source in product["sources"]
        ],
    }


def main() -> int:
    args = arguments()
    config = json.loads(args.config.read_text(encoding="utf-8"))
    manifest = json.loads(args.manifest.read_text(encoding="utf-8"))
    if manifest["crs"] != TARGET_CRS:
        raise SystemExit(f"Manifest muss {TARGET_CRS} verwenden")
    work = safe_path(args.work)
    output = args.manifest.parent
    print(f"{len(config['products'])} Produkte · {args.resolution:g} m · {output}")
    if args.dry_run:
        for product in config["products"]:
            print(f"  {product['id']}: {len(product['classes']) - 1} Klassen, {len(product['sources'])} Quellen")
        return 0
    work.mkdir(parents=True, exist_ok=True)
    masters = output / "Masters/Geoscience"
    masters.mkdir(parents=True, exist_ok=True)
    intermediate = output / "Intermediate/Geoscience"
    intermediate.mkdir(parents=True, exist_ok=True)
    products = []
    for product in config["products"]:
        print(f"Baue {product['name']} …")
        archive_sources(product, intermediate / f"{product['id']}.gpkg")
        master, quality = build_master(product, manifest, args.resolution, work, args.force)
        master_cog = masters / f"{product['id']}-10m.cog.tif"
        quality_cog = masters / f"{product['id']}-quality-10m.cog.tif"
        create_cog(master, master_cog)
        create_cog(quality, quality_cog)
        item = manifest_product(product)
        write_tiles(master_cog, item["suffix"], manifest, output, args.compression)
        write_tiles(quality_cog, item["qualitySuffix"], manifest, output, args.compression)
        products.append(item)
    manifest["thematicRasters"] = products
    temporary = args.manifest.with_suffix(".json.tmp")
    temporary.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    temporary.replace(args.manifest)
    if work.exists() and not args.force:
        shutil.rmtree(work)
    print("Geowissenschaftliche Raster vollständig.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
