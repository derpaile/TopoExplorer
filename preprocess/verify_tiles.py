#!/usr/bin/env python3
"""Validate every tile payload and every overlapping DEM edge."""

from __future__ import annotations

import argparse
import json
import zlib
from functools import lru_cache
from pathlib import Path

import numpy as np


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="TopoExplorer-Kacheln und Reliefnähte prüfen")
    parser.add_argument("root", nargs="?", type=Path, default=Path("MapData/Germany"))
    return parser.parse_args()


def main() -> int:
    root = parse_args().root
    manifest = json.loads((root / "manifest.json").read_text(encoding="utf-8"))
    tile_size = int(manifest["tileSize"])
    tile_count = 0
    seam_count = 0
    has_2020 = any(item.get("year") == 2020 for item in manifest.get("landcoverYears", []))
    land_suffix = manifest.get("landcoverProduct", {}).get("suffix", "land.z")
    maximum_class = len(manifest["classes"]) - 1

    @lru_cache(maxsize=64)
    def elevation(z: int, x: int, y: int, size: int) -> np.ndarray:
        payload = zlib.decompress((root / f"z{z}" / f"{x}_{y}.elev.z").read_bytes())
        elevation_size = size + 2 * int(manifest["elevationBorder"])
        expected = elevation_size * elevation_size * 2
        if len(payload) != expected:
            raise RuntimeError(f"Defekte Höhenkachel z{z}/{x}_{y}")
        return np.frombuffer(payload, dtype="<u2").reshape(elevation_size, elevation_size)

    for level in manifest["levels"]:
        z, tiles_x, tiles_y = int(level["z"]), int(level["tilesX"]), int(level["tilesY"])
        elevation_tile_size = int(level.get("elevationTileSize", tile_size))
        for y in range(tiles_y):
            for x in range(tiles_x):
                land_path = root / f"z{z}" / f"{x}_{y}.{land_suffix}"
                land = np.frombuffer(zlib.decompress(land_path.read_bytes()), dtype=np.uint8)
                if land.size != tile_size * tile_size or land.max(initial=0) > maximum_class:
                    raise RuntimeError(f"Defekte Landkachel z{z}/{x}_{y}")
                if has_2020:
                    land_2020_path = root / f"z{z}" / f"{x}_{y}.land2020.z"
                    land_2020 = np.frombuffer(zlib.decompress(land_2020_path.read_bytes()), dtype=np.uint8)
                    if land_2020.size != tile_size * tile_size or land_2020.max(initial=0) > 7:
                        raise RuntimeError(f"Defekte 2020-Landkachel z{z}/{x}_{y}")
                current = elevation(z, x, y, elevation_tile_size)
                if x + 1 < tiles_x:
                    right = elevation(z, x + 1, y, elevation_tile_size)
                    if not np.array_equal(current[:, -2:], right[:, :2]):
                        raise RuntimeError(f"Vertikale Reliefnaht z{z}/{x}_{y}")
                    seam_count += 1
                if y + 1 < tiles_y:
                    below = elevation(z, x, y + 1, elevation_tile_size)
                    if not np.array_equal(current[-2:, :], below[:2, :]):
                        raise RuntimeError(f"Horizontale Reliefnaht z{z}/{x}_{y}")
                    seam_count += 1
                tile_count += 1

    suffix = " einschließlich 2020" if has_2020 else ""
    print(f"{tile_count} Kachelpaare{suffix} und {seam_count} Reliefübergänge sind exakt nahtlos.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
