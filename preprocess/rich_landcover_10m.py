#!/usr/bin/env python3
"""Build the 10 m, 40-class TopoExplorer land-cover pyramid.

The pipeline is deliberately source-sequential: one downloadable raster or
archive is integrated into compressed output tiles and removed before the next
one is fetched. No Germany-wide source raster is held in memory or on disk.
"""

from __future__ import annotations

import argparse
import json
import math
import re
import shutil
import subprocess
import sys
import time
import zipfile
import zlib
from dataclasses import asdict, dataclass
from pathlib import Path

import numpy as np
import rasterio
from rasterio.enums import Resampling
from rasterio.transform import Affine
from rasterio.vrt import WarpedVRT
from rasterio.warp import transform_bounds

from germany_tiles import (
    ELEVATION_MAX,
    ELEVATION_MIN,
    TARGET_CRS,
    TILE_SIZE,
    encode_elevation,
    read_padded,
    write_compressed,
)


PIPELINE_VERSION = 1
RESOLUTION = 10.0
SUFFIX = "landrich.z"
COMPRESSION = 6
WORLD_COVER_BASE = (
    "https://esa-worldcover.s3.eu-central-1.amazonaws.com/v200/2021/map"
)
EUCROP_BASE = (
    "https://jeodpp.jrc.ec.europa.eu/ftp/jrc-opendata/"
    "EUCROPMAP/2018/tiles"
)
FOREST_RECORD = "https://zenodo.org/api/records/13341104"


CLASSES = [
    (0, "Keine Daten", "#101612", "Grundlage"),
    (1, "Siedlung dicht", "#9E3544", "Siedlung"),
    (2, "Siedlung locker", "#C85862", "Siedlung"),
    (3, "Versiegelte Einzelfläche", "#D97972", "Siedlung"),
    (4, "Wasser", "#39779B", "Natur"),
    (5, "Offener oder spärlicher Boden", "#B59B70", "Natur"),
    (6, "Strauchland und Heide", "#89985C", "Natur"),
    (7, "Grasland", "#88AD69", "Natur"),
    (8, "Krautiges Feuchtgebiet", "#5D9E91", "Natur"),
    (9, "Moose und Flechten", "#A8AE83", "Natur"),
    (10, "Schnee und Eis", "#E7EEE9", "Natur"),
    (11, "Landwirtschaft saisonal", "#C7B474", "Landwirtschaft"),
    (12, "Landwirtschaft unbekannt", "#D5C990", "Landwirtschaft"),
    (13, "Weichweizen", "#C69252", "Landwirtschaft"),
    (14, "Hartweizen", "#A97850", "Landwirtschaft"),
    (15, "Gerste", "#D6A34F", "Landwirtschaft"),
    (16, "Roggen", "#B78352", "Landwirtschaft"),
    (17, "Hafer", "#CEB06D", "Landwirtschaft"),
    (18, "Mais", "#E3C83F", "Landwirtschaft"),
    (19, "Reis", "#72AFC1", "Landwirtschaft"),
    (20, "Triticale", "#B98C78", "Landwirtschaft"),
    (21, "Sonstiges Getreide", "#D0A88E", "Landwirtschaft"),
    (22, "Kartoffeln", "#9A6C3E", "Landwirtschaft"),
    (23, "Zuckerrüben", "#805132", "Landwirtschaft"),
    (24, "Sonstige Wurzelkulturen", "#AA7B56", "Landwirtschaft"),
    (25, "Sonstige Industriekulturen", "#B26670", "Landwirtschaft"),
    (26, "Sonnenblumen", "#D48372", "Landwirtschaft"),
    (27, "Raps und Rübsen", "#D6B448", "Landwirtschaft"),
    (28, "Soja", "#8C6F69", "Landwirtschaft"),
    (29, "Hülsenfrüchte", "#99A66B", "Landwirtschaft"),
    (30, "Futterkulturen", "#A7BC72", "Landwirtschaft"),
    (31, "Lärche", "#3E6848", "Wald"),
    (32, "Fichte", "#1F5135", "Wald"),
    (33, "Kiefer", "#315E3B", "Wald"),
    (34, "Buche", "#669664", "Wald"),
    (35, "Eiche", "#779C65", "Wald"),
    (36, "Sonstiger Nadelwald", "#3D6A49", "Wald"),
    (37, "Sonstiger Laubwald", "#79A875", "Wald"),
    (38, "Waldtyp unbekannt", "#50795A", "Wald"),
    (39, "Nadelwald-Offenfläche", "#947B55", "Wald"),
]

