#!/usr/bin/env python3
# /// script
# requires-python = ">=3.9"
# dependencies = [
#     "osmium>=3.6",
# ]
# ///
"""Download a country from Geofabrik and bake it into a streamable tile cache.

This is an offline, one-time step that mirrors the existing "map.osm in data/"
and tools/bake_dem.py workflows. Instead of a single map.osm the game loads
whole into RAM (fine for ~10 km, hopeless for a country), it produces a
directory of small, self-contained per-tile .osm files plus a manifest the game
streams from disk as the camera moves:

    data/tiles/manifest.json     bbox, center, tile_size, list of non-empty tiles
    data/tiles/<x>_<z>.osm       one standard .osm file per tile

Each per-tile .osm is SELF-CONTAINED: it carries not only the features assigned
to that tile but every node those features reference (and the ways referenced by
its multipolygon relations). That is required because the game's builders resolve
way/relation members through a single per-tile OSMData dictionary
(scripts/osm_tile_manager.gd, scripts/osm_tile_context.gd); a tile missing a
referenced node would render a broken way.

PERFORMANCE: clipping a 1+ GB country .pbf in pure Python means iterating 100M+
node objects (minutes). Instead this tool shells out to the `osmium` command-line
tool (`osmium extract -b <bbox> -s complete_ways`), which does the clip in
optimized C++ in ~seconds, producing a small extract. The Python tiler then only
ever touches that small extract. `osmium` (osmium-tool) must be installed:
    brew install osmium-tool     # macOS
    apt install osmium-tool      # Debian/Ubuntu
The Python `osmium` (pyosmium) library is still used to read the small extract.

--------------------------------------------------------------------------------
COORDINATE / TILE CONSISTENCY (critical)
--------------------------------------------------------------------------------
The projection and tile-key math here MUST match the game exactly or features
land in the wrong tile:

  projection  scripts/osm_parser.gd  _latlon_to_local()
      m_per_deg_lat = 111132.0
      m_per_deg_lon = 111132.0 * cos(deg_to_rad(center_lat))
      x =  (lon - center_lon) * m_per_deg_lon
      z = -(lat - center_lat) * m_per_deg_lat        # Z goes south in Godot
  tile key    scripts/osm_tile_manager.gd  _pos_to_tile()
      tx = floor(x / tile_size)
      tz = floor(z / tile_size)

center_lat/center_lon and tile_size are written into manifest.json and adopted
verbatim by the game (DiskTileSource reads them), so the two sides cannot
silently disagree.

--------------------------------------------------------------------------------
USAGE
--------------------------------------------------------------------------------
Run with uv -- the osmium dependency is declared inline (PEP 723), so `uv run`
installs it into an ephemeral env on first use; no manual setup needed.

List / resolve the Geofabrik URL for a country without downloading:

    uv run tools/bake_osm_tiles.py --country europe/germany --list

Download a country and bake a bbox (min_lon min_lat max_lon max_lat) into tiles:

    uv run tools/bake_osm_tiles.py \\
        --country europe/germany \\
        --bounds 7.5900 50.3400 7.6400 50.3700

Reuse an already-downloaded .pbf (skips the download):

    uv run tools/bake_osm_tiles.py \\
        --pbf germany-latest.osm.pbf \\
        --bounds 7.5900 50.3400 7.6400 50.3700

Override tile size (must be a positive number of meters; the game adopts it):

    uv run tools/bake_osm_tiles.py --pbf x.osm.pbf --bounds ... --tile-size 200

Omit --bounds to bake the .pbf's whole extent, read from its header bbox (this
is instant -- the header is at the front of the file and no node coordinates are
scanned). Best for small, hand-cropped extracts; for a full country the tool
warns because the tile count is enormous. When --bounds IS given it is validated
against that header extent, so a wrong-country file or transposed lon/lat fails
loudly and immediately instead of after a long clip that yields nothing:

    uv run tools/bake_osm_tiles.py --pbf small-city.osm.pbf
"""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import shutil
import subprocess
import sys
import urllib.request
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
DEFAULT_OUT_DIR = REPO_ROOT / "data" / "tiles"
DEFAULT_DOWNLOAD_DIR = REPO_ROOT / "data"

