extends GdUnitTestSuite

## Tests for the overhead cameras' framing maths.
##
## One script backs two of the game's three camera modes, differing only in their
## exported angles and the follow_heading flag:
##
##   isometric   pitch 35.264, follow_heading OFF — world-aligned map view.
##   top-down    pitch 90,     follow_heading ON  — straight down, nose up.
##
## The placement and orientation are pure static functions precisely so they can
## be checked by arithmetic rather than by looking at a screenshot: "the camera is
## above and behind the car" and "the car's nose points up the screen" are exactly
## the sort of claims a rendered picture makes easy to believe and hard to verify.

const TopDownCameraScript := preload("res://scripts/top_down_camera.gd")

const EPS := 0.001

## True isometric pitch, atan(1/sqrt(2)) in degrees.
const ISO_PITCH := 35.264

## Straight down — the pitch that defines the top-down mode and the one that
## look_at() cannot express.
const TOP_PITCH := 90.0


# ─── Fixtures ────────────────────────────────────────────────────────────────

## Build a live camera following a target, wired up as the scene does.
## Returns [camera, target]; both are auto-freed.
func _make_camera(pitch: float, follow_heading: bool) -> Array:
	var cam: Camera3D = TopDownCameraScript.new()
	auto_free(cam)
	var target := Node3D.new()
	auto_free(target)
	add_child(target)
	add_child(cam)
	cam.target_path = cam.get_path_to(target)
	cam.pitch_degrees = pitch
	cam.follow_heading = follow_heading
	cam.yaw_degrees = 45.0 if not follow_heading else 0.0
	cam._ready()
	# Drive _process by hand so a frame ticking by mid-test can't ease the yaw
	# further than the test thinks it has.
	cam.set_process(false)
	return [cam, target]


## Point a Node3D's forward (+Z, the VehicleBody3D convention the car uses) at
## the given compass angle, measured from +Z toward +X.
func _face(target: Node3D, degrees: float) -> void:
	target.global_basis = Basis(Vector3.UP, deg_to_rad(degrees))


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
	var made := _make_camera(ISO_PITCH, false)
	var cam: Camera3D = made[0]
	var target: Node3D = made[1]

	assert_int(cam.projection) \
		.override_failure_message("top-down camera must be orthogonal") \
		.is_equal(Camera3D.PROJECTION_ORTHOGONAL)

	# Rotating the target must not rotate the camera's framing direction.
	var before := cam.global_position
	_face(target, 90.0)
	cam.snap_to_target()
	assert_vector(cam.global_position) \
		.override_failure_message("camera must not yaw with its target") \
		.is_equal_approx(before, Vector3.ONE * EPS)


# ─── Straight-down orientation ───────────────────────────────────────────────
#
# The third camera mode is defined by the one angle look_at() cannot express, so
# these tests exist mainly to stop a future simplification back to look_at().

func test_straight_down_camera_is_directly_above_its_target() -> void:
	# Pitch 90 must put the camera on the target's vertical axis, whatever the
	# yaw: at straight down, yaw only spins the view, it must not slide it.
	for yaw: float in [0.0, 45.0, 137.0, -90.0]:
		var pos := TopDownCameraScript.desired_position(
			Vector3(12.0, 3.0, -8.0), yaw, TOP_PITCH, 120.0)
		assert_vector(Vector3(pos.x, 0.0, pos.z)) \
			.override_failure_message(
				"yaw %.0f slid the straight-down camera off its target" % yaw) \
			.is_equal_approx(Vector3(12.0, 0.0, -8.0), Vector3.ONE * EPS)
		assert_float(pos.y) \
			.override_failure_message("straight down must be straight UP from the car") \
			.is_equal_approx(123.0, EPS)


func test_basis_is_valid_where_look_at_degenerates() -> void:
	# The whole reason the orientation is computed rather than delegated to
	# look_at(): at pitch 90 the view direction is parallel to the up vector
	# look_at() needs, so it has no basis to build. This must still be a clean,
	# right-handed, orthonormal frame with no NaNs.
	var basis := TopDownCameraScript.desired_basis(0.0, TOP_PITCH)
	assert_bool(is_nan(basis.x.x) or is_nan(basis.y.y) or is_nan(basis.z.z)) \
		.override_failure_message("straight-down basis produced NaN") \
		.is_false()
	assert_float(basis.determinant()) \
		.override_failure_message("basis must be right-handed and unit-scaled") \
		.is_equal_approx(1.0, EPS)


