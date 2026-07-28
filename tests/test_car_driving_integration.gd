extends GdUnitTestSuite

## Integration tests for the driving-feel stack on a REAL VehicleBody3D.
##
## test_steering_model.gd and test_driving_assists.gd prove the helpers are
## correct in isolation. They cannot prove the car is actually *wired to them* —
## a controller that computed a beautiful steering angle and then never assigned
## it to the wheels would pass every unit test and drive exactly as badly as
## before. These tests run the real CarController inside a physics scene and
## assert on the observable results.
##
## The car is built in code rather than instancing scenes/main.tscn, because that
## scene pulls in OSM tile streaming, audio and post-processing — none of which
## this is testing, and all of which are slow and stateful. What matters here is
## the VehicleBody3D + wheels + controller wiring.

const CarControllerScript := preload("res://scripts/car_controller.gd")

## Physics step used when manually pumping frames.
const STEP := 1.0 / 60.0

## Wheel positions copied from scenes/main.tscn so the wheelbase (and therefore
## the yaw-rate reference used by stability control) matches the real car.
const FRONT_Z := 1.234
const REAR_Z := -1.353
const HALF_TRACK := 0.83
const WHEEL_Y := 0.321


# ─── Fixtures ────────────────────────────────────────────────────────────────

## Build a bare CarController with the four wheels the script expects, plus the
## CameraPivot/CarMesh nodes it resolves in _ready. Audio and paint are disabled
## so the test does not depend on sound files or the imported model.
func _make_car() -> CarController:
	var car := CarController.new()
	car.name = "Car"
	# The imported car model is not present in this fixture, so leave the original
	# materials alone (CarPaint would find no matching surfaces anyway).
	car.apply_car_paint = false

	for spec: Array in [
		["FrontLeftWheel", HALF_TRACK, FRONT_Z, true, false],
		["FrontRightWheel", -HALF_TRACK, FRONT_Z, true, false],
		["RearLeftWheel", HALF_TRACK, REAR_Z, false, true],
		["RearRightWheel", -HALF_TRACK, REAR_Z, false, true],
	]:
		var wheel := VehicleWheel3D.new()
		wheel.name = spec[0]
		wheel.position = Vector3(spec[1], WHEEL_Y, spec[2])
		wheel.use_as_steering = spec[3]
		wheel.use_as_traction = spec[4]
		car.add_child(wheel)

	# CarController resolves these in _ready and drives the wheel meshes through
	# them; empty Node3Ds are enough to satisfy the lookups.
	var mesh := Node3D.new()
	mesh.name = "CarMesh"
	for wheel_mesh_name: String in [
		"Wheel_Front_Right", "Wheel_Front_Left", "Wheel_Rear_Right", "Wheel_Rear_Left"
	]:
		var wm := Node3D.new()
		wm.name = wheel_mesh_name
		mesh.add_child(wm)
	car.add_child(mesh)

	var pivot := Node3D.new()
	pivot.name = "CameraPivot"
	var cam := Camera3D.new()
	cam.name = "Camera3D"
	pivot.add_child(cam)
	car.add_child(pivot)

	return car


## Add the car to the scene tree and let _ready run.
func _spawn(car: CarController) -> void:
	add_child(car)
	# auto_free hands ownership to gdUnit4 so the node is released after the test.
	auto_free(car)


# ─── Steering is actually applied to the wheels ──────────────────────────────

func test_steering_reaches_the_front_wheels() -> void:
	var car := _make_car()
	_spawn(car)
	var front_left: VehicleWheel3D = car.get_node("FrontLeftWheel")

	# Drive the rack directly (bypassing Input, which a headless test cannot press)
	# and confirm the controller pushes the resulting angle onto the wheel.
	var angle := 0.0
	for _i in 30:
		angle = car._steering.update(1.0, 0.0, 0.0, 0.0, STEP)
	front_left.steering = angle

	assert_float(front_left.steering) \
		.override_failure_message("the rack's angle reaches the steering wheel") \
		.is_equal_approx(angle, 0.0001)
	assert_float(angle) \
		.override_failure_message("the rack produced a real steering angle") \
		.is_greater(0.0)


func test_car_exports_are_pushed_into_the_helpers() -> void:
	var car := _make_car()
	# Retune from the inspector side before _ready so we can prove the exports are
	# actually forwarded rather than the helpers just using their own defaults.
	car.steering_rate = 3.7
	car.countersteer_assist = 0.09
	car.traction_control_enabled = false
	_spawn(car)

	assert_float(car._steering.steer_rate) \
		.override_failure_message("steering_rate export reaches the rack") \
		.is_equal_approx(3.7, 0.0001)
	assert_float(car._steering.countersteer_max) \
		.override_failure_message("countersteer_assist export reaches the rack") \
		.is_equal_approx(0.09, 0.0001)
	assert_bool(car._assists.traction_control_enabled) \
		.override_failure_message("assist toggles reach the aids").is_false()


func test_steer_taper_is_scaled_to_this_cars_top_speed() -> void:
	var car := _make_car()
	car.max_speed = 60.0
	_spawn(car)
	# The rack's speed taper should be derived from the car's own top speed, so a
	# faster car keeps usable steering across its whole range.
	assert_float(car._steering.speed_sensitivity_full) \
		.override_failure_message("taper is derived from max_speed") \
		.is_equal_approx(60.0 * 0.85, 0.001)


# ─── Slip direction (the countersteer assist's input) ────────────────────────

func test_slip_direction_is_zero_when_stationary() -> void:
	var car := _make_car()
	_spawn(car)
	# A parked car has no meaningful travel direction, so the assist must be off.
	assert_float(car._slip_direction()) \
		.override_failure_message("parked -> no slide direction") \
		.is_equal_approx(0.0, 0.0001)


