#!/usr/bin/env python3
# /// script
# requires-python = ">=3.9"
# dependencies = ["pytest"]
# ///
"""Unit tests for tools/bake_osm_tiles.py.

These cover the parts that must stay byte-for-byte consistent with the game and
that carry the real risk of silent breakage:

  1. Projection + tile-key math == the GDScript (osm_parser / osm_tile_manager).
  2. TileAssembler assignment + self-containment closure (a way spanning two
     tiles appears in both AND drags its nodes into each tile file).
  3. Geofabrik URL resolution tolerates the various suffixes users paste.
  4. Emitted per-tile .osm is valid OSM 0.6 XML the game's parser contract reads.

Run with:  uv run tools/test_bake_osm_tiles.py
(pytest is declared inline; the osmium dependency is NOT needed here because we
test the osmium-free TileAssembler directly.)
"""

from __future__ import annotations

import argparse
import importlib.util
import math
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

import pytest

_SPEC = importlib.util.spec_from_file_location(
    "bake_osm_tiles", Path(__file__).with_name("bake_osm_tiles.py")
)
bake = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(bake)


# ─── Projection / tile-key parity ────────────────────────────────────────────

def test_latlon_to_local_matches_gdscript_formula():
    ref_lat, ref_lon = 49.01, 8.01
    lat, lon = 49.015, 8.018
    x, z = bake.latlon_to_local(lat, lon, ref_lat, ref_lon)
    m_lon = 111132.0 * math.cos(math.radians(ref_lat))
    assert x == (lon - ref_lon) * m_lon
    assert z == -(lat - ref_lat) * 111132.0


def test_center_projects_to_origin():
    x, z = bake.latlon_to_local(49.01, 8.01, 49.01, 8.01)
    assert abs(x) < 1e-9 and abs(z) < 1e-9


def test_pos_to_tile_uses_floor():
    assert bake.pos_to_tile(450.0, -50.0, 200.0) == (2, -1)
    assert bake.pos_to_tile(0.0, 0.0, 200.0) == (0, 0)
    assert bake.pos_to_tile(-1.0, -1.0, 200.0) == (-1, -1)


# ─── Geofabrik URL resolution ────────────────────────────────────────────────

def test_geofabrik_url_bare_country():
    assert (
        bake.geofabrik_url("europe/germany")
        == "https://download.geofabrik.de/europe/germany-latest.osm.pbf"
    )


def test_geofabrik_url_tolerates_suffix_and_slashes():
    for arg in (
        "europe/germany-latest.osm.pbf",
        "/europe/germany.osm.pbf",
        "europe/germany.pbf",
    ):
        assert (
            bake.geofabrik_url(arg)
            == "https://download.geofabrik.de/europe/germany-latest.osm.pbf"
        )


# ─── TileAssembler assignment + closure ──────────────────────────────────────

def _bbox():
    # center = (8.01, 49.01); ~1.5 km wide east-west.
    return (8.00, 49.00, 8.02, 49.02)


def test_way_spanning_two_tiles_is_in_both_and_self_contained():
    asm = bake.TileAssembler(_bbox(), tile_size=200.0)
    # Node A far west, node B far east: >200 m apart => different tiles.
    asm.add_node(1, 49.01, 8.001, {})
    asm.add_node(2, 49.01, 8.019, {})
    asm.add_way(10, [1, 2], {"highway": "residential"})
    asm.finalize_standalone_nodes()

    t1 = asm.node_tile[1]
    t2 = asm.node_tile[2]
    assert t1 != t2, "test setup: nodes must fall in different tiles"
    assert 10 in asm.tile_ways[t1]
    assert 10 in asm.tile_ways[t2]

    # Each tile's closure must include BOTH nodes so the file stands alone.
    for tkey in (t1, t2):
        node_ids, way_ids, _ = asm.closure_for_tile(tkey)
        assert way_ids == {10}
        assert {1, 2} <= node_ids


