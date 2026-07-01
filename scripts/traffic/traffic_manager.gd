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

## Packed scene for a single traffic car (the stub block).
const TRAFFIC_CAR_SCENE := preload("res://scenes/traffic_car.tscn")

## Per-car cruise speed range (m/s) so traffic isn't lock-step. ~18–40 km/h.
const _SPEED_MIN := 5.0
const _SPEED_MAX := 11.0

var _network := TrafficRoadNetwork.new()
var _car: Node3D = null
var _tile_manager: OSMTileManager = null
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
	# Build the network as soon as OSM data exists; otherwise wait for the signal
	# (mirrors how main.gd handles the spawn timing).
	var data := _tile_manager.get_osm_data()
	if data != null:
		_on_data_loaded(data)
	else:
		_tile_manager.data_loaded.connect(_on_data_loaded)


func _on_data_loaded(osm_data: OSMParser.OSMData) -> void:
	_network.build(osm_data)
	print("TrafficManager: %d drivable roads, total capacity %d" % [
		_network.road_count(), _network.total_capacity()])
	# Populate immediately so cars are present the moment the world appears.
	_refresh_population()


func _physics_process(delta: float) -> void:
	if _network.road_count() == 0 or _car == null:
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
	car.continue_route(path, car.overshoot(), cont.road.segment_id, cont.reversed)
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
	car.set_route(path, start_distance, road.segment_id, reversed)
	car.visible = true
	# Seed a fresh long-term plan from this road/direction so the car has an
	# intention the moment it's placed (rather than deciding only when it reaches
	# the first junction).
	_routes[car.get_instance_id()] = _network.plan_route(road, reversed, _PLAN_AHEAD, _rng)


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
