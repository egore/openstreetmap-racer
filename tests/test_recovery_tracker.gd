extends GdUnitTestSuite

## Unit tests for RecoveryTracker, the breadcrumb trail behind "recover" (R).
##
## The contract that matters to the player:
##   1. Only safe moments become breadcrumbs.
##   2. Recovery lands a couple of seconds BEFORE the mistake, not at it.
##   3. Pressing recover twice doesn't jump forward into the crash again.

const RecoveryTrackerScript := preload("res://scripts/recovery_tracker.gd")

const STEP := 0.1


## Drive east at 10 m/s for `seconds`, safe or not, starting from `start_x`.
## Returns the x reached.
func _drive(tracker: RecoveryTrackerScript, seconds: float, safe: bool, start_x: float = 0.0) -> float:
	var x := start_x
	var t := 0.0
	while t < seconds - 0.0001:
		x += 10.0 * STEP
		tracker.update(STEP, Vector3(x, 0, 0), Vector3.RIGHT, safe)
		t += STEP
	return x


func test_no_history_means_no_recovery_point() -> void:
	var tracker := RecoveryTrackerScript.new()
	assert_object(tracker.take_recovery_point()).is_null()


func test_unsafe_driving_lays_no_breadcrumbs() -> void:
	var tracker := RecoveryTrackerScript.new()
	_drive(tracker, 5.0, false)
	assert_int(tracker.point_count()).is_equal(0)


func test_safe_driving_lays_breadcrumbs_on_the_interval() -> void:
	var tracker := RecoveryTrackerScript.new()
	_drive(tracker, 5.0, true)
	# One every 0.5 s over 5 s.
	assert_int(tracker.point_count()).is_between(9, 11)


func test_parked_car_does_not_flush_history() -> void:
	var tracker := RecoveryTrackerScript.new()
	_drive(tracker, 2.0, true)
	# The first parked sample may still be a fresh spot; the rest must not be.
	tracker.update(1.0, Vector3(20, 0, 0), Vector3.RIGHT, true)
	var before := tracker.point_count()
	for _i in 50:
		tracker.update(STEP, Vector3(20, 0, 0), Vector3.RIGHT, true)
	assert_int(tracker.point_count()).is_equal(before)


func test_history_is_bounded() -> void:
	var tracker := RecoveryTrackerScript.new()
	_drive(tracker, 60.0, true)
	assert_int(tracker.point_count()).is_equal(tracker.max_points)


func test_recovers_to_a_point_at_least_min_age_old() -> void:
	var tracker := RecoveryTrackerScript.new()
	var x := _drive(tracker, 6.0, true)
	var point := tracker.take_recovery_point()
	assert_object(point).is_not_null()
	# 10 m/s, so two seconds back is at least 20 m behind the crash.
	assert_float(x - point.position.x).is_greater_equal(20.0)
	assert_float(x - point.position.x).is_less(30.0)
	assert_vector(point.forward).is_equal_approx(Vector3.RIGHT, Vector3.ONE * 0.001)


func test_falls_back_to_oldest_point_when_history_is_young() -> void:
	var tracker := RecoveryTrackerScript.new()
	_drive(tracker, 1.0, true)
	var point := tracker.take_recovery_point()
	assert_object(point).is_not_null()
	assert_float(point.position.x).is_less(6.0)


func test_crash_time_unsafe_frames_are_skipped() -> void:
	var tracker := RecoveryTrackerScript.new()
	var x := _drive(tracker, 5.0, true)
	# Tumbling for three seconds lays nothing; the recovery point is still on the
	# clean stretch before it.
	_drive(tracker, 3.0, false, x)
	var point := tracker.take_recovery_point()
	assert_float(point.position.x).is_less_equal(x)


func test_second_recovery_does_not_jump_forward() -> void:
	var tracker := RecoveryTrackerScript.new()
	_drive(tracker, 6.0, true)
	var first := tracker.take_recovery_point()
	var second := tracker.take_recovery_point()
	assert_float(second.position.x).is_less_equal(first.position.x)
	# The breadcrumbs laid between the recovery point and the crash are gone.
	assert_float(tracker.take_recovery_point().position.x).is_less_equal(first.position.x)


func test_remember_seeds_a_point_even_when_parked() -> void:
	var tracker := RecoveryTrackerScript.new()
	tracker.remember(Vector3(5, 1, 5), Vector3(0, 0.5, -2))
	var point := tracker.take_recovery_point()
	assert_vector(point.position).is_equal(Vector3(5, 1, 5))
	assert_vector(point.forward).is_equal_approx(Vector3(0, 0, -1), Vector3.ONE * 0.001)
