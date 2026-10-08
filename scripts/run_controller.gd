extends Node

## Runs a timed mode in the world: holds the car at the line for the countdown,
## keeps the clock, ends the run, saves the result and offers a retry from the
## same start.
##
##   Kudos Attack       score as much as possible before the clock runs out.
##   Checkpoint Sprint  drive a course planned through the real streets, gate by
##                      gate, against the clock.
##
## main.gd creates one for timed modes and forwards the car's kudos events. The
## logic lives in RunSession, SprintRoute and CheckpointTracker; this node is
## the glue between them, the car, the minimap and the overlays.

const RunSessionScript := preload("res://scripts/run_session.gd")
const ProfileStoreScript := preload("res://scripts/profile_store.gd")
const SceneFlowScript := preload("res://scripts/scene_flow.gd")
const RunHudScript := preload("res://scripts/run_hud.gd")
const ResultsScreenScript := preload("res://scripts/results_screen.gd")
const SprintRouteScript := preload("res://scripts/sprint_route.gd")
const CheckpointTrackerScript := preload("res://scripts/checkpoint_tracker.gd")
const CheckpointMarkersScript := preload("res://scripts/checkpoint_markers.gd")
const TrafficRoadNetworkScript := preload("res://scripts/traffic/traffic_road_network.gd")

## The player chose to keep driving without the clock (or no course could be
## planned); main drops back to free drive and frees this node.
signal free_drive_requested

var mode: RunSessionScript.Mode = RunSessionScript.Mode.KUDOS_ATTACK
var car: CarController
## Sprint only: the road graph to plan the course on.
var road_network: TrafficRoadNetworkScript
## Optional: shows the sprint course.
var minimap: Minimap
var session := RunSessionScript.new()
## Where records go. Tests point this at a scratch file before _ready.
var profile_path: String = ProfileStoreScript.DEFAULT_PATH

## The planned sprint course, or null.
var route: SprintRouteScript = null

var _hud: RunHudScript
var _results: ResultsScreenScript
var _markers: CheckpointMarkersScript
var _checkpoints: CheckpointTrackerScript
var _start_position: Vector3
var _start_forward: Vector3


func _ready() -> void:
	# Ticks only while the tree runs, but must keep handling the results card
	# while the world behind it is paused.
	process_mode = Node.PROCESS_MODE_ALWAYS
	if mode == RunSessionScript.Mode.SPRINT:
		session.duration = 0.0
	_hud = RunHudScript.new()
	_hud.name = "RunHud"
	add_child(_hud)
	_hud.set_mode_name(RunSessionScript.mode_name(mode))
	_markers = CheckpointMarkersScript.new()
	_markers.name = "CheckpointMarkers"
	add_child(_markers)
	_results = ResultsScreenScript.new()
	_results.name = "Results"
	add_child(_results)
	_results.retry_pressed.connect(_on_retry)
	_results.free_drive_pressed.connect(_on_free_drive)
	_results.main_menu_pressed.connect(SceneFlowScript.go_to_title.bind(get_tree()))
	_update_clock(0.0)


func _exit_tree() -> void:
	if minimap != null:
		minimap.clear_route()


## Start the first run from wherever the car stands now.
func begin() -> void:
	_start_position = car.global_position
	_start_forward = car.global_transform.basis.z
	if mode == RunSessionScript.Mode.SPRINT and not _plan_course():
		push_warning("RunController: no sprint course from here; switching to free drive")
		free_drive_requested.emit.call_deferred()
		return
	_start_run()


## True while the results card is up; the pause menu stays shut meanwhile.
func is_showing_results() -> bool:
	return _results.visible


func record_event(label: String, amount: int, is_penalty: bool) -> void:
	session.record_event(label, amount, is_penalty)


func _plan_course() -> bool:
	if road_network == null:
		return false
	route = SprintRouteScript.plan(road_network, _start_position, _start_forward)
	if route == null:
		return false
	_checkpoints = CheckpointTrackerScript.new(route.checkpoints)
	_markers.set_gates(route.checkpoints)
	if minimap != null:
		minimap.set_route(route.points, route.checkpoints)
	return true