EUCROP_TO_CLASS = {
    211: 13, 212: 14, 213: 15, 214: 16, 215: 17, 216: 18,
    217: 19, 218: 20, 219: 21, 221: 22, 222: 23, 223: 24,
    230: 25, 231: 26, 232: 27, 233: 28, 240: 29, 250: 30,
}
TREE_TO_CLASS = {0: 31, 1: 32, 2: 33, 3: 34, 4: 35, 5: 36, 6: 37}


@dataclass(frozen=True)
class Level:
    z: int
    resolution: float
    width: int
    height: int
    tilesX: int
    tilesY: int
    elevationTileSize: int


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Speicherschonende 10-m-Landbedeckung für Deutschland"
    )
    parser.add_argument(
        "--bounds-source", type=Path,
        default=Path("Data/Raw/LandCover/Land_Cover_DE_2015.tif"),
        help="Lokales 2015-Raster; bestimmt Grenzen und markiert Nadelwald-Offenflächen",
    )
    parser.add_argument(
        "--dem", type=Path,
        default=Path("Data/Raw/Elevation/gmted2010_mean_7p5arcsec.tiff"),
    )
    parser.add_argument("--output", type=Path, default=Path("MapData/Germany-10m"))
    parser.add_argument("--work", type=Path, default=Path(".build/landcover-10m"))
    parser.add_argument("--resolution", type=float, default=RESOLUTION)
    parser.add_argument(
        "--elevation-resolution", type=float, default=100.0,
        help="Relief-Abtastung; GMTED enthält keine echten 10-m-Höhenwerte",
    )
    parser.add_argument("--max-work-gb", type=float, default=8.0)
    parser.add_argument("--force", action="store_true")
    parser.add_argument("--keep-downloads", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    return parser.parse_args()


def safe_directory(path: Path) -> Path:
    result = path.resolve()
    if result == Path(result.anchor) or len(result.parts) < 4:
        raise SystemExit(f"Unsicheres Verzeichnis: {result}")
    return result


def build_levels(
    width_m: float, height_m: float, resolution: float, elevation_resolution: float
) -> list[Level]:
    width = math.ceil(width_m / resolution)
    height = math.ceil(height_m / resolution)
    max_zoom = max(0, math.ceil(math.log2(max(width, height) / TILE_SIZE)))
    levels = []
    for z in range(max_zoom + 1):
        level_resolution = resolution * 2 ** (max_zoom - z)
        level_width = math.ceil(width_m / level_resolution)
        level_height = math.ceil(height_m / level_resolution)
        tile_metres = TILE_SIZE * level_resolution
        elevation_size = min(
            TILE_SIZE, max(4, math.ceil(tile_metres / elevation_resolution))
        )
        levels.append(
            Level(
                z, level_resolution, level_width, level_height,
                math.ceil(level_width / TILE_SIZE),
                math.ceil(level_height / TILE_SIZE), elevation_size,
            )
        )
    return levels


def directory_size(path: Path) -> int:
    if not path.exists():
        return 0
    return sum(item.stat().st_size for item in path.rglob("*") if item.is_file())


def enforce_budget(output: Path, work: Path, max_bytes: int) -> None:
    used = directory_size(output) + directory_size(work)
    free = shutil.disk_usage(output.parent).free
    if used > max_bytes:
        raise RuntimeError(
            f"Arbeitsgrenze überschritten: {used / 1e9:.2f} GB > {max_bytes / 1e9:.2f} GB"
        )
    if free < 750_000_000:
        raise RuntimeError("Weniger als 750 MB freier Speicher; Verarbeitung sicher gestoppt")


def download(url: str, target: Path, optional: bool = False) -> bool:
    target.parent.mkdir(parents=True, exist_ok=True)
    partial = target.with_suffix(target.suffix + ".part")
    partial.unlink(missing_ok=True)
    print(f"Lade {target.name}")
    result = subprocess.run(
        [
            "curl", "--fail", "--location", "--silent", "--show-error",
            "--retry", "3", "--retry-all-errors", "--output", str(partial), url,
        ],
        check=False,
    )
    if result.returncode:
        partial.unlink(missing_ok=True)
        if optional:
            print(f"  nicht vorhanden, übersprungen: {target.name}")
            return False
        raise RuntimeError(f"Download fehlgeschlagen: {url}")
    partial.replace(target)
    return True


def read_state(path: Path) -> dict:
    if not path.is_file():
        return {"completed": []}
    return json.loads(path.read_text(encoding="utf-8"))


def save_state(path: Path, state: dict) -> None:
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(state, indent=2) + "\n", encoding="utf-8")
    temporary.replace(path)