GEOFABRIK_BASE = "https://download.geofabrik.de"

# Must match scripts/osm_parser.gd:_latlon_to_local.
METERS_PER_DEG_LAT = 111132.0

# Bump when the on-disk manifest/tile layout changes in a breaking way. The game
# checks this so a stale cache from an older tool version fails loudly.
MANIFEST_VERSION = 1


# ─── Geofabrik download ──────────────────────────────────────────────────────

def geofabrik_url(country: str) -> str:
    """Resolve a Geofabrik country path to its latest .osm.pbf URL.

    `country` is the Geofabrik path without the -latest.osm.pbf suffix, e.g.
    "europe/germany" or "north-america/us/california". A trailing
    "-latest.osm.pbf" (or ".osm.pbf") is tolerated and stripped so users can
    paste either form.
    """
    c = country.strip().strip("/")
    for suffix in ("-latest.osm.pbf", ".osm.pbf", ".pbf"):
        if c.endswith(suffix):
            c = c[: -len(suffix)]
            break
    return f"{GEOFABRIK_BASE}/{c}-latest.osm.pbf"


def _download(url: str, dest: Path) -> None:
    """Stream `url` to `dest`, printing coarse progress. Overwrites dest."""
    print(f"# Downloading {url}")
    tmp = dest.with_suffix(dest.suffix + ".part")
    with urllib.request.urlopen(url) as resp:  # noqa: S310 - trusted host
        total = int(resp.headers.get("Content-Length", 0))
        read = 0
        chunk = 1 << 20  # 1 MiB
        with open(tmp, "wb") as fh:
            while True:
                buf = resp.read(chunk)
                if not buf:
                    break
                fh.write(buf)
                read += len(buf)
                if total:
                    pct = 100.0 * read / total
                    print(f"\r#   {read >> 20} / {total >> 20} MiB ({pct:5.1f}%)",
                          end="", flush=True)
    print()
    tmp.replace(dest)


def _verify_md5(pbf: Path, url: str) -> None:
    """Verify `pbf` against Geofabrik's sibling .md5, if reachable.

    Geofabrik publishes "<name>.osm.pbf.md5" next to each download. A mismatch
    is fatal; an unreachable .md5 is a warning (older mirrors omit it).
    """
    md5_url = url + ".md5"
    try:
        with urllib.request.urlopen(md5_url) as resp:  # noqa: S310
            expected = resp.read().decode().split()[0].strip()
    except Exception as exc:  # noqa: BLE001 - best-effort integrity check
        print(f"# WARNING: could not fetch {md5_url} ({exc}); skipping checksum")
        return

    h = hashlib.md5()  # noqa: S324 - Geofabrik publishes md5, not our choice
    with open(pbf, "rb") as fh:
        for block in iter(lambda: fh.read(1 << 20), b""):
            h.update(block)
    got = h.hexdigest()
    if got != expected:
        raise SystemExit(
            f"Checksum mismatch for {pbf}:\n  expected {expected}\n  got      {got}"
        )
    print(f"# Checksum OK ({got})")


# ─── PBF header bounding box ─────────────────────────────────────────────────

def pbf_header_bbox(
    pbf: Path,
) -> tuple[float, float, float, float] | None:
    """Read the bounding box from a .pbf HeaderBlock without scanning entities.

    Geofabrik (and osmium/osmosis) write a bbox into the PBF header, so we can
    recover (min_lon, min_lat, max_lon, max_lat) in microseconds — the header is
    a few hundred bytes at the front of the file; no node/way/relation data is
    touched. Returns None if the header carries no (or an invalid) box, which
    some hand-cut extracts do.

    Note this is the extent of the WHOLE file (e.g. all of Germany for a country
    download), not the tight extent of its data. Baking that verbatim into small
    tiles can be enormous, so the caller warns before doing so.
    """
    import osmium  # imported here so --list / tests can run without the dep

    reader = osmium.io.Reader(str(pbf), osmium.osm.osm_entity_bits.NOTHING)
    try:
        box = reader.header().box()
    finally:
        reader.close()
    if not box.valid():
        return None
    return (
        box.bottom_left.lon,
        box.bottom_left.lat,
        box.top_right.lon,
        box.top_right.lat,
    )


