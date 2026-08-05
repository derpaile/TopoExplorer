#!/usr/bin/env python3
"""Build compact vector and place tiles for TopoExplorer.

The pipeline reads the Germany OSM PBF once through ``osmium`` for roads,
waterways and administrative boundaries. Existing railway and place GeoJSON
caches are streamed without loading them as a whole. All output uses the same
EPSG:3035 grid and zoom levels as the raster pyramid.

No geometry library is required: rasterio projects coordinate batches,
Douglas-Peucker simplifies them and Liang-Barsky clips them to buffered tiles.
"""

from __future__ import annotations

import argparse
import collections
import hashlib
import json
import math
import os
import shutil
import struct
import subprocess
import sys
import time
import unicodedata
import zlib
from dataclasses import dataclass
from pathlib import Path
from typing import Iterable, Iterator, Sequence, TextIO

from rasterio.warp import transform


TARGET_CRS = "EPSG:3035"
SOURCE_CRS = "EPSG:4326"
MAGIC = b"TVT1"
FORMAT_VERSION = 1
PIPELINE_VERSION = 3
EXTENT = 8192
BUFFER = 128  # 8 screen pixels for a 512 pixel raster tile
TILE_HEADER = struct.Struct("<4sHHHII")
LINE_HEADER = struct.Struct("<BBBBHH")
PLACE_HEADER = struct.Struct("<BBHhhIH")
MAX_POINTS = 65535
MAX_NAME_BYTES = 65535
PROJECT_BATCH_POINTS = 250_000

LAYER_ROAD = 1
LAYER_RAIL = 2
LAYER_WATER = 3
LAYER_BOUNDARY = 4

ROAD_TYPES = {
    "motorway": (1, 1),
    "motorway_link": (1, 1),
    "trunk": (2, 2),
    "trunk_link": (2, 2),
    "primary": (3, 2),
    "primary_link": (3, 2),
    "secondary": (4, 3),
    "secondary_link": (4, 3),
    "tertiary": (5, 4),
    "tertiary_link": (5, 4),
    "residential": (6, 5),
    "unclassified": (6, 5),
    "living_street": (6, 5),
    "service": (7, 6),
    "track": (8, 6),
}

RAIL_TYPES = {
    "rail": (1, 2),
    "narrow_gauge": (2, 4),
    "light_rail": (3, 4),
    "subway": (4, 5),
    "tram": (5, 5),
    "funicular": (6, 5),
    "monorail": (6, 5),
    "construction": (7, 6),
}

WATER_TYPES = {
    "river": (1, 2),
    "canal": (2, 3),
    "stream": (3, 4),
    "drain": (4, 5),
    "ditch": (5, 6),
}

PLACE_TYPES = {
    "city": 1,
    "town": 2,
    "village": 3,
    "suburb": 4,
    "quarter": 4,
    "borough": 4,
    "hamlet": 5,
    "isolated_dwelling": 5,
    "locality": 6,
}

OSMIUM_FILTERS = [
    "w/highway=" + ",".join(ROAD_TYPES),
    "w/waterway=" + ",".join(WATER_TYPES),
    "r/boundary=administrative",
]


@dataclass(frozen=True)
class Level:
    z: int
    resolution: float
    width: int
    height: int
    tilesX: int
    tilesY: int


@dataclass(frozen=True)
class LineStyle:
    layer: int
    kind: int
    min_zoom: int
    flags: int
    name: str


@dataclass
class RawLine:
    style: LineStyle
    coordinates: list[tuple[float, float]]


@dataclass(frozen=True)
class Place:
    name: str
    kind: int
    population: int
    x: float
    y: float
    min_zoom: int


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Vektor- und Ortskacheln für TopoExplorer erzeugen")
    parser.add_argument("--manifest", type=Path, default=Path("MapData/Germany/manifest.json"))
    parser.add_argument("--pbf", type=Path, default=Path("Data/Raw/OSM/germany-latest.osm.pbf"))
    parser.add_argument("--railways", type=Path, default=Path("Data/Raw/OSM/railways.geojson"))
    parser.add_argument("--places", type=Path, default=Path("Data/Raw/OSM/places.geojson"))
    parser.add_argument("--output", type=Path, default=Path("MapData/Germany/Vectors"))
    parser.add_argument("--work", type=Path, default=Path(".build/vector-preprocess"))
    parser.add_argument("--compression", type=int, choices=range(1, 10), default=6)
    parser.add_argument("--force", action="store_true", help="Vektor-Ausgabe und Arbeitscache neu erzeugen")
    parser.add_argument("--dry-run", action="store_true", help="Nur Eingaben, Format und Ebenen prüfen")
    parser.add_argument("--keep-work", action="store_true", help="Zwischendaten nach Erfolg behalten")
    return parser.parse_args()


