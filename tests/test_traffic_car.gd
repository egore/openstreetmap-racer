extends GdUnitTestSuite

## Unit tests for TrafficCar route handling.
##
## TrafficCar is a physics body, but its *routing* — where it sits on a polyline
## for a given distance, and when it counts as finished — is deterministic and
## worth pinning without running a physics simulation. These tests assign a
## route and check the placement/finish contract the manager relies on to recycle
## cars:
##
##   1. set_route places the body on the polyline (start at distance 0).
##   2. A distance beyond the polyline length clamps to the end and reports
##      finished, so the manager knows to reassign it.
##   3. path_length reflects the assigned polyline.

const TrafficCarScene := preload("res://scenes/traffic_car.tscn")


func _make_car() -> TrafficCar:
	var car: TrafficCar = TrafficCarScene.instantiate()
	add_child(car)
	auto_free(car)
	return car


func test_set_route_places_at_start() -> void:
	var car := _make_car()
	var path := PackedVector3Array([Vector3(0, 0, 0), Vector3(100, 0, 0)])
	car.set_route(path, 0.0)
	# X≈0 at the start of the route (Y is offset up by the ride height).
	assert_float(car.global_position.x).is_equal_approx(0.0, 0.5)


func test_set_route_places_partway_along() -> void:
	var car := _make_car()
	var path := PackedVector3Array([Vector3(0, 0, 0), Vector3(100, 0, 0)])
	car.set_route(path, 50.0)
	assert_float(car.global_position.x).is_equal_approx(50.0, 0.5)


func test_path_length_matches_polyline() -> void:
	var car := _make_car()
	var path := PackedVector3Array([Vector3(0, 0, 0), Vector3(30, 0, 0), Vector3(30, 0, 40)])
	car.set_route(path, 0.0)
	assert_float(car.path_length()).is_equal_approx(70.0, 0.001)


func test_distance_past_end_is_finished() -> void:
	var car := _make_car()
	var path := PackedVector3Array([Vector3(0, 0, 0), Vector3(100, 0, 0)])
	car.set_route(path, 100.0)
	assert_bool(car.is_finished()).is_true()


func test_car_near_end_within_tolerance_is_finished() -> void:
	# Anti-stall contract: a car within the end tolerance counts as finished so
	# the manager hands it to the next road instead of it crawling to the exact
	# end and getting stuck at the seam.
	var car := _make_car()
	var path := PackedVector3Array([Vector3(0, 0, 0), Vector3(100, 0, 0)])
	car.set_route(path, 99.0)  # 1 m short of the end (< _END_TOLERANCE of 1.5)
	assert_bool(car.is_finished()).is_true()


func test_car_short_of_tolerance_is_not_finished() -> void:
	var car := _make_car()
	var path := PackedVector3Array([Vector3(0, 0, 0), Vector3(100, 0, 0)])
	car.set_route(path, 90.0)  # well before the end
	assert_bool(car.is_finished()).is_false()


func test_fresh_car_with_no_route_is_finished() -> void:
	var car := _make_car()
	# An unrouted car has zero path length and must read as finished so the
	# manager immediately assigns it a road.
	assert_bool(car.is_finished()).is_true()


func test_detailed_toggle_reports_state() -> void:
	var car := _make_car()
	car.set_detailed(true)
	assert_bool(car.is_detailed()).is_true()
	car.set_detailed(false)
	assert_bool(car.is_detailed()).is_false()


func test_route_records_way_id_and_direction() -> void:
	# The manager relies on these for counting cars per road and continuing them
	# onto connected roads at junctions.
	var car := _make_car()
	var path := PackedVector3Array([Vector3(0, 0, 0), Vector3(100, 0, 0)])
	car.set_route(path, 0.0, 42, true)
	assert_int(car.current_way_id()).is_equal(42)
	assert_bool(car.is_reversed()).is_true()


func test_unrouted_car_reports_no_way_id() -> void:
	var car := _make_car()
	assert_int(car.current_way_id()).is_equal(-1)


func test_reassigning_empty_route_clears_way_id() -> void:
	var car := _make_car()
	car.set_route(PackedVector3Array([Vector3(0, 0, 0), Vector3(50, 0, 0)]), 0.0, 7)
	assert_int(car.current_way_id()).is_equal(7)
	# Recycling clears identity (manager passes an empty path + way_id -1).
	car.set_route(PackedVector3Array(), 0.0, -1)
	assert_int(car.current_way_id()).is_equal(-1)


# ─── Position → arc-length projection (the anti-waving fix) ───────────────────
#
# _closest_distance re-derives how far along the route the body actually is by
# projecting its world position onto the polyline. Closing this loop (instead of
# dead-reckoning _distance) is what stopped cars waving around curves, so pin its
# behaviour on straight, offset, and cornered cases.

func test_closest_distance_on_straight_matches_x() -> void:
	var car := _make_car()
	car.set_route(PackedVector3Array([Vector3(0, 0, 0), Vector3(100, 0, 0)]), 0.0)
	# A point 30 m along the straight road projects to arc-length 30.
	assert_float(car._closest_distance(Vector3(30, 0, 0))).is_equal_approx(30.0, 0.01)


func test_closest_distance_ignores_lateral_offset() -> void:
	# A body pushed sideways off the road still projects to the same arc-length —
	# this is exactly the case that used to blow up the lateral correction.
	var car := _make_car()
	car.set_route(PackedVector3Array([Vector3(0, 0, 0), Vector3(100, 0, 0)]), 0.0)
	assert_float(car._closest_distance(Vector3(30, 0, 8))).is_equal_approx(30.0, 0.01)


func test_closest_distance_on_corner_uses_nearest_segment() -> void:
	# L-shaped route: 40 m east then 40 m south. A point near the second leg
	# projects past the corner (arc-length > 40).
	var car := _make_car()
	var path := PackedVector3Array([
		Vector3(0, 0, 0), Vector3(40, 0, 0), Vector3(40, 0, 40)])
	car.set_route(path, 0.0)
	var d := car._closest_distance(Vector3(40, 0, 15))
	assert_float(d).is_greater(40.0)
	assert_float(d).is_less_equal(80.0)


func test_closest_distance_clamps_past_end() -> void:
	var car := _make_car()
	car.set_route(PackedVector3Array([Vector3(0, 0, 0), Vector3(100, 0, 0)]), 0.0)
	# A point beyond the road end projects to the end (arc-length = length).
	assert_float(car._closest_distance(Vector3(130, 0, 0))).is_equal_approx(100.0, 0.01)
