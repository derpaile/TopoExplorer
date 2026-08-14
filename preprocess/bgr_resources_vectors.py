#!/usr/bin/env python3
"""Build official BGR KOR250 resources and GK2000/KOR250 vector products."""

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
from rasterio.errors import NotGeoreferencedWarning
from rasterio.features import rasterize
from rasterio.io import MemoryFile
from rasterio.shutil import copy as rio_copy
from rasterio.transform import Affine
from rasterio.warp import transform_geom

warnings.filterwarnings("ignore", category=NotGeoreferencedWarning)

KOR = "https://services.bgr.de/arcgis/rest/services/rohstoffe/kor250/MapServer"
GK = "https://services.bgr.de/arcgis/rest/services/inspire_mr/gk2000_lagerstaetten/MapServer"
DGAS = "https://services.bgr.de/arcgis/rest/services/rohstoffe/d_erdgase/MapServer"
DOIL = "https://services.bgr.de/arcgis/rest/services/rohstoffe/d_erdoelproben/MapServer"
SOURCE_LEVEL = 5
TILE_SIZE = 512

CLASSES = [
    (0, "Keine Daten", "#000000", "Grundlage"),
    (1, "Kies / Kiessand / Sand", "#E8D39A", "Lockerrohstoff"),
    (2, "Ton / Schluff", "#B88E76", "Lockerrohstoff"),
    (3, "Kalk- / Dolomitstein", "#91BDD0", "Steine und Erden"),
    (4, "Sandstein / Quarzit", "#CA8B5E", "Steine und Erden"),
    (5, "Hartstein / Naturstein", "#8D788A", "Steine und Erden"),
    (6, "Gips / Anhydrit", "#DDD0E5", "Industriemineral"),
    (7, "Industrieminerale", "#7FAE9B", "Industriemineral"),
    (8, "Torf", "#635345", "Energierohstoff"),
    (9, "Braunkohle", "#915B45", "Energierohstoff"),
    (10, "Ölschiefer", "#5E4C52", "Energierohstoff"),
    (11, "Salz / Sole", "#D8B7C8", "Industriemineral"),
    (12, "Erze / Metalle", "#B75A48", "Metallrohstoff"),
    (13, "Steinkohle", "#45484D", "Energierohstoff"),
    (14, "Sonstige Rohstoffe", "#85836E", "Sonstige"),
]


def arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="BGR KOR250/GK2000 für TopoExplorer")
    parser.add_argument("--manifest", type=Path, default=Path("MapData/Germany/manifest.json"))
    parser.add_argument("--raw", type=Path, default=Path("Data/Raw/Geoscience/BGR"))
    parser.add_argument("--vector-config", type=Path, default=Path("Data/Raw/Geoscience/bgr-vectors.json"))
    parser.add_argument("--workers", type=int, default=6)
    parser.add_argument("--compression", type=int, choices=range(1, 10), default=6)
    parser.add_argument("--force", action="store_true")
    return parser.parse_args()


def request_bytes(url: str, parameters: dict | None = None, attempts: int = 7) -> bytes:
    for attempt in range(attempts):
        try:
            command = ["curl", "-sL", "--fail", "--max-time", "120", "-A", "TopoExplorer/1.0"]
            if parameters is not None:
                command += ["--data", urlencode(parameters)]
            command.append(url)
            result = subprocess.run(command, check=True, capture_output=True).stdout
            if result:
                return result
        except Exception:
            if attempt + 1 == attempts:
                raise
            time.sleep(min(15, 1.6 ** attempt))
    raise RuntimeError(f"Leere Antwort: {url}")


def request_json(url: str, parameters: dict) -> dict:
    result = json.loads(request_bytes(url, parameters))
    if result.get("error"):
        raise RuntimeError(result["error"])
    return result


def rgb(hex_color: str) -> list[int]:
    value = hex_color.removeprefix("#")
    return [int(value[index:index + 2], 16) for index in (0, 2, 4)]