def mark_complete(path: Path, state: dict, key: str) -> None:
    if key not in state["completed"]:
        state["completed"].append(key)
        save_state(path, state)


def compressed_tile(path: Path) -> np.ndarray:
    payload = zlib.decompress(path.read_bytes())
    if len(payload) != TILE_SIZE * TILE_SIZE:
        raise RuntimeError(f"Defekte Landkachel: {path}")
    return np.frombuffer(payload, dtype=np.uint8).reshape(TILE_SIZE, TILE_SIZE).copy()


def tile_path(output: Path, z: int, x: int, y: int) -> Path:
    return output / f"z{z}" / f"{x}_{y}.{SUFFIX}"


def tile_range(
    dataset: rasterio.DatasetReader, bounds: tuple[float, float, float, float], level: Level
) -> tuple[range, range]:
    left, _, _, top = bounds
    source_bounds = transform_bounds(
        dataset.crs, TARGET_CRS, *dataset.bounds, densify_pts=21
    )
    span = TILE_SIZE * level.resolution
    x0 = max(0, math.floor((source_bounds[0] - left) / span))
    x1 = min(level.tilesX - 1, math.floor((source_bounds[2] - left) / span))
    y0 = max(0, math.floor((top - source_bounds[3]) / span))
    y1 = min(level.tilesY - 1, math.floor((top - source_bounds[1]) / span))
    if x0 > x1 or y0 > y1:
        return range(0), range(0)
    return range(x0, x1 + 1), range(y0, y1 + 1)


def built_density(built: np.ndarray, radius: int = 5) -> np.ndarray:
    padded = np.pad(built.astype(np.uint16), radius, mode="edge")
    integral = np.pad(padded, ((1, 0), (1, 0))).cumsum(0).cumsum(1)
    width = radius * 2 + 1
    sums = (
        integral[width:, width:] - integral[:-width, width:]
        - integral[width:, :-width] + integral[:-width, :-width]
    )
    return sums.astype(np.float32) / float(width * width)


def classify_worldcover(raw: np.ndarray) -> np.ndarray:
    lookup = np.zeros(256, dtype=np.uint8)
    for source, target in {
        10: 38, 20: 6, 30: 7, 40: 12, 60: 5, 70: 10,
        80: 4, 90: 8, 95: 8, 100: 9,
    }.items():
        lookup[source] = target
    result = lookup[raw]
    built = raw == 50
    if built.any():
        density = built_density(built)
        result[built & (density >= 0.45)] = 1
        result[built & (density >= 0.15) & (density < 0.45)] = 2
        result[built & (density < 0.15)] = 3
    return np.ascontiguousarray(result)


