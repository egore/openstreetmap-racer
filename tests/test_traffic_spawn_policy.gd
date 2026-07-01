extends GdUnitTestSuite

## Unit tests for TrafficSpawnPolicy, the pure "which roads carry cars and how
## many" decision the TrafficManager turns into spawned cars.
##
## The policy is where two feature requirements live, so they're pinned here
## rather than buried in the node:
##
##   1. Traffic stays within a radius of the player — out-of-range roads get no
##      cars at all.
##   2. Larger streets get more cars, and when the global car budget is tight the
##      big arterials fill *before* the side streets (widest-first).
##   3. The plan never exceeds max_cars, and every in-range drivable road gets at
##      least one car so quiet streets aren't dead.

const TrafficSpawnPolicy := preload("res://scripts/traffic/traffic_spawn_policy.gd")
const TrafficRoadNetwork := preload("res://scripts/traffic/traffic_road_network.gd")


# ─── Fixtures ────────────────────────────────────────────────────────────────

## Build a Road with two points from `start` to `end`, a width, and a capacity.
func _road(start: Vector3, end: Vector3, width: float, capacity: int) -> TrafficRoadNetwork.Road:
	var r := TrafficRoadNetwork.Road.new()
	r.points = PackedVector3Array([start, end])
	r.width = width
	r.length = start.distance_to(end)
	r.capacity = capacity
	return r


func _roads(list: Array) -> Array[TrafficRoadNetwork.Road]:
	var out: Array[TrafficRoadNetwork.Road] = []
	for r: TrafficRoadNetwork.Road in list:
		out.append(r)
	return out


# ─── Radius filtering ────────────────────────────────────────────────────────

func test_in_range_road_is_selected() -> void:
	var roads := _roads([_road(Vector3(0, 0, 0), Vector3(50, 0, 0), 8.0, 3)])
	var plans := TrafficSpawnPolicy.select_active_roads(roads, Vector3.ZERO, 100.0, 40)
	assert_int(plans.size()).is_equal(1)


func test_out_of_range_road_excluded() -> void:
	var roads := _roads([_road(Vector3(1000, 0, 0), Vector3(1050, 0, 0), 8.0, 3)])
	var plans := TrafficSpawnPolicy.select_active_roads(roads, Vector3.ZERO, 100.0, 40)
	assert_int(plans.size()).is_equal(0)


func test_road_partially_in_range_selected() -> void:
	# Far start point but a near end point → still in range (any point counts).
	var roads := _roads([_road(Vector3(500, 0, 0), Vector3(20, 0, 0), 8.0, 3)])
	var plans := TrafficSpawnPolicy.select_active_roads(roads, Vector3.ZERO, 100.0, 40)
	assert_int(plans.size()).is_equal(1)


func test_zero_radius_selects_nothing() -> void:
	var roads := _roads([_road(Vector3(0, 0, 0), Vector3(50, 0, 0), 8.0, 3)])
	var plans := TrafficSpawnPolicy.select_active_roads(roads, Vector3.ZERO, 0.0, 40)
	assert_int(plans.size()).is_equal(0)


# ─── Budget cap ──────────────────────────────────────────────────────────────

func test_total_never_exceeds_max_cars() -> void:
	var roads := _roads([
		_road(Vector3(0, 0, 0), Vector3(50, 0, 0), 12.0, 10),
		_road(Vector3(0, 0, 10), Vector3(50, 0, 10), 8.0, 10),
		_road(Vector3(0, 0, 20), Vector3(50, 0, 20), 5.0, 10),
	])
	var plans := TrafficSpawnPolicy.select_active_roads(roads, Vector3.ZERO, 100.0, 12)
	assert_int(TrafficSpawnPolicy.total_desired(plans)).is_less_equal(12)


func test_zero_budget_selects_nothing() -> void:
	var roads := _roads([_road(Vector3(0, 0, 0), Vector3(50, 0, 0), 8.0, 3)])
	var plans := TrafficSpawnPolicy.select_active_roads(roads, Vector3.ZERO, 100.0, 0)
	assert_int(plans.size()).is_equal(0)


# ─── Widest-first priority (the core feature) ────────────────────────────────

func test_wider_road_planned_first() -> void:
	# Order the input narrow→wide; the plan should still put the widest first.
	var narrow := _road(Vector3(0, 0, 0), Vector3(50, 0, 0), 5.0, 4)
	var wide := _road(Vector3(0, 0, 10), Vector3(50, 0, 10), 12.0, 4)
	var plans := TrafficSpawnPolicy.select_active_roads(_roads([narrow, wide]), Vector3.ZERO, 100.0, 40)
	assert_float(plans[0].road.width).is_equal_approx(12.0, 0.001)


func test_wide_road_fills_before_narrow_under_tight_budget() -> void:
	# Two roads, budget only covers one road's capacity: the wide one must win.
	var narrow := _road(Vector3(0, 0, 0), Vector3(50, 0, 0), 5.0, 5)
	var wide := _road(Vector3(0, 0, 10), Vector3(50, 0, 10), 12.0, 5)
	var plans := TrafficSpawnPolicy.select_active_roads(_roads([narrow, wide]), Vector3.ZERO, 100.0, 5)
	# Budget of 5 all goes to the wide road; narrow gets nothing.
	assert_int(plans.size()).is_equal(1)
	assert_float(plans[0].road.width).is_equal_approx(12.0, 0.001)
	assert_int(plans[0].desired_cars).is_equal(5)


func test_wider_road_gets_more_cars() -> void:
	var narrow := _road(Vector3(0, 0, 0), Vector3(50, 0, 0), 5.0, 2)
	var wide := _road(Vector3(0, 0, 10), Vector3(50, 0, 10), 12.0, 8)
	var plans := TrafficSpawnPolicy.select_active_roads(_roads([narrow, wide]), Vector3.ZERO, 100.0, 40)
	# Find each road's plan by width and compare car counts.
	var narrow_cars := -1
	var wide_cars := -1
	for p: TrafficSpawnPolicy.RoadPlan in plans:
		if is_equal_approx(p.road.width, 5.0):
			narrow_cars = p.desired_cars
		elif is_equal_approx(p.road.width, 12.0):
			wide_cars = p.desired_cars
	assert_int(wide_cars).is_greater(narrow_cars)


# ─── Minimum liveliness ──────────────────────────────────────────────────────

func test_in_range_road_gets_at_least_one_car() -> void:
	# A road with capacity 0 (short) still gets a single car so it isn't dead.
	var roads := _roads([_road(Vector3(0, 0, 0), Vector3(10, 0, 0), 5.0, 0)])
	var plans := TrafficSpawnPolicy.select_active_roads(roads, Vector3.ZERO, 100.0, 40)
	assert_int(plans.size()).is_equal(1)
	assert_int(plans[0].desired_cars).is_equal(1)
