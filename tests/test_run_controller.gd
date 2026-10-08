extends GdUnitTestSuite

## RunController: a Kudos Attack run against a real car body, from the line to
## the results card and back again.

const RunControllerScript := preload("res://scripts/run_controller.gd")
const RunSessionScript := preload("res://scripts/run_session.gd")
const ProfileStoreScript := preload("res://scripts/profile_store.gd")
const CarFixture := preload("res://tests/fixtures/car_fixture.gd")
const PROFILE := "user://_test_run_profile.cfg"


func before_test() -> void:
	DirAccess.remove_absolute(ProjectSettings.globalize_path(PROFILE))


func after_test() -> void:
	get_tree().paused = false
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(PROFILE))


func _setup(duration: float = 1.0) -> Array:
	var car := CarFixture.make_car()
	add_child(car)
	auto_free(car)
	car.teleport(Vector3(10, 0, 20), Vector3.LEFT)
	var run: RunControllerScript = RunControllerScript.new()
	run.car = car
	run.profile_path = PROFILE
	run.session.duration = duration
	add_child(run)
	auto_free(run)
	return [run, car]


func test_the_car_is_held_at_the_line_until_go() -> void:
	var parts := _setup()
	var run: RunControllerScript = parts[0]
	var car: CarController = parts[1]
	run.begin()
	assert_bool(car.input_locked).is_true()
	run._process(1.0)
	assert_bool(car.input_locked).is_true()
	run._process(2.5)
	assert_bool(car.input_locked).is_false()
	assert_bool(run.session.is_running()).is_true()


func test_the_end_of_the_clock_saves_the_result_and_shows_it() -> void:
	var parts := _setup()
	var run: RunControllerScript = parts[0]
	run.begin()
	run._process(3.5)
	run.record_event("DRIFT", 40, false)
	run._process(2.0)
	var paused := get_tree().paused
	get_tree().paused = false

	assert_bool(paused).override_failure_message("world pauses behind the results").is_true()
	assert_bool(run.is_showing_results()).is_true()
	assert_int(run.session.drifts).is_equal(1)
	var profile := ProfileStoreScript.new(PROFILE)
	assert_int(profile.runs(RunSessionScript.record_key(RunSessionScript.Mode.KUDOS_ATTACK))).is_equal(1)


func test_retry_restarts_from_the_same_line() -> void:
	var parts := _setup()
	var run: RunControllerScript = parts[0]
	var car: CarController = parts[1]
	run.begin()
	run._process(3.5)
	car.input_locked = false
	car.teleport(Vector3(200, 0, -50), Vector3.FORWARD)
	run._process(2.0)

	run._results.retry_pressed.emit()

	assert_bool(get_tree().paused).is_false()
	assert_bool(run.is_showing_results()).is_false()
	assert_int(run.session.state).is_equal(RunSessionScript.State.COUNTDOWN)
	assert_bool(car.input_locked).is_true()
	assert_float(car.global_position.x).is_equal_approx(10.0, 0.001)
	assert_float(car.global_position.z).is_equal_approx(20.0, 0.001)


func test_keep_driving_hands_back_to_free_drive() -> void:
	var parts := _setup()
	var run: RunControllerScript = parts[0]
	run.begin()
	run._process(3.5)
	run._process(2.0)
	var requested: Array[bool] = []
	run.free_drive_requested.connect(func() -> void: requested.append(true))

	run._results.free_drive_pressed.emit()

	assert_bool(get_tree().paused).is_false()
	assert_int(requested.size()).is_equal(1)


## A car held at the line with its wheels on the ground must still drive at GO.
## Holding it with `freeze` left VehicleWheel3D's rpm NaN (in a rendered run),
## which turned the whole body NaN the moment it was released: the screen went
## blue. It is held by locking the controls instead, which keeps it unfrozen.
func test_the_car_drives_off_the_line_after_the_countdown() -> void:
	var ground := StaticBody3D.new()
	var shape := CollisionShape3D.new()
	var box := BoxShape3D.new()
	box.size = Vector3(200, 1, 200)
	shape.shape = box
	ground.add_child(shape)
	ground.position = Vector3(0, -0.5, 0)
	add_child(ground)
	auto_free(ground)
	var parts := _setup(10.0)
	var run: RunControllerScript = parts[0]
	var car: CarController = parts[1]
	run.session.countdown_time = 0.5
	car.teleport(Vector3(0, 0.6, 0), Vector3.BACK)
	for _i in 60:
		await get_tree().physics_frame
	assert_bool(car.front_left_wheel.is_in_contact()).is_true()

	run.begin()
	# Throttle held through the countdown, as an eager player would.
	Input.action_press("move_forward")
	for _i in 20:
		await get_tree().physics_frame
	assert_bool(car.freeze) \
		.override_failure_message("a grounded car is held by its brakes, not frozen").is_false()
	assert_float(absf(car.global_position.z)).is_less(0.05)
	for _i in 40:
		await get_tree().physics_frame
	assert_bool(run.session.is_running()).is_true()
	for _i in 60:
		await get_tree().physics_frame
	Input.action_release("move_forward")

	assert_bool(car.global_transform.origin.is_finite()).is_true()
	assert_float(car.global_position.z).is_greater(0.5)
