#!/usr/bin/env python3
"""Convert the official Zensus 2022 100 m CSV grid to an EPSG:3035 GeoTIFF."""

from __future__ import annotations

import argparse
import csv
import io
import math
import zipfile
from contextlib import contextmanager
from pathlib import Path
from typing import Iterator, TextIO

import numpy as np
import rasterio
from rasterio.transform import from_origin


GRID_SIZE = 100
CSV_NAME_FRAGMENT = "100m-Gitter.csv"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Amtliches Zensus-2022-Bevölkerungsgitter als GeoTIFF schreiben"
    )
    parser.add_argument("source", type=Path, help="Destatis-ZIP oder entpackte 100-m-CSV")
    parser.add_argument("output", type=Path)
    return parser.parse_args()


@contextmanager
def open_csv(path: Path) -> Iterator[TextIO]:
    if path.suffix.casefold() == ".zip":
        with zipfile.ZipFile(path) as archive:
            candidates = [name for name in archive.namelist() if CSV_NAME_FRAGMENT in name]
            if len(candidates) != 1:
                raise SystemExit(
                    f"Erwartete genau eine *{CSV_NAME_FRAGMENT} im Archiv, gefunden: {candidates}"
                )
            with archive.open(candidates[0]) as raw:
                with io.TextIOWrapper(raw, encoding="utf-8-sig", newline="") as text:
                    yield text
    else:
        with path.open("r", encoding="utf-8-sig", newline="") as text:
            yield text


def rows(path: Path) -> Iterator[tuple[int, int, int]]:
    with open_csv(path) as source:
        reader = csv.DictReader(source, delimiter=";")
        required = {"x_mp_100m", "y_mp_100m", "Einwohner"}
        if not required.issubset(reader.fieldnames or []):
            raise SystemExit(
                f"Zensus-Spalten fehlen: {sorted(required)}; vorhanden: {reader.fieldnames}"
            )
        for line, row in enumerate(reader, start=2):
            try:
                x = int(row["x_mp_100m"])
                y = int(row["y_mp_100m"])
                population = int(row["Einwohner"])
            except (KeyError, TypeError, ValueError) as error:
                raise SystemExit(f"Ungültige Zensus-Zeile {line}: {error}") from error
            if population < 0 or population > np.iinfo(np.uint16).max:
                raise SystemExit(f"Unzulässige Einwohnerzahl in Zeile {line}: {population}")
            yield x, y, population


def main() -> int:
    args = parse_args()
    if not args.source.is_file():
        raise SystemExit(f"Zensus-Quelle fehlt: {args.source}")

    minimum_x = minimum_y = math.inf
    maximum_x = maximum_y = -math.inf
    count = 0
    for x, y, _ in rows(args.source):
        minimum_x, maximum_x = min(minimum_x, x), max(maximum_x, x)
        minimum_y, maximum_y = min(minimum_y, y), max(maximum_y, y)
        count += 1
    if not count:
        raise SystemExit("Das Zensus-100-m-Gitter enthält keine Datenzeilen")
    if any(value % GRID_SIZE != 50 for value in (minimum_x, maximum_x, minimum_y, maximum_y)):
        raise SystemExit("Zensus-Koordinaten sind nicht auf 100-m-Zellmitten ausgerichtet")

    width = int((maximum_x - minimum_x) / GRID_SIZE) + 1
    height = int((maximum_y - minimum_y) / GRID_SIZE) + 1
    values = np.zeros((height, width), dtype=np.uint16)
    total = 0
    for index, (x, y, population) in enumerate(rows(args.source), start=1):
        column = int((x - minimum_x) / GRID_SIZE)
        row = int((maximum_y - y) / GRID_SIZE)
        values[row, column] = population
        total += population
        if index % 500_000 == 0:
            print(f"  {index:,}/{count:,} Zellen", flush=True)

    args.output.parent.mkdir(parents=True, exist_ok=True)
    temporary = args.output.with_suffix(args.output.suffix + ".tmp")
    profile = {
        "driver": "GTiff",
        "width": width,
        "height": height,
        "count": 1,
        "dtype": "uint16",
        "crs": "EPSG:3035",
        "transform": from_origin(
            minimum_x - GRID_SIZE / 2,
            maximum_y + GRID_SIZE / 2,
            GRID_SIZE,
            GRID_SIZE,
        ),
        "nodata": 0,
        "compress": "deflate",
        "predictor": 2,
        "tiled": True,
        "blockxsize": 512,
        "blockysize": 512,
        "bigtiff": "IF_SAFER",
    }
    with rasterio.open(temporary, "w", **profile) as target:
        target.write(values, 1)
        target.update_tags(
            source="Statistisches Bundesamt, Zensus 2022, Bevölkerungszahl im 100-m-Gitter",
            license="Datenlizenz Deutschland – Namensnennung – Version 2.0",
            source_file=args.source.name,
        )
    temporary.replace(args.output)
    print(
        f"Zensus-GeoTIFF: {width}×{height} Zellen · {count:,} belegt · "
        f"{total:,} Einwohner · {args.output}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
