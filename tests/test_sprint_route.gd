extends GdUnitTestSuite

## SprintRoute planning and CheckpointTracker progress, on a synthetic grid of
## streets 200 m apart.

const SprintRouteScript := preload("res://scripts/sprint_route.gd")
const CheckpointTrackerScript := preload("res://scripts/checkpoint_tracker.gd")
const TrafficRoadNetwork := preload("res://scripts/traffic/traffic_road_network.gd")

const GridNetwork := preload("res://tests/fixtures/grid_network.gd")


func _grid(one_way_rows: bool = false) -> TrafficRoadNetwork:
	return GridNetwork.build(6, 200.0, one_way_rows)


func test_plans_a_course_of_the_requested_length() -> void:
	var route := SprintRouteScript.plan(_grid(), Vector3(100, 0, 0), Vector3.RIGHT)
	assert_object(route).is_not_null()
	assert_float(route.length).is_between(700.0, 1300.0)


func test_the_course_starts_at_the_car_and_leaves_along_its_heading() -> void:
	var route := SprintRouteScript.plan(_grid(), Vector3(100, 0, 2), Vector3.RIGHT)
	assert_vector(route.points[0]).is_equal_approx(Vector3(100, 0, 0), Vector3.ONE * 0.01)
	assert_float(route.points[1].x).is_greater(100.0)
	var back := SprintRouteScript.plan(_grid(), Vector3(100, 0, 2), Vector3.LEFT)
	assert_float(back.points[1].x).is_less(100.0)


func test_the_course_is_one_connected_line() -> void:
	var route := SprintRouteScript.plan(_grid(), Vector3(100, 0, 0), Vector3.RIGHT)
	for i in range(route.points.size() - 1):
		# Grid streets are straight between junctions; no jump is longer than a block.
		assert_float(route.points[i].distance_to(route.points[i + 1])).is_less_equal(200.01)


func test_the_finish_is_far_from_the_start_as_the_crow_flies() -> void:
	var route := SprintRouteScript.plan(_grid(), Vector3(100, 0, 0), Vector3.RIGHT)
	var finish := route.points[route.points.size() - 1]
	# In a grid the course length is the Manhattan distance; the farthest finish
	# in the window is well away from the start, not round the block.
	assert_float(Vector3(100, 0, 0).distance_to(finish)).is_greater(500.0)


func test_planning_is_deterministic() -> void:
	var a := SprintRouteScript.plan(_grid(), Vector3(100, 0, 0), Vector3.RIGHT)
	var b := SprintRouteScript.plan(_grid(), Vector3(100, 0, 0), Vector3.RIGHT)
	assert_str(a.id).is_equal(b.id)
	assert_array(Array(a.points)).is_equal(Array(b.points))


func test_one_way_streets_are_only_driven_forwards() -> void:
	# Start on a column, facing north, so the search has to choose its rows.
	var route := SprintRouteScript.plan(_grid(true), Vector3(400, 0, 900), Vector3.FORWARD)
	assert_object(route).is_not_null()
	for i in range(route.points.size() - 1):
		var a := route.points[i]
		var b := route.points[i + 1]
		if is_equal_approx(a.z, b.z) and not is_equal_approx(a.x, b.x):
			assert_float(b.x).override_failure_message("eastbound-only row driven west").is_greater(a.x)


func test_checkpoints_are_spaced_along_the_course_and_end_at_the_finish() -> void:
	var route := SprintRouteScript.plan(_grid(), Vector3(100, 0, 0), Vector3.RIGHT, 700.0, 1300.0, 150.0)
	var n := route.checkpoints.size()
	assert_vector(route.checkpoints[n - 1]).is_equal(route.points[route.points.size() - 1])
	assert_float(route.checkpoint_distances[0]).is_equal_approx(150.0, 0.01)
	for i in range(1, n - 1):
		assert_float(route.checkpoint_distances[i] - route.checkpoint_distances[i - 1]) \
			.is_equal_approx(150.0, 0.01)
	assert_float(route.length - route.checkpoint_distances[n - 2]).is_greater_equal(75.0)


func test_distance_along_measures_progress_on_the_course() -> void:
	var route := SprintRouteScript.plan(_grid(), Vector3(100, 0, 0), Vector3.RIGHT)
	assert_float(route.distance_along(route.points[0])).is_equal_approx(0.0, 0.01)
	assert_float(route.distance_along(route.checkpoints[1])) \
		.is_equal_approx(route.checkpoint_distances[1], 0.5)


func test_no_roads_means_no_course() -> void:
	assert_object(SprintRouteScript.plan(TrafficRoadNetwork.new(), Vector3.ZERO, Vector3.RIGHT)).is_null()


# ─── CheckpointTracker ───────────────────────────────────────────────────────

func _gates() -> PackedVector3Array:
	return PackedVector3Array([Vector3(100, 0, 0), Vector3(200, 0, 0), Vector3(300, 0, 0)])


func test_gates_must_be_taken_in_order() -> void:
	var tracker := CheckpointTrackerScript.new(_gates(), 10.0)
	assert_bool(tracker.update(Vector3(200, 0, 0))).is_false()
	assert_int(tracker.next_index).is_equal(0)
	tracker.reset()
	assert_bool(tracker.update(Vector3(95, 0, 5))).is_true()
	assert_bool(tracker.update(Vector3(198, 0, 0))).is_true()
	assert_bool(tracker.is_complete()).is_false()
	assert_bool(tracker.update(Vector3(300, 0, 9))).is_true()
	assert_bool(tracker.is_complete()).is_true()


func test_a_fast_pass_between_samples_still_counts() -> void:
	var tracker := CheckpointTrackerScript.new(_gates(), 10.0)
	tracker.update(Vector3(85, 0, 0))
	# 30 m in one sample, straight through the gate at x=100.
	assert_bool(tracker.update(Vector3(115, 0, 0))).is_true()


func test_a_teleport_across_a_gate_does_not_count() -> void:
	var tracker := CheckpointTrackerScript.new(_gates(), 10.0)
	tracker.update(Vector3(40, 0, 0))
	# A recovery jump of 120 m across the gate is not driving through it.
	assert_bool(tracker.update(Vector3(160, 0, 0))).is_false()


func test_a_near_miss_of_the_gate_does_not_count() -> void:
	var tracker := CheckpointTrackerScript.new(_gates(), 10.0)
	tracker.update(Vector3(85, 0, 20))
	assert_bool(tracker.update(Vector3(115, 0, 20))).is_false()
	assert_float(tracker.distance_to_next(Vector3(100, 0, 20))).is_equal_approx(20.0, 0.001)