# ─── Projection / tiling (mirror of the GDScript) ────────────────────────────

def latlon_to_local(
    lat: float, lon: float, center_lat: float, center_lon: float
) -> tuple[float, float]:
    """(lat, lon) -> local (x, z) meters. Mirrors osm_parser.gd:_latlon_to_local."""
    m_per_deg_lon = METERS_PER_DEG_LAT * math.cos(math.radians(center_lat))
    x = (lon - center_lon) * m_per_deg_lon
    z = -(lat - center_lat) * METERS_PER_DEG_LAT
    return x, z


def pos_to_tile(x: float, z: float, tile_size: float) -> tuple[int, int]:
    """Local (x, z) -> tile key. Mirrors osm_tile_manager.gd:_pos_to_tile."""
    return math.floor(x / tile_size), math.floor(z / tile_size)


# ─── Tiling core (osmium-free, unit-testable) ────────────────────────────────

class TileAssembler:
    """Collects clipped OSM features and assigns them to tiles.

    Deliberately independent of osmium so it can be unit-tested with plain data
    (see tools/test_bake_osm_tiles.py). The osmium handlers below merely feed it.

    Assignment rules mirror the game's spatial index
    (scripts/osm_tile_source.gd InMemoryTileSource._build_spatial_index):
      - a tagged node occupies the tile of its own position,
      - a way occupies every tile its (in-bbox) nodes touch,
      - a relation occupies every tile its member nodes/ways touch.
    Each emitted tile is then closed over its references so the file stands
    alone: every node a kept way references, and every way (+ its nodes) a kept
    relation references, is included even if that member sits in a neighbor tile.
    """

    def __init__(
        self,
        bounds: tuple[float, float, float, float],
        tile_size: float,
    ) -> None:
        self.bounds = bounds
        self.tile_size = tile_size
        min_lon, min_lat, max_lon, max_lat = bounds
        self.center_lat = (min_lat + max_lat) / 2.0
        self.center_lon = (min_lon + max_lon) / 2.0
        self.nodes: dict[int, tuple[float, float]] = {}
        self.node_tile: dict[int, tuple[int, int]] = {}
        self.node_tags: dict[int, dict[str, str]] = {}
        self.ways: dict[int, dict] = {}       # id -> {nodes:[...], tags:{}}
        self.relations: dict[int, dict] = {}  # id -> {members:[...], tags:{}}
        self.tile_nodes: dict[tuple, set] = {}
        self.tile_ways: dict[tuple, set] = {}
        self.tile_rels: dict[tuple, set] = {}

    def in_bbox(self, lat: float, lon: float) -> bool:
        min_lon, min_lat, max_lon, max_lat = self.bounds
        return min_lat <= lat <= max_lat and min_lon <= lon <= max_lon

    def tile_of(self, lat: float, lon: float) -> tuple[int, int]:
        x, z = latlon_to_local(lat, lon, self.center_lat, self.center_lon)
        return pos_to_tile(x, z, self.tile_size)

    def _bucket(self, tkey: tuple) -> None:
        self.tile_nodes.setdefault(tkey, set())
        self.tile_ways.setdefault(tkey, set())
        self.tile_rels.setdefault(tkey, set())

    def add_node(self, nid: int, lat: float, lon: float, tags: dict) -> None:
        """Record a node if it lies inside the bbox."""
        if not self.in_bbox(lat, lon):
            return
        self.nodes[nid] = (lat, lon)
        self.node_tile[nid] = self.tile_of(lat, lon)
        if tags:
            self.node_tags[nid] = tags

    def needed_missing_node_ids(self) -> set:
        """Node ids referenced by kept ways/relations that we have no coords for.

        A way can cross the bbox edge, so some of its nodes lie outside the clip
        and were dropped by add_node. Those nodes must still be fetched (a
        "complete ways" clip) or the tile file won't be self-contained and the
        game's builders can't resolve the geometry. This returns the ids to
        back-fill in a supplemental pass.
        """
        needed: set = set()
        for way in self.ways.values():
            for nid in way["nodes"]:
                if nid not in self.nodes:
                    needed.add(nid)
        for rel in self.relations.values():
            for m in rel["members"]:
                if m["type"] in ("n", "node") and m["ref"] not in self.nodes:
                    needed.add(m["ref"])
        return needed

    def add_supplemental_node(self, nid: int, lat: float, lon: float) -> None:
        """Record coords for an out-of-bbox node referenced by a kept feature.

        Unlike add_node this bypasses the bbox test (the whole point is that the
        node is outside) and never marks the node as standalone content — it only
        gives the way/relation geometry a resolvable endpoint. It is still binned
        to a tile so closure_for_tile can include it in the right file.
        """
        if nid in self.nodes:
            return
        self.nodes[nid] = (lat, lon)
        self.node_tile[nid] = self.tile_of(lat, lon)

    def add_way(self, wid: int, node_ids: list, tags: dict) -> None:
        """Record a way if any of its nodes is inside the bbox."""
        touched = {self.node_tile[n] for n in node_ids if n in self.node_tile}
        if not touched:
            return
        self.ways[wid] = {"nodes": list(node_ids), "tags": dict(tags)}
        for tkey in touched:
            self._bucket(tkey)
            self.tile_ways[tkey].add(wid)

    def add_relation(self, rid: int, members: list, tags: dict) -> None:
        """Record a relation if any member touches the bbox."""
        touched: set = set()
        for m in members:
            if m["type"] in ("w", "way") and m["ref"] in self.ways:
                for nid in self.ways[m["ref"]]["nodes"]:
                    if nid in self.node_tile:
                        touched.add(self.node_tile[nid])
            elif m["type"] in ("n", "node") and m["ref"] in self.node_tile:
                touched.add(self.node_tile[m["ref"]])
        if not touched:
            return
        norm = [
            {"type": m["type"], "ref": m["ref"], "role": m.get("role", "")}
            for m in members
        ]
        self.relations[rid] = {"members": norm, "tags": dict(tags)}
        for tkey in touched:
            self._bucket(tkey)
            self.tile_rels[tkey].add(rid)

    def finalize_standalone_nodes(self) -> None:
        """Tagged nodes occupy their own tile (traffic lights, trees, etc.)."""
        for nid, tkey in self.node_tile.items():
            if nid in self.node_tags:
                self._bucket(tkey)
                self.tile_nodes[tkey].add(nid)

    def tile_keys(self) -> list:
        return sorted(
            set(self.tile_nodes) | set(self.tile_ways) | set(self.tile_rels)
        )

    def closure_for_tile(self, tkey: tuple) -> tuple[set, set, set]:
        """(node_ids, way_ids, rel_ids) needed to make `tkey` self-contained."""
        node_ids = set(self.tile_nodes.get(tkey, set()))
        way_ids = set(self.tile_ways.get(tkey, set()))
        rel_ids = set(self.tile_rels.get(tkey, set()))
        for rid in rel_ids:
            for m in self.relations[rid]["members"]:
                if m["type"] in ("w", "way") and m["ref"] in self.ways:
                    way_ids.add(m["ref"])
                elif m["type"] in ("n", "node"):
                    node_ids.add(m["ref"])
        for wid in way_ids:
            for nid in self.ways[wid]["nodes"]:
                node_ids.add(nid)
        node_ids = {nid for nid in node_ids if nid in self.nodes}
        return node_ids, way_ids, rel_ids

    def write_tiles(self, out_dir: Path) -> dict:
        """Emit every non-empty tile + manifest.json. Returns the manifest."""
        out_dir.mkdir(parents=True, exist_ok=True)
        for old in out_dir.glob("*.osm"):
            old.unlink()

        written: list[dict] = []
        for tkey in self.tile_keys():
            node_ids, way_ids, rel_ids = self.closure_for_tile(tkey)
            if not (node_ids or way_ids or rel_ids):
                continue
            path = out_dir / f"{tkey[0]}_{tkey[1]}.osm"
            _write_tile_osm(path, node_ids, way_ids, rel_ids, self, self.bounds)
            written.append({"x": tkey[0], "z": tkey[1], "file": path.name})

        min_lon, min_lat, max_lon, max_lat = self.bounds
        manifest = {
            "version": MANIFEST_VERSION,
            "tile_size": self.tile_size,
            "center_lat": self.center_lat,
            "center_lon": self.center_lon,
            "meters_per_deg_lat": METERS_PER_DEG_LAT,
            "bounds": {
                "min_lon": min_lon,
                "min_lat": min_lat,
                "max_lon": max_lon,
                "max_lat": max_lat,
            },
            "tiles": written,
        }
        (out_dir / "manifest.json").write_text(json.dumps(manifest, indent=2))
        return manifest


