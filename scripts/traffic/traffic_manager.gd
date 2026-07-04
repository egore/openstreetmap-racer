class_name TrafficManager
extends Node3D

## Spawns and manages a population of AI traffic cars around the player.
##
## Design goals (from the feature request):
##   * Cars drive along the OSM roads, flowing from one road onto a connected one
##     at shared junctions (a road *graph*, not isolated segments) so they don't
##     teleport between disjoint ways. A car that reaches the end of its road is
##     continued onto a road attached to that junction, keeping its speed.
##   * They don't need to be globally persistent — just consistently *present*
##     within a radius of the player. Cars are pooled; one that drifts out of
##     range, or hits a genuine dead end, is recycled onto a fresh nearby road.
##   * Cars in view get full physics (solid obstacles the player can hit); cars
##     out of view fall back to cheap kinematic motion to stay performant.
##   * The larger the street, the more cars — width-scaled capacity, decided by
##     TrafficRoadNetwork / TrafficSpawnPolicy.
##
## Composition: the scene wires `car_path` (the player) so the manager knows the
## center to keep traffic around, and it reads the OSM data from the tile manager
## via `tile_manager_path`. It builds the road network once the data is ready.

## How far from the player, in meters, to keep traffic populated. Roughly matches
## a couple of tile radii so cars exist a little beyond view and stream naturally.
@export var active_radius: float = 260.0
## Cars beyond this (a bit past active_radius, for hysteresis) are recycled onto a
## nearer road so the population follows the player without thrashing.
@export var recycle_radius: float = 340.0
## Hard cap on live AI cars. The single biggest performance lever; the spawn
## policy fills big roads first up to this budget.
@export var max_cars: int = 40
## Seconds between population refreshes (which roads are active, spawn/recycle).
## The per-frame driving still runs every physics frame; only the bookkeeping is
## throttled.
@export var refresh_interval: float = 0.75
## Distance (m) from the camera within which a car is treated as "in view" and
## upgraded to full physics. Slightly generous so cars are solid just before they
## enter the frustum.
@export var detail_distance: float = 90.0

## The player car (traffic centers on it, and it's excluded from detail checks).
@export var car_path: NodePath
## The tile manager to pull parsed OSM data from.
@export var tile_manager_path: NodePath

## How far the player must move from the last network-build center before the
## drivable graph is rebuilt around the new position. Keeps the graph following
## the player when streaming a country (where the whole map is never resident)
## without rebuilding every frame. Zero-cost on the single-file path too.
##
## Tuned against build_radius (~600 m): a larger threshold means successive
## rebuild regions overlap less, but every overlapping tile is now served from
## the shared parse cache, so a rebuild only pays for the NEW ring of tiles. At
## 200 m the recycle radius (340 m) still comfortably covers the gap travelled
## between rebuilds, so cars never reach an ungraphed edge. Rebuilds also run
## off-thread, so this only controls how often — not whether it stalls a frame.
const _NETWORK_REBUILD_THRESHOLD := 200.0

## Packed scene for a single traffic car (the stub block).
const TRAFFIC_CAR_SCENE := preload("res://scenes/traffic_car.tscn")

# Preloaded so the tracer resolves regardless of global class_name cache order
# (headless test discovery can race class_name registration — same reason the
# tile manager preloads its collaborators).
const FrameTracerScript := preload("res://scripts/frame_tracer.gd")

## Per-car cruise speed range (m/s) so traffic isn't lock-step. ~18–40 km/h.
const _SPEED_MIN := 5.0
const _SPEED_MAX := 11.0

var _network := TrafficRoadNetwork.new()
var _car: Node3D = null
var _tile_manager: OSMTileManager = null

