#!/usr/bin/env python3
"""Create neutral Sentinel-2 surface-detail tiles for TopoExplorer.

The pipeline never creates an RGB satellite product. Remote input is requested
one band at a time and kept in memory; local input is read window by window.
Only the centered, clipped high-pass signal is persisted as UInt8 ``surface.z``.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import time
import urllib.error
import urllib.parse
import urllib.request
import warnings
import zlib
from contextlib import ExitStack
from dataclasses import dataclass
from datetime import date
from pathlib import Path

import numpy as np
import rasterio
from rasterio.enums import Resampling
from rasterio.errors import NotGeoreferencedWarning
from rasterio.io import MemoryFile
from rasterio.transform import Affine
from rasterio.vrt import WarpedVRT
from rasterio.warp import transform
from rasterio.windows import Window


TARGET_CRS = "EPSG:3035"
SURFACE_SUFFIX = "surface.z"
COLLECTION_ID = "5460de54-082e-473a-b6ea-d5cbe3c17cca"
TOKEN_URL = (
    "https://identity.dataspace.copernicus.eu/auth/realms/CDSE/"
    "protocol/openid-connect/token"
)
PROCESS_URL = "https://sh.dataspace.copernicus.eu/api/v1/process"
SOURCE_URL = (
    "https://documentation.dataspace.copernicus.eu/Data/"
    "SentinelMissions/Sentinel2.html#sentinel-2-level-3-quarterly-mosaics"
)
HANNOVER_LON_LAT = (9.732, 52.375)
STRENGTHS = (0.0, 0.20, 0.30, 0.40, 0.50)


@dataclass(frozen=True)
class Tile:
    x: int
    y: int


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Sentinel-2-Oberflächendetails als TopoExplorer-Kacheln erzeugen"
    )
    parser.add_argument("--map-data", type=Path, default=Path("MapData/Germany"))
    parser.add_argument("--quarter", default="2025-Q2", help="Quartal, z. B. 2025-Q2")
    parser.add_argument("--radius-km", type=float, default=10.0, help="Hannover-PoC-Radius")
    parser.add_argument("--center-lon", type=float, default=HANNOVER_LON_LAT[0])
    parser.add_argument("--center-lat", type=float, default=HANNOVER_LON_LAT[1])
    parser.add_argument("--b02", type=Path)
    parser.add_argument("--b03", type=Path)
    parser.add_argument("--b04", type=Path)
    parser.add_argument("--b08", type=Path)
    parser.add_argument("--observations", type=Path)
    parser.add_argument("--highpass-radius", type=int, default=24, help="Filterradius in Pixeln")
    parser.add_argument("--nir-weight", type=float, default=0.22)
    parser.add_argument("--clip-percentile", type=float, default=98.0)
    parser.add_argument("--minimum-observations", type=int, default=1)
    parser.add_argument("--minimum-zoom", type=int, help="Niedrigste erzeugte Zoomstufe")
    parser.add_argument("--compression", type=int, choices=range(1, 10), default=6)
    parser.add_argument("--preview-size", type=int, default=768)
    parser.add_argument("--no-preview", action="store_true")
    parser.add_argument(
        "--preview-only",
        action="store_true",
        help="Vorhandene Surface-Kacheln nur neu vergleichen; kein Satellitenabruf",
    )
    parser.add_argument("--dry-run", action="store_true")
    return parser.parse_args()


def quarter_interval(value: str) -> tuple[str, str]:
    try:
        year_text, quarter_text = value.upper().split("-Q", 1)
        year, quarter = int(year_text), int(quarter_text)
        if quarter not in range(1, 5):
            raise ValueError
    except ValueError as error:
        raise SystemExit("--quarter muss wie 2025-Q2 geschrieben werden") from error
    month = 1 + (quarter - 1) * 3
    start = date(year, month, 1)
    next_start = date(year + (quarter == 4), 1 if quarter == 4 else month + 3, 1)
    return start.isoformat(), next_start.isoformat()


def load_manifest(root: Path) -> dict:
    path = root / "manifest.json"
    try:
        manifest = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise SystemExit(f"Manifest nicht lesbar: {path}: {error}") from error
    if manifest.get("crs") != TARGET_CRS or manifest.get("compression") != "zlib":
        raise SystemExit("Surface Texture benötigt ein EPSG:3035-/zlib-Manifest")
    if int(manifest.get("tileSize", 0)) != 512:
        raise SystemExit("Surface Texture erwartet 512 × 512 Pixel")
    return manifest


def select_tiles(manifest: dict, args: argparse.Namespace) -> tuple[dict, list[Tile]]:
    level = max(manifest["levels"], key=lambda item: int(item["z"]))
    resolution = float(level["resolution"])
    if not math.isclose(resolution, 10.0):
        raise SystemExit(f"Feinste Kartenebene hat {resolution:g} statt 10 m/Pixel")
    center_x, center_y = transform(
        "EPSG:4326", TARGET_CRS, [args.center_lon], [args.center_lat]
    )
    radius = args.radius_km * 1_000.0
    left, _, _, top = map(float, manifest["bounds"])
    tile_span = int(manifest["tileSize"]) * resolution
    min_x = max(0, math.floor((center_x[0] - radius - left) / tile_span))
    max_x = min(int(level["tilesX"]) - 1, math.floor((center_x[0] + radius - left) / tile_span))
    min_y = max(0, math.floor((top - center_y[0] - radius) / tile_span))
    max_y = min(int(level["tilesY"]) - 1, math.floor((top - center_y[0] + radius) / tile_span))
    if min_x > max_x or min_y > max_y:
        raise SystemExit("Die gewählte Testregion liegt außerhalb der Karte")
    return level, [Tile(x, y) for y in range(min_y, max_y + 1) for x in range(min_x, max_x + 1)]


def read_padded(dataset: rasterio.io.DatasetReader, window: Window) -> np.ndarray:
    result = np.full((int(window.height), int(window.width)), np.nan, dtype=np.float32)
    x0, y0 = max(0, int(window.col_off)), max(0, int(window.row_off))
    x1 = min(dataset.width, int(window.col_off + window.width))
    y1 = min(dataset.height, int(window.row_off + window.height))
    if x1 <= x0 or y1 <= y0:
        return result
    with warnings.catch_warnings():
        warnings.simplefilter("ignore", DeprecationWarning)
        values = dataset.read(1, window=Window(x0, y0, x1 - x0, y1 - y0)).astype(
            np.float32
        )
    nodata = dataset.nodata
    if nodata is not None:
        values[values == nodata] = np.nan
    destination_x, destination_y = x0 - int(window.col_off), y0 - int(window.row_off)
    result[
        destination_y : destination_y + values.shape[0],
        destination_x : destination_x + values.shape[1],
    ] = values
    return result


class LocalBands:
    def __init__(self, paths: dict[str, Path | None], manifest: dict, level: dict):
        missing = [band for band in ("B02", "B03", "B04") if paths[band] is None]
        if missing:
            raise SystemExit("Lokaler Modus benötigt --b02, --b03 und --b04")
        self.stack = ExitStack()
        left, _, _, top = map(float, manifest["bounds"])
        resolution = float(level["resolution"])
        target_transform = Affine(resolution, 0, left, 0, -resolution, top)
        self.datasets: dict[str, rasterio.io.DatasetReader] = {}
        for band, path in paths.items():
            if path is None:
                continue
            source = self.stack.enter_context(rasterio.open(path))
            vrt = self.stack.enter_context(
                WarpedVRT(
                    source,
                    crs=TARGET_CRS,
                    transform=target_transform,
                    width=int(level["width"]),
                    height=int(level["height"]),
                    resampling=Resampling.nearest if band == "observations" else Resampling.bilinear,
                    dtype="float32",
                    nodata=np.nan,
                )
            )
            self.datasets[band] = vrt

    def close(self) -> None:
        self.stack.close()

    def read(self, tile: Tile, tile_size: int, halo: int) -> dict[str, np.ndarray]:
        window = Window(
            tile.x * tile_size - halo,
            tile.y * tile_size - halo,
            tile_size + 2 * halo,
            tile_size + 2 * halo,
        )
        result = {band: read_padded(dataset, window) for band, dataset in self.datasets.items()}
        if "observations" not in result:
            result["observations"] = np.ones(
                (int(window.height), int(window.width)), dtype=np.float32
            )
        return result


class SentinelHubBands:
    def __init__(self, quarter: str, manifest: dict, level: dict):
        client_id = os.environ.get("CDSE_CLIENT_ID")
        client_secret = os.environ.get("CDSE_CLIENT_SECRET")
        if not client_id or not client_secret:
            raise SystemExit(
                "Für den Copernicus-Abruf CDSE_CLIENT_ID und CDSE_CLIENT_SECRET setzen; "
                "alternativ lokale Einzelbänder mit --b02/--b03/--b04 angeben."
            )
        form = urllib.parse.urlencode(
            {
                "grant_type": "client_credentials",
                "client_id": client_id,
                "client_secret": client_secret,
            }
        ).encode()
        request = urllib.request.Request(TOKEN_URL, data=form, method="POST")
        request.add_header("Content-Type", "application/x-www-form-urlencoded")
        try:
            with urllib.request.urlopen(request, timeout=45) as response:
                self.token = json.load(response)["access_token"]
        except (OSError, KeyError, json.JSONDecodeError) as error:
            raise SystemExit(f"CDSE-Anmeldung fehlgeschlagen: {error}") from error
        self.start, self.end = quarter_interval(quarter)
        self.manifest = manifest
        self.level = level

    def read(self, tile: Tile, tile_size: int, halo: int) -> dict[str, np.ndarray]:
        left, _, _, top = map(float, self.manifest["bounds"])
        resolution = float(self.level["resolution"])
        pixel_x = tile.x * tile_size - halo
        pixel_y = tile.y * tile_size - halo
        width = height = tile_size + 2 * halo
        bounds = [
            left + pixel_x * resolution,
            top - (pixel_y + height) * resolution,
            left + (pixel_x + width) * resolution,
            top - pixel_y * resolution,
        ]
        result = {}
        for band in ("B02", "B03", "B04", "B08", "observations"):
            result[band] = self._request_band(band, bounds, width, height)
        return result

    def _request_band(
        self, band: str, bounds: list[float], width: int, height: int
    ) -> np.ndarray:
        evalscript = f"""//VERSION=3