def test_nodes_outside_bbox_are_dropped():
    asm = bake.TileAssembler(_bbox(), tile_size=200.0)
    asm.add_node(1, 49.01, 8.01, {})     # inside
    asm.add_node(2, 60.00, 20.00, {})    # far outside
    assert 1 in asm.nodes
    assert 2 not in asm.nodes


def test_boundary_crossing_way_backfills_missing_node():
    # A way with one node inside the bbox and one just outside: the way is kept
    # (it touches the region) but its outside node is initially unknown. The
    # backfill pass must be told to fetch it so the tile is self-contained.
    asm = bake.TileAssembler(_bbox(), tile_size=200.0)
    asm.add_node(1, 49.01, 8.01, {})          # inside
    asm.add_way(10, [1, 2], {"highway": "residential"})  # node 2 is outside
    needed = asm.needed_missing_node_ids()
    assert needed == {2}, "the out-of-bbox node must be flagged for backfill"

    # Simulate the supplemental pass fetching node 2's coords.
    asm.add_supplemental_node(2, 49.01, 8.10)
    asm.finalize_standalone_nodes()

    # Now every tile the way belongs to resolves BOTH nodes.
    for tkey in asm.tile_keys():
        node_ids, way_ids, _ = asm.closure_for_tile(tkey)
        if 10 in way_ids:
            assert {1, 2} <= node_ids, "boundary-crossing way is self-contained"


def test_supplemental_node_is_not_standalone_content():
    # A back-filled boundary node must not surface as a standalone tagged node.
    asm = bake.TileAssembler(_bbox(), tile_size=200.0)
    asm.add_node(1, 49.01, 8.01, {})
    asm.add_way(10, [1, 2], {"highway": "residential"})
    asm.add_supplemental_node(2, 49.01, 8.10)
    asm.finalize_standalone_nodes()
    for tile in asm.tile_nodes.values():
        assert 2 not in tile


def test_tagged_node_occupies_its_own_tile():
    asm = bake.TileAssembler(_bbox(), tile_size=200.0)
    asm.add_node(1, 49.01, 8.01, {"highway": "traffic_signals"})
    asm.add_node(2, 49.01, 8.01, {})  # untagged: not a standalone feature
    asm.finalize_standalone_nodes()
    tkey = asm.node_tile[1]
    assert 1 in asm.tile_nodes[tkey]
    assert 2 not in asm.tile_nodes.get(tkey, set())


def test_relation_pulls_member_way_and_nodes_into_tile(tmp_path):
    asm = bake.TileAssembler(_bbox(), tile_size=200.0)
    asm.add_node(1, 49.010, 8.010, {})
    asm.add_node(2, 49.011, 8.011, {})
    asm.add_node(3, 49.010, 8.011, {})
    asm.add_way(10, [1, 2, 3, 1], {})  # bare ring, semantics from relation
    asm.add_relation(
        100,
        [{"type": "way", "ref": 10, "role": "outer"}],
        {"type": "multipolygon", "building": "yes"},
    )
    asm.finalize_standalone_nodes()

    tkey = next(iter(asm.tile_rels))
    node_ids, way_ids, rel_ids = asm.closure_for_tile(tkey)
    assert 100 in rel_ids
    assert 10 in way_ids
    assert {1, 2, 3} <= node_ids


# ─── Header-bbox derivation / validation ─────────────────────────────────────

def test_validate_bounds_within_header_passes():
    ap = argparse.ArgumentParser()
    header = (8.00, 49.00, 8.02, 49.02)
    # A sub-box strictly inside the header must not raise.
    bake._validate_bounds_against_header(ap, (8.005, 49.005, 8.015, 49.015), header)


def test_validate_bounds_outside_header_errors():
    ap = argparse.ArgumentParser()
    header = (8.00, 49.00, 8.02, 49.02)
    # Requested box pokes east of the header extent => fatal.
    with pytest.raises(SystemExit):
        bake._validate_bounds_against_header(ap, (8.00, 49.00, 9.00, 49.02), header)