# ─── Async graph rebuild state ────────────────────────────────────────────────
# Rebuilding the drivable graph (collect_osm_near + TrafficRoadNetwork.build over
# hundreds of roads) is pure data work but far too heavy for the physics thread —
# doing it inline froze the frame every ~120 m travelled. Cars keep driving the
# CURRENT graph until the fresh one is ready, then it's swapped in on the main
# thread.
#
# It runs on a DEDICATED Thread, not WorkerThreadPool. A fresh region's collect
# cold-parses ~64 tile files serially (~870 ms); on the shared pool that one long
# task saturated the workers the engine + tile streaming also use, and the frame
# hitched even though the traffic work itself was off-thread. A private Thread
# never competes with that pool, so the rebuild is truly invisible.
#
#   _rebuild_thread    the running Thread, or null when idle.
#   _rebuild_center    center the in-flight rebuild is building around.
#   _pending_network   result the thread produced, awaiting main-thread swap-in.
#   _rebuild_done      set true by the thread when finished (guarded by mutex).
# `_use_threads` lets headless tests force synchronous rebuilds for determinism.
var _rebuild_thread: Thread = null
var _rebuild_center: Vector3 = Vector3.ZERO
var _pending_network: TrafficRoadNetwork = null
var _rebuild_done: bool = false
var _rebuild_mutex := Mutex.new()
var _use_threads: bool = true
## Live traffic cars (both LODs). Recycled in place rather than freed.
var _cars: Array[TrafficCar] = []
var _refresh_accum: float = 0.0
## Deterministic-ish RNG for speeds and spawn offsets; seeded once so behavior is
## reproducible within a run.
var _rng := RandomNumberGenerator.new()
## Per-car rolling route plan: car instance id -> Array[Continuation] still to
## drive. This is the car's *long-term intention* — a few segments planned ahead
## via TrafficRoadNetwork.plan_route so it commits to a path through junctions
## instead of re-deciding at every corner (which read as aimless wiggling). The
## queue is consumed one continuation per junction and refilled when it empties.
var _routes: Dictionary = {}

## How many segments to plan ahead for each car. Long enough that a car reads as
## "heading somewhere" through a couple of intersections, short enough that
## re-planning is cheap and traffic still spreads out over the network.
const _PLAN_AHEAD := 6

## World position the current road graph was built around, and whether a graph
## has been built at all. Used to decide when to rebuild as the player drives.
var _network_center: Vector3 = Vector3.ZERO
var _network_built: bool = false


func _ready() -> void:
	_rng.randomize()
	# Freeze all traffic bookkeeping (spawning, junction hand-offs) with the scene
	# pause. Main runs PROCESS_MODE_ALWAYS so Escape works; this node must opt back
	# into pausing or it would keep driving traffic while the menu is up.
	process_mode = Node.PROCESS_MODE_PAUSABLE
	_car = get_node_or_null(car_path) as Node3D
	_tile_manager = get_node_or_null(tile_manager_path) as OSMTileManager
	if _tile_manager == null:
		push_warning("TrafficManager: no tile manager wired; traffic disabled")
		return
	# Build the graph around the player as soon as the tile source is ready;
	# otherwise wait for the signal (mirrors how main.gd handles spawn timing).
	# The network is built from the region around the car (not the whole map) so
	# a streamed country works — see _rebuild_network_around.
	if _tile_manager.is_data_ready():
		_on_data_loaded(null)
	else:
		_tile_manager.data_loaded.connect(_on_data_loaded)


## Join an in-flight rebuild thread before this node is torn down. The thread
## body calls back into this instance; freeing the node while it ran would call
## into a freed object. wait_to_finish blocks until the build completes (bounded:
## one region build) and only happens on scene exit. A Thread that was started
## MUST be joined or Godot errors on shutdown.
func _exit_tree() -> void:
	if _rebuild_thread != null:
		_rebuild_thread.wait_to_finish()
		_rebuild_thread = null
	_pending_network = null


func _on_data_loaded(_osm_data: OSMParser.OSMData) -> void:
	# Build the initial graph around wherever the car currently is. If the car
	# isn't wired yet, defer to the first _physics_process, which will build once
	# a center is available. The FIRST build is synchronous so traffic appears
	# promptly; later rebuilds (as the player drives) run off-thread.
	if _car != null:
		_rebuild_network_sync(_car.global_position)
		_refresh_population()