def extract_bbox(
    pbf: Path,
    bounds: tuple[float, float, float, float],
    dest: Path,
) -> None:
    """Clip `pbf` to `bounds` into a small .osm.pbf using osmium's native (C++)
    reference completion.

    Why this exists: a country .pbf is 1+ GB / 100M+ nodes. Building Python dicts
    of every in-bbox node (and re-scanning all nodes to back-fill boundary ones)
    means several slow full passes. Instead we do the country-scale work almost
    entirely in osmium's C++ layer — the Python callbacks here only flip ids in
    an IdTracker — and emit a *small* extract that the tiler then chews on. The
    extract keeps "complete ways" (every node a kept way references, even outside
    the bbox), so downstream tiles are self-contained without a back-fill pass.

    Two passes over the country file:
      A) mark ids: nodes inside the bbox; ways with any node inside (+ their node
         refs); relations referencing anything already marked. Then complete
         backward references so all nodes of kept ways are included.
      B) write every marked object to `dest`.
    """
    osmium_bin = shutil.which("osmium")
    if osmium_bin is None:
        raise SystemExit(
            "The 'osmium' command-line tool is required to clip a country .pbf.\n"
            "  Install it with:  brew install osmium-tool   (macOS)\n"
            "                    apt install osmium-tool     (Debian/Ubuntu)\n"
            "Then re-run this command."
        )

    min_lon, min_lat, max_lon, max_lat = bounds
    if dest.exists():
        dest.unlink()

    # `osmium extract` does the whole clip in optimized C++: a geographic bbox
    # with "complete ways" (-s complete_ways) so every node a kept way references
    # is included even outside the box, and reference-complete relations. That
    # gives us self-contained geometry for tiling with none of the per-node
    # Python overhead that made a country take minutes.
    bbox = "%f,%f,%f,%f" % (min_lon, min_lat, max_lon, max_lat)

    def _run_extract(src: Path) -> subprocess.CompletedProcess:
        cmd = [
            osmium_bin, "extract",
            "-b", bbox,
            "-s", "complete_ways",
            "--overwrite",
            "-o", str(dest),
            str(src),
        ]
        return subprocess.run(cmd, capture_output=True, text=True)

    print("# Extract: osmium extract -b %s (complete_ways)" % bbox)
    result = _run_extract(pbf)

    # `osmium extract` requires type-then-id-sorted input. Geofabrik .pbf files
    # always are; a hand-made / API-exported .osm may not be. If we hit the
    # "out of order" error, sort once into a temp file and retry.
    sorted_tmp: Path | None = None
    if result.returncode != 0 and "out of order" in (result.stdout + result.stderr):
        sorted_tmp = dest.with_name("_sorted.osm.pbf")
        print("# Input not sorted; running osmium sort first")
        sort = subprocess.run(
            [osmium_bin, "sort", "--overwrite", "-o", str(sorted_tmp), str(pbf)],
            capture_output=True, text=True)
        if sort.returncode != 0:
            _cleanup(dest, sorted_tmp)
            raise SystemExit("osmium sort failed (exit %d):\n%s%s"
                             % (sort.returncode, sort.stdout, sort.stderr))
        result = _run_extract(sorted_tmp)

    if result.returncode != 0:
        _cleanup(dest, sorted_tmp)
        raise SystemExit(
            "osmium extract failed (exit %d):\n%s%s"
            % (result.returncode, result.stdout, result.stderr)
        )
    if sorted_tmp is not None:
        sorted_tmp.unlink(missing_ok=True)
    if not dest.exists():
        raise SystemExit("osmium extract produced no output at %s" % dest)