function setup() {{
  return {{input: [{{bands: [\"{band}\", \"dataMask\"]}}],
    output: {{bands: 2, sampleType: \"FLOAT32\"}}}};
}}
function evaluatePixel(sample) {{ return [sample.{band}, sample.dataMask]; }}
"""
        payload = {
            "input": {
                "bounds": {
                    "bbox": bounds,
                    "properties": {"crs": "http://www.opengis.net/def/crs/EPSG/0/3035"},
                },
                "data": [
                    {
                        "type": f"byoc-{COLLECTION_ID}",
                        "dataFilter": {
                            "timeRange": {
                                "from": f"{self.start}T00:00:00Z",
                                "to": f"{self.end}T00:00:00Z",
                            },
                            "mosaickingOrder": "mostRecent",
                        },
                    }
                ],
            },
            "output": {
                "width": width,
                "height": height,
                "responses": [{"identifier": "default", "format": {"type": "image/tiff"}}],
            },
            "evalscript": evalscript,
        }
        data = json.dumps(payload).encode()
        for attempt in range(4):
            request = urllib.request.Request(PROCESS_URL, data=data, method="POST")
            request.add_header("Authorization", f"Bearer {self.token}")
            request.add_header("Content-Type", "application/json")
            try:
                with urllib.request.urlopen(request, timeout=120) as response:
                    encoded = response.read()
                with MemoryFile(encoded) as memory, memory.open() as dataset:
                    values = dataset.read(1).astype(np.float32)
                    mask = dataset.read(2) > 0
                values[~mask] = np.nan
                return values
            except (urllib.error.URLError, rasterio.errors.RasterioError) as error:
                if attempt == 3:
                    raise SystemExit(f"CDSE-Abruf für {band} fehlgeschlagen: {error}") from error
                time.sleep(2**attempt)
        raise AssertionError("unreachable")


def box_sum(values: np.ndarray, radius: int, axis: int) -> np.ndarray:
    padding = [(0, 0), (0, 0)]
    padding[axis] = (radius, radius)
    padded = np.pad(values, padding, mode="constant")
    cumulative = np.cumsum(padded, axis=axis, dtype=np.float64)
    leading = [(0, 0), (0, 0)]
    leading[axis] = (1, 0)
    cumulative = np.pad(cumulative, leading, mode="constant")
    width = 2 * radius + 1
    if axis == 0:
        return cumulative[width:, :] - cumulative[:-width, :]
    return cumulative[:, width:] - cumulative[:, :-width]


def box_blur(values: np.ndarray, radius: int) -> np.ndarray:
    width = float(2 * radius + 1)
    return (box_sum(box_sum(values, radius, 1), radius, 0) / (width * width)).astype(
        np.float32
    )


def smooth_valid(values: np.ndarray, valid: np.ndarray, radius: int) -> np.ndarray:
    weights = valid.astype(np.float32)
    numerator = box_sum(box_sum(np.where(valid, values, 0), radius, 1), radius, 0)
    denominator = box_sum(box_sum(weights, radius, 1), radius, 0)
    first = np.divide(
        numerator,
        denominator,
        out=np.zeros(values.shape, dtype=np.float64),
        where=denominator > 0,
    ).astype(np.float32)
    return box_blur(box_blur(first, radius), radius)


def detail_for_tile(
    bands: dict[str, np.ndarray],
    tile_size: int,
    halo: int,
    radius: int,
    nir_weight: float,
    minimum_observations: int,
) -> tuple[np.ndarray, np.ndarray]:
    blue, green, red = bands["B02"], bands["B03"], bands["B04"]
    observations = bands["observations"]
    valid = (
        np.isfinite(blue)
        & np.isfinite(green)
        & np.isfinite(red)
        & np.isfinite(observations)
        & (observations >= minimum_observations)
    )
    luminance = np.maximum(0, 0.0722 * blue + 0.7152 * green + 0.2126 * red)
    log_luminance = np.log1p(luminance).astype(np.float32)
    detail = log_luminance - smooth_valid(log_luminance, valid, radius)
    nir = bands.get("B08")
    if nir is not None and nir_weight > 0:
        nir_valid = valid & np.isfinite(nir)
        log_nir = np.log1p(np.maximum(0, nir)).astype(np.float32)
        detail += nir_weight * (log_nir - smooth_valid(log_nir, nir_valid, radius))
        valid &= nir_valid
    core = np.s_[halo : halo + tile_size, halo : halo + tile_size]
    return np.ascontiguousarray(detail[core]), np.ascontiguousarray(valid[core])


def encode_detail(detail: np.ndarray, valid: np.ndarray, limit: float) -> np.ndarray:
    normalized = np.clip(detail / limit, -1, 1)
    encoded = np.where(normalized >= 0, 128 + 127 * normalized, 128 + 128 * normalized)
    result = np.full(detail.shape, 128, dtype=np.uint8)
    result[valid] = np.rint(encoded[valid]).astype(np.uint8)
    return result


def write_tile(path: Path, values: np.ndarray, compression: int) -> None:
    packed = zlib.compress(np.ascontiguousarray(values, dtype=np.uint8).tobytes(), compression)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_bytes(packed)
    temporary.replace(path)


def read_tile(path: Path, tile_size: int) -> np.ndarray:
    values = np.frombuffer(zlib.decompress(path.read_bytes()), dtype=np.uint8)
    if values.size != tile_size * tile_size:
        raise RuntimeError(f"Defekte Surface-Kachel: {path}")
    return values.reshape((tile_size, tile_size))


def derive_parent_tiles(
    root: Path,
    fine_z: int,
    fine_tiles: list[Tile],
    minimum_zoom: int,
    tile_size: int,
    compression: int,
) -> set[Tile]:
    current = set(fine_tiles)
    for child_z in range(fine_z, minimum_zoom, -1):
        parents = {Tile(tile.x // 2, tile.y // 2) for tile in current}
        parent_directory = root / f"z{child_z - 1}"
        parent_directory.mkdir(parents=True, exist_ok=True)
        for parent in sorted(parents, key=lambda tile: (tile.y, tile.x)):
            children = np.full((tile_size * 2, tile_size * 2), 128, dtype=np.uint8)
            for offset_y in range(2):
                for offset_x in range(2):
                    child = Tile(parent.x * 2 + offset_x, parent.y * 2 + offset_y)
                    path = root / f"z{child_z}" / f"{child.x}_{child.y}.{SURFACE_SUFFIX}"
                    if path.is_file():
                        children[
                            offset_y * tile_size : (offset_y + 1) * tile_size,
                            offset_x * tile_size : (offset_x + 1) * tile_size,
                        ] = read_tile(path, tile_size)
            reduced = np.rint(
                children.reshape(tile_size, 2, tile_size, 2).mean(axis=(1, 3))
            ).astype(np.uint8)
            write_tile(
                parent_directory / f"{parent.x}_{parent.y}.{SURFACE_SUFFIX}",
                reduced,
                compression,
            )
        current = parents
    return current


def class_weights(manifest: dict) -> list[float]:
    result = []
    for item in manifest["classes"]:
        identifier = int(item["id"])
        group = item.get("group", "")
        name = item.get("name", "").lower()
        if identifier == 0 or "wasser" in name or "schnee" in name or "eis" in name:
            weight = 0.0
        elif group == "Landwirtschaft":
            weight = 1.0
        elif group == "Wald":
            weight = 0.85
        elif group == "Siedlung":
            weight = 0.42
        elif "gras" in name:
            weight = 0.65
        elif "boden" in name:
            weight = 0.72
        else:
            weight = 0.60
        result.append(weight)
    return result


def hex_rgb(value: str) -> tuple[int, int, int]:
    number = int(value.lstrip("#"), 16)
    return (number >> 16) & 255, (number >> 8) & 255, number & 255


def write_preview(
    root: Path,
    manifest: dict,
    level: dict,
    tiles: list[Tile],
    weights: list[float],
    size: int,
) -> Path:
    tile_size = int(manifest["tileSize"])
    min_x, max_x = min(tile.x for tile in tiles), max(tile.x for tile in tiles)
    min_y, max_y = min(tile.y for tile in tiles), max(tile.y for tile in tiles)
    width, height = (max_x - min_x + 1) * tile_size, (max_y - min_y + 1) * tile_size
    surface = np.full((height, width), 128, dtype=np.uint8)
    land = np.zeros((height, width), dtype=np.uint8)
    land_suffix = manifest.get("landcoverProduct", {}).get("suffix", "land.z")
    for tile in tiles:
        row, column = (tile.y - min_y) * tile_size, (tile.x - min_x) * tile_size
        surface[row : row + tile_size, column : column + tile_size] = read_tile(
            root / f"z{level['z']}" / f"{tile.x}_{tile.y}.{SURFACE_SUFFIX}", tile_size
        )
        land[row : row + tile_size, column : column + tile_size] = read_tile(
            root / f"z{level['z']}" / f"{tile.x}_{tile.y}.{land_suffix}", tile_size
        )
    crop = min(size, width, height)
    x0, y0 = (width - crop) // 2, (height - crop) // 2
    surface, land = surface[y0 : y0 + crop, x0 : x0 + crop], land[y0 : y0 + crop, x0 : x0 + crop]
    palette = np.array([hex_rgb(item["defaultColor"]) for item in manifest["classes"]], dtype=np.float32)
    base = palette[np.minimum(land, len(palette) - 1)]
    class_weight = np.asarray(weights, dtype=np.float32)[np.minimum(land, len(weights) - 1)]
    detail = np.clip((surface.astype(np.float32) - 128) / 127, -1, 1)
    panels = []
    for strength in STRENGTHS:
        factor = 1 + detail * class_weight * strength
        panels.append(np.clip(base * factor[..., None], 0, 255).astype(np.uint8))
    comparison = np.concatenate(panels, axis=1)
    output_directory = root / "SurfaceTexture"
    output_directory.mkdir(parents=True, exist_ok=True)
    suffix = "-".join(f"{round(value * 100):02d}" for value in STRENGTHS)
    output = output_directory / f"hannover-comparison-{suffix}.png"
    profile = {
        "driver": "PNG",
        "width": comparison.shape[1],
        "height": comparison.shape[0],
        "count": 3,
        "dtype": "uint8",
    }
    with warnings.catch_warnings():
        warnings.simplefilter("ignore", NotGeoreferencedWarning)
        with rasterio.open(output, "w", **profile) as dataset:
            dataset.write(np.moveaxis(comparison, 2, 0))
    metadata = {
        "panelsLeftToRight": [f"{value:.0%}" for value in STRENGTHS],
        "description": "TopoExplorer-Klassenfarben, nur durch neutralen Detailkanal moduliert",
    }
    output.with_suffix(".json").write_text(
        json.dumps(metadata, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
    )
    return output


def update_manifest(
    root: Path,
    manifest: dict,
    minimum_zoom: int,
    maximum_zoom: int,
    weights: list[float],
    args: argparse.Namespace,
) -> None:
    manifest["surfaceTexture"] = {
        "suffix": SURFACE_SUFFIX,
        "minZoom": minimum_zoom,
        "maxZoom": maximum_zoom,
        "defaultStrength": 0.30,
        "fullStrengthResolution": 20.0,
        "hiddenResolution": 320.0,
        "classWeights": weights,
        "sources": [
            {
                "id": "copernicus-sentinel-2-quarterly-mosaic",
                "name": f"Copernicus Sentinel-2 Level-3 Quarterly Mosaic {args.quarter}",
                "license": "Copernicus Sentinel Data Terms",
                "url": SOURCE_URL,
                "role": "Neutraler lokaler Oberflächen-Detailkanal",
            }
        ],
    }
    path = root / "manifest.json"
    temporary = path.with_suffix(".json.tmp")
    temporary.write_text(
        json.dumps(manifest, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
    )
    temporary.replace(path)


def main() -> int:
    args = parse_args()
    if args.radius_km <= 0 or args.highpass_radius < 1:
        raise SystemExit("Radius und Hochpassradius müssen positiv sein")
    if not 90 <= args.clip_percentile < 100 or not 0 <= args.nir_weight <= 1:
        raise SystemExit("Ungültige Clip- oder NIR-Einstellung")
    root = args.map_data.resolve()
    manifest = load_manifest(root)
    level, tiles = select_tiles(manifest, args)
    maximum_zoom = int(level["z"])
    default_minimum = max(int(manifest["minZoom"]), maximum_zoom - 4)
    minimum_zoom = args.minimum_zoom if args.minimum_zoom is not None else default_minimum
    if not int(manifest["minZoom"]) <= minimum_zoom <= maximum_zoom:
        raise SystemExit("--minimum-zoom liegt außerhalb des Manifests")
    print(
        f"Hannover-PoC: z{maximum_zoom}, {len(tiles)} Kacheln, "
        f"{level['resolution']:g} m/Pixel; Filterpyramide bis z{minimum_zoom}"
    )
    if args.dry_run:
        print("Feinkacheln:", " ".join(f"{tile.x}_{tile.y}" for tile in tiles))
        return 0

    weights = class_weights(manifest)
    if args.preview_only:
        update_manifest(root, manifest, minimum_zoom, maximum_zoom, weights, args)
        preview = write_preview(root, manifest, level, tiles, weights, args.preview_size)
        print(f"Vergleich {'/'.join(f'{value:.0%}' for value in STRENGTHS)}: {preview}")
        return 0

    paths = {
        "B02": args.b02,
        "B03": args.b03,
        "B04": args.b04,
        "B08": args.b08,
        "observations": args.observations,
    }
    local_mode = any(path is not None for path in paths.values())
    source = LocalBands(paths, manifest, level) if local_mode else SentinelHubBands(args.quarter, manifest, level)
    tile_size = int(manifest["tileSize"])
    halo = args.highpass_radius * 3 + 2
    details: dict[Tile, tuple[np.ndarray, np.ndarray]] = {}
    samples = []
    try:
        for index, tile in enumerate(tiles, 1):
            detail, valid = detail_for_tile(
                source.read(tile, tile_size, halo),
                tile_size,
                halo,
                args.highpass_radius,
                args.nir_weight,
                args.minimum_observations,
            )
            details[tile] = (detail, valid)
            if np.any(valid):
                samples.append(np.abs(detail[valid][::16]))
            print(f"\rDetailkanal {index}/{len(tiles)}", end="", flush=True)
    finally:
        if isinstance(source, LocalBands):
            source.close()
    print()
    if not samples:
        raise SystemExit("Keine gültigen Sentinel-2-Beobachtungen in der Testregion")
    limit = float(np.percentile(np.concatenate(samples), args.clip_percentile))
    if not math.isfinite(limit) or limit <= 1e-6:
        raise SystemExit("Der Detailkanal enthält keine verwertbare lokale Struktur")
    fine_directory = root / f"z{maximum_zoom}"
    for tile, (detail, valid) in details.items():
        write_tile(
            fine_directory / f"{tile.x}_{tile.y}.{SURFACE_SUFFIX}",
            encode_detail(detail, valid, limit),
            args.compression,
        )
    derive_parent_tiles(
        root, maximum_zoom, tiles, minimum_zoom, tile_size, args.compression
    )
    update_manifest(root, manifest, minimum_zoom, maximum_zoom, weights, args)
    print(f"Surface Texture: neutral 128, symmetrisch geclippt bei ±{limit:.5f}")
    if not args.no_preview:
        preview = write_preview(root, manifest, level, tiles, weights, args.preview_size)
        print(f"Vergleich {'/'.join(f'{value:.0%}' for value in STRENGTHS)}: {preview}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
