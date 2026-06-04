#!/usr/bin/env python3
# /// script
# requires-python = ">=3.9"
# dependencies = [
#     "rasterio",
#     "numpy",
#     "pillow",
# ]
# ///
"""Bake a DEM (Copernicus GLO-30 or NASA SRTM) into a heightmap for the game.

This is an offline, one-time step that mirrors the existing ".osm file in data/"
workflow. It reads the geographic bounds from your data/map.osm, samples a DEM
over that area, and writes two files the game loads at startup:

    data/map.dem.png   16-bit grayscale heightmap (elevation, normalized)
    data/map.dem.json  metadata mapping the image back to lat/lon + meters

The Godot side (scripts/height_provider.gd) bilinearly samples the PNG and uses
the JSON to convert normalized samples into absolute elevation in meters, in the
same local coordinate frame the OSM parser uses.

--------------------------------------------------------------------------------
DEM SOURCES
--------------------------------------------------------------------------------
Copernicus GLO-30 (recommended): 30 m, global, void-filled, no auth required.
  AWS Open Data bucket (Cloud-Optimized GeoTIFF):
    s3://copernicus-dem-30m/   (also GLO-90 in copernicus-dem-90m)
  Tiles are 1x1 degree, named e.g.:
    Copernicus_DSM_COG_10_N49_00_E008_00_DEM/Copernicus_DSM_COG_10_N49_00_E008_00_DEM.tif

NASA SRTM: 30 m (US) / 90 m (global, 60N..56S). Public domain.
  Available as 1x1 degree HGT tiles or GeoTIFF from several mirrors.

--------------------------------------------------------------------------------
USAGE
--------------------------------------------------------------------------------
Run with uv -- the dependencies are declared inline (PEP 723) above, so
`uv run` installs them into an ephemeral env on first use; no manual setup or
virtualenv needed.

First, discover which Copernicus tiles your map needs (reads bounds from
data/map.osm, prints S3 URIs + download/bake commands; no DEM or deps required):

    uv run tools/bake_dem.py --list-tiles

Then provide the downloaded DEM raster(s). GDAL handles GeoTIFF, COG, and SRTM
.hgt transparently:

    # Bounds auto-detected from data/map.osm:
    uv run tools/bake_dem.py --dem path/to/dem.tif --source "Copernicus GLO-30"

    # Multiple DEM tiles (they'll be mosaicked):
    uv run tools/bake_dem.py --dem tileA.tif --dem tileB.tif

    # Explicit bounds override (minlon minlat maxlon maxlat):
    uv run tools/bake_dem.py --dem dem.tif --bounds 8.46 49.48 8.48 49.49

Fetching Copernicus tiles (no auth) with the AWS CLI, e.g. for N49 E008:
    aws s3 cp --no-sign-request \\
      s3://copernicus-dem-30m/Copernicus_DSM_COG_10_N49_00_E008_00_DEM/Copernicus_DSM_COG_10_N49_00_E008_00_DEM.tif \\
      n49e008.tif
"""

from __future__ import annotations

import argparse
import json
import math
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_OSM = REPO_ROOT / "data" / "map.osm"
DEFAULT_PNG = REPO_ROOT / "data" / "map.dem.png"
DEFAULT_JSON = REPO_ROOT / "data" / "map.dem.json"


def read_osm_bounds(osm_path: Path) -> tuple[float, float, float, float]:
    """Return (min_lon, min_lat, max_lon, max_lat) from an .osm file.

    Prefers the <bounds> element; falls back to scanning node lat/lon.
    """
    min_lon = min_lat = float("inf")
    max_lon = max_lat = float("-inf")
    found_bounds = False

    # Stream the file so we don't load a multi-MB .osm fully into memory.
    for _event, elem in ET.iterparse(str(osm_path), events=("start",)):
        if elem.tag == "bounds":
            return (
                float(elem.attrib["minlon"]),
                float(elem.attrib["minlat"]),
                float(elem.attrib["maxlon"]),
                float(elem.attrib["maxlat"]),
            )
        if elem.tag == "node":
            lat = float(elem.attrib["lat"])
            lon = float(elem.attrib["lon"])
            min_lon, max_lon = min(min_lon, lon), max(max_lon, lon)
            min_lat, max_lat = min(min_lat, lat), max(max_lat, lat)
            found_bounds = True
        elem.clear()

    if not found_bounds:
        raise SystemExit(f"Could not determine bounds from {osm_path}")
    return (min_lon, min_lat, max_lon, max_lat)