def _cleanup(*paths) -> None:
    """Remove any partial output files, ignoring those that don't exist."""
    for p in paths:
        if p is not None:
            Path(p).unlink(missing_ok=True)


def bake_tiles(
    pbf: Path,
    bounds: tuple[float, float, float, float],
    tile_size: float,
    out_dir: Path,
    keep_extract: bool = False,
) -> dict:
    """Clip `pbf` to `bounds` and write a self-contained per-tile .osm cache.

    Returns the manifest dict (also written to out_dir/manifest.json).

    Fast path: clip the (possibly huge) source to a small .osm.pbf natively,
    then run the Python tiler over that small extract. The tiler still reads the
    extract twice (nodes first, then ways+relations) but the extract is tiny, so
    the country-scale cost is paid once in osmium's C++ layer.
    """
    import osmium  # imported here so --list / tests can run without the dep

    out_dir.mkdir(parents=True, exist_ok=True)
    extract = out_dir / "_extract.osm.pbf"
    extract_bbox(pbf, bounds, extract)

    asm = TileAssembler(bounds, tile_size)

    class NodeCollector(osmium.SimpleHandler):
        def node(self, n: "osmium.osm.Node") -> None:  # noqa: N802
            if n.location.valid():
                tags = {t.k: t.v for t in n.tags}
                asm.add_node(n.id, n.location.lat, n.location.lon, tags)

    print("# Tiling 1/2: reading nodes from extract")
    NodeCollector().apply_file(str(extract))
    print(f"#   {len(asm.nodes)} nodes in bbox")

    class FeatureCollector(osmium.SimpleHandler):
        def way(self, w: "osmium.osm.Way") -> None:  # noqa: N802
            asm.add_way(
                w.id, [nd.ref for nd in w.nodes], {t.k: t.v for t in w.tags}
            )

        def relation(self, r: "osmium.osm.Relation") -> None:  # noqa: N802
            members = [
                {"type": m.type, "ref": m.ref, "role": m.role} for m in r.members
            ]
            asm.add_relation(r.id, members, {t.k: t.v for t in r.tags})

    print("# Tiling 2/2: reading ways and relations from extract")
    FeatureCollector().apply_file(str(extract), locations=False)

    # The native extract already keeps complete ways, so any boundary node is
    # present. Back-fill remains as a cheap safety net over the *small* extract
    # (e.g. a relation member node the extract didn't pull) — near-free here.
    needed = asm.needed_missing_node_ids()
    if needed:
        print(f"#   back-filling {len(needed)} node(s) from extract")

        class SupplementalNodes(osmium.SimpleHandler):
            def node(self, n: "osmium.osm.Node") -> None:  # noqa: N802
                if n.id in needed and n.location.valid():
                    asm.add_supplemental_node(n.id, n.location.lat, n.location.lon)

        SupplementalNodes().apply_file(str(extract))

    asm.finalize_standalone_nodes()
    manifest = asm.write_tiles(out_dir)
    print(f"# Wrote {len(manifest['tiles'])} tile(s) + manifest.json to {out_dir}")

    if not keep_extract:
        extract.unlink(missing_ok=True)
    else:
        print(f"# Kept intermediate extract at {extract}")
    return manifest