func test_basis_is_orthonormal_at_every_pitch() -> void:
	# An orthonormal basis is what guarantees the view is neither sheared nor
	# scaled. Checked across the range because the straight-down case is built
	# by the same code as the isometric one and both must stay clean.
	for pitch: float in [0.0, 20.0, ISO_PITCH, 60.0, TOP_PITCH]:
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


func test_camera_looks_back_at_where_it_was_placed() -> void:
	# Position and orientation are computed separately from the same angles, so
	# they could silently disagree. -Z is the direction a Godot camera looks; it
	# must point from the camera straight back at the target.
	for pitch: float in [ISO_PITCH, 60.0, TOP_PITCH]:
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
	for pitch: float in [0.0, ISO_PITCH, TOP_PITCH]:
		for yaw: float in [0.0, 45.0, 137.0, 300.0]:
			assert_float(TopDownCameraScript.desired_basis(yaw, pitch).x.y) \
				.override_failure_message(
					"yaw %.0f pitch %.0f rolled the horizon" % [yaw, pitch]) \
				.is_equal_approx(0.0, EPS)


func test_camera_is_never_upside_down() -> void:
	# Screen-up must keep a non-negative world Y across the usable pitch range,
	# or the view flips over.
	for pitch: float in [0.0, 20.0, ISO_PITCH, 60.0, TOP_PITCH]:
		assert_float(TopDownCameraScript.desired_basis(30.0, pitch).y.y) \
			.override_failure_message("pitch %.0f filmed the world upside down" % pitch) \
			.is_greater_equal(-EPS)


# ─── Heading follow ──────────────────────────────────────────────────────────
#
# What separates the top-down mode from the isometric one: the car's nose is
# pinned to screen-up and the world sweeps around it.

func test_heading_yaw_puts_the_nose_up_the_screen() -> void:
	# The defining claim of the top-down mode, checked as arithmetic: whichever
	# way the car faces, projecting its forward vector through the camera basis
	# must come out pointing up the screen (+Y in view space).
	for heading: float in [0.0, 45.0, 90.0, 180.0, -137.0, 359.0]:
		var forward := Basis(Vector3.UP, deg_to_rad(heading)) * Vector3.FORWARD * -1.0
		var yaw := TopDownCameraScript.heading_yaw_degrees(forward, 0.0)
		var basis := TopDownCameraScript.desired_basis(yaw, TOP_PITCH)
		# Express the car's forward in the camera's frame. X is screen-right and
		# Y is screen-up, so a nose-up view means no sideways component.
		var in_view := basis.inverse() * forward
		assert_float(in_view.x) \
			.override_failure_message(
				"heading %.0f: nose drifted off screen-vertical" % heading) \
			.is_equal_approx(0.0, EPS)
		assert_float(in_view.y) \
			.override_failure_message(
				"heading %.0f: nose points DOWN the screen, not up" % heading) \
			.is_greater(0.0)


func test_heading_yaw_places_the_camera_behind_the_car() -> void:
	# At a shallow pitch the same convention must put the camera behind the car
	# rather than in front of it staring back — the sign error that would look
	# right in a straight-down view and be obviously wrong in any other.
	var forward := Vector3(0.0, 0.0, 1.0)
	var yaw := TopDownCameraScript.heading_yaw_degrees(forward, 0.0)
	var pos := TopDownCameraScript.desired_position(Vector3.ZERO, yaw, ISO_PITCH, 120.0)
	assert_float(pos.z) \
		.override_failure_message("camera must sit behind a car facing +Z") \
		.is_less(0.0)


func test_vertical_forward_falls_back_instead_of_snapping() -> void:
	# A car standing perfectly on its nose has no horizontal heading. Deriving
	# one anyway would mean atan2(0, 0) and a view that snaps to an arbitrary
	# bearing mid-wheelie, so the last good angle is held instead.
	assert_float(TopDownCameraScript.heading_yaw_degrees(Vector3.UP, 137.0)) \
		.override_failure_message("vertical forward must hold the previous yaw") \
		.is_equal_approx(137.0, EPS)
	assert_float(TopDownCameraScript.heading_yaw_degrees(Vector3.ZERO, -42.0)) \
		.override_failure_message("zero forward must hold the previous yaw") \
		.is_equal_approx(-42.0, EPS)


func test_pitch_does_not_affect_the_heading_answer() -> void:
	# The heading is a compass bearing, so a car climbing a hill must produce the
	# same yaw as one on the flat. Otherwise the view would swing as the car
	# crests a bridge.
	var flat := TopDownCameraScript.heading_yaw_degrees(Vector3(1.0, 0.0, 1.0), 0.0)
	var climbing := TopDownCameraScript.heading_yaw_degrees(Vector3(1.0, 5.0, 1.0), 0.0)
	assert_float(climbing) \
		.override_failure_message("pitching the car must not yaw the camera") \
		.is_equal_approx(flat, EPS)


