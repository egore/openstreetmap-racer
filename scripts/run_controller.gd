extends Node

## Runs a timed mode (Kudos Attack) in the world: holds the car at the line for
## the countdown, keeps the clock, ends the run, saves the result and offers a
## retry from the same start.
##
## main.gd creates one for timed modes and forwards the car's kudos events. The
## run logic itself is RunSession; this node is the glue between it, the car and
## the two overlays.

const RunSessionScript := preload("res://scripts/run_session.gd")
const ProfileStoreScript := preload("res://scripts/profile_store.gd")
const SceneFlowScript := preload("res://scripts/scene_flow.gd")
const RunHudScript := preload("res://scripts/run_hud.gd")
const ResultsScreenScript := preload("res://scripts/results_screen.gd")

## The player chose to keep driving without the clock; main drops back to free
## drive and frees this node.
signal free_drive_requested

var mode: RunSessionScript.Mode = RunSessionScript.Mode.KUDOS_ATTACK
var car: CarController
var session := RunSessionScript.new()
## Where records go. Tests point this at a scratch file before _ready.
var profile_path: String = ProfileStoreScript.DEFAULT_PATH

var _hud: RunHudScript
var _results: ResultsScreenScript
var _start_position: Vector3
var _start_forward: Vector3


func _ready() -> void:
	# Ticks only while the tree runs, but must keep handling the results card
	# while the world behind it is paused.
	process_mode = Node.PROCESS_MODE_ALWAYS
	_hud = RunHudScript.new()
	_hud.name = "RunHud"
	add_child(_hud)
	_hud.set_mode_name(RunSessionScript.mode_name(mode))
	_hud.set_time(session.duration)
	_results = ResultsScreenScript.new()
	_results.name = "Results"
	add_child(_results)
	_results.retry_pressed.connect(_on_retry)
	_results.free_drive_pressed.connect(_on_free_drive)
	_results.main_menu_pressed.connect(SceneFlowScript.go_to_title.bind(get_tree()))


## Start the first run from wherever the car stands now.
func begin() -> void:
	_start_position = car.global_position
	_start_forward = car.global_transform.basis.z
	_start_run()


## True while the results card is up; the pause menu stays shut meanwhile.
func is_showing_results() -> bool:
	return _results.visible


func record_event(label: String, amount: int, is_penalty: bool) -> void:
	session.record_event(label, amount, is_penalty)


func _start_run() -> void:
	car.teleport(_start_position, _start_forward)
	car.input_locked = true
	car.reset_kudos()
	session.start()
	_hud.set_time(session.duration)


func _process(delta: float) -> void:
	if get_tree().paused or car == null:
		return
	match session.tick(delta, car.linear_velocity.length(), car.get_kudos()):
		RunSessionScript.Cue.GO:
			car.reset_kudos()
			car.input_locked = false
			_hud.show_go()
		RunSessionScript.Cue.FINISHED:
			_finish()
			return
	if session.state == RunSessionScript.State.COUNTDOWN:
		_hud.show_count(session.countdown_number())
	_hud.set_time(session.time_left(), delta)


func _finish() -> void:
	_hud.set_time(0.0)
	_hud.show_finish()
	var key := RunSessionScript.record_key(mode)
	var profile := ProfileStoreScript.new(profile_path)
	var previous_best := profile.best_score(key)
	var is_new_best := profile.submit_score(key, session.score)
	profile.add_distance(session.distance_m)
	profile.save()
	get_tree().paused = true
	car.set_engine_muted(true)
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	_results.present(session, mode, is_new_best, maxi(previous_best, session.score))


func _close_results() -> void:
	_results.visible = false
	get_tree().paused = false
	car.set_engine_muted(false)
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)


func _on_retry() -> void:
	_close_results()
	_start_run()


func _on_free_drive() -> void:
	_close_results()
	free_drive_requested.emit()
