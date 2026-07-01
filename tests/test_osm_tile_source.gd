extends GdUnitTestSuite

## Unit tests for OSMTileSource and its two implementations.
##
## The tile source is the seam that lets OSMTileManager stream a country from
## disk (DiskTileSource) or load a small map whole (InMemoryTileSource) without
## the manager caring which. These tests pin the contract both sides must honor:
##
##   1. InMemoryTileSource bins features into the same tiles the old inline
##      _build_spatial_index produced (nodes by tag+position, ways by every tile
##      their nodes touch), and load_tile hands back the shared global OSMData.
##   2. DiskTileSource reads a baked manifest + per-tile .osm files, adopts the
##      manifest tile_size/center, reports has_tile only for baked tiles, and
##      returns a SELF-CONTAINED per-tile OSMData (a cross-tile way keeps every
##      node it references so builders can resolve it).
##   3. The projection + tile-key math matches osm_parser / osm_tile_manager, so
##      the Python baker and the game agree on where a feature lands.

const OSMParser := preload("res://scripts/osm_parser.gd")
const OSMTileSource := preload("res://scripts/osm_tile_source.gd")
const TrafficRoadNetwork := preload("res://scripts/traffic/traffic_road_network.gd")

var _tmp_dir := "user://_test_tiles"
var _tmp_osm := "user://_test_tilesource.osm"


func after() -> void:
	if FileAccess.file_exists(_tmp_osm):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(_tmp_osm))
	_rm_tree(_tmp_dir)


func _rm_tree(path: String) -> void:
	var dir := DirAccess.open(path)
	if dir == null:
		return
	dir.list_dir_begin()
	var name := dir.get_next()
	while name != "":
		if not dir.current_is_dir():
			DirAccess.remove_absolute(ProjectSettings.globalize_path("%s/%s" % [path, name]))
		name = dir.get_next()
	dir.list_dir_end()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


func _write(path: String, body: String) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(body)
	f.close()


# ─── InMemoryTileSource ──────────────────────────────────────────────────────

## Two nodes ~1.1 km apart on the X axis land in different 200 m tiles; the way
## joining them must appear in both tiles' buckets (it touches both).
const _SPAN_DOC := """<?xml version="1.0"?>
<osm version="0.6">
  <bounds minlat="49.00" minlon="8.00" maxlat="49.00" maxlon="8.02"/>
  <node id="1" lat="49.00" lon="8.00"/>
  <node id="2" lat="49.00" lon="8.02"/>
  <way id="10">
    <nd ref="1"/>
    <nd ref="2"/>
    <tag k="highway" v="residential"/>
  </way>
</osm>
"""


func test_in_memory_source_bins_spanning_way_into_both_tiles() -> void:
	_write(_tmp_osm, _SPAN_DOC)
	var src := OSMTileSource.InMemoryTileSource.new(_tmp_osm, 200.0)
	assert_bool(src.is_ready()).override_failure_message("source ready").is_true()

	# center_lon = 8.01, so node 1 (8.00) is west and node 2 (8.02) east: they
	# fall into distinct tiles and the way is in both.
	var tk1 := src._pos_to_tile((src._osm_data.nodes[1] as OSMParser.OSMNode).local_pos)
	var tk2 := src._pos_to_tile((src._osm_data.nodes[2] as OSMParser.OSMNode).local_pos)
	assert_bool(tk1 != tk2).override_failure_message("nodes span two tiles").is_true()

	var b1 := src.load_tile(tk1)
	var b2 := src.load_tile(tk2)
	assert_int((b1["ways"] as Array).size()).override_failure_message("way in tile 1").is_equal(1)
	assert_int((b2["ways"] as Array).size()).override_failure_message("way in tile 2").is_equal(1)


func test_in_memory_load_tile_shares_global_osm_data() -> void:
	_write(_tmp_osm, _SPAN_DOC)
	var src := OSMTileSource.InMemoryTileSource.new(_tmp_osm, 200.0)
	var tk := src._pos_to_tile((src._osm_data.nodes[1] as OSMParser.OSMNode).local_pos)
	var bucket := src.load_tile(tk)
	# The bucket's osm_data must resolve BOTH node ids, including the one whose
	# own tile is the neighbor — that's how builders draw the spanning way.
	var data: OSMParser.OSMData = bucket["osm_data"]
	assert_bool(data.nodes.has(1)).override_failure_message("node 1 resolvable").is_true()
	assert_bool(data.nodes.has(2)).override_failure_message("node 2 resolvable").is_true()


func test_in_memory_missing_tile_returns_empty() -> void:
	_write(_tmp_osm, _SPAN_DOC)
	var src := OSMTileSource.InMemoryTileSource.new(_tmp_osm, 200.0)
	assert_bool(src.has_tile(Vector2i(9999, 9999))).is_false()
	assert_bool(src.load_tile(Vector2i(9999, 9999)).is_empty()).is_true()


