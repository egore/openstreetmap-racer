extends GdUnitTestSuite

## Tests for the T-key camera cycle: chase -> isometric -> top-down -> chase.
##
## test_top_down_camera.gd proves each overhead camera FRAMES correctly. It
## cannot prove the game can actually reach them — a cycle that skipped a mode,
## wrapped wrongly, or resolved a renamed node to null would leave every framing
## test passing and the T key showing two modes, or a black screen.
##
## Two things are checked, because they fail independently:
##
##   the cycle    main.gd's cycle_camera() visits every mode, in order, and wraps.
##   the wiring   main.tscn actually contains the nodes main.gd reaches for, with
##                the exported angles that make the two overhead modes different.
##
## The scene is inspected through its PackedScene state rather than instantiated:
## main.tscn pulls in OSM tile streaming, audio and post-processing, none of which
## this is testing and all of which are slow. Node names and exported values are
## exactly what a rename would break, and they are all readable statically.

const MainScript := preload("res://scripts/main.gd")
const MainScene := preload("res://scenes/main.tscn")

## Paths main.gd resolves with $ or through the car. A rename in the scene without
## a matching edit in the script silently yields null, so these are the literal
## strings both sides must agree on.
const CHASE_PATH := "./Car/CameraPivot/Camera3D"
const ISO_PATH := "./IsometricCamera"
const TOP_PATH := "./TopDownCamera"


# ─── Fixtures ────────────────────────────────────────────────────────────────

## A main.gd instance with its camera list populated by hand.
##
## The script is never added to the tree: its @onready vars would then try to
## resolve against a scene this test deliberately does not build. cycle_camera()
## touches only the camera list, which is the point of it taking one.
func _make_cycle(cameras: Array[Camera3D]) -> Node:
	var main: Node = MainScript.new()
	auto_free(main)
	main._cameras = cameras
	return main


func _make_camera() -> Camera3D:
	var cam := Camera3D.new()
	auto_free(cam)
	add_child(cam)
	return cam


## Read a node's exported properties out of main.tscn without instantiating it.
## Returns an empty dictionary if the node is not in the scene at all.
func _scene_node_props(path: String) -> Dictionary:
	var state := MainScene.get_state()
	for i in state.get_node_count():
		if String(state.get_node_path(i)) != path:
			continue
		var props := {}
		for p in state.get_node_property_count(i):
			props[String(state.get_node_property_name(i, p))] = \
				state.get_node_property_value(i, p)
		return props
	return {}


# ─── The cycle ───────────────────────────────────────────────────────────────

func test_cycle_visits_every_mode_then_wraps() -> void:
	# Three presses must land on three DIFFERENT modes and the fourth must come
	# home. An off-by-one in the modulo shows up here as a mode you can never
	# reach or one you can never leave.
	var cams: Array[Camera3D] = [_make_camera(), _make_camera(), _make_camera()]
	var main := _make_cycle(cams)

	var visited: Array[int] = []
	for i in 4:
		visited.append(main.cycle_camera())

	assert_array(visited) \
		.override_failure_message("T must step 0 -> 1 -> 2 -> 0") \
		.is_equal([1, 2, 0, 1])


func test_every_mode_is_reachable_from_the_starting_camera() -> void:
	# The behavioural version of the above: pressing T repeatedly must make each
	# camera live at some point. Asserted on the cameras rather than the index so
	# it still holds if the ordering is retuned later.
	var cams: Array[Camera3D] = [_make_camera(), _make_camera(), _make_camera()]
	var main := _make_cycle(cams)

	var seen := {}
	for i in cams.size():
		main.cycle_camera()
		for c in cams:
			if c.current:
				seen[c] = true

	assert_int(seen.size()) \
		.override_failure_message("some camera mode is unreachable with T") \
		.is_equal(cams.size())


func test_exactly_one_camera_is_live_at_every_step() -> void:
	# Two live cameras means one silently wins; zero means a black screen. Godot
	# enforces this by clearing `current` on the outgoing camera, and this pins
	# that the cycle relies on it correctly rather than tracking flags itself.
	var cams: Array[Camera3D] = [_make_camera(), _make_camera(), _make_camera()]
	var main := _make_cycle(cams)
	cams[0].current = true

	for i in 7:
		main.cycle_camera()
		var live := 0
		for c in cams:
			if c.current:
				live += 1
		assert_int(live) \
			.override_failure_message("step %d left %d cameras live, want 1" % [i, live]) \
			.is_equal(1)