def integrate_raster(
    source_path: Path,
    output: Path,
    bounds: tuple[float, float, float, float],
    level: Level,
    kind: str,
) -> int:
    changes = 0
    transform = Affine(level.resolution, 0, bounds[0], 0, -level.resolution, bounds[3])
    with rasterio.open(source_path) as source:
        xs, ys = tile_range(source, bounds, level)
        if not xs or not ys:
            return 0
        nodata = 255 if kind == "forest" else 0
        dtype = "uint8" if kind != "crop" else "int16"
        with WarpedVRT(
            source, crs=TARGET_CRS, transform=transform,
            width=level.width, height=level.height,
            resampling=Resampling.nearest, nodata=nodata, dtype=dtype,
        ) as vrt:
            for y in ys:
                for x in xs:
                    raw = read_padded(
                        vrt, x * TILE_SIZE, y * TILE_SIZE,
                        TILE_SIZE, TILE_SIZE, nodata,
                    )
                    path = tile_path(output, level.z, x, y)
                    current = compressed_tile(path) if path.is_file() else np.zeros(
                        (TILE_SIZE, TILE_SIZE), dtype=np.uint8
                    )
                    before = current.copy()
                    if kind == "worldcover":
                        mapped = classify_worldcover(raw.astype(np.uint8, copy=False))
                        mask = raw != 0
                        current[mask] = mapped[mask]
                    elif kind == "crop":
                        domain = np.isin(current, (5, 7, 11, 12))
                        for source_class, target_class in EUCROP_TO_CLASS.items():
                            current[domain & (raw == source_class)] = target_class
                        current[domain & (raw == 290)] = 11
                    elif kind == "forest":
                        forest = current == 38
                        for source_class, target_class in TREE_TO_CLASS.items():
                            current[forest & (raw == source_class)] = target_class
                    else:
                        raise ValueError(kind)
                    if not np.array_equal(before, current) or not path.is_file():
                        path.parent.mkdir(parents=True, exist_ok=True)
                        write_compressed(path, current.tobytes(order="C"), COMPRESSION)
                        changes += int(np.count_nonzero(before != current))
    return changes


def worldcover_names(bounds: tuple[float, float, float, float]) -> list[str]:
    west, south, east, north = transform_bounds(
        TARGET_CRS, "EPSG:4326", *bounds, densify_pts=41
    )
    longitudes = range(math.floor(west / 3) * 3, math.ceil(east / 3) * 3, 3)
    latitudes = range(math.floor(south / 3) * 3, math.ceil(north / 3) * 3, 3)

    def coordinate(value: int, positive: str, negative: str, width: int) -> str:
        return f"{positive if value >= 0 else negative}{abs(value):0{width}d}"

    return [
        f"ESA_WorldCover_10m_2021_v200_"
        f"{coordinate(lat, 'N', 'S', 2)}{coordinate(lon, 'E', 'W', 3)}_Map.tif"
        for lat in latitudes for lon in longitudes
    ]


def initialize_missing_tiles(output: Path, level: Level) -> None:
    empty = np.zeros((TILE_SIZE, TILE_SIZE), dtype=np.uint8).tobytes()
    for y in range(level.tilesY):
        for x in range(level.tilesX):
            path = tile_path(output, level.z, x, y)
            if not path.is_file():
                path.parent.mkdir(parents=True, exist_ok=True)
                write_compressed(path, empty, COMPRESSION)