def copernicus_tile_name(lat_floor: int, lon_floor: int) -> str:
    """Copernicus tile base name for the 1x1 degree tile whose SW corner is
    (lat_floor, lon_floor).

    Copernicus GLO-30 tiles are named by the integer floor of their southwest
    corner, padded to two (lat) / three (lon) digits with a hemisphere letter,
    e.g. N49 E008 -> Copernicus_DSM_COG_10_N49_00_E008_00_DEM. Southern /
    western tiles use S and W. The "10" is the GLO-30 resolution code.
    """
    ns = "N" if lat_floor >= 0 else "S"
    ew = "E" if lon_floor >= 0 else "W"
    return "Copernicus_DSM_COG_10_%s%02d_00_%s%03d_00_DEM" % (
        ns, abs(lat_floor), ew, abs(lon_floor)
    )


def copernicus_tiles_for_bounds(
    bounds: tuple[float, float, float, float], resolution: str = "30m"
) -> list[dict]:
    """Every Copernicus tile a bbox touches, as a list of dicts with:
        name   tile base name (also the folder name on S3)
        key    full S3 object key
        s3     s3:// URI
        https  public HTTPS URL

    A bbox can span multiple 1x1 degree tiles, so we iterate the integer lat/lon
    grid from floor(min) to floor(max) inclusive. The max edge is nudged inward
    by a hair so a bound that lands exactly on an integer boundary (e.g. 9.0)
    does not pull in the adjacent tile it only grazes.
    """
    min_lon, min_lat, max_lon, max_lat = bounds
    bucket = "copernicus-dem-%s" % resolution

    lat_lo = int(math.floor(min_lat))
    lon_lo = int(math.floor(min_lon))
    # Subtract epsilon so a max exactly on an integer stays in the lower tile.
    lat_hi = int(math.floor(max_lat - 1e-9))
    lon_hi = int(math.floor(max_lon - 1e-9))
    lat_hi = max(lat_hi, lat_lo)
    lon_hi = max(lon_hi, lon_lo)

    tiles = []
    for lat_f in range(lat_lo, lat_hi + 1):
        for lon_f in range(lon_lo, lon_hi + 1):
            name = copernicus_tile_name(lat_f, lon_f)
            key = "%s/%s.tif" % (name, name)
            tiles.append({
                "name": name,
                "key": key,
                "s3": "s3://%s/%s" % (bucket, key),
                "https": "https://%s.s3.amazonaws.com/%s" % (bucket, key),
            })
    return tiles


def print_tiles(bounds: tuple[float, float, float, float], resolution: str) -> None:
    """Print the Copernicus tiles for a bbox plus ready-to-run download commands."""
    tiles = copernicus_tiles_for_bounds(bounds, resolution)
    print("# Bounds: min_lon=%.6f min_lat=%.6f max_lon=%.6f max_lat=%.6f"
          % bounds)
    print("# %d Copernicus DEM-%s tile(s) cover this area:" % (len(tiles), resolution))
    for t in tiles:
        print(t["s3"])
    print()
    print("# Download (no AWS credentials needed):")
    for t in tiles:
        local = "%s.tif" % t["name"]
        print("aws s3 cp --no-sign-request %s %s" % (t["s3"], local))
    print()
    print("# Then bake (pass each downloaded tile with --dem):")
    dem_flags = " ".join("--dem %s.tif" % t["name"] for t in tiles)
    print("uv run tools/bake_dem.py %s --source \"Copernicus GLO-30\"" % dem_flags)


