class_name TileStreamingPipeline
extends RefCounted

## The async tile-streaming state machine, extracted from OSMTileManager.
##
## Streaming a country means parsing a per-tile .osm file (disk read + XML parse)
## every time the camera crosses a tile boundary, then turning each parsed tile
## into scene-tree geometry. Doing both inline on the main thread froze the frame.
## This pipeline owns the queues that decouple the two halves; the manager owns
## the actual scene-tree work (which must stay on the main thread) and injects it
## as callbacks. Keeping the queues here means:
##   - the manager shrinks to grid math + OSM semantics + scene building, and
##   - the streaming state machine is testable in isolation with fake callbacks
##     (no scene tree, no OSM data, no real threads).
##
## Two decoupled stages:
##   1. PARSE   each needed tile off the main thread (WorkerThreadPool), because
##              parse_tile touches no scene tree and no shared mutable cache.
##   2. INSTANCE the parsed result on the main thread, spread across frames under
##              a per-frame time budget, so a burst of tiles can't hitch a frame.
##
## The manager supplies these callbacks (all main-thread-safe from the pipeline's
## point of view — it only ever invokes them from drain()/collect on the main
## thread, never from a worker task):
##   parse_tile(tkey) -> Variant    : cold-parse a tile into a bucket (thread-safe;
##                                    invoked ON a worker task, so it must touch no
##                                    scene tree — same contract parse_tile already had)
##   instance_tile(tkey, bucket)    : build a tile's ground + enqueue its features
##   build_feature(item)            : build one queued feature into the scene tree
##   is_loaded(tkey) -> bool        : is this tile already present in the scene?
##   in_range(tkey) -> bool         : is this tile still within the keep radius?

# ─── Async streaming state ────────────────────────────────────────────────────
# A tile crossing can request several new tiles at once. Parsing each (disk read
# + XML parse) on the main thread is what froze the frame; parsing is pushed to
# WorkerThreadPool tasks and the results are instanced on the main thread under a
# per-frame time budget.
#
#   _pending_tiles   tiles a task has been dispatched for (dedupe: don't dispatch
#                    or re-dispatch the same tile while its parse is in flight).
#   _parse_tasks     tile_key -> WorkerThreadPool task id (to poll completion).
#   _ready_buckets   tile_key -> parsed bucket, awaiting main-thread instancing.
#   _instance_queue  FIFO of tile_keys with a ready bucket to drain per frame.
# `use_threads` lets headless tests force synchronous behaviour for determinism.
var _pending_tiles: Dictionary = {}
var _parse_tasks: Dictionary = {}
var _ready_buckets: Dictionary = {}
var _instance_queue: Array[Vector2i] = []

# ─── Incremental feature instancing ───────────────────────────────────────────
# Even off-thread parsing left a hard freeze: building ALL of a tile's features
# in one instance_tile call blocks the main thread 100-900 ms because each
# feature builds a mesh + material + collider, and that work can't move off-thread
# (Godot's scene tree isn't thread-safe). So a tile's ground/collider is built
# immediately (the car needs a surface), but its FEATURES are enqueued as many
# small work items drained across frames under the same budget as tile
# instancing. A dense tile then costs a few ms per frame over several frames
# instead of one long stall.
#   _feature_queue   FIFO of feature-work items awaiting a main-thread build.
var _feature_queue: Array = []

var use_threads: bool = true
## Max wall-clock time (ms) spent instancing/building per drain. Mirrors the
## manager's exported instance_budget_ms; set by the manager after construction.
var instance_budget_ms: float = 4.0

# Injected main-thread callbacks (see class doc for contracts).
var _parse_cb: Callable
var _instance_cb: Callable
var _build_feature_cb: Callable
var _is_loaded_cb: Callable
var _in_range_cb: Callable
var _record_usec_cb: Callable


## Wire the pipeline to the manager's main-thread work. Called once, right after
## construction. record_usec is optional (defaults to a no-op) so the pipeline
## can be exercised in tests without the FrameTracer.
func configure(
		parse_cb: Callable, instance_cb: Callable, build_feature_cb: Callable,
		is_loaded_cb: Callable, in_range_cb: Callable,
		record_usec_cb: Callable = Callable()) -> void:
	_parse_cb = parse_cb
	_instance_cb = instance_cb
	_build_feature_cb = build_feature_cb
	_is_loaded_cb = is_loaded_cb
	_in_range_cb = in_range_cb
	_record_usec_cb = record_usec_cb


## Kick off (or skip) loading a single tile. A tile is skipped when it is already
## loaded, already parsing in a task, or already parsed and waiting to instance.
## Otherwise its parse is dispatched to a worker thread (or run inline when
## threads are disabled), so this returns immediately without touching the scene.
func request_tile(tkey: Vector2i) -> void:
	if _is_loaded_cb.call(tkey) or _pending_tiles.has(tkey) or _ready_buckets.has(tkey):
		return
	_pending_tiles[tkey] = true
	if use_threads:
		var task_id := WorkerThreadPool.add_task(_parse_tile_task.bind(tkey))
		_parse_tasks[tkey] = task_id
	else:
		# Synchronous fallback (headless tests): parse now, instance next drain.
		_ready_buckets[tkey] = _parse_cb.call(tkey)
		_instance_queue.append(tkey)


