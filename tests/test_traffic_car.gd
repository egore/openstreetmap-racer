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


# ─── Slope orientation (the terrain-drape fix) ───────────────────────────────
#
# On a hill the car must sit *on* the road: pitch with the grade (nose up when
# climbing) but never roll or twist across the slope, and never let a steep
# segment corrupt its compass heading. It's the same drape the road mesh uses.
# Before the fix the body was forced dead-level, so on a slope a rigid box rested
# on one bumper with the other floating and gravity crabbed it sideways.

func test_arc_length_is_measured_in_xz_not_3d() -> void:
	# 100 m of horizontal run climbing 30 m. Arc length must be the ground run
	# (100), not the 3D hypotenuse (~104.4), so it agrees with the XZ steering.
	var car := _make_car()
	car.set_route(PackedVector3Array([Vector3(0, 0, 0), Vector3(100, 30, 0)]), 0.0)
	assert_float(car.path_length()).is_equal_approx(100.0, 0.001)


func test_slope_orientation_pitches_with_grade() -> void:
	# Climbing east at a 30 m / 100 m grade: the nose (-Z forward) should tilt up.
	var car := _make_car()
	car.set_route(PackedVector3Array([Vector3(0, 0, 0), Vector3(100, 30, 0)]), 40.0)
	var fwd := -car.global_transform.basis.orthonormalized().z
	# Forward points east (+X) and upward (+Y) on the climb.
	assert_float(fwd.x).is_greater(0.0)
	assert_float(fwd.y).is_greater(0.05)


func test_slope_orientation_does_not_roll() -> void:
	# However steep or curved, the car's right axis stays horizontal (no roll /
	# no twist across the slope) — the property the road drape preserves too.
	var car := _make_car()
	car.set_route(PackedVector3Array([Vector3(0, 0, 0), Vector3(100, 30, 0)]), 40.0)
	var right := car.global_transform.basis.orthonormalized().x
	assert_float(right.y).is_equal_approx(0.0, 0.001)


func test_slope_heading_stays_along_the_road() -> void:
	# The XZ heading must follow the road even on a grade (a steep segment can't
	# wash out the compass direction). Climbing east → forward's XZ is +X.
	var car := _make_car()
	car.set_route(PackedVector3Array([Vector3(0, 0, 0), Vector3(100, 30, 0)]), 40.0)
	var fwd := -car.global_transform.basis.orthonormalized().z
	var heading := Vector2(fwd.x, fwd.z).normalized()
	assert_float(heading.x).is_equal_approx(1.0, 0.01)
	assert_float(heading.y).is_equal_approx(0.0, 0.01)


func test_flat_road_stays_level() -> void:
	# Regression: on flat ground the car is still perfectly level (no spurious
	# pitch introduced by the slope math).
	var car := _make_car()
	car.set_route(PackedVector3Array([Vector3(0, 0, 0), Vector3(100, 0, 0)]), 40.0)
	var fwd := -car.global_transform.basis.orthonormalized().z
	var up := car.global_transform.basis.orthonormalized().y
	assert_float(fwd.y).is_equal_approx(0.0, 0.001)
	assert_float(up.y).is_equal_approx(1.0, 0.001)


func test_extreme_grade_is_clamped() -> void:
	# A near-vertical jump between two path points (mapping glitch / coarse DEM)
	# must not tip the car onto its nose — pitch is clamped to a sane max grade.
	var car := _make_car()
	car.set_route(PackedVector3Array([Vector3(0, 0, 0), Vector3(1, 100, 0)]), 0.5)
	var fwd := -car.global_transform.basis.orthonormalized().z
	# Even on an absurd wall, forward stays below ~40° (tan ≈ 0.84 → sin ≈ 0.64).
	assert_float(fwd.y).is_less_equal(0.65)


func test_slope_basis_is_a_valid_rotation() -> void:
	# Regression: _slope_basis must return an orthonormal rotation basis. If it
	# drifts out of tolerance, Basis.slerp's quaternion cast in _face_direction
	# spams "must be normalized in order to be casted to a Quaternion" every
	# physics frame. is_rotation() is exactly the predicate that cast checks.
	var car := _make_car()
	# A range of headings and grades, including diagonals where float drift bites.
	# All have a non-degenerate XZ run, so all yield a basis (degenerate → null,
	# which callers handle by leaving orientation untouched — see the guard).
	var dirs := [
		Vector3(1, 0.3, 0), Vector3(0.7, 0.7, 0.7), Vector3(-0.4, -0.9, 0.2),
		Vector3(3, 5, -2), Vector3(10.0, 30.0, -10.0)]
	for d: Vector3 in dirs:
		var b: Variant = car._slope_basis(d)
		assert_bool(b != null).override_failure_message(
			"expected a basis for non-degenerate dir %s" % d).is_true()
		var basis := b as Basis
		# A valid rotation basis has determinant 1 and orthonormal axes — exactly
		# what the quaternion cast requires. (is_rotation() isn't exposed to
		# GDScript, so check its constituent properties directly.)
		assert_float(basis.determinant()).override_failure_message(
			"determinant for dir %s not 1" % d).is_equal_approx(1.0, 0.0001)
		assert_float(basis.x.length()).is_equal_approx(1.0, 0.0001)
		assert_float(basis.y.length()).is_equal_approx(1.0, 0.0001)
		assert_float(basis.z.length()).is_equal_approx(1.0, 0.0001)
		assert_float(basis.x.dot(basis.y)).is_equal_approx(0.0, 0.0001)
		assert_float(basis.x.dot(basis.z)).is_equal_approx(0.0, 0.0001)
		assert_float(basis.y.dot(basis.z)).is_equal_approx(0.0, 0.0001)
		# And the cast that actually spams the error must succeed silently.
		var _q := basis.get_rotation_quaternion()


func test_detailed_drive_on_slope_keeps_valid_basis() -> void:
	# End-to-end regression for the "must be normalized ... Quaternion" spam:
	# drive a detailed car along a climbing route for several physics frames
	# (exercising _face_direction's slerp each frame) and confirm the resulting
	# orientation is still a clean rotation.
	var floor_body := StaticBody3D.new()
	var col := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(600, 2, 600)
	col.shape = box
	floor_body.add_child(col)
	add_child(floor_body)
	auto_free(floor_body)
	var angle := atan2(30.0, 100.0)
	floor_body.rotation = Vector3(0, 0, -angle)

	var car := _make_car()
	car.set_route(PackedVector3Array([Vector3(0, 0, 0), Vector3(100, 30, 0)]), 5.0)
	car.set_detailed(true)
	for i in range(30):
		await get_tree().physics_frame
	var basis := car.global_transform.basis.orthonormalized()
	assert_float(basis.determinant()).is_equal_approx(1.0, 0.0001)
	# No roll survived the drive: right axis still horizontal.
	assert_float(basis.x.y).is_equal_approx(0.0, 0.01)
