#!/usr/bin/env python3
"""Build a compact, multiresolution Germany tile pyramid for TopoExplorer.

The source rasters are never loaded as a whole. Every output tile contains:
  - 512 x 512 uint8 land-cover class IDs
  - 514 x 514 uint16 normalized elevation with a one-pixel hillshade border

Payloads are zlib-compressed. The macOS app expands only visible tiles.
"""

from __future__ import annotations

import argparse
import json
import math
import shutil
import sys
import time
import zlib
from dataclasses import asdict, dataclass
from pathlib import Path

import numpy as np
import rasterio
from rasterio.enums import Resampling
from rasterio.transform import Affine
from rasterio.vrt import WarpedVRT
from rasterio.windows import Window


TARGET_CRS = "EPSG:3035"
TILE_SIZE = 512
ELEVATION_MIN = -10.0
ELEVATION_MAX = 3500.0

DEFAULT_COLORS = [
    "#000000",  # no data
    "#FF1111",  # artificial land
    "#FFD700",  # open soil
    "#228B22",  # high seasonal vegetation
    "#006400",  # high perennial vegetation
    "#98FB98",  # low seasonal vegetation
    "#32CD32",  # low perennial vegetation
    "#0066CC",  # water
]

CLASS_NAMES = [
    "Keine Daten",
    "Siedlung und Verkehr",
    "Offener Boden",
    "Hohe saisonale Vegetation",
    "Hohe mehrjährige Vegetation",
    "Niedrige saisonale Vegetation",
    "Niedrige mehrjährige Vegetation",
    "Wasser",
]


@dataclass(frozen=True)
class Level:
    z: int
    resolution: float
    width: int
    height: int
    tilesX: int
    tilesY: int


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Deutschland-Kacheln für TopoExplorer erzeugen")
    parser.add_argument(
        "--landcover",
        type=Path,
        default=Path("Data/Raw/LandCover/Land_Cover_DE_2015.tif"),
    )
    parser.add_argument(
        "--dem",
        type=Path,
        default=Path(
            "Data/Raw/Elevation/gmted2010_mean_7p5arcsec.tiff"
        ),
    )
    parser.add_argument("--output", type=Path, default=Path("MapData/Germany"))
    parser.add_argument("--resolution", type=float, default=50.0, help="Feinste Auflösung in Metern")
    parser.add_argument("--compression", type=int, choices=range(1, 10), default=6)
    parser.add_argument("--force", action="store_true", help="Vorhandene Ausgabe vollständig ersetzen")
    parser.add_argument("--dry-run", action="store_true", help="Nur Größen und Ebenen anzeigen")
    return parser.parse_args()


def build_levels(width_m: float, height_m: float, finest_resolution: float) -> list[Level]:
    finest_width = math.ceil(width_m / finest_resolution)
    finest_height = math.ceil(height_m / finest_resolution)
    max_zoom = max(0, math.ceil(math.log2(max(finest_width, finest_height) / TILE_SIZE)))
    levels: list[Level] = []
    for z in range(max_zoom + 1):
        resolution = finest_resolution * (2 ** (max_zoom - z))
        width = math.ceil(width_m / resolution)
        height = math.ceil(height_m / resolution)
        levels.append(
            Level(
                z=z,
                resolution=resolution,
                width=width,
                height=height,
                tilesX=math.ceil(width / TILE_SIZE),
                tilesY=math.ceil(height / TILE_SIZE),
            )
        )
    return levels


def read_padded(dataset: WarpedVRT, x: int, y: int, width: int, height: int, fill: int) -> np.ndarray:
    result = np.full((height, width), fill, dtype=dataset.dtypes[0])
    src_x0 = max(0, x)
    src_y0 = max(0, y)
    src_x1 = min(dataset.width, x + width)
    src_y1 = min(dataset.height, y + height)
    if src_x1 <= src_x0 or src_y1 <= src_y0:
        return result

    part = dataset.read(
        1,
        window=Window(src_x0, src_y0, src_x1 - src_x0, src_y1 - src_y0),
        masked=False,
    )
    dst_x = src_x0 - x
    dst_y = src_y0 - y
    result[dst_y : dst_y + part.shape[0], dst_x : dst_x + part.shape[1]] = part
    return result


def encode_elevation(values: np.ndarray, nodata: float | int | None) -> np.ndarray:
    valid = np.isfinite(values)
    if nodata is not None:
        valid &= values != nodata
    clipped = np.clip(values.astype(np.float32, copy=False), ELEVATION_MIN, ELEVATION_MAX)
    normalized = (clipped - ELEVATION_MIN) / (ELEVATION_MAX - ELEVATION_MIN)
    encoded = np.zeros(values.shape, dtype="<u2")
    encoded[valid] = np.rint(normalized[valid] * 65535.0).astype(np.uint16)
    return encoded