def test_validate_bounds_transposed_lonlat_errors():
    # A common foot-gun: user passes lat/lon in the wrong order. Those values
    # land far outside the real extent, so validation must reject them.
    ap = argparse.ArgumentParser()
    header = (8.00, 49.00, 8.02, 49.02)
    with pytest.raises(SystemExit):
        bake._validate_bounds_against_header(ap, (49.00, 8.00, 49.02, 8.02), header)


def test_bbox_tile_estimate_scales_with_size():
    bounds = (8.00, 49.00, 8.02, 49.02)
    small = bake._bbox_tile_estimate(bounds, 100.0)
    large = bake._bbox_tile_estimate(bounds, 400.0)
    assert small > large > 0
    # Halving the tile edge roughly quadruples the grid count (2x cols * 2x rows).
    assert bake._bbox_tile_estimate(bounds, 100.0) > \
        3 * bake._bbox_tile_estimate(bounds, 200.0)


def test_bbox_tile_estimate_flags_country_scale(capsys):
    # A ~degree-wide bbox at 200 m must trip the huge-bbox warning.
    bake._warn_if_bbox_huge((8.0, 49.0, 10.0, 51.0), 200.0)
    out = capsys.readouterr().out
    assert "WARNING" in out and "tiles" in out


def test_small_bbox_does_not_warn(capsys):
    bake._warn_if_bbox_huge((8.00, 49.00, 8.02, 49.02), 200.0)
    assert capsys.readouterr().out == ""


# ─── Emitted XML validity ────────────────────────────────────────────────────

def test_write_tiles_emits_parseable_osm(tmp_path):
    asm = bake.TileAssembler(_bbox(), tile_size=200.0)
    asm.add_node(1, 49.010, 8.010, {"amenity": "cafe & bar"})  # escaping check
    asm.add_node(2, 49.011, 8.011, {})
    asm.add_way(10, [1, 2], {"highway": "residential", "name": "A<B"})
    asm.finalize_standalone_nodes()

    manifest = asm.write_tiles(tmp_path)
    assert manifest["version"] == bake.MANIFEST_VERSION
    assert manifest["tile_size"] == 200.0
    assert manifest["tiles"], "at least one tile written"

    # Every listed tile file must be valid XML with the expected structure.
    for entry in manifest["tiles"]:
        tree = ET.parse(tmp_path / entry["file"])
        root = tree.getroot()
        assert root.tag == "osm"
        assert root.find("bounds") is not None
        # XML entities must have round-tripped (escaping worked).
        for tag in root.iter("tag"):
            assert "&" not in tag.get("k", "") or ";" in tag.get("k", "")

    # manifest.json is written and lists the tile.
    assert (tmp_path / "manifest.json").exists()


def test_write_tiles_clears_stale_tiles(tmp_path):
    stale = tmp_path / "99_99.osm"
    tmp_path.mkdir(exist_ok=True)
    stale.write_text("<osm/>")
    asm = bake.TileAssembler(_bbox(), tile_size=200.0)
    asm.add_node(1, 49.010, 8.010, {"amenity": "cafe"})
    asm.finalize_standalone_nodes()
    asm.write_tiles(tmp_path)
    assert not stale.exists(), "stale tile from a previous bake must be removed"


# ─── osmium CLI requirement ──────────────────────────────────────────────────

def test_extract_bbox_errors_clearly_without_osmium(tmp_path, monkeypatch):
    # The country clip shells out to the `osmium` CLI; if it's missing the tool
    # must fail with an actionable install hint rather than a confusing traceback.
    monkeypatch.setattr(bake.shutil, "which", lambda _name: None)
    with pytest.raises(SystemExit) as exc:
        bake.extract_bbox(tmp_path / "in.osm.pbf", _bbox(), tmp_path / "out.osm.pbf")
    msg = str(exc.value)
    assert "osmium" in msg
    assert "install" in msg.lower()


if __name__ == "__main__":
    import pytest

    sys.exit(pytest.main([__file__, "-v"]))
