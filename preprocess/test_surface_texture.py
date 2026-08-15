from __future__ import annotations

import json
import sys
import tempfile
import unittest
import warnings
import zlib
from pathlib import Path
from unittest.mock import patch

import numpy as np
import rasterio
from rasterio.transform import from_origin
from rasterio.errors import NotGeoreferencedWarning
from rasterio.warp import transform

from preprocess import surface_texture


class SurfaceTexturePipelineTests(unittest.TestCase):
    def test_local_hannover_pipeline_writes_neutral_detail(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "MapData"
            (root / "z0").mkdir(parents=True)
            center_x, center_y = transform(
                "EPSG:4326", "EPSG:3035", [9.732], [52.375]
            )
            left, top = center_x[0] - 2_560, center_y[0] + 2_560
            classes = [
                (0, "Keine Daten", "Grundlage"),
                (1, "Siedlung", "Siedlung"),
                (2, "Offener Boden", "Natur"),
                (3, "Landwirtschaft", "Landwirtschaft"),
                (4, "Wasser", "Natur"),
                (5, "Grasland", "Natur"),
                (6, "Laubwald", "Wald"),
                (7, "Nadelwald", "Wald"),
            ]
            manifest = {
                "version": 1,
                "name": "Test",
                "crs": "EPSG:3035",
                "bounds": [left, top - 5_120, left + 5_120, top],
                "tileSize": 512,
                "elevationBorder": 1,
                "minZoom": 0,
                "maxZoom": 0,
                "elevationMin": -10,
                "elevationMax": 3500,
                "compression": "zlib",
                "levels": [
                    {
                        "z": 0,
                        "resolution": 10,
                        "width": 512,
                        "height": 512,
                        "tilesX": 1,
                        "tilesY": 1,
                    }
                ],
                "classes": [
                    {"id": identifier, "name": name, "defaultColor": "#708060", "group": group}
                    for identifier, name, group in classes
                ],
            }
            (root / "manifest.json").write_text(json.dumps(manifest), encoding="utf-8")
            land = np.tile(np.arange(8, dtype=np.uint8), (512, 64))
            (root / "z0" / "0_0.land.z").write_bytes(zlib.compress(land.tobytes()))

            yy, xx = np.mgrid[:512, :512]
            structure = 1_500 + 180 * np.sin(xx / 9) + 120 * np.cos(yy / 13)
            paths = {}
            for name, factor in {
                "B02": 0.78,
                "B03": 0.92,
                "B04": 1.0,
                "B08": 1.35,
                "observations": 0.0,
            }.items():
                path = Path(temporary) / f"{name}.tif"
                values = (
                    np.full((512, 512), 6, dtype=np.float32)
                    if name == "observations"
                    else (structure * factor).astype(np.float32)
                )
                with rasterio.open(
                    path,
                    "w",
                    driver="GTiff",
                    width=512,
                    height=512,
                    count=1,
                    dtype="float32",
                    crs="EPSG:3035",
                    transform=from_origin(left, top, 10, 10),
                ) as dataset:
                    dataset.write(values, 1)
                paths[name] = path

            arguments = [
                "surface_texture.py",
                "--map-data",
                str(root),
                "--archive-dir",
                str(Path(temporary) / "archive"),
                "--archive-format",
                "uint16",
                "--radius-km",
                "1",
                "--highpass-radius",
                "4",
                "--minimum-zoom",
                "0",
                "--preview-size",
                "64",
            ]
            for name in ("B02", "B03", "B04", "B08", "observations"):
                arguments.extend((f"--{name.lower()}", str(paths[name])))
            with patch.object(sys, "argv", arguments):
                self.assertEqual(surface_texture.main(), 0)

            payload = zlib.decompress((root / "z0" / "0_0.surface.z").read_bytes())
            detail = np.frombuffer(payload, dtype=np.uint8)
            self.assertEqual(detail.size, 512 * 512)
            self.assertLess(int(detail.min()), 128)
            self.assertGreater(int(detail.max()), 128)
            updated = json.loads((root / "manifest.json").read_text(encoding="utf-8"))
            self.assertEqual(updated["surfaceTexture"]["suffix"], "surface.z")
            self.assertEqual(updated["surfaceTexture"]["classWeights"][4], 0)
            preview = root / "SurfaceTexture" / "hannover-comparison-00-20-30-40-50-60.png"
            with warnings.catch_warnings():
                warnings.simplefilter("ignore", NotGeoreferencedWarning)
                with rasterio.open(preview) as dataset:
                    self.assertEqual((dataset.width, dataset.height), (384, 64))
            self.assertTrue(
                (root / "SurfaceTexture" / "hannover-check-00-20-30-40-50-60.jpg").is_file()
            )
            self.assertTrue(
                (Path(temporary) / "archive" / "SourceRGB" / "z0" / "0_0.sentinel-rgb16.z").is_file()
            )
            self.assertTrue(
                (Path(temporary) / "archive" / "Processed" / "z0" / "0_0.surface.z").is_file()
            )
            with warnings.catch_warnings():
                warnings.simplefilter("ignore", NotGeoreferencedWarning)
                with rasterio.open(
                    root / "SurfaceTexture" / "hannover-check-00-20-30-40-50-60.jpg"
                ) as dataset:
                    self.assertEqual((dataset.width, dataset.height), (448, 64))

            with patch.object(sys, "argv", arguments + ["--germany", "--restart"]):
                self.assertEqual(surface_texture.main(), 0)
            state = json.loads(
                (root / "SurfaceTexture" / "germany-build.json").read_text(encoding="utf-8")
            )
            self.assertEqual(len(state["completedBlocks"]), 1)
            self.assertFalse(any((root / "SurfaceTexture" / "Calibration").glob("*.npz")))

    def test_germany_block_estimate_and_band_profiles(self) -> None:
        tiles = [surface_texture.Tile(x, y) for y in range(5) for x in range(6)]
        blocks = surface_texture.tile_blocks(tiles, 4)
        self.assertEqual(len(blocks), 4)
        self.assertLessEqual(max(block.max_x - block.min_x + 1 for block in blocks), 4)
        quota = surface_texture.estimated_processing_units(blocks, 512, 74, 3)
        full = surface_texture.estimated_processing_units(blocks, 512, 74, 5)
        self.assertGreater(full, quota)

        source = object.__new__(surface_texture.SentinelHubBands)
        source.profile = "rgb"
        script = source._evalscript()
        self.assertIn('"B02", "B03", "B04"', script)
        self.assertNotIn("B08", script)
        source.profile = "rgbnir"
        self.assertIn("B08", source._evalscript())


if __name__ == "__main__":
    unittest.main()
