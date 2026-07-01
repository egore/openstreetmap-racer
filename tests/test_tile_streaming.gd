extends GdUnitTestSuite

## Tests for OSMTileManager's decoupled (async) tile streaming.
##
## Streaming a country means parsing a per-tile .osm file (disk read + XML parse)
## every time the camera crosses a tile boundary. Doing that inline on the main
## thread froze the frame and spammed the console. The manager now:
##
##   1. dispatches each needed tile's PARSE to a WorkerThreadPool task
##      (thread-safe: parse_tile touches no scene tree, no shared LRU),
##   2. INSTANCES the parsed result on the main thread, spread across frames
##      under a per-frame time budget.
##
## These tests pin that split without relying on real threads (they set
## _use_threads = false for deterministic, single-stepped behaviour) and verify
## the synchronous spawn path (ensure_tiles_around) still instances immediately.

const OSMTileManager := preload("res://scripts/osm_tile_manager.gd")

var _tmp_dir := "user://_test_stream_tiles"


func after() -> void:
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


## Bake a small streaming cache with one non-empty tile (0,0) carrying a road.
## No DEM, so the world stays flat and instancing builds a flat ground collider.
func _bake_fixture() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_tmp_dir))
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
		"tile_size": 200.0,
		"center_lat": 49.01,
		"center_lon": 8.01,
		"meters_per_deg_lat": 111132.0,
		"bounds": {"min_lon": 8.0, "min_lat": 49.0, "max_lon": 8.02, "max_lat": 49.02},
		"tiles": [{"x": 0, "z": 0, "file": "0_0.osm"}],
	}))


## Build a manager streaming from the baked fixture, with threads disabled so the
## request -> parse -> queue -> instance pipeline single-steps deterministically.
func _make_manager() -> OSMTileManager:
	_bake_fixture()
	var mgr := OSMTileManager.new()
	mgr.tile_cache_dir = _tmp_dir
	mgr.load_radius = 1
	mgr.unload_radius = 2
	mgr._use_threads = false
	add_child(mgr)          # triggers _ready -> _load_osm_data
	auto_free(mgr)
	return mgr


func test_manager_streams_from_baked_cache() -> void:
	var mgr := _make_manager()
	assert_bool(mgr.is_data_ready()).override_failure_message("disk cache loaded").is_true()


func test_request_tile_does_not_instance_immediately() -> void:
	# The core of the decouple: asking for a tile must NOT build it on the spot.
	# It's queued for parsing; the scene tree stays untouched this call.
	var mgr := _make_manager()
	mgr._current_tile = Vector2i(0, 0)
	mgr._request_tile(Vector2i(0, 0))
	assert_int(mgr.get_loaded_tile_count()) \
		.override_failure_message("no tile instanced by request alone").is_equal(0)
	# It is, however, now pending (queued to parse).
	assert_bool(mgr._pending_tiles.has(Vector2i(0, 0))) \
		.override_failure_message("requested tile is pending").is_true()


func test_drain_instances_parsed_tile() -> void:
	# After a request + parse-collect, draining the queue instances the tile.
	var mgr := _make_manager()
	mgr._current_tile = Vector2i(0, 0)
	mgr._request_tile(Vector2i(0, 0))      # _use_threads=false parses inline
	mgr._drain_instance_queue()
	assert_int(mgr.get_loaded_tile_count()) \
		.override_failure_message("drained tile instanced").is_greater(0)
	assert_bool(mgr._pending_tiles.has(Vector2i(0, 0))) \
		.override_failure_message("instanced tile no longer pending").is_false()


func test_request_is_idempotent_while_pending() -> void:
	# Re-requesting a tile that's already pending must not double-queue it.
	var mgr := _make_manager()
	mgr._current_tile = Vector2i(0, 0)
	mgr._request_tile(Vector2i(0, 0))
	var q1 := mgr._instance_queue.size()
	mgr._request_tile(Vector2i(0, 0))
	assert_int(mgr._instance_queue.size()) \
		.override_failure_message("second request did not re-queue").is_equal(q1)


func test_drain_skips_tile_that_drifted_out_of_range() -> void:
	# A tile queued while near, then left behind (camera moved far), must be
	# dropped on drain rather than instanced into a region we no longer stream.
	var mgr := _make_manager()
	mgr._current_tile = Vector2i(0, 0)
	mgr._request_tile(Vector2i(0, 0))      # parsed + queued
	mgr._current_tile = Vector2i(100, 100) # camera teleported away
	mgr._drain_instance_queue()
	assert_int(mgr.get_loaded_tile_count()) \
		.override_failure_message("out-of-range tile dropped, not instanced").is_equal(0)