## Radius the drivable graph is built over. Reaches past recycle_radius so
## continuations near the edge still connect and the plan-ahead has room to
## resolve; clamped to a sane floor.
##
## Sized to recycle_radius + one tile: any car within recycle range, plus the
## tile it might flow into before the next rebuild, is graphed — so no car reaches
## an ungraphed edge. This is deliberately TIGHTER than the old
## recycle+active (~600 m) because the collect parses one tile file per grid cell;
## 540 m over 200 m tiles is ~49 cells vs ~64, roughly a third less cold-parse
## work per fresh-region rebuild (the felt-stutter source).
func _build_radius() -> float:
	var ts := _tile_manager.tile_size if _tile_manager != null else 200.0
	return maxf(recycle_radius + ts, 400.0)


## Assemble the region OSM data + build the road graph. PURE DATA (no scene tree,
## no physics) so it is safe to run on a WorkerThreadPool thread. Returns the
## freshly built network; does NOT touch any manager state.
func _build_network_for(center: Vector3) -> TrafficRoadNetwork:
	# Split the two halves so we can see whether the cost is re-collecting the
	# region (tile walk + parse) or building the graph. Both run off-thread, so
	# record_usec (thread-safe) rather than begin/end spans.
	var t0 := Time.get_ticks_usec()
	# yield_every=4: on the rebuild thread, yield the scheduler every 4 cold tile
	# parses so a fresh region's parse burst doesn't monopolize the shared
	# allocator against the main thread. 0 in the sync path (tests) keeps it tight.
	var yield_every := 4 if _use_threads else 0
	var osm_data := _tile_manager.collect_osm_near(center, _build_radius(), yield_every)
	var t1 := Time.get_ticks_usec()
	FrameTracerScript.record_usec("traffic_collect_osm", t1 - t0)
	var net := TrafficRoadNetwork.new()
	net.build(osm_data)
	FrameTracerScript.record_usec("traffic_network_build", Time.get_ticks_usec() - t1)
	return net


## Swap a freshly built graph in as the live network (MAIN THREAD). Cars whose
## segment vanished from the rebuilt graph (roads just outside the new region)
## are unrouted; they keep driving their cached polyline this frame and
## _refresh_population recycles them onto a live road next tick.
func _adopt_network(net: TrafficRoadNetwork, center: Vector3) -> void:
	# The swap-in + car rerouting runs on the main thread; trace it in case the
	# reroute loop over many cars ever becomes a spike itself.
	var _trace := FrameTracerScript.scope("traffic_adopt_network")
	_network = net
	_network_center = center
	_network_built = true
	for c: TrafficCar in _cars:
		var wid := c.current_way_id()
		if wid != -1 and _network.find_road(wid) == null:
			_routes.erase(c.get_instance_id())


## Build + adopt the graph synchronously on the calling (main) thread. Used for
## the very first build, where there is no existing graph to drive on while a
## worker task runs, and in the headless/test path (_use_threads = false).
func _rebuild_network_sync(center: Vector3) -> void:
	_adopt_network(_build_network_for(center), center)


## Kick off an off-thread rebuild around `center` if one isn't already running.
## Cars keep driving the current graph until the thread finishes and its result
## is adopted in _physics_process. Falls back to a synchronous rebuild when
## threads are disabled (tests).
func _request_rebuild(center: Vector3) -> void:
	if _rebuild_thread != null:
		return  # a rebuild is already in flight; it'll re-center soon enough
	if not _use_threads:
		_rebuild_network_sync(center)
		_refresh_population()
		return
	_rebuild_center = center
	_rebuild_mutex.lock()
	_rebuild_done = false
	_rebuild_mutex.unlock()
	_rebuild_thread = Thread.new()
	# A dedicated Thread (not WorkerThreadPool) so a fresh region's ~870 ms
	# cold-parse never competes with the pool the engine + tile streaming use.
	_rebuild_thread.start(_rebuild_thread_body)