func test_heading_following_camera_yaws_with_its_target() -> void:
	# The live counterpart to test_camera_is_orthogonal_and_world_aligned: this
	# mode must do the OPPOSITE and track the car around.
	var made := _make_camera(TOP_PITCH, true)
	var cam: Camera3D = made[0]
	var target: Node3D = made[1]

	_face(target, 0.0)
	cam.snap_to_target()
	# Watched through the X axis (screen-right), not Z: at pitch 90 the view
	# direction is straight down whatever the yaw, so Z cannot see this rotation
	# at all and the test would pass on a camera that never turned.
	var before := cam.global_basis.x
	_face(target, 90.0)
	cam.snap_to_target()
	assert_float(cam.global_basis.x.angle_to(before)) \
		.override_failure_message("heading-following camera failed to yaw with the car") \
		.is_equal_approx(deg_to_rad(90.0), 0.01)


func test_heading_follow_eases_rather_than_snapping() -> void:
	# Rotation is the most nauseating thing a camera can do, so the yaw is eased.
	# One frame of a 90 degree turn must move the view part of the way, not all
	# of it — and must move it at all, or the mode would never turn.
	var made := _make_camera(TOP_PITCH, true)
	var cam: Camera3D = made[0]
	var target: Node3D = made[1]

	_face(target, 0.0)
	cam.snap_to_target()
	var start := cam.global_basis.x
	_face(target, 90.0)
	cam.current = true
	cam._process(1.0 / 60.0)
	var moved := cam.global_basis.x.angle_to(start)
	assert_float(moved) \
		.override_failure_message("eased yaw did not move at all") \
		.is_greater(0.0)
	assert_float(moved) \
		.override_failure_message("yaw snapped instead of easing") \
		.is_less(deg_to_rad(90.0))


func test_eased_yaw_takes_the_short_way_round_the_wrap() -> void:
	# Crossing the +/-180 boundary is where a plain lerp spins the entire world
	# through half a turn to make a small correction. Two headings 10 degrees
	# apart must move the view by less than 10 degrees in a frame — not by a
	# fraction of the 350 the long way round.
	#
	# The camera sits BEHIND the car, so its yaw is the heading plus 180: it is
	# headings either side of due north (not due south) that straddle the wrap in
	# camera space, which is the boundary lerp_angle has to handle.
	var made := _make_camera(TOP_PITCH, true)
	var cam: Camera3D = made[0]
	var target: Node3D = made[1]

	_face(target, 5.0)
	cam.snap_to_target()
	assert_float(absf(cam._yaw_deg)) \
		.override_failure_message("test setup is not straddling the wrap") \
		.is_greater(170.0)
	var start := cam.global_basis.x
	_face(target, -5.0)
	cam.current = true
	cam._process(1.0 / 60.0)
	# One eased frame of the true 10 degree correction is well under 10; one eased
	# frame of the 350 degree long way round would be over 20.
	assert_float(cam.global_basis.x.angle_to(start)) \
		.override_failure_message("yaw took the long way round the wrap") \
		.is_less(deg_to_rad(10.0))


func test_world_aligned_camera_ignores_heading_lerp() -> void:
	# follow_heading off must mean truly fixed: running frames while the car spins
	# must leave the framing direction untouched, not merely slow to drift.
	var made := _make_camera(ISO_PITCH, false)
	var cam: Camera3D = made[0]
	var target: Node3D = made[1]
	cam.current = true
	var before := cam.global_basis

	for i in 30:
		_face(target, i * 12.0)
		cam._process(1.0 / 60.0)

	assert_vector(cam.global_basis.z) \
		.override_failure_message("world-aligned camera drifted with the car") \
		.is_equal_approx(before.z, Vector3.ONE * EPS)


func test_activation_is_a_cut_not_a_swoop() -> void:
	# snap_to_target exists so a mode change is instant. Left where the previous
	# mode abandoned it, the camera would visibly slide across the map on every
	# press of T.
	var made := _make_camera(TOP_PITCH, true)
	var cam: Camera3D = made[0]
	var target: Node3D = made[1]

	target.global_position = Vector3(500.0, 0.0, -250.0)
	cam.global_position = Vector3.ZERO
	cam.snap_to_target()
	assert_vector(cam.global_position) \
		.override_failure_message("activation did not cut straight to the car") \
		.is_equal_approx(
			TopDownCameraScript.desired_position(
				target.global_position, cam.yaw_degrees, TOP_PITCH, cam.view_distance),
			Vector3.ONE * EPS)
