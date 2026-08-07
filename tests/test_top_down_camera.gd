extends GdUnitTestSuite

## Tests for the isometric top-down camera's framing maths.
##
## The placement is a pure static function precisely so it can be checked by
## arithmetic rather than by looking at a screenshot: "the camera is above and
## behind the car" is the sort of claim that a rendered picture makes easy to
## believe and hard to verify.

const TopDownCameraScript := preload("res://scripts/top_down_camera.gd")

const EPS := 0.001

## True isometric pitch, atan(1/sqrt(2)) in degrees.
const ISO_PITCH := 35.264


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


# ─── Orientation ─────────────────────────────────────────────────────────────
#
# The framing direction is computed from the angles rather than delegated to
# look_at(), so that a camera lagging behind a moving car cannot roll the world
# while it catches up. These pin the properties that keeps.

func test_basis_is_orthonormal_at_every_pitch() -> void:
	# An orthonormal basis is what guarantees the view is neither sheared nor
	# scaled — the thing a hand-built basis can get wrong and look_at() could not.
	for pitch: float in [0.0, 20.0, ISO_PITCH, 60.0]:
		for yaw: float in [0.0, 45.0, 200.0]:
			var basis := TopDownCameraScript.desired_basis(yaw, pitch)
			var label := "yaw %.0f pitch %.0f" % [yaw, pitch]
			assert_float(basis.x.length()) \
				.override_failure_message("%s: x axis not unit length" % label) \
				.is_equal_approx(1.0, EPS)
			assert_float(basis.y.length()) \
				.override_failure_message("%s: y axis not unit length" % label) \
				.is_equal_approx(1.0, EPS)
			assert_float(basis.z.length()) \
				.override_failure_message("%s: z axis not unit length" % label) \
				.is_equal_approx(1.0, EPS)
			assert_float(basis.x.dot(basis.y)) \
				.override_failure_message("%s: axes not perpendicular" % label) \
				.is_equal_approx(0.0, EPS)
			assert_float(basis.x.dot(basis.z)) \
				.override_failure_message("%s: axes not perpendicular" % label) \
				.is_equal_approx(0.0, EPS)
			assert_float(basis.determinant()) \
				.override_failure_message("%s: basis is not right-handed" % label) \
				.is_equal_approx(1.0, EPS)


func test_camera_looks_back_at_where_it_was_placed() -> void:
	# Position and orientation are computed separately from the same angles, so
	# they could silently disagree. -Z is the direction a Godot camera looks; it
	# must point from the camera straight back at the target.
	for pitch: float in [ISO_PITCH, 60.0]:
		for yaw: float in [0.0, 45.0, -120.0]:
			var target := Vector3(4.0, 1.0, -9.0)
			var pos := TopDownCameraScript.desired_position(target, yaw, pitch, 120.0)
			var forward := -TopDownCameraScript.desired_basis(yaw, pitch).z
			assert_vector(pos + forward * 120.0) \
				.override_failure_message(
					"yaw %.0f pitch %.0f: camera does not look at its target"
					% [yaw, pitch]) \
				.is_equal_approx(target, Vector3.ONE * EPS)


func test_horizon_never_rolls() -> void:
	# Screen-right must stay level at every angle. If the X axis picked up a Y
	# component the whole world would tilt, which reads as a bug rather than as
	# a camera angle.
	for pitch: float in [0.0, ISO_PITCH, 60.0]:
		for yaw: float in [0.0, 45.0, 137.0, 300.0]:
			assert_float(TopDownCameraScript.desired_basis(yaw, pitch).x.y) \
				.override_failure_message(
					"yaw %.0f pitch %.0f rolled the horizon" % [yaw, pitch]) \
				.is_equal_approx(0.0, EPS)


func test_lagging_behind_the_car_does_not_roll_the_world() -> void:
	# The regression this replaced look_at() for. The camera eases toward its
	# target, so a moving car sits off-centre for a few frames; look_at() would
	# rotate the view to re-centre it, swinging the whole map for what is only a
	# positional lag. The orientation must depend on the ANGLES alone.
	var cam: Camera3D = TopDownCameraScript.new()
	auto_free(cam)
	var target := Node3D.new()
	auto_free(target)
	add_child(target)
	add_child(cam)
	cam.target_path = cam.get_path_to(target)
	cam._ready()
	cam.current = true
	cam.set_process(false)
	var settled := cam.global_basis

	# Jump the car far enough that the smoothing cannot possibly keep up, then
	# run frames while it chases.
	target.global_position = Vector3(300.0, 0.0, 300.0)
	for i in 5:
		cam._process(1.0 / 60.0)
		assert_vector(cam.global_basis.z) \
			.override_failure_message("frame %d: catching up rolled the view" % i) \
			.is_equal_approx(settled.z, Vector3.ONE * EPS)
