#!/usr/bin/env python3
"""Fuse the complementary 2015 and 2020 classifications into one rich map."""

from __future__ import annotations

import argparse
import hashlib
import json
import time
import zlib
from pathlib import Path

import numpy as np

from germany_tiles import TILE_SIZE, write_compressed


SUFFIX = "landfusion.z"
PIPELINE_VERSION = 1

# Fusion classes. They deliberately describe land cover, not a change timeline.
CLASSES = [
    {"id": 0, "name": "Keine Daten", "defaultColor": "#101612"},
    {"id": 1, "name": "Siedlung und Verkehr", "defaultColor": "#C84C55"},
    {"id": 2, "name": "Offener Boden", "defaultColor": "#C9A96E"},
    {"id": 3, "name": "Landwirtschaft saisonal", "defaultColor": "#B7CEA8"},
    {"id": 4, "name": "Landwirtschaft unbekannt", "defaultColor": "#D6BE78"},
    {"id": 5, "name": "Laubwald", "defaultColor": "#6FAF7A"},
    {"id": 6, "name": "Nadelwald", "defaultColor": "#245C3A"},
    {"id": 7, "name": "Waldtyp unbekannt", "defaultColor": "#47785A"},
    {"id": 8, "name": "Nadelwald-Offenfläche", "defaultColor": "#927A55"},
    {"id": 9, "name": "Niedrige Dauervegetation", "defaultColor": "#78A96D"},
    {"id": 10, "name": "Wasser", "defaultColor": "#39779B"},
]

# 2015 IDs: 1 built, 2 bare, 3 deciduous, 4 coniferous, 5 seasonal
# agriculture, 6 low perennial vegetation, 7 water.
# Mapped 2020 IDs: 1 built, 2 bare, 3 agriculture, 4 forest,
# 6 low vegetation, 7 water.
FUSION = np.array(
    [
        [0, 1, 2, 4, 7, 0, 9, 10],
        [0, 1, 2, 4, 7, 1, 9, 10],
        [0, 1, 2, 4, 7, 2, 9, 10],
        [0, 1, 2, 4, 5, 5, 9, 10],
        [0, 1, 8, 4, 6, 6, 8, 10],
        [0, 1, 3, 3, 7, 3, 3, 10],
        [0, 1, 2, 4, 7, 9, 9, 10],
        [0, 1, 2, 4, 7, 10, 9, 10],
    ],
    dtype=np.uint8,
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Detailreiche Gesamt-Landbedeckung erzeugen")
    parser.add_argument("--output", type=Path, default=Path("MapData/Germany"))
    parser.add_argument("--force", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    return parser.parse_args()


def read_tile(path: Path) -> np.ndarray:
    payload = zlib.decompress(path.read_bytes())
    if len(payload) != TILE_SIZE * TILE_SIZE:
        raise RuntimeError(f"Defekte Landkachel: {path}")
    return np.frombuffer(payload, dtype=np.uint8).reshape(TILE_SIZE, TILE_SIZE)


def signature(manifest: dict) -> dict:
    inputs = {
        "generationSignature": manifest.get("generationSignature"),
        "landcover2020Signature": manifest.get("landcover2020Signature"),
    }
    encoded = json.dumps(inputs, sort_keys=True, separators=(",", ":")).encode()
    return {
        "pipelineVersion": PIPELINE_VERSION,
        "pipelineSHA256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        "inputsSHA256": hashlib.sha256(encoded).hexdigest(),
    }


def tiles_complete(output: Path, levels: list[dict]) -> bool:
    return all(
        (output / f"z{int(level['z'])}" / f"{x}_{y}.{SUFFIX}").is_file()
        for level in levels
        for y in range(int(level["tilesY"]))
        for x in range(int(level["tilesX"]))
    )


def main() -> int:
    args = parse_args()
    output = args.output.resolve()
    manifest_path = output / "manifest.json"
    if not manifest_path.is_file():
        raise SystemExit("Kartenmanifest fehlt; zuerst 2015 und 2020 aufbereiten.")
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    levels = manifest["levels"]
    total = sum(int(level["tilesX"]) * int(level["tilesY"]) for level in levels)
    current_signature = signature(manifest)
    print(f"Gesamt-Landbedeckung: {total:,} Kacheln, {len(CLASSES) - 1} Klassen")
    if args.dry_run:
        return 0
    if (
        not args.force
        and manifest.get("landcoverFusionSignature") == current_signature
        and tiles_complete(output, levels)
    ):
        print(f"Bereits vollständig: {output}")
        return 0

    incomplete = output / ".incomplete-landcover-fusion"
    incomplete.write_text("Landbedeckungsfusion läuft\n", encoding="utf-8")
    if args.force or manifest.get("landcoverFusionSignature") != current_signature:
        for path in output.glob(f"z*/*.{SUFFIX}"):
            path.unlink()

    started = time.time()
    counts = np.zeros(len(CLASSES), dtype=np.int64)
    completed = 0
    for level in levels:
        z = int(level["z"])
        directory = output / f"z{z}"
        for y in range(int(level["tilesY"])):
            for x in range(int(level["tilesX"])):
                fused_path = directory / f"{x}_{y}.{SUFFIX}"
                if not fused_path.exists():
                    land2015 = read_tile(directory / f"{x}_{y}.land.z")
                    land2020 = read_tile(directory / f"{x}_{y}.land2020.z")
                    if land2015.max(initial=0) > 7 or land2020.max(initial=0) > 7:
                        raise RuntimeError(f"Unerwartete Quellklasse in z{z}/{x}_{y}")
                    fused = np.ascontiguousarray(FUSION[land2015, land2020])
                    write_compressed(fused_path, fused.tobytes(order="C"), 6)
                else:
                    fused = read_tile(fused_path)
                counts += np.bincount(fused.ravel(), minlength=len(CLASSES))[: len(CLASSES)]
                completed += 1

    manifest["classes"] = CLASSES
    manifest["landcoverProduct"] = {
        "name": "Detailreiche Gesamtkarte",
        "suffix": SUFFIX,
    }
    manifest["landcoverFusionGeneratedAt"] = time.strftime(
        "%Y-%m-%dT%H:%M:%SZ", time.gmtime()
    )
    manifest["landcoverFusionSignature"] = current_signature
    temporary = manifest_path.with_suffix(".json.tmp")
    temporary.write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    temporary.replace(manifest_path)
    incomplete.unlink(missing_ok=True)

    named_counts = ", ".join(
        f"{item['name']}: {counts[item['id']]:,}" for item in CLASSES[1:]
    )
    print(named_counts)
    print(f"Fertig: {completed:,} Kacheln in {time.time() - started:.1f} s")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