def load_grid(path: Path) -> tuple[tuple[float, float, float, float], int, list[Level]]:
    document = json.loads(path.read_text(encoding="utf-8"))
    if document.get("crs") != TARGET_CRS:
        raise SystemExit(f"Rastermanifest muss {TARGET_CRS} verwenden: {path}")
    bounds = tuple(float(value) for value in document["bounds"])
    if len(bounds) != 4:
        raise SystemExit(f"Ungültige Grenzen in {path}")
    tile_size = int(document["tileSize"])
    levels = [Level(**level) for level in document["levels"]]
    return bounds, tile_size, levels


def ensure_safe_directory(path: Path) -> Path:
    resolved = path.resolve()
    if resolved == Path(resolved.anchor) or len(resolved.parts) < 4:
        raise SystemExit(f"Unsicheres Ausgabeverzeichnis: {resolved}")
    return resolved


def source_signature(paths: Sequence[Path], manifest: Path) -> dict:
    result: dict[str, object] = {
        "formatVersion": FORMAT_VERSION,
        "pipelineVersion": PIPELINE_VERSION,
        "pipelineSHA256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
    }
    grid_document = json.loads(manifest.read_text(encoding="utf-8"))
    stable_grid = {
        key: grid_document[key]
        for key in ("crs", "bounds", "tileSize", "levels")
    }
    grid_payload = json.dumps(stable_grid, sort_keys=True, separators=(",", ":")).encode("utf-8")
    result[str(manifest)] = {"gridSHA256": hashlib.sha256(grid_payload).hexdigest()}
    for path in paths:
        stat = path.stat()
        result[str(path)] = {"size": stat.st_size, "modifiedNs": stat.st_mtime_ns}
    return result


def normalized_name(value: str) -> str:
    folded = unicodedata.normalize("NFKD", value.casefold())
    return "".join(character for character in folded if not unicodedata.combining(character))


def parse_population(value: object) -> int:
    if value is None:
        return 0
    if isinstance(value, (int, float)):
        if not math.isfinite(float(value)):
            return 0
        return min(0xFFFFFFFF, max(0, int(round(float(value)))))
    text = str(value).strip().replace(" ", "").replace("\u00a0", "")
    try:
        if text.lstrip("+-").isdigit():
            parsed = int(text)
        elif text.count(".") + text.count(",") == 1:
            separator = "." if "." in text else ","
            whole, fraction = text.split(separator)
            parsed = int(round(float(text.replace(",", ".")))) if len(fraction) <= 2 else int(whole + fraction)
        else:
            parsed = int(text.replace(".", "").replace(",", ""))
        return min(0xFFFFFFFF, max(0, parsed))
    except (TypeError, ValueError):
        return 0


def truthy_tag(value: object) -> bool:
    return str(value or "").casefold() not in {"", "0", "false", "no", "none"}


def feature_name(properties: dict) -> str:
    return str(properties.get("name:de") or properties.get("name") or "").strip()


def classify_line(properties: dict) -> LineStyle | None:
    name = feature_name(properties)
    flags = (1 if truthy_tag(properties.get("bridge")) else 0) | (
        2 if truthy_tag(properties.get("tunnel")) else 0
    )
    highway = properties.get("highway")
    if highway in ROAD_TYPES:
        kind, min_zoom = ROAD_TYPES[str(highway)]
        return LineStyle(LAYER_ROAD, kind, min_zoom, flags, name)
    railway = properties.get("railway")
    if railway in RAIL_TYPES:
        kind, min_zoom = RAIL_TYPES[str(railway)]
        return LineStyle(LAYER_RAIL, kind, min_zoom, flags, name)
    waterway = properties.get("waterway")
    if waterway in WATER_TYPES:
        kind, min_zoom = WATER_TYPES[str(waterway)]
        return LineStyle(LAYER_WATER, kind, min_zoom, flags, name)
    if properties.get("boundary") == "administrative":
        try:
            admin_level = int(properties.get("admin_level", 99))
        except (TypeError, ValueError):
            return None
        if admin_level <= 2:
            kind, min_zoom = 1, 0
        elif admin_level <= 4:
            kind, min_zoom = 2, 2
        elif admin_level <= 6:
            kind, min_zoom = 3, 4
        elif admin_level <= 8:
            kind, min_zoom = 4, 5
        else:
            return None
        return LineStyle(LAYER_BOUNDARY, kind, min_zoom, flags, name)
    return None


def place_min_zoom(place_type: str, population: int) -> int:
    if place_type == "city":
        if population >= 500_000:
            return 1
        if population >= 100_000:
            return 2
        return 3
    if place_type == "town":
        return 3 if population >= 50_000 else 4
    if place_type in {"suburb", "quarter", "borough"}:
        return 5
    if place_type == "village":
        return 5
    return 6