# ─── DiskTileSource ──────────────────────────────────────────────────────────

## Hand-bake a tiny cache: one tile file with a self-contained spanning way and
## a manifest that only lists that tile. Mirrors bake_osm_tiles.py output.
func _bake_fixture() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_tmp_dir))
	# Tile 0_0 holds a way whose two nodes both sit inside this tile.
	_write("%s/0_0.osm" % _tmp_dir, """<?xml version="1.0" encoding="UTF-8"?>
<osm version="0.6" generator="test">
  <bounds minlat="49.00" minlon="8.00" maxlat="49.02" maxlon="8.02"/>
  <node id="1" lat="49.010" lon="8.010"/>
  <node id="2" lat="49.011" lon="8.011"/>
  <way id="10">
    <nd ref="1"/>
    <nd ref="2"/>
    <tag k="highway" v="residential"/>
  </way>
</osm>
""")
	_write("%s/manifest.json" % _tmp_dir, JSON.stringify({
		"version": 1,
		"tile_size": 250.0,
		"center_lat": 49.01,
		"center_lon": 8.01,
		"meters_per_deg_lat": 111132.0,
		"bounds": {"min_lon": 8.0, "min_lat": 49.0, "max_lon": 8.02, "max_lat": 49.02},
		"tiles": [{"x": 0, "z": 0, "file": "0_0.osm"}],
	}))


func test_disk_source_adopts_manifest_tile_size_and_center() -> void:
	_bake_fixture()
	var src := OSMTileSource.DiskTileSource.new(_tmp_dir)
	assert_bool(src.is_ready()).override_failure_message("disk source ready").is_true()
	assert_float(src.get_tile_size()).override_failure_message("tile_size from manifest").is_equal_approx(250.0, 1e-6)
	assert_float(src.get_center_lat()).override_failure_message("center_lat from manifest").is_equal_approx(49.01, 1e-6)
	assert_float(src.get_center_lon()).override_failure_message("center_lon from manifest").is_equal_approx(8.01, 1e-6)


func test_disk_source_has_tile_only_for_baked_tiles() -> void:
	_bake_fixture()
	var src := OSMTileSource.DiskTileSource.new(_tmp_dir)
	assert_bool(src.has_tile(Vector2i(0, 0))).override_failure_message("baked tile present").is_true()
	assert_bool(src.has_tile(Vector2i(5, 5))).override_failure_message("unbaked tile absent").is_false()
	assert_bool(src.load_tile(Vector2i(5, 5)).is_empty()).override_failure_message("unbaked tile empty").is_true()


func test_disk_source_returns_self_contained_tile() -> void:
	_bake_fixture()
	var src := OSMTileSource.DiskTileSource.new(_tmp_dir)
	var bucket := src.load_tile(Vector2i(0, 0))
	assert_bool(bucket.is_empty()).override_failure_message("baked tile not empty").is_false()
	var data: OSMParser.OSMData = bucket["osm_data"]
	# The way and both nodes it references are present in the tile's own data.
	assert_bool(data.ways.has(10)).override_failure_message("way present").is_true()
	assert_bool(data.nodes.has(1)).override_failure_message("node 1 present").is_true()
	assert_bool(data.nodes.has(2)).override_failure_message("node 2 present").is_true()
	assert_int((bucket["ways"] as Array).size()).override_failure_message("one way surfaced").is_equal(1)


func test_disk_source_rejects_unsupported_version() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_tmp_dir))
	_write("%s/manifest.json" % _tmp_dir, JSON.stringify({
		"version": 999, "tile_size": 200.0, "center_lat": 0.0, "center_lon": 0.0,
		"tiles": [],
	}))
	var src := OSMTileSource.DiskTileSource.new(_tmp_dir)
	assert_bool(src.is_ready()).override_failure_message("stale-version cache refused").is_false()


func test_disk_source_lru_caches_parsed_tile() -> void:
	_bake_fixture()
	var src := OSMTileSource.DiskTileSource.new(_tmp_dir)
	var b1 := src.load_tile(Vector2i(0, 0))
	var b2 := src.load_tile(Vector2i(0, 0))
	# Second load must hit the cache and hand back the identical parsed object.
	assert_bool(b1["osm_data"] == b2["osm_data"]) \
		.override_failure_message("second load served from LRU cache").is_true()


# ─── Projection parity ───────────────────────────────────────────────────────