def classify(text: str) -> int:
    value = (text or "").casefold().replace("\u00ad", "")
    if any(word in value for word in ("erz", "schwermineral", "bauxit")): return 12
    if "steinkohle" in value or "black coal" in value: return 13
    if "braunkohl" in value or "brown coal" in value: return 9
    if "ölschiefer" in value: return 10
    if "torf" in value: return 8
    if any(word in value for word in ("gips", "anhydrit")): return 6
    if any(word in value for word in ("salz", "sole")): return 11
    if any(word in value for word in ("ton", "schluff")): return 2
    if any(word in value for word in ("kies", "sand", "flugsand")) and "sandstein" not in value: return 1
    if any(word in value for word in ("karbonat", "kalk", "dolomit", "marmor")): return 3
    if any(word in value for word in ("sandstein", "quarzit", "grauwack", "konglomerat")): return 4
    if any(word in value for word in (
        "baryt", "fluorit", "bentonit", "kaolin", "diatomit", "kieselerde",
        "feldspat", "hydrosilikat", "farberde", "quarz,", "eisenkiesel",
    )): return 7
    if any(word in value for word in (
        "granit", "granodiorit", "gneis", "basalt", "diabas", "vulkanit",
        "rhyolit", "phonolith", "trachyt", "diorit", "gabbro", "syenit",
        "amphibolit", "eklogit", "serpentinit", "schiefer", "magmati",
        "metamorph", "suevit", "granulit",
    )): return 5
    return 14 if value.strip() else 0


def unique_values(layer: int) -> list[str]:
    result = request_json(f"{KOR}/{layer}/query", {
        "where": "1=1", "outFields": "Rohstoff1_Generallegende",
        "returnGeometry": "false", "returnDistinctValues": "true", "f": "json",
    })
    return sorted({
        feature["attributes"].get("Rohstoff1_Generallegende") or ""
        for feature in result.get("features", [])
    })


def symbol(class_id: int) -> dict:
    color = rgb(CLASSES[class_id][2]) + ([255] if class_id else [0])
    return {
        "type": "esriSFS", "style": "esriSFSSolid", "color": color,
        "outline": {"type": "esriSLS", "style": "esriSLSNull", "color": [0, 0, 0, 0], "width": 0},
    }


def dynamic_layer(layer: int, values: list[str]) -> dict:
    return {
        "id": layer, "source": {"type": "mapLayer", "mapLayerId": layer},
        "minScale": 0, "maxScale": 0,
        "drawingInfo": {"showLabels": False, "renderer": {
            "type": "uniqueValue", "field1": "Rohstoff1_Generallegende",
            "defaultSymbol": symbol(0),
            "uniqueValueInfos": [
                {"value": value, "label": value, "symbol": symbol(classify(value))}
                for value in values
            ],
        }},
    }


def export_tile_once(tile_x: int, tile_y: int, level: dict, bounds: list[float], layers: list[dict]):
    span = level["resolution"] * TILE_SIZE
    left = bounds[0] + tile_x * span
    top = bounds[3] - tile_y * span
    packed = request_bytes(f"{KOR}/export", {
        "bbox": f"{left},{top - span},{left + span},{top}",
        "bboxSR": "3035", "imageSR": "3035", "size": f"{TILE_SIZE},{TILE_SIZE}",
        "format": "png32", "transparent": "true", "dpi": "96",
        "dynamicLayers": json.dumps(layers, separators=(",", ":")), "f": "image",
    })
    if packed.startswith(b"{"):
        raise RuntimeError(json.loads(packed))
    with MemoryFile(packed) as memory:
        with memory.open() as image:
            pixels = image.read()
    result = np.zeros((TILE_SIZE, TILE_SIZE), dtype=np.uint8)
    for class_id, _, color, _ in CLASSES[1:]:
        expected = np.asarray(rgb(color), dtype=np.uint8)[:, None, None]
        result[np.all(pixels[:3] == expected, axis=0)] = class_id
    return tile_x, tile_y, result


def export_tile(*args):
    for attempt in range(5):
        try:
            return export_tile_once(*args)
        except Exception:
            if attempt == 4:
                raise
            time.sleep(1.6 ** attempt)


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