func test_switching_snaps_the_incoming_camera_onto_the_car() -> void:
	# Without the snap the incoming overhead camera eases in from wherever it was
	# last left, so every press of T swoops across the map instead of cutting.
	var chase := _make_camera()
	var overhead: Camera3D = preload("res://scripts/top_down_camera.gd").new()
	auto_free(overhead)
	var target := Node3D.new()
	auto_free(target)
	add_child(target)
	add_child(overhead)
	target.global_position = Vector3(400.0, 0.0, -900.0)
	overhead.target_path = overhead.get_path_to(target)
	overhead.pitch_degrees = 90.0
	overhead._ready()
	# Strand it far from the car, as leaving a mode would.
	overhead.global_position = Vector3.ZERO

	var cams: Array[Camera3D] = [chase, overhead]
	var main := _make_cycle(cams)
	main.cycle_camera()

	assert_float(Vector2(overhead.global_position.x, overhead.global_position.z) \
			.distance_to(Vector2(target.global_position.x, target.global_position.z))) \
		.override_failure_message("incoming camera did not cut straight to the car") \
		.is_less(0.001)


func test_a_missing_camera_does_not_wedge_the_cycle() -> void:
	# Cameras are resolved from the scene, so a rename yields null rather than a
	# crash. The cycle must step past it on the next press instead of parking
	# there and making T look dead.
	var cams: Array[Camera3D] = [_make_camera(), null, _make_camera()]
	var main := _make_cycle(cams)

	main.cycle_camera()
	assert_int(main.cycle_camera()) \
		.override_failure_message("cycle stuck on a missing camera") \
		.is_equal(2)
	assert_bool(cams[2].current) \
		.override_failure_message("cycle failed to reach the camera after the gap") \
		.is_true()


func test_empty_cycle_is_harmless() -> void:
	# Guard the boundary rather than leave it to chance: before _ready populates
	# the list, a stray key press must not divide by zero.
	var main := _make_cycle([] as Array[Camera3D])
	assert_int(main.cycle_camera()) \
		.override_failure_message("empty cycle must be a no-op") \
		.is_equal(0)


# ─── Scene wiring ────────────────────────────────────────────────────────────

func test_scene_contains_every_camera_main_reaches_for() -> void:
	# The rename that motivated this suite: main.gd resolves these by name, and a
	# scene-side rename produces a null that only shows up as T doing nothing.
	for path: String in [CHASE_PATH, ISO_PATH, TOP_PATH]:
		assert_bool(_scene_node_props(path).is_empty()) \
			.override_failure_message("main.tscn is missing %s" % path) \
			.is_false()


func test_the_two_overhead_modes_are_actually_different() -> void:
	# Adding a third mode is only worth it if it looks different from the second.
	# These are the exact properties that separate them, so a scene edit that
	# quietly made them twins would otherwise ship unnoticed.
	var iso := _scene_node_props(ISO_PATH)
	var top := _scene_node_props(TOP_PATH)

	assert_bool(iso["follow_heading"]) \
		.override_failure_message("isometric mode must stay world-aligned") \
		.is_false()
	assert_bool(top["follow_heading"]) \
		.override_failure_message("top-down mode must follow the car's heading") \
		.is_true()
	assert_float(top["pitch_degrees"]) \
		.override_failure_message("top-down mode must look straight down") \
		.is_equal_approx(90.0, 0.001)
	assert_float(iso["pitch_degrees"]) \
		.override_failure_message("isometric mode must keep its true-isometric pitch") \
		.is_equal_approx(35.264, 0.001)


func test_overhead_cameras_are_orthogonal_in_the_scene() -> void:
	# _ready() sets this too, but the scene must agree: a perspective value here
	# means the editor viewport and the first frame disagree with every frame
	# after it.
	for path: String in [ISO_PATH, TOP_PATH]:
		assert_int(_scene_node_props(path)["projection"]) \
			.override_failure_message("%s must be orthogonal in the scene" % path) \
			.is_equal(Camera3D.PROJECTION_ORTHOGONAL)


func test_scene_ortho_size_matches_the_exported_one() -> void:
	# The script drives `size` from `ortho_size` in _ready, so the two must be
	# authored in agreement or the framing visibly pops on the first frame.
	for path: String in [ISO_PATH, TOP_PATH]:
		var props := _scene_node_props(path)
		assert_float(props["size"]) \
			.override_failure_message("%s: size and ortho_size disagree" % path) \
			.is_equal_approx(props["ortho_size"], 0.001)


func test_scene_starts_on_the_chase_camera() -> void:
	# main.gd builds the cycle with chase first so the index and the live camera
	# agree from frame zero. If an overhead camera were authored `current`, the
	# first press of T would appear to skip a mode.
	for path: String in [ISO_PATH, TOP_PATH]:
		assert_bool(_scene_node_props(path)["current"]) \
			.override_failure_message("%s must not start live" % path) \
			.is_false()