def _xml_escape(value: str) -> str:
    return (
        value.replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace('"', "&quot;")
    )


def _write_tile_osm(
    path: Path,
    node_ids: set,
    way_ids: set,
    rel_ids: set,
    asm: "TileAssembler",
    bounds: tuple[float, float, float, float],
) -> None:
    """Write one self-contained tile as standard OSM 0.6 XML.

    The format matches what scripts/osm_parser.gd reads: <bounds>, <node> with
    lat/lon and tags, <way> with <nd ref>/tags, <relation> with <member>/tags.
    """
    min_lon, min_lat, max_lon, max_lat = bounds
    lines = ['<?xml version="1.0" encoding="UTF-8"?>']
    lines.append('<osm version="0.6" generator="bake_osm_tiles.py">')
    lines.append(
        '  <bounds minlat="%.7f" minlon="%.7f" maxlat="%.7f" maxlon="%.7f"/>'
        % (min_lat, min_lon, max_lat, max_lon)
    )

    for nid in sorted(node_ids):
        lat, lon = asm.nodes[nid]
        tags = asm.node_tags.get(nid)
        if tags:
            lines.append('  <node id="%d" lat="%.7f" lon="%.7f">' % (nid, lat, lon))
            for k, v in tags.items():
                lines.append('    <tag k="%s" v="%s"/>'
                             % (_xml_escape(k), _xml_escape(v)))
            lines.append("  </node>")
        else:
            lines.append('  <node id="%d" lat="%.7f" lon="%.7f"/>' % (nid, lat, lon))

    for wid in sorted(way_ids):
        way = asm.ways[wid]
        lines.append('  <way id="%d">' % wid)
        for nid in way["nodes"]:
            lines.append('    <nd ref="%d"/>' % nid)
        for k, v in way["tags"].items():
            lines.append('    <tag k="%s" v="%s"/>' % (_xml_escape(k), _xml_escape(v)))
        lines.append("  </way>")

    for rid in sorted(rel_ids):
        rel = asm.relations[rid]
        lines.append('  <relation id="%d">' % rid)
        for m in rel["members"]:
            mtype = {"n": "node", "w": "way", "r": "relation"}.get(
                m["type"], m["type"]
            )
            lines.append(
                '    <member type="%s" ref="%d" role="%s"/>'
                % (mtype, m["ref"], _xml_escape(m["role"]))
            )
        for k, v in rel["tags"].items():
            lines.append('    <tag k="%s" v="%s"/>' % (_xml_escape(k), _xml_escape(v)))
        lines.append("  </relation>")

    lines.append("</osm>")
    path.write_text("\n".join(lines) + "\n")