def write_compressed(path: Path, payload: bytes, level: int) -> tuple[int, int]:
    compressed = zlib.compress(payload, level)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_bytes(compressed)
    temporary.replace(path)
    return len(payload), len(compressed)


def read_land_tile(path: Path) -> np.ndarray:
    payload = zlib.decompress(path.read_bytes())
    expected = TILE_SIZE * TILE_SIZE
    if len(payload) != expected:
        raise RuntimeError(f"Defekte Landkachel: {path}")
    return np.frombuffer(payload, dtype=np.uint8).reshape((TILE_SIZE, TILE_SIZE))


def derive_land_tile(output: Path, child_z: int, tile_x: int, tile_y: int) -> np.ndarray:
    children = np.zeros((TILE_SIZE * 2, TILE_SIZE * 2), dtype=np.uint8)
    child_dir = output / f"z{child_z}"
    for offset_y in range(2):
        for offset_x in range(2):
            child_path = child_dir / f"{tile_x * 2 + offset_x}_{tile_y * 2 + offset_y}.land.z"
            if child_path.exists():
                children[
                    offset_y * TILE_SIZE : (offset_y + 1) * TILE_SIZE,
                    offset_x * TILE_SIZE : (offset_x + 1) * TILE_SIZE,
                ] = read_land_tile(child_path)
    return np.ascontiguousarray(children[1::2, 1::2])


def show_progress(done: int, total: int, started: float) -> None:
    if done % 25 != 0 and done != total:
        return
    elapsed = time.time() - started
    speed = done / elapsed if elapsed else 0
    remaining = (total - done) / speed if speed else 0
    print(
        f"\r{done:,}/{total:,} ({done/total:5.1%}) · noch ca. {remaining/60:4.1f} min",
        end="",
        flush=True,
    )


def manifest_for(bounds: tuple[float, float, float, float], levels: list[Level]) -> dict:
    return {
        "version": 1,
        "name": "Deutschland Topografie",
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
            {"id": class_id, "name": name, "defaultColor": DEFAULT_COLORS[class_id]}
            for class_id, name in enumerate(CLASS_NAMES)
        ],
    }