def integrate_worldcover(
    output: Path, work: Path, bounds: tuple[float, float, float, float],
    level: Level, state_path: Path, state: dict, keep: bool,
) -> None:
    for name in worldcover_names(bounds):
        key = f"worldcover/{name}"
        if key in state["completed"]:
            continue
        path = work / "downloads" / name
        if download(f"{WORLD_COVER_BASE}/{name}", path, optional=True):
            changed = integrate_raster(path, output, bounds, level, "worldcover")
            print(f"  integriert: {changed:,} Zellen")
            mark_complete(state_path, state, key)
            if not keep:
                path.unlink(missing_ok=True)
        else:
            # WorldCover publishes no all-ocean GeoTIFFs. Their target cells
            # intentionally remain no-data, so the missing tile is complete.
            mark_complete(state_path, state, key)
    initialize_missing_tiles(output, level)


def crop_tile_ids() -> list[int]:
    # EUCROPMAP is a 40-column LAEA grid. The one-cell margin absorbs its
    # curved edge coordinates; non-intersecting files are discarded untouched.
    return [row * 40 + column for row in range(16, 28) for column in range(13, 25)]


def integrate_crops(
    output: Path, work: Path, bounds: tuple[float, float, float, float],
    level: Level, state_path: Path, state: dict, keep: bool,
) -> None:
    for tile_id in crop_tile_ids():
        name = f"eucropmap_masked_{tile_id}_1600.tif"
        key = f"eucrop/{name}"
        if key in state["completed"]:
            continue
        path = work / "downloads" / name
        if download(f"{EUCROP_BASE}/{name}", path):
            changed = integrate_raster(path, output, bounds, level, "crop")
            print(f"  integriert: {changed:,} Zellen")
            mark_complete(state_path, state, key)
            if not keep:
                path.unlink(missing_ok=True)


def forest_archives(bounds: tuple[float, float, float, float]) -> list[str]:
    first = math.floor(bounds[0] / 100_000) * 100
    last = math.floor(bounds[2] / 100_000) * 100
    return [f"ulx_{column}.zip" for column in range(first, last + 1, 100)]


def integrate_forests(
    output: Path, work: Path, bounds: tuple[float, float, float, float],
    level: Level, state_path: Path, state: dict, keep: bool,
) -> None:
    for archive_name in forest_archives(bounds):
        archive_key = f"forest/{archive_name}"
        if archive_key in state["completed"]:
            continue
        archive_path = work / "downloads" / archive_name
        url = f"{FOREST_RECORD}/files/{archive_name}/content"
        if not download(url, archive_path):
            continue
        with zipfile.ZipFile(archive_path) as archive:
            for member in archive.namelist():
                match = re.search(r"ulx_(\d+)_uly_(\d+).*\.tif$", member)
                if not match:
                    continue
                upper_y = int(match.group(2)) * 1_000
                if upper_y < bounds[1] or upper_y > bounds[3] + 150_000:
                    continue
                member_key = f"{archive_key}/{Path(member).name}"
                if member_key in state["completed"]:
                    continue
                extracted = work / "forest-tile.tif"
                with archive.open(member) as source, extracted.open("wb") as target:
                    shutil.copyfileobj(source, target, length=8 * 1024 * 1024)
                changed = integrate_raster(extracted, output, bounds, level, "forest")
                print(f"  {Path(member).name}: {changed:,} Zellen")
                extracted.unlink(missing_ok=True)
                mark_complete(state_path, state, member_key)
        mark_complete(state_path, state, archive_key)
        if not keep:
            archive_path.unlink(missing_ok=True)


def integrate_openings(
    old_path: Path, output: Path, bounds: tuple[float, float, float, float],
    level: Level, state_path: Path, state: dict,
) -> None:
    key = "local-2015/openings"
    if key in state["completed"]:
        return
    transform = Affine(level.resolution, 0, bounds[0], 0, -level.resolution, bounds[3])
    changed = 0
    with rasterio.open(old_path) as source, WarpedVRT(
        source, crs=TARGET_CRS, transform=transform,
        width=level.width, height=level.height,
        resampling=Resampling.nearest, nodata=0, dtype="uint8",
    ) as vrt:
        for y in range(level.tilesY):
            for x in range(level.tilesX):
                old = read_padded(
                    vrt, x * TILE_SIZE, y * TILE_SIZE,
                    TILE_SIZE, TILE_SIZE, 0,
                )
                path = tile_path(output, level.z, x, y)
                current = compressed_tile(path)
                mask = (old == 4) & np.isin(current, (5, 6, 7))
                changed += int(np.count_nonzero(mask))
                if mask.any():
                    current[mask] = 39
                    write_compressed(path, current.tobytes(order="C"), COMPRESSION)
    print(f"Nadelwald-Offenfläche: {changed:,} Zellen")
    mark_complete(state_path, state, key)