def geometry_lines(geometry: dict | None) -> Iterator[list[tuple[float, float]]]:
    if not geometry:
        return
    geometry_type = geometry.get("type")
    coordinates = geometry.get("coordinates")

    def clean_line(values: object) -> list[tuple[float, float]]:
        result: list[tuple[float, float]] = []
        if not isinstance(values, list):
            return result
        for coordinate in values:
            if not isinstance(coordinate, (list, tuple)) or len(coordinate) < 2:
                continue
            try:
                point = (float(coordinate[0]), float(coordinate[1]))
            except (TypeError, ValueError):
                continue
            if not result or point != result[-1]:
                result.append(point)
        return result

    if geometry_type == "LineString":
        line = clean_line(coordinates)
        if len(line) >= 2:
            yield line
    elif geometry_type == "MultiLineString":
        for values in coordinates or []:
            line = clean_line(values)
            if len(line) >= 2:
                yield line
    elif geometry_type == "Polygon":
        for values in coordinates or []:
            line = clean_line(values)
            if len(line) >= 2:
                yield line
    elif geometry_type == "MultiPolygon":
        for polygon in coordinates or []:
            for values in polygon:
                line = clean_line(values)
                if len(line) >= 2:
                    yield line
    elif geometry_type == "GeometryCollection":
        for child in geometry.get("geometries", []):
            yield from geometry_lines(child)


def iter_feature_collection(path: Path, chunk_size: int = 1 << 20) -> Iterator[dict]:
    """Stream features from a GeoJSON FeatureCollection with stdlib only."""
    decoder = json.JSONDecoder()
    with path.open("r", encoding="utf-8") as source:
        buffer = ""
        while True:
            chunk = source.read(chunk_size)
            if not chunk:
                raise RuntimeError(f"Kein features-Array in {path}")
            buffer += chunk
            marker = buffer.find('"features"')
            if marker < 0:
                buffer = buffer[-32:]
                continue
            array_start = buffer.find("[", marker)
            if array_start < 0:
                continue
            buffer = buffer[array_start + 1 :]
            break

        eof = False
        while True:
            buffer = buffer.lstrip(" \t\r\n,")
            if buffer.startswith("]"):
                return
            try:
                feature, offset = decoder.raw_decode(buffer)
            except json.JSONDecodeError:
                if eof:
                    raise RuntimeError(f"Unvollständiges GeoJSON: {path}")
                chunk = source.read(chunk_size)
                if chunk:
                    buffer += chunk
                else:
                    eof = True
                continue
            buffer = buffer[offset:]
            if isinstance(feature, dict) and feature.get("type") == "Feature":
                yield feature


def iter_geojson_sequence(stream: TextIO) -> Iterator[dict]:
    for line in stream:
        line = line.lstrip("\x1e \t\r\n")
        if not line:
            continue
        feature = json.loads(line)
        if feature.get("type") == "Feature":
            yield feature


def squared_distance_to_segment(
    point: tuple[float, float], start: tuple[float, float], end: tuple[float, float]
) -> float:
    dx = end[0] - start[0]
    dy = end[1] - start[1]
    denominator = dx * dx + dy * dy
    if denominator == 0:
        return (point[0] - start[0]) ** 2 + (point[1] - start[1]) ** 2
    amount = ((point[0] - start[0]) * dx + (point[1] - start[1]) * dy) / denominator
    amount = min(1.0, max(0.0, amount))
    x = start[0] + amount * dx
    y = start[1] + amount * dy
    return (point[0] - x) ** 2 + (point[1] - y) ** 2


def simplify_line(points: Sequence[tuple[float, float]], tolerance: float) -> list[tuple[float, float]]:
    if len(points) <= 2 or tolerance <= 0:
        return list(points)
    keep = [False] * len(points)
    keep[0] = keep[-1] = True
    stack = [(0, len(points) - 1)]
    threshold = tolerance * tolerance
    while stack:
        start_index, end_index = stack.pop()
        largest = threshold
        largest_index = -1
        for index in range(start_index + 1, end_index):
            distance = squared_distance_to_segment(points[index], points[start_index], points[end_index])
            if distance > largest:
                largest = distance
                largest_index = index
        if largest_index >= 0:
            keep[largest_index] = True
            stack.append((start_index, largest_index))
            stack.append((largest_index, end_index))
    return [point for point, retained in zip(points, keep) if retained]