def main() -> int:
    args = parse_args()
    if args.resolution <= 0:
        raise SystemExit("--resolution muss größer als 0 sein")
    for source in (args.landcover, args.dem):
        if not source.is_file():
            raise SystemExit(f"Quelldatei fehlt: {source}")

    with rasterio.open(args.landcover) as landcover:
        if landcover.crs is None:
            raise SystemExit("Landbedeckungsraster besitzt kein Koordinatensystem")
        if landcover.crs.to_string() != TARGET_CRS:
            print(f"Hinweis: Landbedeckung wird von {landcover.crs} nach {TARGET_CRS} projiziert")
        left, bottom, right, top = landcover.bounds

    bounds = (left, bottom, right, top)
    levels = build_levels(right - left, top - bottom, args.resolution)
    total_tiles = sum(level.tilesX * level.tilesY for level in levels)
    print(f"Gebiet: {right-left:,.0f} × {top-bottom:,.0f} m; {len(levels)} Zoomstufen; {total_tiles:,} Kacheln")
    for level in levels:
        print(
            f"  z{level.z}: {level.resolution:g} m, {level.width}×{level.height} Pixel, "
            f"{level.tilesX}×{level.tilesY} Kacheln"
        )
    if args.dry_run:
        return 0

    output = args.output.resolve()
    if args.force and output.exists():
        shutil.rmtree(output)
    output.mkdir(parents=True, exist_ok=True)
    incomplete = output / ".incomplete"
    incomplete.write_text("Kachelerzeugung läuft\n", encoding="utf-8")

    started = time.time()
    done = 0
    raw_bytes = 0
    compressed_bytes = 0

    with rasterio.open(args.landcover) as landcover, rasterio.open(args.dem) as dem:
        finest = levels[-1]
        finest_dir = output / f"z{finest.z}"
        finest_dir.mkdir(exist_ok=True)
        finest_transform = Affine(finest.resolution, 0.0, left, 0.0, -finest.resolution, top)

        # The 6.7-billion-cell source land-cover raster is traversed exactly once,
        # window by window, at the finest requested resolution.
        with WarpedVRT(
            landcover,
            crs=TARGET_CRS,
            transform=finest_transform,
            width=finest.width,
            height=finest.height,
            resampling=Resampling.nearest,
            nodata=0,
            dtype="uint8",
        ) as land_vrt, WarpedVRT(
            dem,
            crs=TARGET_CRS,
            transform=finest_transform,
            width=finest.width,
            height=finest.height,
            resampling=Resampling.bilinear,
            nodata=dem.nodata,
            dtype="int16",
        ) as dem_vrt:
            for tile_y in range(finest.tilesY):
                for tile_x in range(finest.tilesX):
                    land_path = finest_dir / f"{tile_x}_{tile_y}.land.z"
                    elevation_path = finest_dir / f"{tile_x}_{tile_y}.elev.z"
                    if not land_path.exists():
                        land = read_padded(
                            land_vrt,
                            tile_x * TILE_SIZE,
                            tile_y * TILE_SIZE,
                            TILE_SIZE,
                            TILE_SIZE,
                            0,
                        ).astype(np.uint8, copy=False)
                        if land.max(initial=0) > 7:
                            raise RuntimeError(
                                f"Unerwartete Landklasse in z{finest.z}/{tile_x}_{tile_y}: {land.max()}"
                            )
                        raw, packed = write_compressed(land_path, land.tobytes(order="C"), args.compression)
                        raw_bytes += raw
                        compressed_bytes += packed

                    if not elevation_path.exists():
                        elevation = read_padded(
                            dem_vrt,
                            tile_x * TILE_SIZE - 1,
                            tile_y * TILE_SIZE - 1,
                            TILE_SIZE + 2,
                            TILE_SIZE + 2,
                            int(dem.nodata if dem.nodata is not None else -32768),
                        )
                        encoded = encode_elevation(elevation, dem.nodata)
                        raw, packed = write_compressed(elevation_path, encoded.tobytes(order="C"), args.compression)
                        raw_bytes += raw
                        compressed_bytes += packed

                    done += 1
                    show_progress(done, total_tiles, started)

        # Coarser land-cover levels come from the already-created child tiles.
        # The much smaller DEM can still be sampled directly for smooth relief.
        for level in reversed(levels[:-1]):
            level_dir = output / f"z{level.z}"
            level_dir.mkdir(exist_ok=True)
            transform = Affine(level.resolution, 0.0, left, 0.0, -level.resolution, top)
            with WarpedVRT(
                dem,
                crs=TARGET_CRS,
                transform=transform,
                width=level.width,
                height=level.height,
                resampling=Resampling.bilinear,
                nodata=dem.nodata,
                dtype="int16",
            ) as dem_vrt:
                for tile_y in range(level.tilesY):
                    for tile_x in range(level.tilesX):
                        land_path = level_dir / f"{tile_x}_{tile_y}.land.z"
                        elevation_path = level_dir / f"{tile_x}_{tile_y}.elev.z"
                        if not land_path.exists():
                            land = derive_land_tile(output, level.z + 1, tile_x, tile_y)
                            raw, packed = write_compressed(land_path, land.tobytes(order="C"), args.compression)
                            raw_bytes += raw
                            compressed_bytes += packed

                        if not elevation_path.exists():
                            elevation = read_padded(
                                dem_vrt,
                                tile_x * TILE_SIZE - 1,
                                tile_y * TILE_SIZE - 1,
                                TILE_SIZE + 2,
                                TILE_SIZE + 2,
                                int(dem.nodata if dem.nodata is not None else -32768),
                            )
                            encoded = encode_elevation(elevation, dem.nodata)
                            raw, packed = write_compressed(
                                elevation_path, encoded.tobytes(order="C"), args.compression
                            )
                            raw_bytes += raw
                            compressed_bytes += packed

                        done += 1
                        show_progress(done, total_tiles, started)

    manifest = manifest_for(bounds, levels)
    manifest["generatedAt"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    manifest["source"] = {"landcover": str(args.landcover), "dem": str(args.dem)}
    manifest_path = output / "manifest.json"
    manifest_path.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    incomplete.unlink(missing_ok=True)

    elapsed = time.time() - started
    print()
    print(
        f"Fertig in {elapsed/60:.1f} min: {output} · "
        f"{compressed_bytes/1024**2:.1f} MiB statt {raw_bytes/1024**2:.1f} MiB Rohdaten"
    )
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        print("\nAbgebrochen; vorhandene Kacheln werden beim nächsten Lauf weiterverwendet.", file=sys.stderr)
        raise SystemExit(130)