def derive_tile(output: Path, child_z: int, x: int, y: int) -> np.ndarray:
    children = np.zeros((TILE_SIZE * 2, TILE_SIZE * 2), dtype=np.uint8)
    for dy in range(2):
        for dx in range(2):
            path = tile_path(output, child_z, x * 2 + dx, y * 2 + dy)
            if path.is_file():
                children[
                    dy * TILE_SIZE:(dy + 1) * TILE_SIZE,
                    dx * TILE_SIZE:(dx + 1) * TILE_SIZE,
                ] = compressed_tile(path)
    samples = np.stack(
        [children[0::2, 0::2], children[0::2, 1::2],
         children[1::2, 0::2], children[1::2, 1::2]], axis=0,
    )
    result = np.zeros((TILE_SIZE, TILE_SIZE), dtype=np.uint8)
    best_count = np.zeros_like(result)
    priority = np.arange(len(CLASSES), dtype=np.uint8)
    priority[[1, 2, 3, 4, 39]] = [255, 254, 253, 252, 251]
    best_priority = np.zeros_like(result)
    # There are exactly four child samples. Testing those four candidates is
    # identical to scanning all 40 classes, but about ten times cheaper.
    for candidate in samples:
        count = np.sum(samples == candidate, axis=0, dtype=np.uint8)
        candidate_priority = priority[candidate]
        choose = (count > best_count) | (
            (count == best_count) & (count > 0) & (candidate_priority > best_priority)
        )
        choose &= candidate != 0
        result[choose] = candidate[choose]
        best_count[choose] = count[choose]
        best_priority[choose] = candidate_priority[choose]
    return np.ascontiguousarray(result)


def build_pyramid(
    output: Path, levels: list[Level], state_path: Path, state: dict
) -> None:
    for level in reversed(levels[:-1]):
        key = f"pyramid/z{level.z}"
        if key in state["completed"]:
            continue
        directory = output / f"z{level.z}"
        directory.mkdir(exist_ok=True)
        for y in range(level.tilesY):
            for x in range(level.tilesX):
                values = derive_tile(output, level.z + 1, x, y)
                write_compressed(
                    tile_path(output, level.z, x, y), values.tobytes(order="C"), COMPRESSION
                )
        mark_complete(state_path, state, key)
        print(f"Landklassen z{level.z}: {level.tilesX * level.tilesY:,} Kacheln")


def elevation_path(output: Path, z: int, x: int, y: int) -> Path:
    return output / f"z{z}" / f"{x}_{y}.elev.z"


def read_elevation(path: Path, size: int) -> np.ndarray:
    payload = zlib.decompress(path.read_bytes())
    expected = (size + 2) ** 2 * 2
    if len(payload) != expected:
        raise RuntimeError(f"Defekte Höhenkachel: {path}")
    return np.frombuffer(payload, dtype="<u2").reshape(size + 2, size + 2).copy()


