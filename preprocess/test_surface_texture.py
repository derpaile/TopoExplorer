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


if __name__ == "__main__":
    unittest.main()