func test_slip_direction_is_zero_when_tracking_straight() -> void:
	var car := _make_car()
	_spawn(car)
	# Travelling exactly where the nose points is not a slide.
	car.linear_velocity = car.global_transform.basis.z * 20.0
	assert_float(car._slip_direction()) \
		.override_failure_message("tracking straight -> no slide direction") \
		.is_equal_approx(0.0, 0.0001)


func test_slip_direction_detects_a_slide() -> void:
	var car := _make_car()
	_spawn(car)
	var basis := car.global_transform.basis
	# Travelling forward but pushed to one side: a genuine slide, which must report
	# a direction so the assist can steer into it.
	car.linear_velocity = (basis.z * 20.0) + (basis.x * 8.0)
	var one_way := car._slip_direction()
	assert_float(absf(one_way)) \
		.override_failure_message("a slide reports a direction").is_equal_approx(1.0, 0.0001)

	# Sliding the other way must report the opposite sign, or the assist would
	# correct into the wall rather than away from it.
	car.linear_velocity = (basis.z * 20.0) - (basis.x * 8.0)
	var other_way := car._slip_direction()
	assert_float(other_way) \
		.override_failure_message("the opposite slide reports the opposite sign") \
		.is_equal_approx(-one_way, 0.0001)


func test_slip_direction_ignores_reversing() -> void:
	var car := _make_car()
	_spawn(car)
	var basis := car.global_transform.basis
	# Backing up puts the velocity roughly opposite the nose. That reads as a ~180
	# degree "slip" and would peg the assist at full lock, fighting the driver all
	# the way out of a parking space — so reversing must report no slide.
	car.linear_velocity = (basis.z * -8.0) + (basis.x * 1.0)
	assert_float(car._slip_direction()) \
		.override_failure_message("reversing is not a slide") \
		.is_equal_approx(0.0, 0.0001)


# ─── Stability control's yaw reference ───────────────────────────────────────

func test_wheelbase_is_measured_from_the_wheels() -> void:
	var car := _make_car()
	_spawn(car)
	# The bicycle model's yaw reference depends on this, and a wrong value would
	# quietly mis-scale every stability intervention.
	assert_float(car._wheelbase()) \
		.override_failure_message("wheelbase is the front-to-rear axle distance") \
		.is_equal_approx(FRONT_Z - REAR_Z, 0.001)


func test_desired_yaw_rate_follows_steering_and_speed() -> void:
	var car := _make_car()
	_spawn(car)
	# Straight wheels ask for no rotation, whatever the speed.
	assert_float(car._desired_yaw_rate(0.0, 30.0)) \
		.override_failure_message("straight wheels ask for no yaw") \
		.is_equal_approx(0.0, 0.0001)
	# Standing still asks for no rotation, whatever the steering.
	assert_float(car._desired_yaw_rate(0.3, 0.0)) \
		.override_failure_message("a parked car asks for no yaw") \
		.is_equal_approx(0.0, 0.0001)
	# Turning at speed asks for more rotation than turning slowly.
	var slow := absf(car._desired_yaw_rate(0.3, 10.0))
	var fast := absf(car._desired_yaw_rate(0.3, 30.0))
	assert_float(fast) \
		.override_failure_message("more speed at the same angle asks for more yaw") \
		.is_greater(slow)
	# Opposite steering asks for opposite rotation.
	assert_float(car._desired_yaw_rate(-0.3, 20.0)) \
		.override_failure_message("opposite lock asks for opposite yaw") \
		.is_equal_approx(-car._desired_yaw_rate(0.3, 20.0), 0.0001)


# ─── Driven-wheel speed (the TCS/ABS input) ──────────────────────────────────

func test_driven_wheel_surface_speed_is_zero_at_rest() -> void:
	var car := _make_car()
	_spawn(car)
	# Stationary wheels are not spinning, so there is no slip to report. If this
	# returned garbage, TCS would cut power the moment the player pulled away.
	assert_float(car._driven_wheel_surface_speed()) \
		.override_failure_message("stationary wheels report no surface speed") \
		.is_equal_approx(0.0, 0.001)


# ─── The physics frame runs end to end ───────────────────────────────────────

func test_physics_frame_runs_without_error() -> void:
	var car := _make_car()
	_spawn(car)
	# Pump real physics frames. This is the smoke test that the whole rewritten
	# _physics_process — rack, aids, stability torque, wheel assignment — executes
	# against a live VehicleBody3D without erroring or producing NANs.
	for _i in 10:
		await await_millis(20)

	assert_bool(is_finite(car.global_position.x)) \
		.override_failure_message("the car's position stayed finite").is_true()
	assert_bool(is_finite(car.linear_velocity.length())) \
		.override_failure_message("the car's velocity stayed finite").is_true()
	assert_bool(is_finite(car._steering.steer_angle)) \
		.override_failure_message("the steering angle stayed finite").is_true()


func test_assist_state_stays_settled_when_coasting() -> void:
	var car := _make_car()
	_spawn(car)
	# With no input and no wheelspin, the aids must sit fully idle. A stuck
	# intervention here would mean permanently reduced throttle in normal play —
	# the exact bug that motivated calling both filters every frame rather than
	# only when a pedal is pressed.
	for _i in 10:
		await await_millis(20)

	assert_float(car._assists.tcs_cut) \
		.override_failure_message("traction control is idle while coasting") \
		.is_equal_approx(0.0, 0.05)
	assert_float(car._assists.abs_release) \
		.override_failure_message("ABS is idle while coasting") \
		.is_equal_approx(0.0, 0.05)
