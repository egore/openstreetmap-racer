extends GdUnitTestSuite

## Unit tests for TileStreamingPipeline in ISOLATION.
##
## The pipeline was extracted from OSMTileManager so the async streaming state
## machine (parse queue -> instance queue -> feature queue) could be tested
## without a scene tree, without OSM data, and without real threads. Here it is
## driven purely through injected fake callbacks: the manager's scene-tree work
## is replaced by lambdas that record what happened, so each queue transition can
## be asserted directly.
##
## Threads are disabled (use_threads = false) so request -> parse -> queue is
## synchronous and single-stepped. The manager-level pipeline behaviour is
## covered end-to-end in test_tile_streaming.gd; this suite pins the pipeline's
## own contract (dedupe, budget/progress, range-drop, purge, callback ordering).

const TileStreamingPipeline := preload("res://scripts/tile_streaming_pipeline.gd")

# ─── Fake manager state driven by the injected callbacks ──────────────────────
var _loaded: Dictionary          # tile_key -> true, mimics manager._loaded_tiles
var _range_ok: bool              # what the in_range callback returns
var _parsed: Array               # tile_keys the parse callback was asked to parse
var _instanced: Array            # tile_keys the instance callback built
var _built_features: Array       # feature items the build callback built


func before_test() -> void:
	_loaded = {}
	_range_ok = true
	_parsed = []
	_instanced = []
	_built_features = []


## A pipeline wired to the fakes above. instance_tile marks the tile "loaded"
## (as the real manager does the moment a tile's ground exists) so dedupe and
## drain-skip logic behaves like production.
func _make_pipeline() -> TileStreamingPipeline:
	var p := TileStreamingPipeline.new()
	p.use_threads = false
	p.instance_budget_ms = 1000.0
	p.configure(
		func(tkey: Vector2i) -> Variant:
			_parsed.append(tkey)
			return {"tile": tkey},                       # opaque fake bucket
		func(tkey: Vector2i, _bucket: Variant) -> void:
			_instanced.append(tkey)
			_loaded[tkey] = true,                         # tile is now present
		func(item: Variant) -> void:
			_built_features.append(item),
		func(tkey: Vector2i) -> bool: return _loaded.has(tkey),
		func(_tkey: Vector2i) -> bool: return _range_ok)
	return p


func test_request_parses_but_does_not_instance() -> void:
	# Requesting queues a parse (synchronous here) but must not instance yet:
	# instancing is the main-thread drain's job.
	var p := _make_pipeline()
	p.request_tile(Vector2i(0, 0))
	assert_array(_parsed).contains([Vector2i(0, 0)])
	assert_array(_instanced).is_empty()
	assert_bool(p._pending_tiles.has(Vector2i(0, 0))).is_true()


func test_drain_instances_requested_tile() -> void:
	var p := _make_pipeline()
	p.request_tile(Vector2i(1, 2))
	p.drain()
	assert_array(_instanced).contains([Vector2i(1, 2)])
	assert_bool(p._pending_tiles.has(Vector2i(1, 2))).is_false()


func test_request_is_idempotent_while_pending() -> void:
	# A second request for a still-pending tile must not re-parse or double-queue.
	var p := _make_pipeline()
	p.request_tile(Vector2i(0, 0))
	p.request_tile(Vector2i(0, 0))
	assert_int(_parsed.size()).is_equal(1)
	assert_int(p._instance_queue.size()).is_equal(1)


func test_request_skips_already_loaded_tile() -> void:
	var p := _make_pipeline()
	_loaded[Vector2i(3, 3)] = true
	p.request_tile(Vector2i(3, 3))
	assert_array(_parsed).is_empty()
	assert_bool(p._pending_tiles.has(Vector2i(3, 3))).is_false()


func test_drain_drops_out_of_range_tile() -> void:
	# A tile parsed while near, then left behind, is dropped on drain (not built).
	var p := _make_pipeline()
	p.request_tile(Vector2i(0, 0))
	_range_ok = false                 # camera moved away
	p.drain()
	assert_array(_instanced).is_empty()


func test_drain_makes_progress_on_zero_budget() -> void:
	# The "always take at least one" rule: even with no budget, one tile is
	# instanced per drain so the queue can never wedge.
	var p := _make_pipeline()
	p.instance_budget_ms = 0.0
	p.request_tile(Vector2i(0, 0))
	p.request_tile(Vector2i(1, 0))
	p.drain()
	assert_int(_instanced.size()).is_equal(1)   # exactly one, budget spent
	p.drain()
	assert_int(_instanced.size()).is_equal(2)   # the rest follows next frame


func test_enqueued_features_drain_to_empty() -> void:
	var p := _make_pipeline()
	p.enqueue_features(["a", "b", "c"])
	p.drain()
	assert_array(_built_features).contains(["a", "b", "c"])
	assert_int(p._feature_queue.size()).is_equal(0)


func test_zero_budget_still_builds_one_feature() -> void:
	var p := _make_pipeline()
	p.instance_budget_ms = 0.0
	p.enqueue_features(["a", "b", "c"])
	p.drain()
	assert_int(_built_features.size()).is_equal(1)
	assert_int(p._feature_queue.size()).is_equal(2)


func test_purge_features_removes_matching() -> void:
	# purge_features keeps only items the predicate approves; here, drop "x".
	var p := _make_pipeline()
	p.enqueue_features(["keep1", "x", "keep2", "x"])
	p.purge_features(func(item: Variant) -> bool: return item != "x")
	assert_int(p._feature_queue.size()).is_equal(2)
	assert_array(p._feature_queue).contains(["keep1", "keep2"])


func test_cancel_pending_clears_all_traces_of_tile() -> void:
	# Used by the synchronous spawn path so an async request can't double-instance.
	var p := _make_pipeline()
	p.request_tile(Vector2i(5, 5))
	p.cancel_pending(Vector2i(5, 5))
	assert_bool(p._pending_tiles.has(Vector2i(5, 5))).is_false()
	assert_bool(p._instance_queue.has(Vector2i(5, 5))).is_false()


func test_tiles_drain_before_features() -> void:
	# Ordering contract: a drain builds ready tiles first (so a streamed tile is
	# drivable immediately), then spends the rest of the budget on features.
	var order: Array = []
	var p := TileStreamingPipeline.new()
	p.use_threads = false
	p.instance_budget_ms = 1000.0
	p.configure(
		func(tkey: Vector2i) -> Variant: return {"tile": tkey},
		func(tkey: Vector2i, _b: Variant) -> void:
			order.append("tile"),
		func(_item: Variant) -> void:
			order.append("feature"),
		func(_tkey: Vector2i) -> bool: return false,
		func(_tkey: Vector2i) -> bool: return true)
	p.request_tile(Vector2i(0, 0))
	p.enqueue_features(["f1"])
	p.drain()
	assert_array(order).is_equal(["tile", "feature"])
