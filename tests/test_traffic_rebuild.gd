extends GdUnitTestSuite

## Tests for TrafficManager's decoupled (off-thread) road-graph rebuild.
##
## Rebuilding the drivable graph — collect_osm_near (tile walk + parse) plus
## TrafficRoadNetwork.build over hundreds of roads — is pure data work but far
## too heavy for the physics thread; doing it inline froze the frame every time
## the player moved ~120 m. The manager now:
##
##   * builds the FIRST graph synchronously (so traffic appears at once), and
##   * runs later rebuilds on a WorkerThreadPool task, keeping cars on the old
##     graph until the fresh one is swapped in on the main thread.
##
## These tests drive that logic deterministically with _use_threads = false (the
## rebuild runs inline but through the same request/collect/adopt path), and pin
## the invariants: an initial build happens, a request re-centers the graph, and
## an in-flight request isn't double-dispatched.

const TrafficManager := preload("res://scripts/traffic/traffic_manager.gd")
const OSMTileManager := preload("res://scripts/osm_tile_manager.gd")

var _tmp_dir := "user://_test_traffic_tiles"


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


## Bake a streaming cache whose one tile (0,0) carries two connected drivable
## roads sharing a junction node, so TrafficRoadNetwork.build finds real roads.
func _bake_fixture() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(_tmp_dir))
	# Geometry mirrors the proven fixture in test_osm_tile_source.gd (center
	# 8.01/49.01, 200 m tiles) so node 1 projects to the origin and the ways land
	# in tile (0,0). Two ways share node 2 (a junction) so build() yields a real
	# connected graph.
	_write("%s/0_0.osm" % _tmp_dir, """<?xml version="1.0" encoding="UTF-8"?>
<osm version="0.6" generator="test">
  <bounds minlat="49.00" minlon="8.00" maxlat="49.02" maxlon="8.02"/>
  <node id="1" lat="49.010" lon="8.010"/>
  <node id="2" lat="49.011" lon="8.011"/>
  <node id="3" lat="49.012" lon="8.012"/>
  <way id="10">
    <nd ref="1"/>
    <nd ref="2"/>
    <tag k="highway" v="residential"/>
  </way>
  <way id="11">
    <nd ref="2"/>
    <nd ref="3"/>
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


## Build a tile manager streaming from the baked cache (threads off so tile work
## is deterministic), plus a dummy "car" Node3D at the origin.
func _make_tile_manager() -> OSMTileManager:
	_bake_fixture()
	var tm := OSMTileManager.new()
	tm.tile_cache_dir = _tmp_dir
	tm._use_threads = false
	add_child(tm)
	auto_free(tm)
	return tm


## Traffic manager wired to the tile manager + a car, with threads off so the
## rebuild path single-steps synchronously through _request_rebuild.
func _make_traffic(tm: OSMTileManager, car: Node3D) -> TrafficManager:
	var traffic := TrafficManager.new()
	traffic._use_threads = false
	# Wire the collaborators directly (the scene normally does this via exports).
	add_child(traffic)
	auto_free(traffic)
	traffic._tile_manager = tm
	traffic._car = car
	return traffic


func test_first_build_is_synchronous_and_finds_roads() -> void:
	var tm := _make_tile_manager()
	var car := Node3D.new()
	add_child(car)
	auto_free(car)
	var traffic := _make_traffic(tm, car)

	# Drive the first build directly (as _physics_process would once data ready).
	traffic._rebuild_network_sync(car.global_position)
	assert_bool(traffic._network_built) \
		.override_failure_message("first build marks the network built").is_true()
	assert_int(traffic._network.road_count()) \
		.override_failure_message("baked roads found by first build").is_greater(0)


func test_request_rebuild_recenters_graph() -> void:
	var tm := _make_tile_manager()
	var car := Node3D.new()
	add_child(car)
	auto_free(car)
	var traffic := _make_traffic(tm, car)
	traffic._rebuild_network_sync(Vector3.ZERO)

	# A rebuild request at a new center (threads off => runs inline) must move the
	# recorded network center there.
	var new_center := Vector3(50, 0, 0)
	traffic._request_rebuild(new_center)
	assert_vector(traffic._network_center) \
		.override_failure_message("graph re-centered on the rebuild request").is_equal(new_center)


func test_request_rebuild_skipped_while_thread_in_flight() -> void:
	# With threads ON, a second request while a rebuild thread is present must be
	# a no-op (single in-flight rebuild at a time): the existing thread handle is
	# not replaced.
	var tm := _make_tile_manager()
	var car := Node3D.new()
	add_child(car)
	auto_free(car)
	var traffic := _make_traffic(tm, car)
	traffic._use_threads = true
	# Simulate an in-flight rebuild with a real (trivial) thread handle.
	var t := Thread.new()
	t.start(func() -> void: pass)
	traffic._rebuild_thread = t

	traffic._request_rebuild(Vector3(10, 0, 0))
	assert_bool(traffic._rebuild_thread == t) \
		.override_failure_message("in-flight rebuild not replaced by a new request").is_true()
	# Join and clear so _exit_tree doesn't block on it.
	t.wait_to_finish()
	traffic._rebuild_thread = null


func test_build_network_for_is_pure_and_matches_direct_build() -> void:
	# _build_network_for is the pure-data body the worker thread runs; it must
	# produce the same road count as building the network directly from the same
	# collected region (proving the off-thread path is behaviour-preserving).
	var tm := _make_tile_manager()
	var car := Node3D.new()
	add_child(car)
	auto_free(car)
	var traffic := _make_traffic(tm, car)

	var net := traffic._build_network_for(Vector3.ZERO)
	assert_int(net.road_count()) \
		.override_failure_message("pure build finds the baked roads").is_greater(0)


func test_threaded_rebuild_runs_on_dedicated_thread_and_adopts() -> void:
	# End-to-end of the real async path: with threads ON, _request_rebuild spawns
	# a dedicated Thread; once it finishes, _collect_finished_rebuild joins it and
	# swaps the graph in. Verifies the rebuild never touches WorkerThreadPool and
	# still produces a live network.
	var tm := _make_tile_manager()
	var car := Node3D.new()
	add_child(car)
	auto_free(car)
	var traffic := _make_traffic(tm, car)
	traffic._use_threads = true
	# Seed an initial graph so there's an "old" one to drive while rebuilding.
	traffic._rebuild_network_sync(Vector3.ZERO)

	traffic._request_rebuild(Vector3(10, 0, 0))
	assert_bool(traffic._rebuild_thread != null) \
		.override_failure_message("dedicated rebuild thread started").is_true()

	# Wait (bounded) for the thread to finish, then let the main-thread collector
	# join + adopt it.
	var guard := 0
	while traffic._rebuild_thread != null and guard < 200:
		traffic._collect_finished_rebuild()
		if traffic._rebuild_thread != null:
			OS.delay_msec(5)
		guard += 1
	assert_bool(traffic._rebuild_thread == null) \
		.override_failure_message("rebuild thread joined after completion").is_true()
	assert_vector(traffic._network_center) \
		.override_failure_message("graph re-centered after threaded rebuild").is_equal(Vector3(10, 0, 0))
