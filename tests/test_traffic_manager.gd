extends GdUnitTestSuite

## Unit tests for TrafficManager policy helpers that don't need the scene wired.
##
## TrafficManager mostly orchestrates the scene (camera, tile data, physics), but
## a few decisions are pure policy worth pinning in isolation:
##   * the keep-right lane offset (how far right of the centreline to drive), and
##   * the travel-direction assignment (a two-way road must carry traffic BOTH
##     ways so there's oncoming traffic; a one-way road only its forward way).

const TrafficManagerScript := preload("res://scripts/traffic/traffic_manager.gd")
const TrafficRoadNetwork := preload("res://scripts/traffic/traffic_road_network.gd")
const TrafficCarScene := preload("res://scenes/traffic_car.tscn")


func _make_manager() -> TrafficManager:
	# No car_path / tile_manager_path wired: _ready() warns and returns, leaving a
	# bare manager whose pure helpers we can call directly.
	var mgr: TrafficManager = TrafficManagerScript.new()
	add_child(mgr)
	auto_free(mgr)
	return mgr


func _make_car() -> TrafficCar:
	var car: TrafficCar = TrafficCarScene.instantiate()
	add_child(car)
	auto_free(car)
	return car


func _road(width: float, one_way: bool) -> TrafficRoadNetwork.Road:
	var road := TrafficRoadNetwork.Road.new()
	road.width = width
	road.one_way = one_way
	return road


## A straight 100 m road along +X, so a forward car reports reversed == false and
## a flipped one reports reversed == true. segment_id is set so the car records a
## valid identity when placed.
func _straight_road(one_way: bool) -> TrafficRoadNetwork.Road:
	var road := _road(6.0, one_way)
	road.segment_id = 1
	road.points = PackedVector3Array([Vector3(0, 0, 0), Vector3(100, 0, 0)])
	road.length = 100.0
	return road


func test_two_way_road_offsets_into_right_half() -> void:
	# A two-way road splits into two lanes; a car sits in the centre of the right
	# half — a quarter of the full carriageway width to the right of the centre.
	var mgr := _make_manager()
	assert_float(mgr._lane_offset_for(_road(8.0, false))).is_equal_approx(2.0, 0.001)


func test_one_way_road_stays_centred() -> void:
	# A one-way road uses the whole carriageway for its single direction, so its
	# cars stay on the centreline (no lateral offset).
	var mgr := _make_manager()
	assert_float(mgr._lane_offset_for(_road(8.0, true))).is_equal_approx(0.0, 0.001)


func test_narrower_two_way_road_offsets_less() -> void:
	# The offset scales with width so cars stay within the drawn asphalt on
	# narrow residential streets as well as wide primaries.
	var mgr := _make_manager()
	assert_float(mgr._lane_offset_for(_road(5.0, false))).is_equal_approx(1.25, 0.001)


# ─── Travel-direction assignment (oncoming traffic) ──────────────────────────
#
# Regression: fresh cars are seeded at a *random* distance along a road, and the
# direction coin-flip used to be gated on start_distance <= 0.001 (a proxy for
# "fresh placement"). That guard almost never held for a mid-road spawn, so every
# car drove the forward direction and a two-way street had no oncoming traffic.
# The flip must fire for every fresh placement on a two-way road.

func test_two_way_road_assigns_both_directions() -> void:
	# Placing many cars on a two-way road (each at a random distance, as the real
	# spawner does) must produce BOTH travel directions, not just forward.
	var mgr := _make_manager()
	var road := _straight_road(false)
	var saw_forward := false
	var saw_reversed := false
	for i in range(40):
		var car := _make_car()
		mgr._assign_to_road(car, road, randf() * road.length)
		if car.is_reversed():
			saw_reversed = true
		else:
			saw_forward = true
	assert_bool(saw_forward).override_failure_message(
		"expected some cars driving the road forward").is_true()
	assert_bool(saw_reversed).override_failure_message(
		"expected some cars driving the road reversed (oncoming traffic)").is_true()


func test_two_way_road_direction_independent_of_start_distance() -> void:
	# The direction flip must not depend on where along the road the car starts —
	# a mid-road spawn is just as likely to be reversed as one seeded at the start.
	var mgr := _make_manager()
	var road := _straight_road(false)
	var reversed_count := 0
	for i in range(60):
		var car := _make_car()
		mgr._assign_to_road(car, road, 50.0)  # always mid-road
		if car.is_reversed():
			reversed_count += 1
	# With a fair coin over 60 mid-road placements, expect a healthy mix; the old
	# bug pinned this to exactly 0. Assert it's neither all-forward nor all-reversed.
	assert_int(reversed_count).is_greater(0)
	assert_int(reversed_count).is_less(60)


func test_one_way_road_never_reverses() -> void:
	# A one-way road must only ever be driven forward, regardless of start point.
	var mgr := _make_manager()
	var road := _straight_road(true)
	for i in range(40):
		var car := _make_car()
		mgr._assign_to_road(car, road, randf() * road.length)
		assert_bool(car.is_reversed()).override_failure_message(
			"a one-way road must never be driven reversed").is_false()