def bake(
    dem_paths: list[Path],
    bounds: tuple[float, float, float, float],
    out_png: Path,
    out_json: Path,
    source: str,
    width: int,
) -> None:
    try:
        import numpy as np
        import rasterio
        from rasterio.merge import merge
        from rasterio.warp import transform_bounds
        from PIL import Image
    except ImportError as exc:  # pragma: no cover - environment dependent
        raise SystemExit(
            "Missing dependency: %s\nRun this script with uv so inline deps are "
            "installed automatically:\n    uv run tools/bake_dem.py ..." % exc.name
        )

    min_lon, min_lat, max_lon, max_lat = bounds

    datasets = [rasterio.open(p) for p in dem_paths]
    try:
        # Mosaic (no-op for a single tile) so multi-tile areas stitch together.
        mosaic, transform = merge(datasets)
        crs = datasets[0].crs
    finally:
        for d in datasets:
            d.close()

    band = mosaic[0].astype("float64")

    # Map our geographic bounds into the DEM's pixel grid. DEMs are usually
    # EPSG:4326 already, but transform_bounds keeps us correct if they aren't.
    src_minx, src_miny, src_maxx, src_maxy = transform_bounds(
        "EPSG:4326", crs, min_lon, min_lat, max_lon, max_lat
    )

    inv = ~transform  # world -> pixel (col, row)
    col0, row0 = inv * (src_minx, src_maxy)  # top-left
    col1, row1 = inv * (src_maxx, src_miny)  # bottom-right
    c0, c1 = sorted((int(col0), int(col1)))
    r0, r1 = sorted((int(row0), int(row1)))
    c0, r0 = max(c0, 0), max(r0, 0)
    c1 = min(c1, band.shape[1] - 1)
    r1 = min(r1, band.shape[0] - 1)
    if c1 <= c0 or r1 <= r0:
        raise SystemExit("Requested bounds do not overlap the DEM coverage.")

    crop = band[r0 : r1 + 1, c0 : c1 + 1]

    # Resample to the requested output width, preserving aspect ratio.
    aspect = crop.shape[0] / crop.shape[1]
    height = max(2, int(round(width * aspect)))
    resized = np.array(
        Image.fromarray(crop).resize((width, height), Image.BILINEAR),
        dtype="float64",
    )

    # Treat extreme negatives (common DEM nodata sentinels) as min elevation.
    valid = resized[resized > -1e4]
    if valid.size == 0:
        raise SystemExit("No valid elevation samples in the cropped region.")
    min_elev = float(valid.min())
    max_elev = float(valid.max())
    resized = np.clip(resized, min_elev, max_elev)

    span = max(max_elev - min_elev, 1e-6)
    norm = ((resized - min_elev) / span * 65535.0).round().astype("uint16")

    Image.fromarray(norm, mode="I;16").save(out_png)

    meta = {
        "min_lon": min_lon,
        "min_lat": min_lat,
        "max_lon": max_lon,
        "max_lat": max_lat,
        "width": width,
        "height": height,
        "min_elev": round(min_elev, 3),
        "max_elev": round(max_elev, 3),
        "source": source,
    }
    out_json.write_text(json.dumps(meta, indent=2) + "\n")

    print(f"Wrote {out_png} ({width}x{height})")
    print(f"Wrote {out_json}")
    print(f"Elevation range: {min_elev:.1f} .. {max_elev:.1f} m  (relief {span:.1f} m)")


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--dem", action="append", type=Path,
                   help="DEM raster (GeoTIFF/COG/HGT). Repeat for multiple tiles. "
                        "Required to bake; omit when using --list-tiles.")
    p.add_argument("--osm", type=Path, default=DEFAULT_OSM,
                   help="OSM file to read bounds from (default: data/map.osm)")
    p.add_argument("--bounds", nargs=4, type=float, metavar=("MINLON", "MINLAT", "MAXLON", "MAXLAT"),
                   help="Explicit bounds, overriding the OSM file.")
    p.add_argument("--list-tiles", action="store_true",
                   help="Print the Copernicus AWS tiles covering the bounds "
                        "(with download + bake commands) and exit. No DEM needed.")
    p.add_argument("--resolution", choices=["30m", "90m"], default="30m",
                   help="Copernicus product for --list-tiles (default: 30m / GLO-30).")
    p.add_argument("--out-png", type=Path, default=DEFAULT_PNG)
    p.add_argument("--out-json", type=Path, default=DEFAULT_JSON)
    p.add_argument("--width", type=int, default=512,
                   help="Heightmap width in pixels (default: 512).")
    p.add_argument("--source", default="Copernicus GLO-30",
                   help="Source label stored in metadata.")
    args = p.parse_args(argv)

    if args.bounds:
        bounds = tuple(args.bounds)  # type: ignore[assignment]
    else:
        bounds = read_osm_bounds(args.osm)
        if not args.list_tiles:
            print("Bounds from %s: %s" % (args.osm, bounds))

    if args.list_tiles:
        print_tiles(bounds, args.resolution)
        return 0

    if not args.dem:
        print("error: --dem is required to bake. Use --list-tiles to discover "
              "which Copernicus files to download.", file=sys.stderr)
        return 2
    for dem in args.dem:
        if not dem.exists():
            print(f"DEM not found: {dem}", file=sys.stderr)
            return 1

    bake(args.dem, bounds, args.out_png, args.out_json, args.source, args.width)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