## Dedicated-thread body: build the graph for _rebuild_center and publish it.
## Touches only pure-data collect/build paths (thread-safe: collect_osm_near uses
## the mutex-guarded parse_tile cache). Sets _rebuild_done under the mutex so the
## main thread can observe completion without a data race.
func _rebuild_thread_body() -> void:
	var t0 := Time.get_ticks_usec()
	var net := _build_network_for(_rebuild_center)
	FrameTracerScript.record_usec("traffic_rebuild_task", Time.get_ticks_usec() - t0)
	_rebuild_mutex.lock()
	_pending_network = net
	_rebuild_done = true
	_rebuild_mutex.unlock()


## Main thread: adopt a finished rebuild, if any. Non-blocking — while the thread
## is still working, _rebuild_done is false and we return immediately. Once done,
## join the thread (near-instant, it has already finished) and swap in the graph.
func _collect_finished_rebuild() -> void:
	if _rebuild_thread == null:
		return
	_rebuild_mutex.lock()
	var done := _rebuild_done
	_rebuild_mutex.unlock()
	if not done:
		return
	_rebuild_thread.wait_to_finish()  # join; returns at once since it's finished
	_rebuild_thread = null
	if _pending_network != null:
		_adopt_network(_pending_network, _rebuild_center)
		_pending_network = null
		_refresh_population()


func _physics_process(delta: float) -> void:
	if _car == null:
		return

	# Adopt any off-thread rebuild that finished since last frame.
	_collect_finished_rebuild()

	# Keep the drivable graph centered on the player: rebuild the region graph
	# whenever the player has moved far enough. On a small single-file map the
	# build radius covers the whole area so this is effectively the classic
	# once-built graph; on a streamed country it follows the player. The first
	# build is synchronous (no graph to drive on yet); later rebuilds run on a
	# worker thread so the physics frame never stalls on collect + build.
	if _tile_manager != null and _tile_manager.is_data_ready():
		if not _network_built:
			# First build: synchronous, so cars exist as soon as data is ready.
			_rebuild_network_sync(_car.global_position)
			_refresh_population()
		elif _car.global_position.distance_to(_network_center) > _NETWORK_REBUILD_THRESHOLD:
			# Subsequent rebuilds: off-thread, driving the old graph meanwhile.
			_request_rebuild(_car.global_position)

	if _network.road_count() == 0:
		return
	# Flow every car that reached the end of its road onto a connected road *this*
	# frame, so it rolls through the junction with no visible pause or teleport.
	# This is the fix for "cars jump instead of passing segment to segment".
	_advance_finished_cars()
	# Cheap every-frame work: update each car's LOD based on distance to the
	# camera. The heavier "which roads / spawn / recycle" pass is throttled.
	_update_car_lod()

	_refresh_accum += delta
	if _refresh_accum >= refresh_interval:
		_refresh_accum = 0.0
		_refresh_population()


## Top up the roads near the player toward their desired car count. This only
## *adds* cars to under-populated roads (drawing from cars that are out of range
## or unrouted, then spawning up to max_cars); it never touches a car already
## driving a route, which is what stopped the periodic random teleporting.
func _refresh_population() -> void:
	if _car == null:
		return
	# Trace the population refresh: it may instance new TrafficCar scenes
	# (add_child) which is main-thread work and a possible stutter source.
	var _trace := FrameTracerScript.scope("traffic_refresh_population")
	var center := _car.global_position
	var plans := TrafficSpawnPolicy.select_active_roads(
		_network.get_roads(), center, active_radius, max_cars)

	# A car is reassignable only if it has no valid route or has wandered out of
	# range. Cars mid-route (the common case) are left alone — they flow across
	# junctions on their own via _advance_finished_cars.
	var free_cars: Array[TrafficCar] = []
	for c: TrafficCar in _cars:
		if c.current_way_id() == -1 or _out_of_range(c.global_position, center, recycle_radius):
			free_cars.append(c)

	for plan: TrafficSpawnPolicy.RoadPlan in plans:
		var have := _count_cars_on_road(plan.road)
		var need := plan.desired_cars - have
		while need > 0:
			var car := _take_free_car(free_cars)
			if car == null:
				if _cars.size() >= max_cars:
					return  # budget exhausted
				car = _spawn_car()
			_assign_to_road(car, plan.road, _rng.randf_range(0.0, maxf(0.0, plan.road.length)))
			need -= 1


