#!/usr/bin/env python3
"""Create neutral Sentinel-2 surface-detail tiles for TopoExplorer.

The app dataset only persists the centered, clipped high-pass signal as UInt8
``surface.z``. Remote bands are bundled per request and kept in memory. An
explicit archive path can additionally retain exactly the RGB input used by the
detail pipeline; it never causes a second satellite request.
"""

from __future__ import annotations

import argparse
import getpass
import json
import math
import os
import shutil
import struct
import subprocess
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
STRENGTHS = (0.0, 0.20, 0.30, 0.40, 0.50, 0.60)
EDGE_STRENGTH = 1.0
KEYCHAIN_SERVICE = "de.topoexplorer.cdse"
MAX_PROCESS_PIXELS = 2_500


@dataclass(frozen=True)
class Tile:
    x: int
    y: int


@dataclass(frozen=True)
class TileBlock:
    tiles: tuple[Tile, ...]
    min_x: int
    min_y: int
    max_x: int
    max_y: int

    @property
    def identifier(self) -> str:
        return f"{self.min_x}_{self.min_y}_{self.max_x}_{self.max_y}"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Sentinel-2-Oberflächendetails als TopoExplorer-Kacheln erzeugen"
    )
    parser.add_argument("--map-data", type=Path, default=Path("MapData/Germany"))
    parser.add_argument("--quarter", default="2025-Q2", help="Quartal, z. B. 2025-Q2")
    parser.add_argument(
        "--germany", action="store_true", help="Deutschland vollständig statt Hannover erzeugen"
    )
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
    parser.add_argument("--minimum-observations", type=int)
    parser.add_argument("--minimum-zoom", type=int, help="Niedrigste erzeugte Zoomstufe")
    parser.add_argument("--chunk-tiles", type=int, default=4, help="Kacheln je API-Blockkante")
    parser.add_argument(
        "--calibration-tiles", type=int, default=24, help="Deutschland-Stichprobe zur Normierung"
    )
    parser.add_argument("--normalization-limit", type=float, help="Feste symmetrische Clip-Grenze")
    parser.add_argument(
        "--band-profile",
        choices=("auto", "quota", "rgb", "rgbnir", "full"),
        default="auto",
        help="quota: Grün/Rot/NIR; rgb: RGB; rgbnir: RGB/NIR; full: plus Beobachtungen",
    )
    parser.add_argument(
        "--archive-dir",
        type=Path,
        help="Dieselben genutzten RGB-Pixel zusätzlich als Farbkacheln sichern",
    )
    parser.add_argument(
        "--archive-format",
        choices=("jpeg", "uint16"),
        default="jpeg",
        help="JPEG-Sichtarchiv oder verlustfreue 16-Bit-DN-Kacheln",
    )
    parser.add_argument(
        "--hannover-jpeg",
        type=Path,
        help="Pfad für den JPEG-Prüfexport; Standard: SurfaceTexture/hannover-check.jpg",
    )
    parser.add_argument("--restart", action="store_true", help="Deutschland-Blöcke neu berechnen")
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


def select_hannover_tiles(manifest: dict, args: argparse.Namespace) -> tuple[dict, list[Tile]]:
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


def landcover_suffix(manifest: dict) -> str:
    return manifest.get("landcoverProduct", {}).get("suffix", "land.z")


def select_germany_tiles(
    root: Path, manifest: dict, level: dict, weights: list[float]
) -> list[Tile]:
    suffix = landcover_suffix(manifest)
    weight_lookup = np.asarray(weights, dtype=np.float32)
    selected = []
    for path in sorted((root / f"z{level['z']}").glob(f"*.{suffix}")):
        stem = path.name[: -len(suffix) - 1]
        try:
            x, y = map(int, stem.split("_"))
            classes = np.frombuffer(zlib.decompress(path.read_bytes()), dtype=np.uint8)
        except (ValueError, zlib.error) as error:
            raise SystemExit(f"Landcover-Kachel nicht lesbar: {path}: {error}") from error
        indices = np.minimum(classes, len(weight_lookup) - 1)
        if np.any(weight_lookup[indices] > 0):
            selected.append(Tile(x, y))
    if not selected:
        raise SystemExit("Keine texturierbaren Deutschland-Kacheln gefunden")
    return selected