# ─── CLI ─────────────────────────────────────────────────────────────────────

def _bbox_tile_estimate(
    bounds: tuple[float, float, float, float], tile_size: float
) -> int:
    """Rough count of tiles a bbox spans at `tile_size` (upper bound guess).

    Uses the same projection as the game so the estimate tracks reality: bbox
    width/height in meters divided by tile_size. This is the grid extent, not
    the number of NON-EMPTY tiles (usually far fewer), so it deliberately
    over-estimates — good enough to catch a "you asked for all of Germany" foot-gun.
    """
    min_lon, min_lat, max_lon, max_lat = bounds
    center_lat = (min_lat + max_lat) / 2.0
    center_lon = (min_lon + max_lon) / 2.0
    x0, z0 = latlon_to_local(min_lat, min_lon, center_lat, center_lon)
    x1, z1 = latlon_to_local(max_lat, max_lon, center_lat, center_lon)
    cols = math.ceil(abs(x1 - x0) / tile_size)
    rows = math.ceil(abs(z1 - z0) / tile_size)
    return cols * rows


# Warn once a derived bbox would span more grid tiles than this. A few thousand
# is fine; a whole country at 200 m is millions and almost never intended.
_HUGE_BBOX_TILE_THRESHOLD = 50_000


def _warn_if_bbox_huge(
    bounds: tuple[float, float, float, float], tile_size: float
) -> None:
    est = _bbox_tile_estimate(bounds, tile_size)
    if est >= _HUGE_BBOX_TILE_THRESHOLD:
        print(
            f"# WARNING: derived bbox spans ~{est:,} tiles at {tile_size:g} m. "
            "This is likely the whole file's extent, not a race area. Pass an "
            "explicit --bounds to clip to the region you want."
        )