def clip_segment(
    start: tuple[float, float],
    end: tuple[float, float],
    rectangle: tuple[float, float, float, float],
) -> tuple[tuple[float, float], tuple[float, float]] | None:
    xmin, ymin, xmax, ymax = rectangle
    dx = end[0] - start[0]
    dy = end[1] - start[1]
    first, last = 0.0, 1.0
    for direction, distance in (
        (-dx, start[0] - xmin),
        (dx, xmax - start[0]),
        (-dy, start[1] - ymin),
        (dy, ymax - start[1]),
    ):
        if direction == 0:
            if distance < 0:
                return None
            continue
        amount = distance / direction
        if direction < 0:
            if amount > last:
                return None
            first = max(first, amount)
        else:
            if amount < first:
                return None
            last = min(last, amount)
    return (
        (start[0] + first * dx, start[1] + first * dy),
        (start[0] + last * dx, start[1] + last * dy),
    )


def clip_line(
    points: Sequence[tuple[float, float]], rectangle: tuple[float, float, float, float]
) -> Iterator[list[tuple[float, float]]]:
    current: list[tuple[float, float]] = []
    for start, end in zip(points, points[1:]):
        clipped = clip_segment(start, end, rectangle)
        if clipped is None:
            if len(current) >= 2:
                yield current
            current = []
            continue
        clipped_start, clipped_end = clipped
        if current and math.isclose(current[-1][0], clipped_start[0], abs_tol=1e-7) and math.isclose(
            current[-1][1], clipped_start[1], abs_tol=1e-7
        ):
            if clipped_end != current[-1]:
                current.append(clipped_end)
        else:
            if len(current) >= 2:
                yield current
            current = [clipped_start, clipped_end]
    if len(current) >= 2:
        yield current


class SpoolWriter:
    def __init__(self, root: Path, max_open: int = 64):
        self.root = root
        self.max_open = max_open
        self.handles: collections.OrderedDict[Path, object] = collections.OrderedDict()
        self.line_counts: collections.Counter[str] = collections.Counter()
        self.place_counts: collections.Counter[str] = collections.Counter()
        self.layer_records: collections.Counter[int] = collections.Counter()

    def _write(self, path: Path, payload: bytes) -> None:
        handle = self.handles.pop(path, None)
        if handle is None:
            path.parent.mkdir(parents=True, exist_ok=True)
            handle = path.open("ab")
        self.handles[path] = handle
        handle.write(payload)
        if len(self.handles) > self.max_open:
            _, oldest = self.handles.popitem(last=False)
            oldest.close()

    @staticmethod
    def key(z: int, x: int, y: int) -> str:
        return f"{z}/{x}_{y}"

    def line(self, z: int, x: int, y: int, payload: bytes, layer: int) -> None:
        key = self.key(z, x, y)
        self._write(self.root / f"z{z}" / f"{x}_{y}.lines", payload)
        self.line_counts[key] += 1
        self.layer_records[layer] += 1

    def place(self, z: int, x: int, y: int, payload: bytes) -> None:
        key = self.key(z, x, y)
        self._write(self.root / f"z{z}" / f"{x}_{y}.places", payload)
        self.place_counts[key] += 1

    def close(self) -> None:
        for handle in self.handles.values():
            handle.close()
        self.handles.clear()