## Continue any car that reached the end of its current road onto a connected
## road at that junction, so it drives *through* the junction seamlessly instead
## of teleporting. Cars that hit a dead end, or are out of range, are unrouted so
## the next _refresh_population recycles them onto a fresh nearby road.
func _advance_finished_cars() -> void:
	var center := _car.global_position
	for c: TrafficCar in _cars:
		if c.current_way_id() == -1 or not c.is_finished():
			continue
		# A car that has drifted out of range is cheaper to recycle wholesale than
		# to keep flowing across junctions far from the player.
		if _out_of_range(c.global_position, center, recycle_radius):
			c.set_route(PackedVector3Array(), 0.0, -1)
			_routes.erase(c.get_instance_id())
			continue
		if not _continue_car(c):
			# Dead end (or road vanished): drop the route so refresh recycles it.
			c.set_route(PackedVector3Array(), 0.0, -1)
			_routes.erase(c.get_instance_id())


## Roll a finished car onto a road connected at its exit junction. Returns false
## when there's no legal continuation (dead end / one-way trap). The car keeps
## its speed, momentum and position across the seam (continue_route, no teleport)
## and any overshoot carries into the new road so there's no stutter.
func _continue_car(car: TrafficCar) -> bool:
	var road := _network.find_road(car.current_way_id())
	if road == null:
		return false
	# The car exits at the far end of its *travel* direction: for a forward
	# traversal that's the road's end_node, for a reversed one it's the start_node.
	# Follow the car's planned route (its long-term intention). Pull the next
	# planned continuation; if the plan is empty or stale, re-plan from here.
	var cont := _next_planned_continuation(car, road)
	if cont == null:
		return false
	var path := _reverse_points(cont.road.points) if cont.reversed else cont.road.points
	car.continue_route(path, car.overshoot(), cont.road.segment_id, cont.reversed, _lane_offset_for(cont.road))
	return true


## Return the next continuation from the car's planned route, refilling the plan
## when it runs out. Guards against a stale plan (whose head no longer starts at
## the junction the car actually reached, e.g. after a recycle) by re-planning.
## Null means a genuine dead end.
func _next_planned_continuation(car: TrafficCar, road: TrafficRoadNetwork.Road) -> TrafficRoadNetwork.Continuation:
	var key := car.get_instance_id()
	var plan: Array = _routes.get(key, [])
	# The next hop must start at the junction the car is exiting; if the queued
	# head doesn't connect to `road`, the plan is stale — drop it and re-plan.
	if not plan.is_empty():
		var head: TrafficRoadNetwork.Continuation = plan[0]
		if not _connects(road, car.is_reversed(), head):
			plan = []
	if plan.is_empty():
		plan = _network.plan_route(road, car.is_reversed(), _PLAN_AHEAD, _rng)
	if plan.is_empty():
		_routes.erase(key)
		return null
	var cont: TrafficRoadNetwork.Continuation = plan.pop_front()
	_routes[key] = plan
	return cont


## True when `cont` is a legal next hop out of `road` given the travel direction:
## the junction `road` exits at must be the entering endpoint of `cont.road`.
static func _connects(road: TrafficRoadNetwork.Road, reversed: bool, cont: TrafficRoadNetwork.Continuation) -> bool:
	var junction: int = road.start_node if reversed else road.end_node
	var enter: int = cont.road.end_node if cont.reversed else cont.road.start_node
	return junction == enter


