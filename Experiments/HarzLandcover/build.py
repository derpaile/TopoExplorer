#!/usr/bin/env python3
"""Build a disk-bounded, OSM-free 10 m land-cover portrait of the Harz."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import shutil
import subprocess
import time
import zipfile
from pathlib import Path

import numpy as np
import rasterio
from rasterio.enums import Resampling
from rasterio.transform import from_bounds, from_origin
from rasterio.warp import reproject, transform_bounds
from rasterio.windows import Window, from_bounds as window_from_bounds


HERE = Path(__file__).resolve().parent
PROJECT = HERE.parents[1]
WORK = HERE / "work"
OUTPUT = HERE / "output"

AOI_WGS84 = (10.35, 51.60, 11.08, 52.02)
TARGET_CRS = "EPSG:3035"
TARGET_RESOLUTION = 10.0

WORLD_COVER_URL = (
    "https://esa-worldcover.s3.eu-central-1.amazonaws.com/v200/2021/map/"
    "ESA_WorldCover_10m_2021_v200_N51E009_Map.tif"
)
WORLD_COVER_SIZE = 85_525_178

FOREST_ARCHIVE_URL = (
    "https://zenodo.org/api/records/13341104/files/ulx_4300.zip/content"
)
FOREST_ARCHIVE_MD5 = "9ac87b2f7354abe37aaa76e05ac0370e"
FOREST_MEMBER = "spp_pred_ulx_4300_uly_3240.tif"

EUCROP_TILE_IDS = (818, 819, 858, 859)
EUCROP_BASE_URL = (
    "https://jeodpp.jrc.ec.europa.eu/ftp/jrc-opendata/"
    "EUCROPMAP/2018/tiles"
)

LOCAL_2015 = PROJECT / "Data/Raw/LandCover/Land_Cover_DE_2015.tif"
LOCAL_ELEVATION = PROJECT / "Data/Raw/Elevation/gmted2010_mean_7p5arcsec.tiff"


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
    211: 13,
    212: 14,
    213: 15,
    214: 16,
    215: 17,
    216: 18,
    217: 19,
    218: 20,
    219: 21,
    221: 22,
    222: 23,
    223: 24,
    230: 25,
    231: 26,
    232: 27,
    233: 28,
    240: 29,
    250: 30,
}

TREE_TO_CLASS = {0: 31, 1: 32, 2: 33, 3: 34, 4: 35, 5: 36, 6: 37}

SOURCE_NAMES = {
    0: "Keine Daten",
    1: "ESA WorldCover 2021",
    2: "JRC EUCROPMAP 2018",
    3: "ForestPaths 2020",
    4: "WorldCover 2021 + Landbedeckung 2015",
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Isolierte 10-m-Harzkarte erzeugen")
    parser.add_argument("--keep-downloads", action="store_true")
    parser.add_argument("--force-download", action="store_true")
    parser.add_argument("--max-work-mb", type=int, default=6000)
    return parser.parse_args()


def directory_size(path: Path) -> int:
    if not path.exists():
        return 0
    return sum(item.stat().st_size for item in path.rglob("*") if item.is_file())


def ensure_budget(max_bytes: int) -> None:
    used = directory_size(WORK) + directory_size(OUTPUT)
    if used > max_bytes:
        raise RuntimeError(
            f"Speichergrenze überschritten: {used / 1_000_000:.0f} MB "
            f"> {max_bytes / 1_000_000:.0f} MB"
        )


def md5(path: Path) -> str:
    digest = hashlib.md5()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(8 * 1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def download(url: str, destination: Path, force: bool, expected_size: int | None = None) -> None:
    if destination.is_file() and not force:
        if expected_size is None or destination.stat().st_size == expected_size:
            print(f"Vorhanden: {destination.name}")
            return
    destination.parent.mkdir(parents=True, exist_ok=True)
    temporary = destination.with_suffix(destination.suffix + ".part")
    temporary.unlink(missing_ok=True)
    print(f"Lade {destination.name}")
    subprocess.run(
        [
            "curl",
            "--fail",
            "--location",
            "--silent",
            "--show-error",
            "--retry",
            "3",
            "--output",
            str(temporary),
            url,
        ],
        check=True,
    )
    if expected_size is not None and temporary.stat().st_size != expected_size:
        raise RuntimeError(f"Unerwartete Größe für {destination.name}")
    temporary.replace(destination)


def target_grid() -> tuple[rasterio.Affine, int, int, tuple[float, float, float, float]]:
    left, bottom, right, top = transform_bounds(
        "EPSG:4326", TARGET_CRS, *AOI_WGS84, densify_pts=41
    )
    left = math.floor(left / TARGET_RESOLUTION) * TARGET_RESOLUTION
    bottom = math.floor(bottom / TARGET_RESOLUTION) * TARGET_RESOLUTION
    right = math.ceil(right / TARGET_RESOLUTION) * TARGET_RESOLUTION
    top = math.ceil(top / TARGET_RESOLUTION) * TARGET_RESOLUTION
    width = int(round((right - left) / TARGET_RESOLUTION))
    height = int(round((top - bottom) / TARGET_RESOLUTION))
    return from_origin(left, top, TARGET_RESOLUTION, TARGET_RESOLUTION), width, height, (
        left,
        bottom,
        right,
        top,
    )


def reproject_band(
    path: Path,
    destination: np.ndarray,
    transform: rasterio.Affine,
    resampling: Resampling = Resampling.nearest,
    src_nodata: int | float | None = None,
    dst_nodata: int | float = 0,
) -> None:
    with rasterio.open(path) as source:
        reproject(
            source=rasterio.band(source, 1),
            destination=destination,
            src_transform=source.transform,
            src_crs=source.crs,
            src_nodata=source.nodata if src_nodata is None else src_nodata,
            dst_transform=transform,
            dst_crs=TARGET_CRS,
            dst_nodata=dst_nodata,
            resampling=resampling,
            num_threads=2,
        )


def fetch_sources(force: bool, max_bytes: int) -> dict[str, object]:
    downloads = WORK / "downloads"
    worldcover = downloads / "worldcover-2021-N51E009.tif"
    forest_archive = downloads / "forestpaths-ulx_4300.zip"
    forest_tile = WORK / "forestpaths" / FOREST_MEMBER

    download(WORLD_COVER_URL, worldcover, force, WORLD_COVER_SIZE)
    ensure_budget(max_bytes)
    download(FOREST_ARCHIVE_URL, forest_archive, force)
    if md5(forest_archive) != FOREST_ARCHIVE_MD5:
        raise RuntimeError("ForestPaths-Prüfsumme stimmt nicht")
    ensure_budget(max_bytes)

    forest_tile.parent.mkdir(parents=True, exist_ok=True)
    if force or not forest_tile.is_file():
        with zipfile.ZipFile(forest_archive) as archive:
            with archive.open(FOREST_MEMBER) as source, forest_tile.open("wb") as target:
                shutil.copyfileobj(source, target, length=8 * 1024 * 1024)

    crop_tiles: list[Path] = []
    for tile_id in EUCROP_TILE_IDS:
        name = f"eucropmap_masked_{tile_id}_1600.tif"
        path = downloads / name
        download(f"{EUCROP_BASE_URL}/{name}", path, force)
        crop_tiles.append(path)
    ensure_budget(max_bytes)
    return {
        "worldcover": worldcover,
        "forest": forest_tile,
        "forestArchive": forest_archive,
        "cropTiles": crop_tiles,
    }


def settlement_density(built: np.ndarray, transform: rasterio.Affine) -> np.ndarray:
    height, width = built.shape
    coarse_width = math.ceil(width / 10)
    coarse_height = math.ceil(height / 10)
    left = transform.c
    top = transform.f
    right = left + width * transform.a
    bottom = top + height * transform.e
    coarse_transform = from_bounds(left, bottom, right, top, coarse_width, coarse_height)
    coarse = np.zeros((coarse_height, coarse_width), dtype=np.float32)
    reproject(
        source=built.astype(np.uint8, copy=False),
        destination=coarse,
        src_transform=transform,
        src_crs=TARGET_CRS,
        dst_transform=coarse_transform,
        dst_crs=TARGET_CRS,
        resampling=Resampling.average,
    )
    coarse = np.clip(np.rint(coarse * 100), 0, 100).astype(np.uint8)
    density = np.zeros_like(built, dtype=np.uint8)
    reproject(
        source=coarse,
        destination=density,
        src_transform=coarse_transform,
        src_crs=TARGET_CRS,
        dst_transform=transform,
        dst_crs=TARGET_CRS,
        resampling=Resampling.nearest,
    )
    return density


def classify(
    worldcover: np.ndarray,
    crop: np.ndarray,
    trees: np.ndarray,
    old_landcover: np.ndarray,
    transform: rasterio.Affine,
) -> tuple[np.ndarray, np.ndarray]:
    result = np.zeros(worldcover.shape, dtype=np.uint8)
    source = np.zeros(worldcover.shape, dtype=np.uint8)

    base = {
        20: 6,
        30: 7,
        40: 12,
        60: 5,
        70: 10,
        80: 4,
        90: 8,
        95: 8,
        100: 9,
    }
    for raw, final in base.items():
        mask = worldcover == raw
        result[mask] = final
        source[mask] = 1

    forest = worldcover == 10
    result[forest] = 38
    source[forest] = 1
    for raw, final in TREE_TO_CLASS.items():
        mask = forest & (trees == raw)
        result[mask] = final
        source[mask] = 3

    built = worldcover == 50
    density = settlement_density(built, transform)
    result[built & (density >= 45)] = 1
    result[built & (density >= 15) & (density < 45)] = 2
    result[built & (density < 15)] = 3
    source[built] = 1
    del density

    crop_domain = np.isin(worldcover, (30, 40, 60))
    exact_crop = np.isin(crop, tuple(EUCROP_TO_CLASS)) & crop_domain
    for raw, final in EUCROP_TO_CLASS.items():
        mask = (crop == raw) & crop_domain
        result[mask] = final
        source[mask] = 2
    seasonal = (crop == 290) & crop_domain
    result[seasonal] = 11
    source[seasonal] = 2

    opening = (
        (old_landcover == 4)
        & np.isin(worldcover, (20, 30, 60))
        & ~exact_crop
        & ~seasonal
    )
    result[opening] = 39
    source[opening] = 4

    return result, source


def hex_rgb(value: str) -> tuple[int, int, int]:
    value = value.lstrip("#")
    return tuple(int(value[index : index + 2], 16) for index in (0, 2, 4))


def write_class_raster(
    path: Path,
    array: np.ndarray,
    transform: rasterio.Affine,
    class_names: bool,
) -> None:
    profile = {
        "driver": "GTiff",
        "width": array.shape[1],
        "height": array.shape[0],
        "count": 1,
        "dtype": "uint8",
        "crs": TARGET_CRS,
        "transform": transform,
        "nodata": 0,
        "tiled": True,
        "blockxsize": 512,
        "blockysize": 512,
        "compress": "DEFLATE",
        "zlevel": 9,
        "predictor": 2,
        "bigtiff": "IF_SAFER",
    }
    with rasterio.open(path, "w", **profile) as destination:
        destination.write(array, 1)
        if class_names:
            destination.write_colormap(
                1, {class_id: (*hex_rgb(color), 255) for class_id, _, color, _ in CLASSES}
            )
            destination.update_tags(
                classes=json.dumps(
                    {class_id: name for class_id, name, _, _ in CLASSES},
                    ensure_ascii=False,
                )
            )
        else:
            destination.update_tags(
                sources=json.dumps(SOURCE_NAMES, ensure_ascii=False)
            )
        destination.build_overviews([2, 4, 8, 16, 32], Resampling.nearest)
        destination.update_tags(ns="rio_overview", resampling="nearest")


def array_window(
    array: np.ndarray,
    transform: rasterio.Affine,
    bounds_wgs84: tuple[float, float, float, float] | None,
) -> tuple[np.ndarray, rasterio.Affine]:
    if bounds_wgs84 is None:
        return array, transform
    bounds = transform_bounds("EPSG:4326", TARGET_CRS, *bounds_wgs84, densify_pts=21)
    raw = window_from_bounds(*bounds, transform=transform)
    row_start = max(0, int(math.floor(raw.row_off)))
    col_start = max(0, int(math.floor(raw.col_off)))
    row_stop = min(array.shape[0], int(math.ceil(raw.row_off + raw.height)))
    col_stop = min(array.shape[1], int(math.ceil(raw.col_off + raw.width)))
    window = Window(col_start, row_start, col_stop - col_start, row_stop - row_start)
    return array[row_start:row_stop, col_start:col_stop], rasterio.windows.transform(
        window, transform
    )


def render_preview(
    name: str,
    classes: np.ndarray,
    transform: rasterio.Affine,
    elevation_path: Path,
    bounds_wgs84: tuple[float, float, float, float] | None,
    max_width: int,
) -> Path:
    region, region_transform = array_window(classes, transform, bounds_wgs84)
    scale = max(1.0, region.shape[1] / max_width)
    width = max(1, int(round(region.shape[1] / scale)))
    height = max(1, int(round(region.shape[0] / scale)))
    left = region_transform.c
    top = region_transform.f
    right = left + region.shape[1] * region_transform.a
    bottom = top + region.shape[0] * region_transform.e
    preview_transform = from_bounds(left, bottom, right, top, width, height)

    reduced = np.zeros((height, width), dtype=np.uint8)
    reproject(
        source=region,
        destination=reduced,
        src_transform=region_transform,
        src_crs=TARGET_CRS,
        dst_transform=preview_transform,
        dst_crs=TARGET_CRS,
        resampling=Resampling.mode,
    )

    palette = np.zeros((256, 3), dtype=np.uint8)
    for class_id, _, color, _ in CLASSES:
        palette[class_id] = hex_rgb(color)
    rgb = palette[reduced].astype(np.float32)

    elevation = np.zeros((height, width), dtype=np.float32)
    with rasterio.open(elevation_path) as source_elevation:
        reproject(
            source=rasterio.band(source_elevation, 1),
            destination=elevation,
            src_transform=source_elevation.transform,
            src_crs=source_elevation.crs,
            src_nodata=source_elevation.nodata,
            dst_transform=preview_transform,
            dst_crs=TARGET_CRS,
            dst_nodata=np.nan,
            resampling=Resampling.bilinear,
        )
    valid = np.isfinite(elevation)
    if valid.any():
        elevation[~valid] = float(np.nanmedian(elevation))
        dy, dx = np.gradient(elevation)
        slope = np.pi / 2 - np.arctan(np.hypot(dx, dy))
        aspect = np.arctan2(-dx, dy)
        altitude = math.radians(38)
        azimuth = math.radians(315)
        shade = np.sin(altitude) * np.sin(slope) + np.cos(altitude) * np.cos(
            slope
        ) * np.cos(azimuth - aspect)
        shade = np.clip((shade + 1) / 2, 0, 1)
        modulation = 0.78 + 0.34 * shade
        rgb *= modulation[:, :, None]
    rgb[reduced == 0] = palette[0]
    rgb = np.clip(rgb, 0, 255).astype(np.uint8)

    path = OUTPUT / name
    profile = {
        "driver": "PNG",
        "width": width,
        "height": height,
        "count": 3,
        "dtype": "uint8",
        "crs": TARGET_CRS,
        "transform": preview_transform,
        "compress": "DEFLATE",
        "zlevel": 9,
    }
    with rasterio.open(path, "w", **profile) as destination:
        destination.write(np.moveaxis(rgb, 2, 0))
    return path


def build(max_bytes: int, force: bool, keep_downloads: bool) -> None:
    if not LOCAL_2015.is_file() or not LOCAL_ELEVATION.is_file():
        raise RuntimeError("Lokale 2015-Landbedeckung oder Höhendaten fehlen")
    WORK.mkdir(parents=True, exist_ok=True)
    OUTPUT.mkdir(parents=True, exist_ok=True)
    sources = fetch_sources(force, max_bytes)
    transform, width, height, bounds = target_grid()
    print(f"Zielraster: {width} × {height} Zellen ({width * height:,})")

    worldcover = np.zeros((height, width), dtype=np.uint8)
    reproject_band(sources["worldcover"], worldcover, transform)

    crop = np.zeros((height, width), dtype=np.int16)
    for crop_path in sources["cropTiles"]:
        tile = np.zeros((height, width), dtype=np.int16)
        reproject_band(crop_path, tile, transform)
        mask = tile != 0
        crop[mask] = tile[mask]
        del tile

    trees = np.full((height, width), 255, dtype=np.uint8)
    reproject_band(sources["forest"], trees, transform, src_nodata=255, dst_nodata=255)

    old_landcover = np.zeros((height, width), dtype=np.uint8)
    reproject_band(LOCAL_2015, old_landcover, transform)

    classes, provenance = classify(worldcover, crop, trees, old_landcover, transform)
    del worldcover, crop, trees, old_landcover

    class_path = OUTPUT / "harz-landcover-10m.tif"
    source_path = OUTPUT / "harz-source-10m.tif"
    write_class_raster(class_path, classes, transform, class_names=True)
    write_class_raster(source_path, provenance, transform, class_names=False)

    previews = [
        render_preview(
            "harz-overview.png", classes, transform, LOCAL_ELEVATION, None, 2400
        ),
        render_preview(
            "harz-nordharz.png",
            classes,
            transform,
            LOCAL_ELEVATION,
            (10.43, 51.82, 11.02, 52.015),
            2600,
        ),
        render_preview(
            "harz-brocken.png",
            classes,
            transform,
            LOCAL_ELEVATION,
            (10.43, 51.67, 10.83, 51.91),
            2400,
        ),
    ]

    counts = np.bincount(classes.ravel(), minlength=len(CLASSES))
    total = int(counts.sum())
    class_rows = []
    for class_id, name, color, group in CLASSES:
        pixels = int(counts[class_id])
        class_rows.append(
            {
                "id": class_id,
                "name": name,
                "group": group,
                "color": color,
                "pixels": pixels,
                "areaKm2": round(pixels / 10000, 3),
                "share": round(pixels / total, 6),
            }
        )
    manifest = {
        "name": "Harz Landbedeckung 10 m",
        "generatedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "osmUsed": False,
        "resolutionMetres": 10,
        "crs": TARGET_CRS,
        "aoiWgs84": AOI_WGS84,
        "bounds": bounds,
        "width": width,
        "height": height,
        "classes": class_rows,
        "sources": [
            {"name": "ESA WorldCover", "year": 2021, "role": "Grundlage"},
            {"name": "JRC EUCROPMAP", "year": 2018, "role": "Kulturarten"},
            {
                "name": "ForestPaths European Tree Genus Map",
                "year": 2020,
                "role": "Baumgattungen, Early Access",
            },
            {
                "name": "Landbedeckung Deutschland",
                "year": 2015,
                "role": "nur Nadelwald-Offenfläche",
            },
        ],
        "files": {
            path.name: path.stat().st_size
            for path in [class_path, source_path, *previews]
        },
    }
    (OUTPUT / "manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    ensure_budget(max_bytes)
    print(
        "Klassen mit Fläche: "
        + ", ".join(row["name"] for row in class_rows if row["pixels"] > 0)
    )
    print(
        f"Ergebnis: {(directory_size(OUTPUT) / 1_000_000):.1f} MB; "
        f"Spitzenbestand: {((directory_size(WORK) + directory_size(OUTPUT)) / 1_000_000):.1f} MB"
    )
    if not keep_downloads:
        shutil.rmtree(WORK)
        print("Temporäre Downloads entfernt")


def main() -> int:
    args = parse_args()
    if args.max_work_mb < 1000:
        raise SystemExit("Die Speichergrenze muss mindestens 1000 MB betragen")
    build(
        max_bytes=args.max_work_mb * 1_000_000,
        force=args.force_download,
        keep_downloads=args.keep_downloads,
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