def stitch_elevation(output: Path, level: Level) -> None:
    size = level.elevationTileSize
    for y in range(level.tilesY):
        for x in range(level.tilesX - 1):
            left_path = elevation_path(output, level.z, x, y)
            right_path = elevation_path(output, level.z, x + 1, y)
            left = read_elevation(left_path, size)
            right = read_elevation(right_path, size)
            left[:, -1] = right[:, 1]
            right[:, 0] = left[:, -2]
            write_compressed(left_path, left.tobytes(), COMPRESSION)
            write_compressed(right_path, right.tobytes(), COMPRESSION)
    for y in range(level.tilesY - 1):
        for x in range(level.tilesX):
            top_path = elevation_path(output, level.z, x, y)
            bottom_path = elevation_path(output, level.z, x, y + 1)
            top_values = read_elevation(top_path, size)
            bottom_values = read_elevation(bottom_path, size)
            top_values[-1, :] = bottom_values[1, :]
            bottom_values[0, :] = top_values[-2, :]
            write_compressed(top_path, top_values.tobytes(), COMPRESSION)
            write_compressed(bottom_path, bottom_values.tobytes(), COMPRESSION)


def build_elevation(
    dem_path: Path, output: Path, bounds: tuple[float, float, float, float],
    levels: list[Level], state_path: Path, state: dict,
) -> None:
    with rasterio.open(dem_path) as dem:
        for level in levels:
            key = f"elevation/z{level.z}"
            if key in state["completed"]:
                continue
            size = level.elevationTileSize
            sample_resolution = TILE_SIZE * level.resolution / size
            transform = Affine(sample_resolution, 0, bounds[0], 0, -sample_resolution, bounds[3])
            width = level.tilesX * size
            height = level.tilesY * size
            with WarpedVRT(
                dem, crs=TARGET_CRS, transform=transform, width=width, height=height,
                resampling=Resampling.bilinear, nodata=dem.nodata, dtype="int16",
            ) as vrt:
                for y in range(level.tilesY):
                    for x in range(level.tilesX):
                        values = read_padded(
                            vrt, x * size - 1, y * size - 1, size + 2, size + 2,
                            int(dem.nodata if dem.nodata is not None else -32768),
                        )
                        encoded = encode_elevation(values, dem.nodata)
                        write_compressed(
                            elevation_path(output, level.z, x, y),
                            encoded.tobytes(order="C"), COMPRESSION,
                        )
            stitch_elevation(output, level)
            mark_complete(state_path, state, key)
            print(f"Relief z{level.z}: {size}×{size} Werte je Kachel")


def manifest_document(
    bounds: tuple[float, float, float, float], levels: list[Level]
) -> dict:
    return {
        "version": 1,
        "name": "Deutschland Landbedeckung 10 m",
        "crs": TARGET_CRS,
        "bounds": list(bounds),
        "tileSize": TILE_SIZE,
        "elevationBorder": 1,
        "minZoom": levels[0].z,
        "maxZoom": levels[-1].z,
        "elevationMin": ELEVATION_MIN,
        "elevationMax": ELEVATION_MAX,
        "compression": "zlib",
        "levels": [asdict(level) for level in levels],
        "classes": [
            {"id": class_id, "name": name, "defaultColor": color, "group": group}
            for class_id, name, color, group in CLASSES
        ],
        "landcoverProduct": {
            "name": "Artenreiche Gesamtkarte 10 m", "suffix": SUFFIX,
        },
        "sources": [
            {
                "name": "ESA WorldCover", "year": 2021,
                "role": "Grundbedeckung", "license": "CC BY 4.0",
                "url": "https://esa-worldcover.org/",
            },
            {
                "name": "JRC EUCROPMAP", "year": 2018,
                "role": "Kulturarten", "license": "European Commission reuse notice",
                "url": "https://data.jrc.ec.europa.eu/dataset/15f86c84-eae1-4723-8e00-c1b35c8f56b9",
            },
            {
                "name": "ForestPaths European Tree Genus Map", "year": 2020,
                "role": "Baumgattungen (Early Access)", "license": "CC BY 4.0",
                "url": "https://zenodo.org/records/13341104",
            },
            {
                "name": "Land Cover DE", "year": 2015,
                "role": "nur Nadelwald-Offenfläche", "license": "CC BY-NC 4.0",
                "url": "https://geoservice.dlr.de/data-assets/1ccmlap3mn39.html",
            },
            {
                "name": "GMTED2010", "year": 2010,
                "role": "Relief", "license": "Public Domain",
                "url": "https://www.usgs.gov/coastal-changes-and-impacts/gmted2010",
            },
        ],
        "generatedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "processing": {
            "resolutionMetres": RESOLUTION,
            "sourceSequential": True,
            "temporaryDownloadsRetained": False,
            "pipelineVersion": PIPELINE_VERSION,
        },
    }