## Place a car on a road: orient the polyline for the travel direction, keep the
## car's speed (only randomise it on a *fresh* placement, i.e. start ~0), and
## record the way id + direction so it can be counted and continued later.
## start_distance seeds progress (0 at the entering junction).
func _assign_to_road(car: TrafficCar, road: TrafficRoadNetwork.Road, start_distance: float, reversed: bool = false) -> void:
	# A two-way road with no forced direction gets a coin-flip so both directions
	# see traffic; a continuation passes an explicit `reversed` and skips this.
	if not reversed and not road.one_way and start_distance <= 0.001:
		reversed = _rng.randf() < 0.5
	var path := _reverse_points(road.points) if reversed else road.points
	# Give a car a fresh cruise speed only when it's being placed anew (near the
	# start); a continuation (overshoot-seeded) keeps its current speed for a
	# smooth junction crossing.
	if start_distance <= 0.001:
		car.cruise_speed = _rng.randf_range(_SPEED_MIN, _SPEED_MAX)
	car.set_route(path, start_distance, road.segment_id, reversed, _lane_offset_for(road))
	car.visible = true
	# Seed a fresh long-term plan from this road/direction so the car has an
	# intention the moment it's placed (rather than deciding only when it reaches
	# the first junction).
	_routes[car.get_instance_id()] = _network.plan_route(road, reversed, _PLAN_AHEAD, _rng)


## How far right of the centreline a car on this road should drive, in meters.
##
## A two-way road carries traffic in both directions, so each direction gets half
## the carriageway; a car sits in the middle of its half — a quarter of the full
## width to the right of the centreline. A one-way road uses the whole
## carriageway for one direction, so its cars stay centred (offset 0). The result
## is clamped so a very wide road doesn't push a small block car off the edge of
## the asphalt onto the verge.
func _lane_offset_for(road: TrafficRoadNetwork.Road) -> float:
	if road.one_way:
		return 0.0
	# Keep the car's centre inside the right half: half the half-width, minus a
	# small margin so a wide car body still sits fully on the asphalt.
	return maxf(road.width * 0.25, 0.0)


## Instance a new pooled traffic car and track it.
func _spawn_car() -> TrafficCar:
	var car: TrafficCar = TRAFFIC_CAR_SCENE.instantiate()
	add_child(car)
	_cars.append(car)
	return car


## Pull a reusable car off the free list, or null if none are free.
func _take_free_car(free_cars: Array[TrafficCar]) -> TrafficCar:
	while free_cars.size() > 0:
		var c: TrafficCar = free_cars.pop_back()
		if is_instance_valid(c):
			return c
	return null


## Upgrade cars near the camera to full physics, and demote distant ones to the
## cheap kinematic mover. Uses the active camera so the LOD tracks what's on
## screen, not just proximity to the player body.
func _update_car_lod() -> void:
	var cam := get_viewport().get_camera_3d()
	var ref_pos := cam.global_position if cam != null else _car.global_position
	var d2 := detail_distance * detail_distance
	for c: TrafficCar in _cars:
		var dx := c.global_position.x - ref_pos.x
		var dz := c.global_position.z - ref_pos.z
		c.set_detailed(dx * dx + dz * dz <= d2)


## How many live cars are currently routed on the given road, matched by the
## unique segment id (a stable identity — the old length-based signature collided
## between same-length and reversed roads, which made the manager repeatedly "top
## up" roads it thought were empty and teleport cars around). Note the OSM way id
## is *not* unique now that ways split into per-junction segments, so we match on
## segment_id.
func _count_cars_on_road(road: TrafficRoadNetwork.Road) -> int:
	var count := 0
	for c: TrafficCar in _cars:
		if c.current_way_id() == road.segment_id:
			count += 1
	return count


## Number of live traffic cars (for the HUD / debugging / tests).
func car_count() -> int:
	return _cars.size()


## Number of cars currently in full-physics (in-view) mode.
func detailed_car_count() -> int:
	var n := 0
	for c: TrafficCar in _cars:
		if c.is_detailed():
			n += 1
	return n


# --- Internals -------------------------------------------------------------

static func _out_of_range(pos: Vector3, center: Vector3, radius: float) -> bool:
	var dx := pos.x - center.x
	var dz := pos.z - center.z
	return dx * dx + dz * dz > radius * radius


static func _reverse_points(points: PackedVector3Array) -> PackedVector3Array:
	var out := PackedVector3Array()
	out.resize(points.size())
	var n := points.size()
	for i: int in range(n):
		out[i] = points[n - 1 - i]
	return out