## WorkerThreadPool task body: parse ONE tile off the main thread. Touches only
## the thread-safe parse callback (no scene tree, no shared mutable cache), then
## stashes the result for the main thread to pick up in collect_finished_parses.
func _parse_tile_task(tkey: Vector2i) -> void:
	# Time the off-thread parse and record it (record_usec is thread-safe). If
	# parses are cheap here but frames still hitch, the cost is in instancing, not
	# parsing — which tells us where to look next.
	var t0 := Time.get_ticks_usec()
	var bucket: Variant = _parse_cb.call(tkey)
	if _record_usec_cb.is_valid():
		_record_usec_cb.call("parse_tile_task", Time.get_ticks_usec() - t0)
	# Dictionary assignment keyed by a unique tile is safe here: each task writes
	# its own distinct key exactly once, and the main thread only reads a key
	# after WorkerThreadPool.is_task_completed() confirms this task finished.
	_ready_buckets[tkey] = bucket


## Main-thread: harvest every parse task that has completed since last frame,
## moving its tile onto the instance queue. Non-blocking — unfinished tasks are
## left for a later frame.
func collect_finished_parses() -> void:
	if _parse_tasks.is_empty():
		return
	var done: Array[Vector2i] = []
	for tkey: Vector2i in _parse_tasks:
		if WorkerThreadPool.is_task_completed(_parse_tasks[tkey]):
			done.append(tkey)
	for tkey: Vector2i in done:
		# Reclaim the task slot (also the documented way to observe completion).
		WorkerThreadPool.wait_for_task_completion(_parse_tasks[tkey])
		_parse_tasks.erase(tkey)
		_instance_queue.append(tkey)


## Main-thread: instance queued tiles into the scene tree until the per-frame
## time budget is spent, then spend whatever remains building queued features.
## Always makes progress on at least one tile and one feature so neither queue
## can wedge. Tiles that drifted out of range while queued are dropped.
func drain() -> void:
	if _instance_queue.is_empty() and _feature_queue.is_empty():
		return
	var deadline := Time.get_ticks_usec() + int(instance_budget_ms * 1000.0)

	# Drain ready tiles first: each pass builds a tile's ground + collider (so a
	# freshly streamed tile is drivable immediately) and enqueues its features.
	# Always take at least one tile so the queue can't wedge, but stop consuming
	# more once the budget is spent.
	var first := true
	while not _instance_queue.is_empty() and (first or Time.get_ticks_usec() < deadline):
		first = false
		var tkey: Vector2i = _instance_queue.pop_front()
		var bucket: Variant = _ready_buckets.get(tkey, {})
		_ready_buckets.erase(tkey)
		_pending_tiles.erase(tkey)
		# Skip tiles that were unloaded / drifted out of range while queued, or
		# that got instanced by a synchronous load in the meantime.
		if _is_loaded_cb.call(tkey):
			continue
		if not _in_range_cb.call(tkey):
			continue
		_instance_cb.call(tkey, bucket)  # builds ground + enqueues features

	# Then spend whatever budget remains building queued FEATURES. Always build at
	# least one so progress is guaranteed even when tiles ate the whole budget.
	first = true
	while not _feature_queue.is_empty() and (first or Time.get_ticks_usec() < deadline):
		first = false
		_build_feature_cb.call(_feature_queue.pop_front())


## Enqueue a tile's planned feature-build items for draining across frames.
func enqueue_features(items: Array) -> void:
	_feature_queue.append_array(items)


## Cancel any in-flight/queued streaming work for a tile that's about to be
## loaded synchronously, so it isn't also instanced by the async path.
func cancel_pending(tkey: Vector2i) -> void:
	_pending_tiles.erase(tkey)
	_ready_buckets.erase(tkey)
	_instance_queue.erase(tkey)


## Drop still-queued feature items for an unloaded tile so we never build onto a
## freed tile root. `should_keep` is a predicate: keep(item) -> bool.
func purge_features(should_keep: Callable) -> void:
	if _feature_queue.is_empty():
		return
	var kept: Array = []
	for item in _feature_queue:
		if should_keep.call(item):
			kept.append(item)
	_feature_queue = kept


## Block until every in-flight parse task finishes, then clear all queues. Called
## on scene exit: a running task holds a bound reference into the pipeline, so it
## must not outlive it. Bounded (each task parses one tile) and exit-only.
func shutdown() -> void:
	for tkey: Vector2i in _parse_tasks:
		WorkerThreadPool.wait_for_task_completion(_parse_tasks[tkey])
	_parse_tasks.clear()
	_pending_tiles.clear()
	_ready_buckets.clear()
	_instance_queue.clear()
	_feature_queue.clear()