func test_tile_key_matches_manager_formula() -> void:
	# Reproduce osm_tile_manager._pos_to_tile for a known local position and make
	# sure the source's binning agrees. This is the invariant the Python baker
	# also mirrors (bake_osm_tiles.py:pos_to_tile).
	_write(_tmp_osm, _SPAN_DOC)
	var src := OSMTileSource.InMemoryTileSource.new(_tmp_osm, 200.0)
	var pos := Vector3(450.0, 0.0, -50.0)
	var expected := Vector2i(floori(450.0 / 200.0), floori(-50.0 / 200.0))
	assert_vector(src._pos_to_tile(pos)).override_failure_message("tile key formula").is_equal(expected)


# ─── Shared collect_ways_near (minimap / world consistency) ──────────────────

func test_collect_ways_near_in_memory_finds_and_dedupes_spanning_way() -> void:
	# The spanning way lives in two tiles; collect_ways_near must return it ONCE
	# with its full geometry, regardless of how many tiles it touches.
	_write(_tmp_osm, _SPAN_DOC)
	var src := OSMTileSource.InMemoryTileSource.new(_tmp_osm, 200.0)
	var found := src.collect_ways_near(Vector3.ZERO, 5000.0)
	assert_int(found.size()).override_failure_message("spanning way returned exactly once").is_equal(1)
	var entry: Dictionary = found[0]
	assert_int((entry["way"] as OSMParser.OSMWay).id).is_equal(10)
	# Both node positions resolved (self-contained), so the polyline is complete.
	assert_int((entry["points"] as PackedVector3Array).size()).override_failure_message("both endpoints resolved").is_equal(2)


func test_collect_ways_near_respects_radius() -> void:
	_write(_tmp_osm, _SPAN_DOC)
	var src := OSMTileSource.InMemoryTileSource.new(_tmp_osm, 200.0)
	# A tiny radius around a point far from the way returns nothing.
	var far := src.collect_ways_near(Vector3(100000.0, 0.0, 100000.0), 50.0)
	assert_int(far.size()).override_failure_message("no ways far from the query point").is_equal(0)


func test_collect_ways_near_disk_matches_in_memory() -> void:
	# The disk source must surface the same near-ways as the in-memory source,
	# so the streaming minimap stays consistent with the small-map minimap.
	_bake_fixture()
	var src := OSMTileSource.DiskTileSource.new(_tmp_dir)
	var found := src.collect_ways_near(Vector3.ZERO, 5000.0)
	assert_int(found.size()).override_failure_message("disk source returns the baked way").is_equal(1)
	assert_int((found[0]["way"] as OSMParser.OSMWay).id).is_equal(10)


func test_collect_ways_near_empty_before_ready() -> void:
	# A source that failed to init (bad manifest) returns [] rather than erroring.
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_tmp_dir))
	_write("%s/manifest.json" % _tmp_dir, JSON.stringify({"version": 999, "tiles": []}))
	var src := OSMTileSource.DiskTileSource.new(_tmp_dir)
	assert_int(src.collect_ways_near(Vector3.ZERO, 1000.0).size()) \
		.override_failure_message("not-ready source yields no ways").is_equal(0)


# ─── Shared collect_osm_near (traffic graph consistency) ─────────────────────

func test_collect_osm_near_returns_self_contained_ways_and_nodes() -> void:
	# Traffic builds its junction graph from ways + their nodes, so collect_osm_near
	# must return both — every node a returned way references must be present.
	_write(_tmp_osm, _SPAN_DOC)
	var src := OSMTileSource.InMemoryTileSource.new(_tmp_osm, 200.0)
	var data := src.collect_osm_near(Vector3.ZERO, 5000.0)
	assert_bool(data.ways.has(10)).override_failure_message("way collected").is_true()
	var way: OSMParser.OSMWay = data.ways[10]
	for nid: int in way.node_ids:
		assert_bool(data.nodes.has(nid)) \
			.override_failure_message("node %d resolvable in collected data" % nid).is_true()
	# Center is carried so the coordinate frame matches the world.
	assert_float(data.center_lon).is_equal_approx(8.01, 1e-6)


func test_collect_osm_near_disk_builds_drivable_network() -> void:
	# End-to-end: a disk-baked region feeds a TrafficRoadNetwork with drivable
	# roads, proving the streaming path produces a usable traffic graph.
	_bake_fixture()
	var src := OSMTileSource.DiskTileSource.new(_tmp_dir)
	var data := src.collect_osm_near(Vector3.ZERO, 5000.0)
	var net := TrafficRoadNetwork.new()
	net.build(data)
	assert_int(net.road_count()).override_failure_message("drivable roads built from streamed region").is_greater(0)


func test_collect_osm_near_empty_before_ready() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_tmp_dir))
	_write("%s/manifest.json" % _tmp_dir, JSON.stringify({"version": 999, "tiles": []}))
	var src := OSMTileSource.DiskTileSource.new(_tmp_dir)
	var data := src.collect_osm_near(Vector3.ZERO, 1000.0)
	assert_int(data.ways.size()).override_failure_message("not-ready source yields no ways").is_equal(0)