def tile_blocks(tiles: list[Tile], chunk_tiles: int) -> list[TileBlock]:
    groups: dict[tuple[int, int], list[Tile]] = {}
    for tile in tiles:
        groups.setdefault((tile.x // chunk_tiles, tile.y // chunk_tiles), []).append(tile)
    result = []
    for key in sorted(groups, key=lambda value: (value[1], value[0])):
        members = tuple(sorted(groups[key], key=lambda tile: (tile.y, tile.x)))
        result.append(
            TileBlock(
                members,
                min(tile.x for tile in members),
                min(tile.y for tile in members),
                max(tile.x for tile in members),
                max(tile.y for tile in members),
            )
        )
    return result


def estimated_processing_units(
    blocks: list[TileBlock], tile_size: int, halo: int, input_bands: int
) -> float:
    pixels = sum(
        ((block.max_x - block.min_x + 1) * tile_size + 2 * halo)
        * ((block.max_y - block.min_y + 1) * tile_size + 2 * halo)
        for block in blocks
    )
    return pixels / (512 * 512) * input_bands / 3


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

    def read_window(
        self, pixel_x: int, pixel_y: int, width: int, height: int
    ) -> dict[str, np.ndarray]:
        window = Window(
            pixel_x,
            pixel_y,
            width,
            height,
        )
        result = {band: read_padded(dataset, window) for band, dataset in self.datasets.items()}
        if "observations" not in result:
            result["observations"] = np.ones(
                (int(window.height), int(window.width)), dtype=np.float32
            )
        return result

    def read(self, tile: Tile, tile_size: int, halo: int) -> dict[str, np.ndarray]:
        return self.read_window(
            tile.x * tile_size - halo,
            tile.y * tile_size - halo,
            tile_size + 2 * halo,
            tile_size + 2 * halo,
        )


def keychain_value(account: str) -> str | None:
    try:
        result = subprocess.run(
            [
                "security",
                "find-generic-password",
                "-s",
                KEYCHAIN_SERVICE,
                "-a",
                account,
                "-w",
            ],
            check=True,
            capture_output=True,
            text=True,
        )
    except (FileNotFoundError, subprocess.CalledProcessError):
        return None
    return result.stdout.strip() or None


def dotenv_credentials(path: Path) -> tuple[str, str] | None:
    if not path.is_file():
        return None
    values: dict[str, str] = {}
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError:
        return None
    for raw_line in lines:
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[7:].lstrip()
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        key, value = key.strip(), value.strip()
        key = {
            "CDSE Client-ID": "CDSE_CLIENT_ID",
            "CDSE Client-Secret": "CDSE_CLIENT_SECRET",
        }.get(key, key)
        if key not in ("CDSE_CLIENT_ID", "CDSE_CLIENT_SECRET"):
            continue
        if len(value) >= 2 and value[0] == value[-1] and value[0] in ("'", '"'):
            value = value[1:-1]
        values[key] = value
    client_id = values.get("CDSE_CLIENT_ID")
    client_secret = values.get("CDSE_CLIENT_SECRET")
    return (client_id, client_secret) if client_id and client_secret else None


def cdse_credentials() -> tuple[str, str, str]:
    client_id = os.environ.get("CDSE_CLIENT_ID")
    client_secret = os.environ.get("CDSE_CLIENT_SECRET")
    if client_id and client_secret:
        return client_id, client_secret, "Umgebungsvariablen"
    dotenv = dotenv_credentials(Path(__file__).resolve().parent.parent / ".env")
    if dotenv is not None:
        return dotenv[0], dotenv[1], "lokale .env"
    client_id = keychain_value("client-id")
    client_secret = keychain_value("client-secret")
    if client_id and client_secret:
        return client_id, client_secret, "macOS-Schlüsselbund"
    raise SystemExit(
        "CDSE-Zugangsdaten fehlen. Einmal ./scripts/configure_cdse_credentials.sh "
        "ausführen, lokal in .env ablegen oder CDSE_CLIENT_ID/CDSE_CLIENT_SECRET "
        "nur für diesen Prozess setzen."
    )


class SentinelHubBands:
    def __init__(self, quarter: str, manifest: dict, level: dict, profile: str):
        self.client_id, self.client_secret, credential_source = cdse_credentials()
        self.profile = profile
        self.token = ""
        self.token_expires_at = 0.0
        self._authenticate()
        print(f"CDSE-Anmeldung: {credential_source}; Bandprofil: {profile}")
        self.start, self.end = quarter_interval(quarter)
        self.manifest = manifest
        self.level = level

    @property
    def input_band_count(self) -> int:
        return {"quota": 3, "rgb": 3, "rgbnir": 4, "full": 5}[self.profile]

    def _authenticate(self) -> None:
        form = urllib.parse.urlencode(
            {
                "grant_type": "client_credentials",
                "client_id": self.client_id,
                "client_secret": self.client_secret,
            }
        ).encode()
        request = urllib.request.Request(TOKEN_URL, data=form, method="POST")
        request.add_header("Content-Type", "application/x-www-form-urlencoded")
        try:
            with urllib.request.urlopen(request, timeout=45) as response:
                self.token = json.load(response)["access_token"]
        except (OSError, KeyError, json.JSONDecodeError) as error:
            raise SystemExit(f"CDSE-Anmeldung fehlgeschlagen: {error}") from error
        self.token_expires_at = time.monotonic() + 50 * 60

    def read(self, tile: Tile, tile_size: int, halo: int) -> dict[str, np.ndarray]:
        return self.read_window(
            tile.x * tile_size - halo,
            tile.y * tile_size - halo,
            tile_size + 2 * halo,
            tile_size + 2 * halo,
        )

    def read_window(
        self, pixel_x: int, pixel_y: int, width: int, height: int
    ) -> dict[str, np.ndarray]:
        if width > MAX_PROCESS_PIXELS or height > MAX_PROCESS_PIXELS:
            raise SystemExit(
                f"Process-API-Limit überschritten: {width} × {height} statt maximal "
                f"{MAX_PROCESS_PIXELS} × {MAX_PROCESS_PIXELS} Pixel"
            )
        left, _, _, top = map(float, self.manifest["bounds"])
        resolution = float(self.level["resolution"])
        bounds = [
            left + pixel_x * resolution,
            top - (pixel_y + height) * resolution,
            left + (pixel_x + width) * resolution,
            top - pixel_y * resolution,
        ]
        return self._request_window(bounds, width, height)

    def _evalscript(self) -> str:
        if self.profile == "quota":
            return """//VERSION=3
function setup() {
  return {input: [{bands: ["B03", "B04", "B08", "dataMask"]}],
    output: {bands: 3, sampleType: "UINT16"}};
}
function evaluatePixel(s) {
  return [Math.max(0, 0.7874 * s.B03 + 0.2126 * s.B04),
    Math.max(0, s.B08), s.dataMask];
}
"""
        if self.profile == "rgb":
            return """//VERSION=3
function setup() {
  return {input: [{bands: ["B02", "B03", "B04", "dataMask"]}],
    output: {bands: 4, sampleType: "UINT16"}};
}
function evaluatePixel(s) {
  return [Math.max(0, s.B02), Math.max(0, s.B03), Math.max(0, s.B04), s.dataMask];
}
"""
        if self.profile == "rgbnir":
            return """//VERSION=3
function setup() {
  return {input: [{bands: ["B02", "B03", "B04", "B08", "dataMask"]}],
    output: {bands: 5, sampleType: "UINT16"}};
}
function evaluatePixel(s) {
  return [Math.max(0, s.B02), Math.max(0, s.B03), Math.max(0, s.B04),
    Math.max(0, s.B08), s.dataMask];
}
"""
        return """//VERSION=3
function setup() {
  return {input: [{bands: ["B02", "B03", "B04", "B08", "observations", "dataMask"]}],
    output: {bands: 6, sampleType: "UINT16"}};
}
function evaluatePixel(s) {
  return [Math.max(0, s.B02), Math.max(0, s.B03), Math.max(0, s.B04),
    Math.max(0, s.B08), Math.max(0, s.observations), s.dataMask];
}
"""

    def _request_window(
        self, bounds: list[float], width: int, height: int
    ) -> dict[str, np.ndarray]:
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
            "evalscript": self._evalscript(),
        }
        data = json.dumps(payload).encode()
        for attempt in range(6):
            if time.monotonic() >= self.token_expires_at:
                self._authenticate()
            request = urllib.request.Request(PROCESS_URL, data=data, method="POST")
            request.add_header("Authorization", f"Bearer {self.token}")
            request.add_header("Content-Type", "application/json")
            try:
                with urllib.request.urlopen(request, timeout=120) as response:
                    encoded = response.read()
                with MemoryFile(encoded) as memory, memory.open() as dataset:
                    values = dataset.read().astype(np.float32)
                mask = values[-1] > 0
                if self.profile == "quota":
                    result = {"luminance": values[0], "B08": values[1]}
                elif self.profile == "rgb":
                    result = {"B02": values[0], "B03": values[1], "B04": values[2]}
                elif self.profile == "rgbnir":
                    result = {
                        "B02": values[0],
                        "B03": values[1],
                        "B04": values[2],
                        "B08": values[3],
                    }
                else:
                    result = {
                        "B02": values[0],
                        "B03": values[1],
                        "B04": values[2],
                        "B08": values[3],
                        "observations": values[4],
                    }
                for band in result.values():
                    band[~mask] = np.nan
                result["dataMask"] = mask
                return result
            except urllib.error.HTTPError as error:
                if error.code == 401 and attempt < 5:
                    self._authenticate()
                    continue
                retryable = error.code == 429 or 500 <= error.code < 600
                if not retryable or attempt == 5:
                    raise SystemExit(f"CDSE-Abruf fehlgeschlagen (HTTP {error.code})") from error
                delay = min(float(error.headers.get("Retry-After", 2**attempt)), 30)
                time.sleep(delay)
            except (urllib.error.URLError, rasterio.errors.RasterioError) as error:
                if attempt == 5:
                    raise SystemExit(f"CDSE-Abruf fehlgeschlagen: {error}") from error
                time.sleep(min(2**attempt, 30))
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


def detail_for_region(
    bands: dict[str, np.ndarray],
    core_width: int,
    core_height: int,
    halo: int,
    radius: int,
    nir_weight: float,
    minimum_observations: int,
) -> tuple[np.ndarray, np.ndarray]:
    if "luminance" in bands:
        luminance = bands["luminance"]
        spectral = [luminance]
    else:
        blue, green, red = bands["B02"], bands["B03"], bands["B04"]
        spectral = [blue, green, red]
        luminance = np.maximum(0, 0.0722 * blue + 0.7152 * green + 0.2126 * red)
    observations = bands.get("observations")
    data_mask = bands.get("dataMask")
    valid = (
        np.logical_and.reduce([np.isfinite(value) for value in spectral])
        & (data_mask if data_mask is not None else True)
    )
    if minimum_observations > 0:
        if observations is None:
            raise SystemExit(
                "--minimum-observations benötigt das Bandprofil full oder ein lokales Beobachtungsraster"
            )
        valid &= np.isfinite(observations) & (observations >= minimum_observations)
    log_luminance = np.log1p(luminance).astype(np.float32)
    detail = log_luminance - smooth_valid(log_luminance, valid, radius)
    nir = bands.get("B08")
    if nir is not None and nir_weight > 0:
        nir_valid = valid & np.isfinite(nir)
        log_nir = np.log1p(np.maximum(0, nir)).astype(np.float32)
        detail += nir_weight * (log_nir - smooth_valid(log_nir, nir_valid, radius))
        valid &= nir_valid
    core = np.s_[halo : halo + core_height, halo : halo + core_width]
    return np.ascontiguousarray(detail[core]), np.ascontiguousarray(valid[core])


def detail_for_tile(
    bands: dict[str, np.ndarray],
    tile_size: int,
    halo: int,
    radius: int,
    nir_weight: float,
    minimum_observations: int,
) -> tuple[np.ndarray, np.ndarray]:
    return detail_for_region(
        bands,
        tile_size,
        tile_size,
        halo,
        radius,
        nir_weight,
        minimum_observations,
    )


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


def rgb_display_values(
    blue: np.ndarray, green: np.ndarray, red: np.ndarray
) -> np.ndarray:
    reflectance = np.stack((red, green, blue)) / 10_000.0
    display = np.power(np.clip(reflectance / 0.32, 0, 1), 1 / 1.8)
    return np.rint(display * 255).astype(np.uint8)


def write_rgb_archive_tile(
    archive: Path,
    level: dict,
    manifest: dict,
    tile: Tile,
    rgb: tuple[np.ndarray, np.ndarray, np.ndarray],
    archive_format: str,
    compression: int,
) -> Path:
    directory = archive / "SourceRGB" / f"z{level['z']}"
    directory.mkdir(parents=True, exist_ok=True)
    blue, green, red = (np.nan_to_num(value, nan=0.0) for value in rgb)
    if archive_format == "uint16":
        output = directory / f"{tile.x}_{tile.y}.sentinel-rgb16.z"
        values = np.clip(np.stack((red, green, blue)), 0, 65_535).astype("<u2")
        payload = b"SRG1" + struct.pack("<HH", values.shape[2], values.shape[1]) + values.tobytes()
        temporary = output.with_suffix(output.suffix + ".tmp")
        temporary.write_bytes(zlib.compress(payload, compression))
        temporary.replace(output)
        return output

    output = directory / f"{tile.x}_{tile.y}.sentinel-rgb.jpg"
    values = rgb_display_values(blue, green, red)
    resolution = float(level["resolution"])
    left, _, _, top = map(float, manifest["bounds"])
    transform_value = Affine(
        resolution,
        0,
        left + tile.x * int(manifest["tileSize"]) * resolution,
        0,
        -resolution,
        top - tile.y * int(manifest["tileSize"]) * resolution,
    )
    temporary = output.with_suffix(".tmp.jpg")
    with rasterio.open(
        temporary,
        "w",
        driver="JPEG",
        width=values.shape[2],
        height=values.shape[1],
        count=3,
        dtype="uint8",
        crs=TARGET_CRS,
        transform=transform_value,
        quality=92,
    ) as dataset:
        dataset.write(values)
    temporary.replace(output)
    return output


def read_rgb_archive_tile(
    archive: Path, level: dict, tile: Tile, archive_format: str, tile_size: int
) -> np.ndarray | None:
    directory = archive / "SourceRGB" / f"z{level['z']}"
    if archive_format == "uint16":
        path = directory / f"{tile.x}_{tile.y}.sentinel-rgb16.z"
        if not path.is_file():
            return None
        payload = zlib.decompress(path.read_bytes())
        if len(payload) < 8 or payload[:4] != b"SRG1":
            raise RuntimeError(f"Defekte Sentinel-RGB-Kachel: {path}")
        width, height = struct.unpack_from("<HH", payload, 4)
        values = np.frombuffer(payload, dtype="<u2", offset=8).reshape(3, height, width)
        red, green, blue = values.astype(np.float32)
        return rgb_display_values(blue, green, red)
    path = directory / f"{tile.x}_{tile.y}.sentinel-rgb.jpg"
    if not path.is_file():
        return None
    with rasterio.open(path) as dataset:
        return dataset.read()[:3]


def write_rgb_archive_preview(
    archive: Path,
    level: dict,
    tiles: list[Tile],
    archive_format: str,
    tile_size: int,
    crop_size: int,
    output: Path,
) -> Path | None:
    min_x, max_x = min(tile.x for tile in tiles), max(tile.x for tile in tiles)
    min_y, max_y = min(tile.y for tile in tiles), max(tile.y for tile in tiles)
    width = (max_x - min_x + 1) * tile_size
    height = (max_y - min_y + 1) * tile_size
    mosaic = np.zeros((3, height, width), dtype=np.uint8)
    found = False
    for tile in tiles:
        values = read_rgb_archive_tile(archive, level, tile, archive_format, tile_size)
        if values is None:
            continue
        found = True
        x0, y0 = (tile.x - min_x) * tile_size, (tile.y - min_y) * tile_size
        mosaic[:, y0 : y0 + tile_size, x0 : x0 + tile_size] = values
    if not found:
        return None
    crop = min(crop_size, width, height)
    x0, y0 = (width - crop) // 2, (height - crop) // 2
    values = mosaic[:, y0 : y0 + crop, x0 : x0 + crop]
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_suffix(".tmp.jpg")
    with warnings.catch_warnings():
        warnings.simplefilter("ignore", NotGeoreferencedWarning)
        with rasterio.open(
            temporary,
            "w",
            driver="JPEG",
            width=crop,
            height=crop,
            count=3,
            dtype="uint8",
            quality=95,
        ) as dataset:
            dataset.write(values)
    temporary.replace(output)
    return output


def write_jpeg_preview(source: Path, output: Path, prefix: Path | None = None) -> Path:
    output.parent.mkdir(parents=True, exist_ok=True)
    with warnings.catch_warnings():
        warnings.simplefilter("ignore", NotGeoreferencedWarning)
        with rasterio.open(source) as dataset:
            values = dataset.read()
    if prefix is not None and prefix.is_file():
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", NotGeoreferencedWarning)
            with rasterio.open(prefix) as dataset:
                first = dataset.read()[:3]
        if first.shape[1] != values.shape[1]:
            indices = np.linspace(0, first.shape[1] - 1, values.shape[1]).astype(np.int32)
            first = first[:, indices]
        values = np.concatenate((first, values[:3]), axis=2)
    temporary = output.with_suffix(".tmp.jpg")
    with warnings.catch_warnings():
        warnings.simplefilter("ignore", NotGeoreferencedWarning)
        with rasterio.open(
            temporary,
            "w",
            driver="JPEG",
            width=values.shape[2],
            height=values.shape[1],
            count=3,
            dtype="uint8",
            quality=95,
        ) as dataset:
            dataset.write(values[:3].astype(np.uint8))
    temporary.replace(output)
    return output


def read_tile(path: Path, tile_size: int) -> np.ndarray:
    values = np.frombuffer(zlib.decompress(path.read_bytes()), dtype=np.uint8)
    if values.size != tile_size * tile_size:
        raise RuntimeError(f"Defekte Surface-Kachel: {path}")
    return values.reshape((tile_size, tile_size))


def build_state_path(root: Path) -> Path:
    return root / "SurfaceTexture" / "germany-build.json"


def load_build_state(path: Path, configuration: dict, restart: bool) -> dict:
    if not restart and path.is_file():
        try:
            state = json.loads(path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            state = {}
        if state.get("configuration") == configuration:
            return state
    return {"configuration": configuration, "completedBlocks": []}


def save_build_state(path: Path, state: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(".json.tmp")
    temporary.write_text(json.dumps(state, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    temporary.replace(path)


def archive_preflight(archive: Path, tile_count: int, archive_format: str) -> None:
    probe = archive
    while not probe.exists() and probe != probe.parent:
        probe = probe.parent
    free = shutil.disk_usage(probe).free
    rgb_per_tile = 1_650_000 if archive_format == "uint16" else 380_000
    processed_per_tile = 210_000
    estimated = int(tile_count * (rgb_per_tile + processed_per_tile) * 1.35)
    reserve = 5 * 1024**3
    if free < estimated + reserve:
        raise SystemExit(
            f"Zu wenig freier Speicher für das Sentinel-Archiv: etwa {estimated / 1024**3:.1f} GiB "
            f"plus 5 GiB Reserve benötigt, {free / 1024**3:.1f} GiB frei. "
            "Bitte --archive-dir auf ein externes Laufwerk legen."
        )


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


def process_germany(
    root: Path,
    manifest: dict,
    level: dict,
    tiles: list[Tile],
    source: LocalBands | SentinelHubBands,
    weights: list[float],
    minimum_zoom: int,
    args: argparse.Namespace,
    profile: str,
    minimum_observations: int,
) -> float:
    tile_size = int(manifest["tileSize"])
    halo = args.highpass_radius * 3 + 2
    blocks = tile_blocks(tiles, args.chunk_tiles)
    input_bands = source.input_band_count if isinstance(source, SentinelHubBands) else 0
    if input_bands:
        estimate = estimated_processing_units(blocks, tile_size, halo, input_bands)
        print(
            f"Deutschland: {len(tiles)} Nutzkacheln in {len(blocks)} API-Blöcken; "
            f"geschätzt {estimate:,.0f} Processing Units".replace(",", ".")
        )

    archive = args.archive_dir.resolve() if args.archive_dir else None
    if archive is not None and profile not in ("rgb", "rgbnir", "full"):
        raise SystemExit("Das Farbsichtarchiv benötigt --band-profile rgb, rgbnir oder full")
    if archive is not None:
        archive_preflight(archive, len(tiles), args.archive_format)

    configuration = {
        "quarter": args.quarter,
        "profile": profile,
        "highpassRadius": args.highpass_radius,
        "nirWeight": args.nir_weight,
        "clipPercentile": args.clip_percentile,
        "minimumObservations": minimum_observations,
        "maximumZoom": int(level["z"]),
        "archive": str(archive) if archive else None,
        "archiveFormat": args.archive_format if archive else None,
    }
    state_path = build_state_path(root)
    state = load_build_state(state_path, configuration, args.restart)
    completed = set() if args.restart else set(state.get("completedBlocks", []))
    fine_directory = root / f"z{level['z']}"
    archive_processed = archive / "Processed" if archive else None

    def read_block(
        block: TileBlock,
    ) -> tuple[dict[str, np.ndarray], np.ndarray, np.ndarray]:
        core_width = (block.max_x - block.min_x + 1) * tile_size
        core_height = (block.max_y - block.min_y + 1) * tile_size
        bands = source.read_window(
            block.min_x * tile_size - halo,
            block.min_y * tile_size - halo,
            core_width + 2 * halo,
            core_height + 2 * halo,
        )
        detail, valid = detail_for_region(
            bands,
            core_width,
            core_height,
            halo,
            args.highpass_radius,
            args.nir_weight,
            minimum_observations,
        )
        return bands, detail, valid

    def write_archive_sources(block: TileBlock, bands: dict[str, np.ndarray]) -> None:
        if archive is None:
            return
        for tile in block.tiles:
            x0 = (tile.x - block.min_x) * tile_size
            y0 = (tile.y - block.min_y) * tile_size
            rgb_crop = np.s_[
                halo + y0 : halo + y0 + tile_size,
                halo + x0 : halo + x0 + tile_size,
            ]
            write_rgb_archive_tile(
                archive,
                level,
                manifest,
                tile,
                (bands["B02"][rgb_crop], bands["B03"][rgb_crop], bands["B04"][rgb_crop]),
                args.archive_format,
                args.compression,
            )

    def write_processed(
        block: TileBlock, detail: np.ndarray, valid: np.ndarray, limit: float
    ) -> None:
        for tile in block.tiles:
            x0 = (tile.x - block.min_x) * tile_size
            y0 = (tile.y - block.min_y) * tile_size
            crop = np.s_[y0 : y0 + tile_size, x0 : x0 + tile_size]
            encoded = encode_detail(detail[crop], valid[crop], limit)
            write_tile(
                fine_directory / f"{tile.x}_{tile.y}.{SURFACE_SUFFIX}",
                encoded,
                args.compression,
            )
            if archive_processed is not None:
                directory = archive_processed / f"z{level['z']}"
                directory.mkdir(parents=True, exist_ok=True)
                write_tile(
                    directory / f"{tile.x}_{tile.y}.{SURFACE_SUFFIX}",
                    encoded,
                    args.compression,
                )

    limit = args.normalization_limit
    if limit is None and state.get("normalizationLimit"):
        limit = float(state["normalizationLimit"])
    if limit is None:
        candidates = [block for block in blocks if block.identifier not in completed]
        if not candidates:
            raise SystemExit("Build-Zustand enthält keine Normierungsgrenze; bitte --restart verwenden")
        sample_count = min(args.calibration_tiles, len(candidates))
        sample_indices = np.linspace(0, len(candidates) - 1, sample_count, dtype=np.int32)
        calibration = [candidates[int(index)] for index in sample_indices]
        calibration_directory = root / "SurfaceTexture" / "Calibration"
        calibration_directory.mkdir(parents=True, exist_ok=True)
        samples = []
        for index, block in enumerate(calibration, 1):
            path = calibration_directory / f"{block.identifier}.npz"
            if path.is_file() and not args.restart:
                with np.load(path) as saved:
                    detail = saved["detail"]
                    valid = saved["valid"]
            else:
                bands, detail, valid = read_block(block)
                write_archive_sources(block, bands)
                temporary = path.with_suffix(".tmp.npz")
                np.savez_compressed(temporary, detail=detail, valid=valid)
                temporary.replace(path)
            if np.any(valid):
                samples.append(np.abs(detail[valid][::32]))
            state["calibrationBlocks"] = [item.identifier for item in calibration[:index]]
            save_build_state(state_path, state)
            print(f"\rNormierungsblöcke {index}/{len(calibration)}", end="", flush=True)
        print()
        if not samples:
            raise SystemExit("Keine gültigen Sentinel-2-Beobachtungen in der Normierungsstichprobe")
        limit = float(np.percentile(np.concatenate(samples), args.clip_percentile))
        state["normalizationLimit"] = limit
        save_build_state(state_path, state)
        for block in calibration:
            path = calibration_directory / f"{block.identifier}.npz"
            with np.load(path) as saved:
                write_processed(block, saved["detail"], saved["valid"], limit)
            path.unlink()
            completed.add(block.identifier)
            state["completedBlocks"] = sorted(completed)
            save_build_state(state_path, state)
        state.pop("calibrationBlocks", None)
        save_build_state(state_path, state)
    if not math.isfinite(limit) or limit <= 1e-6:
        raise SystemExit("--normalization-limit muss positiv und endlich sein")
    print(f"Normierungsgrenze: ±{limit:.5f}")

    remaining = [block for block in blocks if block.identifier not in completed]
    for index, block in enumerate(remaining, 1):
        bands, detail, valid = read_block(block)
        write_archive_sources(block, bands)
        write_processed(block, detail, valid, limit)
        completed.add(block.identifier)
        state["completedBlocks"] = sorted(completed)
        save_build_state(state_path, state)
        print(
            f"\rDeutschland-Blöcke {len(completed)}/{len(blocks)} "
            f"(dieser Lauf {index}/{len(remaining)})",
            end="",
            flush=True,
        )
    print()

    maximum_zoom = int(level["z"])
    derive_parent_tiles(
        root, maximum_zoom, tiles, minimum_zoom, tile_size, args.compression
    )
    if archive_processed is not None:
        derive_parent_tiles(
            archive_processed,
            maximum_zoom,
            tiles,
            minimum_zoom,
            tile_size,
            args.compression,
        )
        metadata = {
            "quarter": args.quarter,
            "crs": TARGET_CRS,
            "tileSize": tile_size,
            "sourceProfile": profile,
            "sourceRGB": f"SourceRGB/z{maximum_zoom}",
            "processedVariants": f"Processed/z{minimum_zoom}…z{maximum_zoom}",
            "normalizationLimit": limit,
            "note": "RGB und Detailkanal stammen aus denselben Process-API-Abrufen.",
        }
        archive.mkdir(parents=True, exist_ok=True)
        (archive / "archive.json").write_text(
            json.dumps(metadata, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
        )
    return limit


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


def preview_road_masks(
    root: Path,
    level: dict,
    tiles: list[Tile],
    tile_size: int,
    crop_x: int,
    crop_y: int,
    crop_size: int,
) -> tuple[np.ndarray, np.ndarray, np.ndarray] | None:
    vector_directory = root / "Vectors" / f"z{level['z']}"
    if not vector_directory.is_dir():
        return None
    min_x, min_y = min(tile.x for tile in tiles), min(tile.y for tile in tiles)
    masks = tuple(np.zeros((crop_size, crop_size), dtype=bool) for _ in range(3))

    def draw_segment(mask: np.ndarray, start: tuple[float, float], end: tuple[float, float]) -> None:
        x1, y1 = start[0] - crop_x, start[1] - crop_y
        x2, y2 = end[0] - crop_x, end[1] - crop_y
        if max(x1, x2) < -1 or min(x1, x2) > crop_size or max(y1, y2) < -1 or min(y1, y2) > crop_size:
            return
        steps = max(2, int(math.ceil(max(abs(x2 - x1), abs(y2 - y1)))) + 1)
        xx = np.rint(np.linspace(x1, x2, steps)).astype(np.int32)
        yy = np.rint(np.linspace(y1, y2, steps)).astype(np.int32)
        inside = (xx >= 0) & (xx < crop_size) & (yy >= 0) & (yy < crop_size)
        mask[yy[inside], xx[inside]] = True

    for tile in tiles:
        path = vector_directory / f"{tile.x}_{tile.y}.vector.z"
        if not path.is_file():
            continue
        data = zlib.decompress(path.read_bytes())
        if len(data) < 18 or data[:4] not in (b"TVT1", b"TVT2"):
            continue
        magic = data[:4]
        _, extent, _ = struct.unpack_from("<HHH", data, 4)
        line_count, _ = struct.unpack_from("<II", data, 10)
        offset = 22 if magic == b"TVT2" else 18
        scale = tile_size / extent
        base_x = (tile.x - min_x) * tile_size
        base_y = (tile.y - min_y) * tile_size
        for _ in range(line_count):
            layer, kind, minimum_zoom, _, point_count, name_length = struct.unpack_from(
                "<BBBBHH", data, offset
            )
            offset += 8
            points = np.frombuffer(data, dtype="<i2", count=point_count * 2, offset=offset).reshape(
                point_count, 2
            )
            offset += point_count * 4 + name_length
            if layer != 1 or minimum_zoom > int(level["z"]):
                continue
            target = masks[0 if kind <= 3 else 1 if kind <= 5 else 2]
            for first, second in zip(points, points[1:]):
                draw_segment(
                    target,
                    (base_x + float(first[0]) * scale, base_y + float(first[1]) * scale),
                    (base_x + float(second[0]) * scale, base_y + float(second[1]) * scale),
                )
    return masks if any(np.any(mask) for mask in masks) else None


def dilate(mask: np.ndarray, radius: int) -> np.ndarray:
    if radius <= 0:
        return mask
    padded = np.pad(mask, radius, mode="constant")
    result = np.zeros_like(mask)
    for offset_y in range(-radius, radius + 1):
        for offset_x in range(-radius, radius + 1):
            if offset_x * offset_x + offset_y * offset_y > radius * radius:
                continue
            y0, x0 = radius + offset_y, radius + offset_x
            result |= padded[y0 : y0 + mask.shape[0], x0 : x0 + mask.shape[1]]
    return result


def overlay_preview_roads(
    image: np.ndarray,
    masks: tuple[np.ndarray, np.ndarray, np.ndarray] | None,
) -> np.ndarray:
    if masks is None:
        return image
    result = image.astype(np.float32)

    def blend(mask: np.ndarray, color: tuple[int, int, int], opacity: float) -> None:
        result[mask] = result[mask] * (1 - opacity) + np.asarray(color) * opacity

    primary, regional, local = masks
    blend(dilate(primary, 2), (77, 79, 77), 0.50)
    blend(local, (209, 212, 204), 0.68)
    blend(dilate(regional, 1), (225, 224, 217), 0.80)
    blend(dilate(primary, 1), (237, 235, 227), 0.90)
    return np.clip(result, 0, 255).astype(np.uint8)


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
    padded = np.pad(detail, 1, mode="edge")
    local_mean = (
        padded[1:-1, :-2] + padded[1:-1, 2:] + padded[:-2, 1:-1] + padded[2:, 1:-1]
    ) * 0.25
    detail = np.clip(detail + (detail - local_mean) * EDGE_STRENGTH, -1, 1)
    road_masks = preview_road_masks(root, level, tiles, tile_size, x0, y0, crop)
    panels = []
    for strength in STRENGTHS:
        factor = 1 + detail * class_weight * strength
        panel = np.clip(base * factor[..., None], 0, 255).astype(np.uint8)
        panels.append(overlay_preview_roads(panel, road_masks))
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
        "edgeStrength": EDGE_STRENGTH,
        "roads": road_masks is not None,
        "description": "Klassenfarben mit neutralem Detailkanal und hellen Vektorstraßen",
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


def resolved_band_profile(args: argparse.Namespace) -> str:
    if args.band_profile != "auto":
        return args.band_profile
    if not args.germany:
        return "full"
    return "rgb" if args.archive_dir else "quota"


def main() -> int:
    args = parse_args()
    if args.radius_km <= 0 or args.highpass_radius < 1:
        raise SystemExit("Radius und Hochpassradius müssen positiv sein")
    if not 90 <= args.clip_percentile < 100 or not 0 <= args.nir_weight <= 1:
        raise SystemExit("Ungültige Clip- oder NIR-Einstellung")
    if args.chunk_tiles < 1 or args.calibration_tiles < 1:
        raise SystemExit("Blockkante und Normierungsstichprobe müssen positiv sein")
    root = args.map_data.resolve()
    manifest = load_manifest(root)
    level, hannover_tiles = select_hannover_tiles(manifest, args)
    maximum_zoom = int(level["z"])
    default_minimum = max(int(manifest["minZoom"]), maximum_zoom - 4)
    minimum_zoom = args.minimum_zoom if args.minimum_zoom is not None else default_minimum
    if not int(manifest["minZoom"]) <= minimum_zoom <= maximum_zoom:
        raise SystemExit("--minimum-zoom liegt außerhalb des Manifests")
    weights = class_weights(manifest)
    tiles = select_germany_tiles(root, manifest, level, weights) if args.germany else hannover_tiles
    profile = resolved_band_profile(args)
    minimum_observations = (
        args.minimum_observations
        if args.minimum_observations is not None
        else (1 if profile == "full" else 0)
    )
    halo = args.highpass_radius * 3 + 2
    maximum_block_size = args.chunk_tiles * int(manifest["tileSize"]) + 2 * halo
    if maximum_block_size > MAX_PROCESS_PIXELS:
        raise SystemExit(
            f"--chunk-tiles ist mit Filterhalo zu groß ({maximum_block_size} Pixel; "
            f"Process-API-Limit {MAX_PROCESS_PIXELS})"
        )
    scope = "Deutschland" if args.germany else "Hannover-PoC"
    print(
        f"{scope}: z{maximum_zoom}, {len(tiles)} Kacheln, {level['resolution']:g} m/Pixel; "
        f"Filterpyramide bis z{minimum_zoom}; Profil {profile}"
    )
    if args.dry_run:
        if args.germany:
            blocks = tile_blocks(tiles, args.chunk_tiles)
            units = estimated_processing_units(
                blocks,
                int(manifest["tileSize"]),
                halo,
                {"quota": 3, "rgb": 3, "rgbnir": 4, "full": 5}[profile],
            )
            print(f"API-Blöcke: {len(blocks)}; geschätzt {units:.0f} Processing Units")
        else:
            print("Feinkacheln:", " ".join(f"{tile.x}_{tile.y}" for tile in tiles))
        return 0

    if args.preview_only:
        update_manifest(root, manifest, minimum_zoom, maximum_zoom, weights, args)
        preview = write_preview(
            root, manifest, level, hannover_tiles, weights, args.preview_size
        )
        source_preview = (
            write_rgb_archive_preview(
                args.archive_dir.resolve(),
                level,
                hannover_tiles,
                args.archive_format,
                int(manifest["tileSize"]),
                args.preview_size,
                root / "SurfaceTexture" / "hannover-sentinel-source.jpg",
            )
            if args.archive_dir
            else None
        )
        jpeg = write_jpeg_preview(
            preview,
            args.hannover_jpeg
            or root / "SurfaceTexture" / "hannover-check-00-20-30-40-50-60.jpg",
            source_preview,
        )
        print(f"Vergleich {'/'.join(f'{value:.0%}' for value in STRENGTHS)}: {preview}")
        print(f"Hannover-JPEG: {jpeg}")
        return 0

    paths = {
        "B02": args.b02,
        "B03": args.b03,
        "B04": args.b04,
        "B08": args.b08,
        "observations": args.observations,
    }
    local_mode = any(path is not None for path in paths.values())
    source = (
        LocalBands(paths, manifest, level)
        if local_mode
        else SentinelHubBands(args.quarter, manifest, level, profile)
    )
    tile_size = int(manifest["tileSize"])
    try:
        if args.germany:
            limit = process_germany(
                root,
                manifest,
                level,
                tiles,
                source,
                weights,
                minimum_zoom,
                args,
                profile,
                minimum_observations,
            )
        else:
            details: dict[Tile, tuple[np.ndarray, np.ndarray]] = {}
            rgb_tiles: dict[Tile, tuple[np.ndarray, np.ndarray, np.ndarray]] = {}
            samples = []
            archive = args.archive_dir.resolve() if args.archive_dir else None
            if archive is not None:
                if profile not in ("rgb", "rgbnir", "full"):
                    raise SystemExit(
                        "Das Farbsichtarchiv benötigt --band-profile rgb, rgbnir oder full"
                    )
                archive_preflight(archive, len(tiles), args.archive_format)
            for index, tile in enumerate(tiles, 1):
                bands = source.read(tile, tile_size, halo)
                detail, valid = detail_for_tile(
                    bands,
                    tile_size,
                    halo,
                    args.highpass_radius,
                    args.nir_weight,
                    minimum_observations,
                )
                details[tile] = (detail, valid)
                if archive is not None:
                    core = np.s_[halo : halo + tile_size, halo : halo + tile_size]
                    rgb_tiles[tile] = (
                        bands["B02"][core].copy(),
                        bands["B03"][core].copy(),
                        bands["B04"][core].copy(),
                    )
                if np.any(valid):
                    samples.append(np.abs(detail[valid][::16]))
                print(f"\rDetailkanal {index}/{len(tiles)}", end="", flush=True)
            print()
            if not samples:
                raise SystemExit("Keine gültigen Sentinel-2-Beobachtungen in der Testregion")
            limit = float(np.percentile(np.concatenate(samples), args.clip_percentile))
            if not math.isfinite(limit) or limit <= 1e-6:
                raise SystemExit("Der Detailkanal enthält keine verwertbare lokale Struktur")
            fine_directory = root / f"z{maximum_zoom}"
            for tile, (detail, valid) in details.items():
                encoded = encode_detail(detail, valid, limit)
                write_tile(
                    fine_directory / f"{tile.x}_{tile.y}.{SURFACE_SUFFIX}",
                    encoded,
                    args.compression,
                )
                if archive is not None:
                    directory = archive / "Processed" / f"z{maximum_zoom}"
                    directory.mkdir(parents=True, exist_ok=True)
                    write_tile(
                        directory / f"{tile.x}_{tile.y}.{SURFACE_SUFFIX}",
                        encoded,
                        args.compression,
                    )
                    write_rgb_archive_tile(
                        archive,
                        level,
                        manifest,
                        tile,
                        rgb_tiles[tile],
                        args.archive_format,
                        args.compression,
                    )
            derive_parent_tiles(
                root, maximum_zoom, tiles, minimum_zoom, tile_size, args.compression
            )
            if archive is not None:
                derive_parent_tiles(
                    archive / "Processed",
                    maximum_zoom,
                    tiles,
                    minimum_zoom,
                    tile_size,
                    args.compression,
                )
    finally:
        if isinstance(source, LocalBands):
            source.close()
    update_manifest(root, manifest, minimum_zoom, maximum_zoom, weights, args)
    print(f"Surface Texture: neutral 128, symmetrisch geclippt bei ±{limit:.5f}")
    if not args.no_preview:
        preview = write_preview(
            root, manifest, level, hannover_tiles, weights, args.preview_size
        )
        source_preview = (
            write_rgb_archive_preview(
                args.archive_dir.resolve(),
                level,
                hannover_tiles,
                args.archive_format,
                tile_size,
                args.preview_size,
                root / "SurfaceTexture" / "hannover-sentinel-source.jpg",
            )
            if args.archive_dir
            else None
        )
        jpeg = write_jpeg_preview(
            preview,
            args.hannover_jpeg
            or root / "SurfaceTexture" / "hannover-check-00-20-30-40-50-60.jpg",
            source_preview,
        )
        print(f"Vergleich {'/'.join(f'{value:.0%}' for value in STRENGTHS)}: {preview}")
        print(f"Hannover-JPEG: {jpeg}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