func test_ensure_tiles_around_instances_synchronously() -> void:
	# Spawn safety: ensure_tiles_around must instance a collider THIS call, not
	# defer it to a later frame's drain (or the car falls through the world).
	var mgr := _make_manager()
	mgr.ensure_tiles_around(Vector3.ZERO)
	assert_int(mgr.get_loaded_tile_count()) \
		.override_failure_message("spawn tiles instanced synchronously").is_greater(0)


func test_empty_tiles_get_ground_placeholder() -> void:
	# A tile with no baked file is still instanced as an empty ground placeholder
	# (so there's a surface to drive on), synchronously via _load_tile.
	var mgr := _make_manager()
	mgr._current_tile = Vector2i(0, 0)
	mgr._load_tile(Vector2i(50, 50))   # no file baked here
	assert_bool(mgr._loaded_tiles.has(Vector2i(50, 50))) \
		.override_failure_message("empty tile still instanced as placeholder").is_true()


# ─── Incremental feature instancing ──────────────────────────────────────────

func test_streamed_tile_defers_features_to_queue() -> void:
	# A streamed tile becomes drivable immediately (marked loaded, ground built)
	# but its FEATURES are enqueued rather than built inline — that's what turns a
	# 100-900 ms freeze into a few ms/frame. With a zero budget, one drain builds
	# the tile + at most one feature (the "always make progress" rule), leaving the
	# rest queued for later frames.
	var mgr := _make_manager()
	mgr._current_tile = Vector2i(0, 0)
	mgr.instance_budget_ms = 0.0   # force features to spill across frames
	mgr._request_tile(Vector2i(0, 0))
	mgr._drain_instance_queue()
	assert_bool(mgr._loaded_tiles.has(Vector2i(0, 0))) \
		.override_failure_message("tile drivable (loaded) right away").is_true()
	assert_int(mgr._feature_queue.size()) \
		.override_failure_message("features deferred across frames under budget").is_greater(0)


func test_feature_queue_drains_to_empty_over_drains() -> void:
	# Repeated drains eventually build every queued feature (the queue empties).
	var mgr := _make_manager()
	mgr._current_tile = Vector2i(0, 0)
	mgr._request_tile(Vector2i(0, 0))
	# Generous budget so a couple of drains clear the small fixture's features.
	mgr.instance_budget_ms = 1000.0
	mgr._drain_instance_queue()
	# Drain again until the feature queue is empty (bounded loop for safety).
	var guard := 0
	while not mgr._feature_queue.is_empty() and guard < 50:
		mgr._drain_instance_queue()
		guard += 1
	assert_int(mgr._feature_queue.size()) \
		.override_failure_message("all queued features eventually built").is_equal(0)


func test_unload_purges_queued_features() -> void:
	# Unloading a tile must drop its still-queued feature items so we never build
	# onto a freed tile root.
	var mgr := _make_manager()
	mgr._current_tile = Vector2i(0, 0)
	mgr.instance_budget_ms = 0.0         # leave features on the queue
	mgr._request_tile(Vector2i(0, 0))
	mgr._drain_instance_queue()          # tile loaded, features queued
	assert_int(mgr._feature_queue.size()).is_greater(0)
	mgr._unload_tile(Vector2i(0, 0))
	var remaining := 0
	for item: OSMTileManager.FeatureWork in mgr._feature_queue:
		if item.tile_key == Vector2i(0, 0):
			remaining += 1
	assert_int(remaining) \
		.override_failure_message("unloaded tile's queued features purged").is_equal(0)


func test_synchronous_load_builds_features_inline() -> void:
	# The spawn path (_load_tile, defer=false) must build features immediately —
	# NOT defer them — so a spawned-into tile is fully present at once and nothing
	# is left on the feature queue for it.
	var mgr := _make_manager()
	mgr._current_tile = Vector2i(0, 0)
	mgr._load_tile(Vector2i(0, 0))
	assert_bool(mgr._loaded_tiles.has(Vector2i(0, 0))) \
		.override_failure_message("sync-loaded tile present").is_true()
	var queued_for_tile := 0
	for item: OSMTileManager.FeatureWork in mgr._feature_queue:
		if item.tile_key == Vector2i(0, 0):
			queued_for_tile += 1
	assert_int(queued_for_tile) \
		.override_failure_message("sync load did not defer features").is_equal(0)