def write_level(values: np.ndarray, quality: np.ndarray, level: dict, output: Path, compression: int) -> None:
    for tile_y in range(level["tilesY"]):
        for tile_x in range(level["tilesX"]):
            start_x, start_y = tile_x * TILE_SIZE, tile_y * TILE_SIZE
            end_x = min(start_x + TILE_SIZE, values.shape[1])
            end_y = min(start_y + TILE_SIZE, values.shape[0])
            tile = np.zeros((TILE_SIZE, TILE_SIZE), dtype=np.uint8)
            source = np.zeros_like(tile)
            tile[:end_y - start_y, :end_x - start_x] = values[start_y:end_y, start_x:end_x]
            source[:end_y - start_y, :end_x - start_x] = quality[start_y:end_y, start_x:end_x]
            directory = output / f"z{level['z']}"
            write_tile(directory / f"{tile_x}_{tile_y}.resources.z", tile, compression)
            write_tile(directory / f"{tile_x}_{tile_y}.resources.quality.z", source, compression)


def identify_geojson(service: str, layer: int, bounds: tuple[float, float, float, float], divisions: int = 1) -> dict:
    """Use identify because these BGR MapServers suppress geometry in query."""
    left, bottom, right, top = bounds
    features: dict[str, dict] = {}
    for row in range(divisions):
        y0 = bottom + (top - bottom) * row / divisions
        y1 = bottom + (top - bottom) * (row + 1) / divisions
        for column in range(divisions):
            x0 = left + (right - left) * column / divisions
            x1 = left + (right - left) * (column + 1) / divisions
            extent = f"{x0},{y0},{x1},{y1}"
            result = request_json(f"{service}/identify", {
                "geometry": extent, "geometryType": "esriGeometryEnvelope", "sr": "25832",
                "layers": f"all:{layer}", "tolerance": "0", "mapExtent": extent,
                "imageDisplay": "1600,1600,96", "returnGeometry": "true", "f": "json",
            })
            for item in result.get("results", []):
                geometry = item.get("geometry") or {}
                if item.get("geometryType") == "esriGeometryPoint":
                    mapped = {"type": "Point", "coordinates": [geometry["x"], geometry["y"]]}
                elif item.get("geometryType") == "esriGeometryPolygon":
                    mapped = {"type": "Polygon", "coordinates": geometry.get("rings", [])}
                else:
                    continue
                properties = item.get("attributes") or {}
                object_id = str(properties.get("OBJECTID", item.get("value", len(features))))
                features[object_id] = {
                    "type": "Feature", "id": object_id,
                    "geometry": transform_geom("EPSG:25832", "EPSG:4326", mapped, precision=7),
                    "properties": properties,
                }
    return {"type": "FeatureCollection", "features": list(features.values())}


def property_value(properties: dict, *names: str):
    for name in names:
        value = properties.get(name)
        if value not in (None, "Null", ""):
            return value
    return None