func _start_run() -> void:
	car.teleport(_start_position, _start_forward)
	car.input_locked = true
	car.reset_kudos()
	session.start()
	if _checkpoints != null:
		_checkpoints.reset()
		_show_next_gate()
	_update_clock(0.0)


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
	if session.is_running() and _checkpoints != null and _checkpoints.update(car.global_position):
		_on_gate_passed()
		if session.state == RunSessionScript.State.FINISHED:
			return
	_update_clock(delta)


func _on_gate_passed() -> void:
	if _checkpoints.is_complete():
		session.finish(car.get_kudos())
		_finish()
		return
	_hud.show_split("CHECKPOINT %d/%d   %s" % [
		_checkpoints.next_index, _checkpoints.gate_count() - 1,
		RunSessionScript.format_race_time(session.elapsed)])
	_show_next_gate()


func _show_next_gate() -> void:
	_markers.set_next(_checkpoints.next_index)
	if minimap != null:
		minimap.set_next_gate(_checkpoints.next_index)


func _update_clock(delta: float) -> void:
	if session.has_time_limit():
		_hud.set_time(session.time_left(), delta)
		return
	_hud.set_clock_text(RunSessionScript.format_race_time(session.elapsed))
	if _checkpoints == null:
		return
	if session.is_running():
		var gates := _checkpoints.gate_count()
		var label := "FINISH" if _checkpoints.next_index == gates - 1 \
			else "CHECKPOINT %d/%d" % [_checkpoints.next_index + 1, gates - 1]
		_hud.set_detail("%s  ·  %d m" % [label, roundi(_checkpoints.distance_to_next(car.global_position))])
	else:
		_hud.set_detail("%d CHECKPOINTS  ·  %.1f km" % [_checkpoints.gate_count() - 1, route.length / 1000.0])


func _finish() -> void:
	_update_clock(0.0)
	if session.has_time_limit():
		_hud.show_finish()
	var profile := ProfileStoreScript.new(profile_path)
	var card := _sprint_card(profile) if mode == RunSessionScript.Mode.SPRINT \
		else _attack_card(profile)
	profile.add_distance(session.distance_m)
	profile.save()
	get_tree().paused = true
	car.set_engine_muted(true)
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	_results.present(card)


func _attack_card(profile: ProfileStoreScript) -> Dictionary:
	var key := RunSessionScript.record_key(mode)
	var previous_best := profile.best_score(key)
	return {
		"eyebrow": "%s  /  RESULTS" % RunSessionScript.mode_name(mode),
		"headline": "TIME'S UP.",
		"caption": "KUDOS",
		"value": RunSessionScript.format_score(session.score),
		"is_new_best": profile.submit_score(key, session.score),
		"best": "PERSONAL BEST  %s" % RunSessionScript.format_score(maxi(previous_best, session.score)),
		"stats": [
			["DISTANCE", "%.2f km" % (session.distance_m / 1000.0)],
			["TOP SPEED", "%d km/h" % roundi(session.top_speed_ms * 3.6)],
			["DRIFTS", str(session.drifts)],
			["NEAR MISSES", str(session.near_misses)],
			["MISTAKES", str(session.mistakes)],
			["BEST MOVE", _best_move()],
		],
	}


func _sprint_card(profile: ProfileStoreScript) -> Dictionary:
	var key := RunSessionScript.record_key(mode, route.id)
	var previous_best := profile.best_time(key)
	var average_kmh := route.length / maxf(session.elapsed, 0.001) * 3.6
	return {
		"eyebrow": "%s  /  RESULTS" % RunSessionScript.mode_name(mode),
		"headline": "FINISHED.",
		"caption": "TIME",
		"value": RunSessionScript.format_race_time(session.elapsed),
		"is_new_best": profile.submit_time(key, session.elapsed),
		"best": "PERSONAL BEST  %s" % RunSessionScript.format_race_time(previous_best),
		"stats": [
			["COURSE", "%.2f km" % (route.length / 1000.0)],
			["AVERAGE SPEED", "%d km/h" % roundi(average_kmh)],
			["TOP SPEED", "%d km/h" % roundi(session.top_speed_ms * 3.6)],
			["KUDOS", RunSessionScript.format_score(session.score)],
			["MISTAKES", str(session.mistakes)],
			["BEST MOVE", _best_move()],
		],
	}


func _best_move() -> String:
	if session.best_move_amount <= 0:
		return "—"
	return "%s  +%d" % [session.best_move_label, session.best_move_amount]


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
