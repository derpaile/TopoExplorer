#!/usr/bin/env python3
"""Extract sparse Autobahn/Bundesstraße shield anchors from the local OSM PBF."""

from __future__ import annotations

import argparse
import json
import re
import shutil
import subprocess
import tempfile
import zlib
from pathlib import Path

from rasterio.warp import transform

from germany_vectors import geometry_lines, iter_geojson_sequence


REFERENCE = re.compile(r"(?<![A-Z])([AB])\s*([0-9]{1,4}[a-z]?)(?![0-9])", re.I)
ROAD_KINDS = {"motorway": 1, "trunk": 2, "primary": 3}


def arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="A-/B-Straßenschilder aus lokalem OSM erzeugen")
    parser.add_argument("--pbf", type=Path, default=Path("Data/Raw/OSM/germany-latest.osm.pbf"))
    parser.add_argument(
        "--output", type=Path,
        default=Path("MapData/Germany/Vectors/road-shields.json.z"),
    )
    parser.add_argument("--spacing-km", type=float, default=7.0)
    parser.add_argument("--compression", type=int, choices=range(1, 10), default=9)
    return parser.parse_args()


def normalized_references(value: object) -> list[str]:
    result: list[str] = []
    for prefix, number in REFERENCE.findall(str(value or "")):
        reference = f"{prefix.upper()} {number.lower()}"
        if reference not in result:
            result.append(reference)
    return result


def midpoint(line: list[tuple[float, float]]) -> tuple[float, float]:
    return line[len(line) // 2]


def extract(pbf: Path) -> list[tuple[str, int, float, float]]:
    config = {
        "attributes": {"type": False, "id": False, "version": False},
        "format_options": {},
        "linear_tags": True,
        "area_tags": False,
        "include_tags": ["highway", "ref"],
    }
    with tempfile.TemporaryDirectory(prefix="topo-road-shields-") as temporary:
        config_path = Path(temporary) / "osmium-export.json"
        filtered_path = Path(temporary) / "important-roads.pbf"
        config_path.write_text(json.dumps(config), encoding="utf-8")
        filter_command = [
            "osmium", "tags-filter", str(pbf),
            "w/highway=motorway,trunk,primary", "-f", "pbf",
            "-o", str(filtered_path),
        ]
        export_command = [
            "osmium", "export", str(filtered_path), "-f", "geojsonseq",
            "--geometry-types", "linestring", "-c", str(config_path),
            "-x", "print_record_separator=false",
        ]
        subprocess.run(filter_command, check=True)
        exported = subprocess.Popen(
            export_command, stdout=subprocess.PIPE, text=True, encoding="utf-8",
        )
        assert exported.stdout is not None
        candidates: list[tuple[str, int, float, float]] = []
        for feature in iter_geojson_sequence(exported.stdout):
            properties = feature.get("properties") or {}
            road_kind = ROAD_KINDS.get(str(properties.get("highway")))
            if road_kind is None:
                continue
            references = normalized_references(properties.get("ref"))
            if not references:
                continue
            for line in geometry_lines(feature.get("geometry")):
                if len(line) < 2:
                    continue
                lon, lat = midpoint(line)
                for reference in references:
                    if reference.startswith("A ") or reference.startswith("B "):
                        candidates.append((reference, road_kind, lon, lat))
        exported.stdout.close()
        export_code = exported.wait()
        if export_code:
            raise SystemExit(f"osmium-Export fehlgeschlagen ({export_code})")
    if not candidates:
        raise SystemExit("Keine A-/B-Routen im lokalen OSM-PBF gefunden")
    xs, ys = transform(
        "EPSG:4326", "EPSG:3035",
        [candidate[2] for candidate in candidates],
        [candidate[3] for candidate in candidates],
    )
    return [
        (reference, road_kind, x, y)
        for (reference, road_kind, _, _), x, y in zip(candidates, xs, ys)
    ]


def main() -> int:
    args = arguments()
    if not args.pbf.is_file():
        raise SystemExit(f"Lokales OSM-PBF fehlt: {args.pbf}")
    if shutil.which("osmium") is None:
        raise SystemExit("`osmium` fehlt")
    if args.spacing_km <= 0:
        raise SystemExit("--spacing-km muss positiv sein")
    print("Autobahn-/Bundesstraßen-Referenzen werden lokal extrahiert …", flush=True)
    spacing = args.spacing_km * 1_000
    seen: set[tuple[str, int, int]] = set()
    shields = []
    for reference, road_kind, x, y in extract(args.pbf):
        key = (reference, int(x // spacing), int(y // spacing))
        if key in seen:
            continue
        seen.add(key)
        shields.append(
            {
                "reference": reference,
                "roadKind": road_kind,
                "x": round(x, 1),
                "y": round(y, 1),
                "minZoom": 2 if reference.startswith("A ") else 3,
            }
        )
    shields.sort(key=lambda item: (item["minZoom"], item["reference"], item["y"], item["x"]))
    document = {"version": 1, "crs": "EPSG:3035", "shields": shields}
    packed = zlib.compress(
        json.dumps(document, ensure_ascii=False, separators=(",", ":")).encode("utf-8"),
        args.compression,
    )
    args.output.parent.mkdir(parents=True, exist_ok=True)
    temporary = args.output.with_suffix(args.output.suffix + ".tmp")
    temporary.write_bytes(packed)
    temporary.replace(args.output)
    autobahns = sum(item["reference"].startswith("A ") for item in shields)
    print(
        f"Fertig: {len(shields):,} Anker ({autobahns:,} A, "
        f"{len(shields) - autobahns:,} B) · {len(packed) / 1024:.0f} KiB"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