def _validate_bounds_against_header(
    ap: argparse.ArgumentParser,
    bounds: tuple[float, float, float, float],
    header: tuple[float, float, float, float],
) -> None:
    """Fatal error if requested `bounds` fall outside the .pbf header extent.

    Catches the common "wrong country / transposed lat & lon" mistake instantly
    instead of after a long clip that silently yields zero tiles.
    """
    b_min_lon, b_min_lat, b_max_lon, b_max_lat = bounds
    h_min_lon, h_min_lat, h_max_lon, h_max_lat = header
    if (
        b_min_lon < h_min_lon
        or b_max_lon > h_max_lon
        or b_min_lat < h_min_lat
        or b_max_lat > h_max_lat
    ):
        ap.error(
            "--bounds fall (partly) outside the .pbf extent — wrong file, or "
            "lon/lat transposed?\n"
            f"  requested: {b_min_lon} {b_min_lat} {b_max_lon} {b_max_lat}\n"
            f"  .pbf covers: {h_min_lon} {h_min_lat} {h_max_lon} {h_max_lat}"
        )


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(
        description="Download a Geofabrik country and bake a streamable OSM tile cache.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    ap.add_argument(
        "--country",
        help="Geofabrik path without -latest.osm.pbf, e.g. 'europe/germany'.",
    )
    ap.add_argument(
        "--pbf",
        type=Path,
        help="Use an already-downloaded .osm.pbf instead of downloading.",
    )
    ap.add_argument(
        "--bounds",
        nargs=4,
        type=float,
        metavar=("MIN_LON", "MIN_LAT", "MAX_LON", "MAX_LAT"),
        help="Bounding box to extract (degrees). If omitted, it is derived from "
             "the .pbf header bbox (the file's full extent); if given, it is "
             "validated to lie within that extent.",
    )
    ap.add_argument(
        "--tile-size",
        type=float,
        default=200.0,
        help="Tile edge length in meters (default 200; the game adopts this).",
    )
    ap.add_argument(
        "--out-dir",
        type=Path,
        default=DEFAULT_OUT_DIR,
        help="Output directory for the tile cache (default data/tiles).",
    )
    ap.add_argument(
        "--list",
        action="store_true",
        help="Print the resolved Geofabrik URL and exit (no download / bake).",
    )
    ap.add_argument(
        "--skip-checksum",
        action="store_true",
        help="Skip MD5 verification of the downloaded .pbf.",
    )
    ap.add_argument(
        "--keep-extract",
        action="store_true",
        help="Keep the intermediate clipped .osm.pbf (debugging).",
    )
    args = ap.parse_args(argv)

    if args.list:
        if not args.country:
            ap.error("--list requires --country")
        print(geofabrik_url(args.country))
        return 0

    if args.tile_size <= 0:
        ap.error("--tile-size must be positive")

    # Resolve the .pbf: reuse a local file or download the country.
    if args.pbf:
        pbf = args.pbf
        if not pbf.exists():
            ap.error(f"--pbf not found: {pbf}")
    else:
        if not args.country:
            ap.error("provide --country (to download) or --pbf (local file)")
        url = geofabrik_url(args.country)
        name = url.rsplit("/", 1)[-1]
        DEFAULT_DOWNLOAD_DIR.mkdir(parents=True, exist_ok=True)
        pbf = DEFAULT_DOWNLOAD_DIR / name
        if pbf.exists():
            print(f"# Reusing existing download {pbf}")
        else:
            _download(url, pbf)
        if not args.skip_checksum:
            _verify_md5(pbf, url)

    # Resolve the bake bounds. Explicit --bounds is validated against the PBF
    # header; omitted --bounds is derived from that header (the file's extent).
    header = pbf_header_bbox(pbf)

    if args.bounds:
        min_lon, min_lat, max_lon, max_lat = args.bounds
        if not (min_lon < max_lon and min_lat < max_lat):
            ap.error("--bounds must satisfy min_lon < max_lon and min_lat < max_lat")
        if header is not None:
            _validate_bounds_against_header(
                ap, (min_lon, min_lat, max_lon, max_lat), header
            )
        else:
            print("# WARNING: .pbf has no header bbox; cannot validate --bounds")
    else:
        if header is None:
            ap.error(
                "--bounds is required: this .pbf has no header bounding box to "
                "derive it from"
            )
        min_lon, min_lat, max_lon, max_lat = header
        print(
            "# Deriving --bounds from .pbf header: "
            f"{min_lon:.4f} {min_lat:.4f} {max_lon:.4f} {max_lat:.4f}"
        )
        _warn_if_bbox_huge(
            (min_lon, min_lat, max_lon, max_lat), args.tile_size
        )

    bake_tiles(pbf, (min_lon, min_lat, max_lon, max_lat), args.tile_size,
               args.out_dir, keep_extract=args.keep_extract)
    print("# Done. Launch the game; it will stream from data/tiles/.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