def normalize_vectors(raw: Path, config_path: Path) -> tuple[dict, list[dict]]:
    raw.mkdir(parents=True, exist_ok=True)
    kor = identify_geojson(KOR, 0, (282000, 5265000, 922000, 6089000), divisions=4)
    mines = identify_geojson(GK, 1, (251000, 5235000, 923000, 6115000))
    energy = identify_geojson(GK, 2, (251000, 5235000, 923000, 6115000))
    gas_samples = identify_geojson(DGAS, 0, (329000, 5269000, 781000, 6015000))
    oil_samples = identify_geojson(DOIL, 0, (348000, 5269000, 892000, 6050000))
    (raw / "kor250-abbaustellen.geojson").write_text(json.dumps(kor, ensure_ascii=False), encoding="utf-8")
    (raw / "gk2000-bergwerke.geojson").write_text(json.dumps(mines, ensure_ascii=False), encoding="utf-8")
    (raw / "gk2000-energiefelder.geojson").write_text(json.dumps(energy, ensure_ascii=False), encoding="utf-8")
    (raw / "bgr-erdgasproben.geojson").write_text(json.dumps(gas_samples, ensure_ascii=False), encoding="utf-8")
    (raw / "bgr-erdoelproben.geojson").write_text(json.dumps(oil_samples, ensure_ascii=False), encoding="utf-8")

    kor_mining_features = []
    gk_mining_features = []
    gk_hydro_features = []
    for feature in kor["features"]:
        p = feature.setdefault("properties", {})
        resource = property_value(p, "Rohstoff1_Generallegende", "Rohstoff 1") or "Rohstoff-Abbaustelle"
        class_id = classify(resource)
        p.update(name=resource.strip(), _kind=(2 if class_id == 12 else 3 if class_id in (9, 10, 13) else 4 if class_id in (6, 11) else 5 if class_id == 7 else 6), _minZoom=4)
        kor_mining_features.append(feature)
    for feature in mines["features"]:
        p = feature.setdefault("properties", {})
        commodity = " / ".join(str(p.get(key)) for key in ("commodity1", "commodity2", "commodity3") if p.get(key) not in (None, "Null"))
        name = property_value(p, "mineName")
        p["name"] = name if name and name != "mine" else commodity or "Bergwerk/Förderstelle"
        lower = commodity.casefold()
        if "oil" in lower or "petroleum" in lower:
            p.update(_kind=1, _minZoom=2); gk_hydro_features.append(feature)
        elif "gas" in lower or "hydrocarbon" in lower:
            p.update(_kind=2, _minZoom=2); gk_hydro_features.append(feature)
        else:
            class_id = classify(commodity)
            p.update(_kind=(2 if class_id == 12 else 3 if class_id in (9, 13) else 4 if class_id == 11 else 5), _minZoom=2)
            gk_mining_features.append(feature)
    for feature in energy["features"]:
        p = feature.setdefault("properties", {})
        commodity = property_value(p, "CommodityCodeValue_WMS", "commodity") or ""
        lower = commodity.casefold()
        if "oil" not in lower and "hydrocarbon" not in lower and "gas" not in lower:
            continue
        p.update(name=("Erdölprovinz" if "oil" in lower else "Erdgasprovinz"), _kind=(1 if "oil" in lower else 2), _minZoom=1)
        gk_hydro_features.append(feature)
    for feature in gas_samples["features"]:
        p = feature.setdefault("properties", {})
        p.update(name=property_value(p, "Bohrungsna", "NIBIS Bohrungsname") or "Erdgas-Bohrungsnachweis", _kind=2, _minZoom=4)
    for feature in oil_samples["features"]:
        p = feature.setdefault("properties", {})
        p.update(name=property_value(p, "NIBIS_Bohrungsn", "NIBIS Bohrungsname") or "Erdöl-Bohrungsnachweis", _kind=1, _minZoom=4)
    kor_mining = {"type": "FeatureCollection", "features": kor_mining_features}
    gk_mining = {"type": "FeatureCollection", "features": gk_mining_features}
    gk_hydrocarbons = {"type": "FeatureCollection", "features": gk_hydro_features}
    kor_mining_path = raw / "kor250-mining-normalized.geojson"
    gk_mining_path = raw / "gk2000-mining-normalized.geojson"
    gk_hydro_path = raw / "gk2000-hydrocarbons-normalized.geojson"
    gas_path = raw / "erdgasproben-normalized.geojson"
    oil_path = raw / "erdoelproben-normalized.geojson"
    kor_mining_path.write_text(json.dumps(kor_mining, ensure_ascii=False), encoding="utf-8")
    gk_mining_path.write_text(json.dumps(gk_mining, ensure_ascii=False), encoding="utf-8")
    gk_hydro_path.write_text(json.dumps(gk_hydrocarbons, ensure_ascii=False), encoding="utf-8")
    gas_path.write_text(json.dumps(gas_samples, ensure_ascii=False), encoding="utf-8")
    oil_path.write_text(json.dumps(oil_samples, ensure_ascii=False), encoding="utf-8")
    config = {"sources": [
        {"id": "bgr-kor250-mining", "name": "BGR KOR250 Abbaustellen", "path": str(kor_mining_path), "crs": "EPSG:4326", "layer": 5, "kindProperty": "_kind", "nameProperty": "name", "minZoomProperty": "_minZoom", "license": "© BGR 2026", "url": KOR, "role": "Abbaustellen"},
        {"id": "bgr-gk2000-mines", "name": "BGR GK2000 Bergwerke", "path": str(gk_mining_path), "crs": "EPSG:4326", "layer": 5, "kindProperty": "_kind", "nameProperty": "name", "minZoomProperty": "_minZoom", "license": "© BGR 2026", "url": GK, "role": "Erze, Kohle, Salze und Industrieminerale"},
        {"id": "bgr-gk2000-hydrocarbons", "name": "BGR GK2000 Erdöl/Erdgas", "path": str(gk_hydro_path), "crs": "EPSG:4326", "layer": 6, "kindProperty": "_kind", "nameProperty": "name", "minZoomProperty": "_minZoom", "license": "© BGR 2026", "url": GK, "role": "Provinzen und ausgewählte Förderpunkte"},
        {"id": "bgr-d-erdgase", "name": "BGR D-Erdgase", "path": str(gas_path), "crs": "EPSG:4326", "layer": 6, "kindProperty": "_kind", "nameProperty": "name", "minZoomProperty": "_minZoom", "license": "© BGR 2026", "url": DGAS, "role": "Öffentliche Erdgas-Bohrungsnachweise"},
        {"id": "bgr-d-erdoelproben", "name": "BGR Erdölarchiv", "path": str(oil_path), "crs": "EPSG:4326", "layer": 6, "kindProperty": "_kind", "nameProperty": "name", "minZoomProperty": "_minZoom", "license": "© BGR 2026", "url": DOIL, "role": "Öffentliche Erdöl-Bohrungsnachweise"},
    ]}
    config_path.parent.mkdir(parents=True, exist_ok=True)
    config_path.write_text(json.dumps(config, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return energy, config["sources"]


def overlay_coal(mosaic: np.ndarray, quality: np.ndarray, energy: dict, transform: Affine) -> None:
    shapes = []
    for feature in energy["features"]:
        properties = feature.get("properties", {})
        commodity = (property_value(properties, "CommodityCodeValue_WMS", "commodity") or "").casefold()
        class_id = 13 if "black coal" in commodity else 9 if "brown coal" in commodity else 0
        if class_id:
            shapes.append((transform_geom("EPSG:4326", "EPSG:3035", feature["geometry"], precision=1), class_id))
    if not shapes:
        return
    coal = rasterize(shapes, out_shape=mosaic.shape, transform=transform, fill=0, dtype="uint8")
    # KOR250 remains the more detailed authority for lignite; GK2000 fills missing coal fields.
    fill = (mosaic == 0) & (coal != 0)
    mosaic[fill] = coal[fill]
    quality[fill] = 2


def write_master(values: np.ndarray, level: dict, manifest: dict, output: Path) -> None:
    directory = output / "Masters/Geoscience"
    directory.mkdir(parents=True, exist_ok=True)
    path = directory / "resources-kor250-gk2000-80m.cog.tif"
    temporary = path.with_suffix(".tmp.tif")
    transform = Affine(level["resolution"], 0, manifest["bounds"][0], 0, -level["resolution"], manifest["bounds"][3])
    with rasterio.open(temporary, "w", driver="GTiff", width=values.shape[1], height=values.shape[0], count=1, dtype="uint8", crs=manifest["crs"], nodata=0, transform=transform, tiled=True, blockxsize=512, blockysize=512, compress="DEFLATE") as dataset:
        dataset.write(values, 1)
        dataset.update_tags(SOURCE="BGR KOR250; GK2000 coal fallback", SOURCE_SCALE="1:250000 / 1:2000000", GRID_RESOLUTION="80 m; keine fachliche 80-m-Genauigkeit")
    rio_copy(temporary, path, driver="COG", compress="DEFLATE", blocksize=512, overview_resampling="MODE")
    temporary.unlink()


def update_manifest(path: Path, manifest: dict) -> None:
    product = {
        "id": "resources", "name": "Rohstoffvorkommen & Erze",
        "suffix": "resources.z", "qualitySuffix": "resources.quality.z",
        "classes": [{"id": item[0], "name": item[1], "defaultColor": item[2], "group": item[3]} for item in CLASSES],
        "sources": [
            {"id": "bgr-kor250", "name": "BGR KOR250", "license": "© BGR 2026", "url": KOR, "scale": 250000, "role": "Bundesweiter Fallback"},
            {"id": "bgr-gk2000-coal", "name": "BGR GK2000 Kohlefelder", "license": "© BGR 2026", "url": GK, "scale": 2000000, "role": "Steinkohle-Übersicht"},
        ],
    }
    products = [item for item in manifest.get("thematicRasters", []) if item.get("id") != "resources"]
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
    values = {layer: unique_values(layer) for layer in (4, 3, 2)}
    layers = [dynamic_layer(layer, values[layer]) for layer in (4, 3, 2)]
    mosaic = np.zeros((level["height"], level["width"]), dtype=np.uint8)
    quality_mosaic = np.zeros_like(mosaic)
    jobs = []
    with ThreadPoolExecutor(max_workers=max(1, args.workers)) as executor:
        for tile_y in range(level["tilesY"]):
            for tile_x in range(level["tilesX"]):
                path = output / f"z{SOURCE_LEVEL}" / f"{tile_x}_{tile_y}.resources.z"
                if path.exists() and not args.force:
                    tile = np.frombuffer(zlib.decompress(path.read_bytes()), dtype=np.uint8).reshape(TILE_SIZE, TILE_SIZE)
                    quality_path = output / f"z{SOURCE_LEVEL}" / f"{tile_x}_{tile_y}.resources.quality.z"
                    source_tile = np.frombuffer(zlib.decompress(quality_path.read_bytes()), dtype=np.uint8).reshape(TILE_SIZE, TILE_SIZE) if quality_path.exists() else (tile != 0).astype(np.uint8)
                    end_y = min(level["height"], (tile_y + 1) * TILE_SIZE)
                    end_x = min(level["width"], (tile_x + 1) * TILE_SIZE)
                    mosaic[tile_y * TILE_SIZE:end_y, tile_x * TILE_SIZE:end_x] = tile[:end_y - tile_y * TILE_SIZE, :end_x - tile_x * TILE_SIZE]
                    quality_mosaic[tile_y * TILE_SIZE:end_y, tile_x * TILE_SIZE:end_x] = source_tile[:end_y - tile_y * TILE_SIZE, :end_x - tile_x * TILE_SIZE]
                else:
                    jobs.append(executor.submit(export_tile, tile_x, tile_y, level, manifest["bounds"], layers))
        completed = level["tilesX"] * level["tilesY"] - len(jobs)
        total = level["tilesX"] * level["tilesY"]
        for future in as_completed(jobs):
            tile_x, tile_y, tile = future.result()
            end_y = min(level["height"], (tile_y + 1) * TILE_SIZE)
            end_x = min(level["width"], (tile_x + 1) * TILE_SIZE)
            mosaic[tile_y * TILE_SIZE:end_y, tile_x * TILE_SIZE:end_x] = tile[:end_y - tile_y * TILE_SIZE, :end_x - tile_x * TILE_SIZE]
            quality_mosaic[tile_y * TILE_SIZE:end_y, tile_x * TILE_SIZE:end_x] = (tile[:end_y - tile_y * TILE_SIZE, :end_x - tile_x * TILE_SIZE] != 0).astype(np.uint8)
            completed += 1
            if completed % 20 == 0 or completed == total:
                print(f"\rKOR250 z{SOURCE_LEVEL}: {completed}/{total}", end="", flush=True)
    print()
    quality = quality_mosaic
    energy, _ = normalize_vectors(args.raw, args.vector_config)
    transform = Affine(level["resolution"], 0, manifest["bounds"][0], 0, -level["resolution"], manifest["bounds"][3])
    overlay_coal(mosaic, quality, energy, transform)
    write_level(mosaic, quality, level, output, args.compression)
    current, current_quality = mosaic, quality
    for zoom in range(SOURCE_LEVEL - 1, -1, -1):
        current = downsample_mode(current, [item[0] for item in CLASSES])
        current_quality = downsample_mode(current_quality, [0, 1, 2])
        target = next(item for item in manifest["levels"] if item["z"] == zoom)
        current = current[:target["height"], :target["width"]]
        current_quality = current_quality[:target["height"], :target["width"]]
        write_level(current, current_quality, target, output, args.compression)
    write_master(mosaic, level, manifest, output)
    update_manifest(args.manifest, manifest)
    print(f"Fertig: {np.count_nonzero(mosaic) / mosaic.size:.1%} Rohstoffabdeckung; Vektorkonfiguration {args.vector_config}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
