extends GdUnitTestSuite

## Tests for the isometric top-down camera's framing maths.
##
## The placement is a pure static function precisely so it can be checked by
## arithmetic rather than by looking at a screenshot: "the camera is above and
## behind the car" is the sort of claim that a rendered picture makes easy to
## believe and hard to verify.

const TopDownCameraScript := preload("res://scripts/top_down_camera.gd")

const EPS := 0.001


func test_camera_sits_above_its_target() -> void:
	# The defining property of a top-down view: the camera is higher than what it
	# looks at, whatever the compass direction.
	for yaw: float in [0.0, 45.0, 90.0, 180.0, 270.0, -135.0]:
		var pos := TopDownCameraScript.desired_position(
			Vector3(10.0, 5.0, -20.0), yaw, 35.264, 120.0)
		assert_float(pos.y) \
			.override_failure_message(
				"yaw %.0f must still place the camera above the car" % yaw) \
			.is_greater(5.0)


func test_distance_to_target_is_independent_of_angle() -> void:
	# Changing yaw or pitch must ORBIT the camera, not dolly it. If the distance
	# drifted with the angles, tuning the pitch would silently change how much
	# world sits in front of the near plane and buildings would start clipping.
	var target := Vector3(-3.0, 2.0, 7.0)
	for yaw: float in [0.0, 45.0, 137.0]:
		for pitch: float in [15.0, 35.264, 80.0]:
			var pos := TopDownCameraScript.desired_position(
				target, yaw, pitch, 120.0)
			assert_float(pos.distance_to(target)) \
				.override_failure_message(
					"yaw %.0f pitch %.1f changed the view distance" % [yaw, pitch]) \
				.is_equal_approx(120.0, EPS)


func test_true_isometric_pitch_places_camera_at_equal_offsets() -> void:
	# atan(1/sqrt(2)) ~ 35.264 deg is what makes the view ISOMETRIC rather than
	# just tilted: at that pitch the camera's height equals its horizontal
	# distance divided by sqrt(2), which is what projects the three world axes
	# 120 degrees apart on screen. Pinning it stops the constant being "tidied"
	# to 45 and quietly turning the look dimetric.
	var pos := TopDownCameraScript.desired_position(
		Vector3.ZERO, 45.0, 35.264, 120.0)
	var horizontal := Vector2(pos.x, pos.z).length()
	assert_float(horizontal / pos.y) \
		.override_failure_message("pitch is no longer true isometric") \
		.is_equal_approx(sqrt(2.0), 0.001)


func test_yaw_45_looks_from_between_two_axes() -> void:
	# The three-quarter view: at 45 degrees the camera is offset equally along X
	# and Z, so neither street direction is seen exactly end-on.
	var pos := TopDownCameraScript.desired_position(
		Vector3.ZERO, 45.0, 35.264, 120.0)
	assert_float(pos.x) \
		.override_failure_message("45 deg must offset equally in X and Z") \
		.is_equal_approx(pos.z, EPS)
	assert_float(pos.x).is_greater(0.0)


func test_framing_follows_the_target() -> void:
	# Moving the car must translate the camera by exactly the same vector: the
	# offset is rigid, so the world slides under a car that stays put on screen.
	var a := TopDownCameraScript.desired_position(
		Vector3.ZERO, 45.0, 35.264, 120.0)
	var b := TopDownCameraScript.desired_position(
		Vector3(100.0, 0.0, -250.0), 45.0, 35.264, 120.0)
	assert_vector(b - a) \
		.override_failure_message("camera offset must be rigid") \
		.is_equal_approx(Vector3(100.0, 0.0, -250.0), Vector3.ONE * EPS)


func test_zero_distance_degenerates_to_the_target() -> void:
	# Guard the boundary rather than leave it to chance: a zero view distance
	# must not produce a NaN direction.
	var pos := TopDownCameraScript.desired_position(
		Vector3(5.0, 1.0, 2.0), 45.0, 35.264, 0.0)
	assert_bool(is_nan(pos.x) or is_nan(pos.y) or is_nan(pos.z)) \
		.override_failure_message("degenerate distance produced NaN") \
		.is_false()


func test_camera_is_orthogonal_and_world_aligned() -> void:
	# The two properties that make this ISOMETRIC rather than a second chase cam:
	# an orthogonal projection (no perspective divide, so equal-height buildings
	# draw equal-sized), and no inheritance of the car's yaw.
	var cam: Camera3D = TopDownCameraScript.new()
	auto_free(cam)
	var target := Node3D.new()
	auto_free(target)
	add_child(target)
	add_child(cam)
	cam.target_path = cam.get_path_to(target)
	cam._ready()

	assert_int(cam.projection) \
		.override_failure_message("top-down camera must be orthogonal") \
		.is_equal(Camera3D.PROJECTION_ORTHOGONAL)

	# Rotating the target must not rotate the camera's framing direction.
	var before := cam.global_position
	target.rotation = Vector3(0.0, deg_to_rad(90.0), 0.0)
	cam.snap_to_target()
	assert_vector(cam.global_position) \
		.override_failure_message("camera must not yaw with its target") \
		.is_equal_approx(before, Vector3.ONE * EPS)