def main() -> int:
    args = parse_args()
    if args.resolution != 10:
        raise SystemExit("Diese Kartenprodukt-Version ist auf 10 m festgelegt")
    if args.elevation_resolution < args.resolution:
        raise SystemExit("Die Relief-Auflösung darf nicht feiner als die Landbedeckung sein")
    for path in (args.bounds_source, args.dem):
        if not path.is_file():
            raise SystemExit(f"Quelldatei fehlt: {path}")
    output = safe_directory(args.output)
    work = safe_directory(args.work)
    with rasterio.open(args.bounds_source) as source:
        bounds = tuple(float(value) for value in transform_bounds(
            source.crs, TARGET_CRS, *source.bounds, densify_pts=21
        ))
    levels = build_levels(
        bounds[2] - bounds[0], bounds[3] - bounds[1],
        args.resolution, args.elevation_resolution,
    )
    total = sum(level.tilesX * level.tilesY for level in levels)
    print(
        f"10-m-Karte: {levels[-1].width:,}×{levels[-1].height:,} Zellen · "
        f"{len(levels)} Stufen · {total:,} Kacheln"
    )
    for level in levels:
        print(
            f"  z{level.z}: {level.resolution:g} m · "
            f"{level.tilesX}×{level.tilesY} · Relief {level.elevationTileSize}²"
        )
    print(
        f"Quellenfolgen: {len(worldcover_names(bounds))} WorldCover-Kacheln · "
        f"{len(crop_tile_ids())} EUCROPMAP-Kandidaten · "
        f"{len(forest_archives(bounds))} ForestPaths-Archive"
    )
    if args.dry_run:
        return 0

    if args.force and output.exists():
        shutil.rmtree(output)
    output.mkdir(parents=True, exist_ok=True)
    work.mkdir(parents=True, exist_ok=True)
    state_path = output / ".rich-landcover-state.json"
    state = read_state(state_path)
    incomplete = output / ".incomplete"
    incomplete.write_text("10-m-Landbedeckung wird aufgebaut\n", encoding="utf-8")
    (output / "manifest.json").write_text(
        json.dumps(manifest_document(bounds, levels), ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    max_bytes = int(args.max_work_gb * 1_000_000_000)

    finest = levels[-1]
    integrate_worldcover(
        output, work, bounds, finest, state_path, state, args.keep_downloads
    )
    enforce_budget(output, work, max_bytes)
    integrate_crops(output, work, bounds, finest, state_path, state, args.keep_downloads)
    enforce_budget(output, work, max_bytes)
    integrate_forests(
        output, work, bounds, finest, state_path, state, args.keep_downloads
    )
    enforce_budget(output, work, max_bytes)
    integrate_openings(args.bounds_source, output, bounds, finest, state_path, state)
    build_pyramid(output, levels, state_path, state)
    build_elevation(args.dem, output, bounds, levels, state_path, state)
    enforce_budget(output, work, max_bytes)

    state_path.unlink(missing_ok=True)
    incomplete.unlink(missing_ok=True)
    if not args.keep_downloads:
        shutil.rmtree(work, ignore_errors=True)
    print(f"Fertig: {output} · {directory_size(output) / 1e9:.2f} GB")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        print("\nAbgebrochen; der nächste Lauf setzt fort.", file=sys.stderr)
        raise SystemExit(130)