class VectorBuilder:
    def __init__(
        self,
        bounds: tuple[float, float, float, float],
        tile_size: int,
        levels: list[Level],
        spool: SpoolWriter,
    ):
        self.bounds = bounds
        self.tile_size = tile_size
        self.levels = levels
        self.spool = spool
        self.source_features: collections.Counter[int] = collections.Counter()
        self.source_parts: collections.Counter[int] = collections.Counter()
        self.skipped = 0

    def add_projected_line(self, style: LineStyle, points: Sequence[tuple[float, float]]) -> None:
        if len(points) < 2:
            return
        left, bottom, right, top = self.bounds
        xs = [point[0] for point in points]
        ys = [point[1] for point in points]
        if max(xs) < left or min(xs) > right or max(ys) < bottom or min(ys) > top:
            return
        self.source_parts[style.layer] += 1
        for level in self.levels:
            if level.z < style.min_zoom:
                continue
            simplified = simplify_line(points, level.resolution * 0.65)
            if len(simplified) < 2:
                continue
            span = level.resolution * self.tile_size
            physical_buffer = span * BUFFER / EXTENT
            min_x = max(0, math.floor((min(point[0] for point in simplified) - left - physical_buffer) / span))
            max_x = min(
                level.tilesX - 1,
                math.floor((max(point[0] for point in simplified) - left + physical_buffer) / span),
            )
            min_down = top - max(point[1] for point in simplified)
            max_down = top - min(point[1] for point in simplified)
            min_y = max(0, math.floor((min_down - physical_buffer) / span))
            max_y = min(level.tilesY - 1, math.floor((max_down + physical_buffer) / span))
            if min_x > max_x or min_y > max_y:
                continue
            for tile_y in range(min_y, max_y + 1):
                tile_top = top - tile_y * span
                for tile_x in range(min_x, max_x + 1):
                    tile_left = left + tile_x * span
                    rectangle = (
                        tile_left - physical_buffer,
                        tile_top - span - physical_buffer,
                        tile_left + span + physical_buffer,
                        tile_top + physical_buffer,
                    )
                    for clipped in clip_line(simplified, rectangle):
                        quantized: list[tuple[int, int]] = []
                        for x_value, y_value in clipped:
                            x = round((x_value - tile_left) / span * EXTENT)
                            y = round((tile_top - y_value) / span * EXTENT)
                            x = min(EXTENT + BUFFER, max(-BUFFER, x))
                            y = min(EXTENT + BUFFER, max(-BUFFER, y))
                            point = (x, y)
                            if not quantized or point != quantized[-1]:
                                quantized.append(point)
                        if len(quantized) < 2:
                            continue
                        self._write_line_parts(level.z, tile_x, tile_y, style, quantized)

    def _write_line_parts(
        self,
        z: int,
        tile_x: int,
        tile_y: int,
        style: LineStyle,
        points: Sequence[tuple[int, int]],
    ) -> None:
        name = style.name.encode("utf-8")[:MAX_NAME_BYTES]
        offset = 0
        while offset < len(points) - 1:
            end = min(len(points), offset + MAX_POINTS)
            part = points[offset:end]
            point_bytes = b"".join(struct.pack("<hh", x, y) for x, y in part)
            payload = LINE_HEADER.pack(
                style.layer,
                style.kind,
                z if style.min_zoom > z else style.min_zoom,
                style.flags,
                len(part),
                len(name),
            ) + point_bytes + name
            self.spool.line(z, tile_x, tile_y, payload, style.layer)
            offset = end - 1

    def add_place(self, place: Place) -> None:
        left, bottom, right, top = self.bounds
        if not (left <= place.x <= right and bottom <= place.y <= top):
            return
        name = place.name.encode("utf-8")[:MAX_NAME_BYTES]
        for level in self.levels:
            if level.z < place.min_zoom:
                continue
            span = level.resolution * self.tile_size
            tile_x = min(level.tilesX - 1, max(0, int((place.x - left) // span)))
            tile_y = min(level.tilesY - 1, max(0, int((top - place.y) // span)))
            tile_left = left + tile_x * span
            tile_top = top - tile_y * span
            x = min(EXTENT, max(0, round((place.x - tile_left) / span * EXTENT)))
            y = min(EXTENT, max(0, round((tile_top - place.y) / span * EXTENT)))
            payload = PLACE_HEADER.pack(
                place.kind,
                place.min_zoom,
                0,
                x,
                y,
                place.population,
                len(name),
            ) + name
            self.spool.place(level.z, tile_x, tile_y, payload)


def project_batch(raw_lines: Sequence[RawLine], builder: VectorBuilder) -> None:
    if not raw_lines:
        return
    xs: list[float] = []
    ys: list[float] = []
    offsets = [0]
    for raw in raw_lines:
        xs.extend(point[0] for point in raw.coordinates)
        ys.extend(point[1] for point in raw.coordinates)
        offsets.append(len(xs))
    projected_xs, projected_ys = transform(SOURCE_CRS, TARGET_CRS, xs, ys)
    for index, raw in enumerate(raw_lines):
        start, end = offsets[index], offsets[index + 1]
        points = list(zip(projected_xs[start:end], projected_ys[start:end]))
        builder.add_projected_line(raw.style, points)


def process_line_features(features: Iterable[dict], builder: VectorBuilder, label: str) -> int:
    raw_lines: list[RawLine] = []
    point_count = 0
    feature_count = 0
    started = time.time()
    for feature in features:
        properties = feature.get("properties") or {}
        style = classify_line(properties)
        if style is None:
            continue
        builder.source_features[style.layer] += 1
        feature_count += 1
        for coordinates in geometry_lines(feature.get("geometry")):
            raw_lines.append(RawLine(style, coordinates))
            point_count += len(coordinates)
        if point_count >= PROJECT_BATCH_POINTS:
            project_batch(raw_lines, builder)
            raw_lines.clear()
            point_count = 0
            if feature_count % 25_000 < 500:
                print(f"  {label}: {feature_count:,} Objekte", flush=True)
    project_batch(raw_lines, builder)
    print(f"  {label}: {feature_count:,} Objekte in {(time.time() - started) / 60:.1f} min")
    return feature_count


def read_places(path: Path, builder: VectorBuilder) -> list[Place]:
    candidates: list[tuple[str, int, int, int, float, float]] = []
    for feature in iter_feature_collection(path):
        properties = feature.get("properties") or {}
        geometry = feature.get("geometry") or {}
        coordinates = geometry.get("coordinates")
        name = str(properties.get("name") or "").strip()
        place_type = str(properties.get("place_type") or properties.get("place") or "locality")
        if not name or geometry.get("type") != "Point" or not coordinates or len(coordinates) < 2:
            continue
        kind = PLACE_TYPES.get(place_type, 6)
        population = parse_population(properties.get("population"))
        candidates.append(
            (name, kind, population, place_min_zoom(place_type, population), float(coordinates[0]), float(coordinates[1]))
        )
    projected_xs, projected_ys = transform(
        SOURCE_CRS,
        TARGET_CRS,
        [candidate[4] for candidate in candidates],
        [candidate[5] for candidate in candidates],
    )
    places: list[Place] = []
    seen: set[tuple[str, int, int]] = set()
    for candidate, x, y in zip(candidates, projected_xs, projected_ys):
        name, kind, population, min_zoom, _, _ = candidate
        identity = (normalized_name(name), round(x / 20), round(y / 20))
        if identity in seen:
            continue
        seen.add(identity)
        place = Place(name, kind, population, x, y, min_zoom)
        left, bottom, right, top = builder.bounds
        if left <= x <= right and bottom <= y <= top:
            places.append(place)
            builder.add_place(place)
    places.sort(key=lambda place: (-place.population, place.min_zoom, normalized_name(place.name)))
    print(f"  Orte: {len(places):,} innerhalb des Kartengebiets")
    return places


def write_osmium_config(path: Path) -> None:
    document = {
        "attributes": {
            "type": False,
            "id": False,
            "version": False,
            "changeset": False,
            "timestamp": False,
            "uid": False,
            "user": False,
            "way_nodes": False,
        },
        "format_options": {},
        "linear_tags": True,
        "area_tags": True,
        "include_tags": [
            "highway",
            "waterway",
            "boundary",
            "admin_level",
            "name",
            "name:de",
            "bridge",
            "tunnel",
        ],
    }
    path.write_text(json.dumps(document, indent=2) + "\n", encoding="utf-8")


def create_filtered_pbf(source: Path, destination: Path) -> None:
    temporary = destination.with_name(destination.stem + ".tmp.pbf")
    temporary.unlink(missing_ok=True)
    command = [
        "osmium",
        "tags-filter",
        "-t",
        str(source),
        "-o",
        str(temporary),
        *OSMIUM_FILTERS,
    ]
    print("OSM-PBF wird einmalig auf Kartenlinien reduziert …", flush=True)
    subprocess.run(command, check=True)
    temporary.replace(destination)


def osmium_features(path: Path, config: Path) -> Iterator[dict]:
    command = [
        "osmium",
        "export",
        "-c",
        str(config),
        "-f",
        "geojsonseq",
        "-x",
        "print_record_separator=false",
        str(path),
    ]
    process = subprocess.Popen(command, stdout=subprocess.PIPE, text=True, encoding="utf-8")
    assert process.stdout is not None
    try:
        yield from iter_geojson_sequence(process.stdout)
    finally:
        process.stdout.close()
        return_code = process.wait()
        if return_code:
            raise subprocess.CalledProcessError(return_code, command)


def counts_document(spool: SpoolWriter, builder: VectorBuilder, places: list[Place]) -> dict:
    return {
        "lineCounts": dict(spool.line_counts),
        "placeCounts": dict(spool.place_counts),
        "layerRecords": {str(key): value for key, value in spool.layer_records.items()},
        "sourceFeatures": {str(key): value for key, value in builder.source_features.items()},
        "sourceParts": {str(key): value for key, value in builder.source_parts.items()},
        "places": [
            [place.name, place.kind, place.population, round(place.x, 2), round(place.y, 2), place.min_zoom]
            for place in places
        ],
    }


def write_places_index(path: Path, places: list[list], compression: int) -> tuple[int, int]:
    document = {
        "version": 1,
        "crs": TARGET_CRS,
        "fields": ["name", "kind", "population", "x", "y", "minZoom"],
        "places": places,
    }
    raw = json.dumps(document, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    packed = zlib.compress(raw, compression)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_bytes(packed)
    temporary.replace(path)
    return len(raw), len(packed)


def pack_tiles(
    output: Path,
    spool_root: Path,
    levels: list[Level],
    counts: dict,
    compression: int,
) -> tuple[list[dict], int, int]:
    raw_bytes = 0
    packed_bytes = 0
    level_stats: list[dict] = []
    for level in levels:
        tiles_with_data = 0
        line_records = 0
        place_records = 0
        level_dir = output / f"z{level.z}"
        level_dir.mkdir(parents=True, exist_ok=True)
        for tile_y in range(level.tilesY):
            for tile_x in range(level.tilesX):
                key = SpoolWriter.key(level.z, tile_x, tile_y)
                line_count = int(counts["lineCounts"].get(key, 0))
                place_count = int(counts["placeCounts"].get(key, 0))
                if line_count == 0 and place_count == 0:
                    continue
                destination = level_dir / f"{tile_x}_{tile_y}.vector.z"
                if destination.is_file():
                    tiles_with_data += 1
                    line_records += line_count
                    place_records += place_count
                    packed_bytes += destination.stat().st_size
                    continue
                lines_path = spool_root / f"z{level.z}" / f"{tile_x}_{tile_y}.lines"
                places_path = spool_root / f"z{level.z}" / f"{tile_x}_{tile_y}.places"
                payload = bytearray(TILE_HEADER.pack(MAGIC, FORMAT_VERSION, EXTENT, BUFFER, line_count, place_count))
                if lines_path.is_file():
                    payload.extend(lines_path.read_bytes())
                if places_path.is_file():
                    payload.extend(places_path.read_bytes())
                compressed = zlib.compress(payload, compression)
                temporary = destination.with_suffix(destination.suffix + ".tmp")
                temporary.write_bytes(compressed)
                temporary.replace(destination)
                raw_bytes += len(payload)
                packed_bytes += len(compressed)
                tiles_with_data += 1
                line_records += line_count
                place_records += place_count
        level_stats.append(
            {
                "z": level.z,
                "tilesWithData": tiles_with_data,
                "lineRecords": line_records,
                "placeRecords": place_records,
            }
        )
        print(
            f"  z{level.z}: {tiles_with_data:,} Kacheln, {line_records:,} Linien, {place_records:,} Orte"
        )
    return level_stats, raw_bytes, packed_bytes


def layer_manifest() -> list[dict]:
    return [
        {
            "id": LAYER_ROAD,
            "name": "Straßen",
            "kinds": [
                "Autobahn",
                "Fernstraße",
                "Bundesstraße",
                "Landesstraße",
                "Kreisstraße",
                "Ortsstraße",
                "Erschließung",
                "Feldweg",
            ],
        },
        {
            "id": LAYER_RAIL,
            "name": "Eisenbahn",
            "kinds": ["Bahn", "Schmalspur", "Stadtbahn", "U-Bahn", "Straßenbahn", "Sonderbahn", "Bau"],
        },
        {"id": LAYER_WATER, "name": "Fließgewässer", "kinds": ["Fluss", "Kanal", "Bach", "Graben", "Entwässerung"]},
        {"id": LAYER_BOUNDARY, "name": "Grenzen", "kinds": ["Staat", "Land", "Kreis", "Kommune"]},
    ]


def write_manifest(
    path: Path,
    bounds: tuple[float, float, float, float],
    tile_size: int,
    levels: list[Level],
    level_stats: list[dict],
    counts: dict,
    source_paths: dict,
    place_index_sizes: tuple[int, int],
    packed_bytes: int,
    generation_signature: dict,
) -> None:
    stats_by_zoom = {entry["z"]: entry for entry in level_stats}
    document = {
        "version": 1,
        "name": "Deutschland Vektoren",
        "crs": TARGET_CRS,
        "bounds": list(bounds),
        "tileSize": tile_size,
        "compression": "zlib",
        "tileFormat": {
            "magic": MAGIC.decode("ascii"),
            "version": FORMAT_VERSION,
            "byteOrder": "little-endian",
            "extent": EXTENT,
            "buffer": BUFFER,
            "path": "z{z}/{x}_{y}.vector.z",
            "missingTile": "empty",
        },
        "levels": [
            {
                "z": level.z,
                "resolution": level.resolution,
                "tilesX": level.tilesX,
                "tilesY": level.tilesY,
                **stats_by_zoom[level.z],
            }
            for level in levels
        ],
        "layers": layer_manifest(),
        "flags": {"bridge": 1, "tunnel": 2},
        "places": {
            "kinds": ["Stadt", "Kleinstadt", "Dorf", "Stadtteil", "Weiler", "Ort"],
            "index": "places-index.json.z",
            "indexFormat": "zlib-json",
            "fields": ["name", "kind", "population", "x", "y", "minZoom"],
            "count": len(counts["places"]),
            "rawBytes": place_index_sizes[0],
            "compressedBytes": place_index_sizes[1],
        },
        "counts": {
            "sourceFeaturesByLayer": counts["sourceFeatures"],
            "sourcePartsByLayer": counts["sourceParts"],
            "tileRecordsByLayer": counts["layerRecords"],
            "compressedTileBytes": packed_bytes,
        },
        "source": source_paths,
        "generatedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "generationSignature": generation_signature,
    }
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(document, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    temporary.replace(path)


def main() -> int:
    args = parse_args()
    required = [args.manifest, args.pbf, args.railways, args.places]
    for path in required:
        if not path.is_file():
            raise SystemExit(f"Quelldatei fehlt: {path}")
    if shutil.which("osmium") is None:
        raise SystemExit("`osmium` fehlt. Installation auf macOS: brew install osmium-tool")

    bounds, tile_size, levels = load_grid(args.manifest)
    print(
        f"Vektorraster: {len(levels)} Zoomstufen, {sum(level.tilesX * level.tilesY for level in levels):,} mögliche Kacheln"
    )
    print(f"Format: {MAGIC.decode()} · Extent {EXTENT} · Puffer {BUFFER} ({BUFFER / EXTENT * tile_size:g} px)")
    for path in required[1:]:
        print(f"  {path}: {path.stat().st_size / 1024**2:,.1f} MiB")
    if args.dry_run:
        for level in levels:
            print(
                f"  z{level.z}: {level.resolution:g} m · {level.tilesX}×{level.tilesY} · "
                f"{level.tilesX * level.tilesY:,} Kacheln"
            )
        return 0

    output = ensure_safe_directory(args.output)
    work = ensure_safe_directory(args.work)
    if args.force:
        shutil.rmtree(output, ignore_errors=True)
        shutil.rmtree(work, ignore_errors=True)
    output.mkdir(parents=True, exist_ok=True)
    work.mkdir(parents=True, exist_ok=True)

    signature = source_signature([args.pbf, args.railways, args.places], args.manifest)
    final_manifest = output / "vector-manifest.json"
    if final_manifest.is_file() and not args.force:
        existing = json.loads(final_manifest.read_text(encoding="utf-8"))
        if existing.get("generationSignature") == signature:
            print(f"Bereits vollständig: {output}")
            return 0
        print("Quellen oder Pipeline wurden verändert; Vektorkacheln werden neu aufgebaut.")
        shutil.rmtree(output)
        output.mkdir(parents=True)

    signature_path = work / "source-signature.json"
    if signature_path.is_file() and json.loads(signature_path.read_text(encoding="utf-8")) != signature:
        print("Quellen oder Pipeline wurden verändert; Arbeitscache wird neu aufgebaut.")
        shutil.rmtree(work)
        shutil.rmtree(output)
        work.mkdir(parents=True)
        output.mkdir(parents=True)
        signature_path = work / "source-signature.json"
    signature_path.write_text(json.dumps(signature, indent=2) + "\n", encoding="utf-8")

    filtered_pbf = work / "filtered-vectors.pbf"
    if not filtered_pbf.is_file():
        create_filtered_pbf(args.pbf, filtered_pbf)
    else:
        print(f"OSM-Arbeitscache wird fortgesetzt: {filtered_pbf}")

    spool_root = work / "spool"
    counts_path = work / "spool-counts.json"
    config_path = work / "osmium-export.json"
    write_osmium_config(config_path)
    if counts_path.is_file():
        print("Vollständige Geometrie-Zwischendaten werden fortgesetzt.")
        counts = json.loads(counts_path.read_text(encoding="utf-8"))
    else:
        shutil.rmtree(spool_root, ignore_errors=True)
        spool = SpoolWriter(spool_root)
        builder = VectorBuilder(bounds, tile_size, levels, spool)
        try:
            print("Bahncache wird gekachelt …")
            process_line_features(iter_feature_collection(args.railways), builder, "Bahn")
            print("Straßen, Gewässer und Grenzen werden gekachelt …")
            process_line_features(osmium_features(filtered_pbf, config_path), builder, "OSM")
            print("Orte werden gekachelt und indexiert …")
            places = read_places(args.places, builder)
        finally:
            spool.close()
        counts = counts_document(spool, builder, places)
        temporary_counts = counts_path.with_suffix(".tmp")
        temporary_counts.write_text(json.dumps(counts, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")
        temporary_counts.replace(counts_path)

    print("Binärkacheln werden komprimiert …")
    level_stats, raw_tile_bytes, packed_tile_bytes = pack_tiles(
        output, spool_root, levels, counts, args.compression
    )
    place_index_sizes = write_places_index(
        output / "places-index.json.z", counts["places"], args.compression
    )
    write_manifest(
        final_manifest,
        bounds,
        tile_size,
        levels,
        level_stats,
        counts,
        {
            "pbf": str(args.pbf),
            "railways": str(args.railways),
            "places": str(args.places),
            "rasterManifest": str(args.manifest),
        },
        place_index_sizes,
        packed_tile_bytes,
        signature,
    )

    print(
        f"Fertig: {output} · {packed_tile_bytes / 1024**2:.1f} MiB Kacheln "
        f"(unkomprimiert {raw_tile_bytes / 1024**2:.1f} MiB) · {len(counts['places']):,} Orte"
    )
    if not args.keep_work:
        shutil.rmtree(work, ignore_errors=True)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        print("\nAbgebrochen; fertige Arbeitsstufen werden beim nächsten Lauf fortgesetzt.", file=sys.stderr)
        raise SystemExit(130)
