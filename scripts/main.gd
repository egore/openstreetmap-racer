extends Node3D

## Main scene script. Sets up the OSM world and manages high-level game state.
## Acts as the composition root: it wires the car and tile manager to the HUD
## via signals instead of having those nodes reach across the tree themselves.

const FrameTracerScript := preload("res://scripts/frame_tracer.gd")
const ScreenshotScript := preload("res://scripts/screenshot.gd")
## Preloaded rather than referenced by its class_name: a bare TopDownCamera here
## resolves through the global class cache, which is not guaranteed to be
## populated when main.gd is first parsed. That makes the script fail to load
## with "Could not find type" depending on parse order — and because the scene
## still instantiates, the failure shows up as the T key silently doing nothing
## rather than as an obvious error.
const TopDownCameraScript := preload("res://scripts/top_down_camera.gd")

@onready var tile_manager: OSMTileManager = $OSMTileManager
@onready var car: CarController = $Car
## Instrument cluster: swept rev counter, gear in the hub, digital speed and the
## driver-aid telltales. Replaces the old plain speed/gear corner labels.
@onready var dial_cluster: DialCluster = $HUD/DialCluster
## Radial speed blur. Lives on its own CanvasLayer *below* the HUD so it smears
## the world without touching the instruments.
@onready var speed_blur: SpeedBlur = $SpeedBlurLayer/SpeedBlur
@onready var info_label: Label = $HUD/InfoLabel
@onready var kudos_label: Label = $HUD/KudosLabel
@onready var combo_label: Label = $HUD/ComboLabel
@onready var kudos_popup: Label = $HUD/KudosPopup
@onready var pause_menu: CanvasLayer = $PauseMenu
@onready var resume_button: Button = $PauseMenu/CenterContainer/Panel/ResumeButton
@onready var quit_button: Button = $PauseMenu/CenterContainer/Panel/QuitButton
@onready var sky_controller: SkyController = $SkyController
## Post-processing stack (glow/SSAO/SSIL/SSR/grade). Self-wires to the
## WorldEnvironment and SkyController via its exported paths; referenced here for
## discoverability and so effect toggles can be reached from the composition root.
@onready var post_processing: PostProcessing = $PostProcessing
@onready var day_night_toggle: CheckButton = $PauseMenu/CenterContainer/Panel/DayNightToggle
@onready var debug_labels_toggle: CheckButton = $PauseMenu/CenterContainer/Panel/DebugLabelsToggle
@onready var wet_weather_toggle: CheckButton = $PauseMenu/CenterContainer/Panel/WetWeatherToggle
@onready var speed_blur_toggle: CheckButton = $PauseMenu/CenterContainer/Panel/SpeedBlurToggle
@onready var driving_assists_toggle: CheckButton = $PauseMenu/CenterContainer/Panel/DrivingAssistsToggle
@onready var frame_tracer_toggle: CheckButton = $PauseMenu/CenterContainer/Panel/FrameTracerToggle
@onready var dump_frame_times_button: Button = $PauseMenu/CenterContainer/Panel/DumpFrameTimesButton
@onready var headlights: Headlights = $Car/Headlights
@onready var street_lamp_lights: StreetLampLights = $StreetLampLights
## Wet-road weather. Self-wires via the global `wetness` shader uniform; kept
## here so the debug key (F5) can toggle rain from the composition root.
@onready var weather_controller: WeatherController = $WeatherController
## The overhead cameras, cycled with T alongside the car's chase camera. Both
## live on the scene root rather than on the car: the isometric one must NOT
## inherit the car's yaw, and the top-down one takes the heading as a number
## instead (see top_down_camera.gd for why).
@onready var isometric_camera: Camera3D = $IsometricCamera
@onready var top_down_camera: Camera3D = $TopDownCamera

## The camera cycle, in the order T steps through them. Built in _ready because
## the chase camera is reached through the car. Kept as a list rather than an
## enum + match so adding a fourth mode is one scene node and one line here,
## with no branching to keep in sync.
var _cameras: Array[Camera3D] = []
## Index into _cameras of the mode currently live. Tracked rather than derived
## from each camera's `current` flag so the cycle order survives anything else
## in the scene activating a camera behind our back.
var _camera_index: int = 0

## Active tween for the centre kudos popup's pop-and-fade, kept so a new event can
## kill the in-flight animation before starting its own (avoids stacked tweens).
var _kudos_popup_tween: Tween = null

func _ready() -> void:
	# Keep handling input even while the tree is paused so Escape can resume.
	process_mode = Node.PROCESS_MODE_ALWAYS

	# Capture mouse for camera control
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

	# Dependency injection: the car broadcasts its telemetry, the HUD reacts. The
	# cluster takes speed/gear/revs and the assist levels straight from the car's
	# signals, so neither side reaches across the tree for the other.
	car.speed_changed.connect(_on_car_speed_changed)
	car.gear_changed.connect(_on_car_gear_changed)
	car.gear_ratio_changed.connect(dial_cluster.set_gear_ratio)
	car.assists_changed.connect(dial_cluster.set_assist_levels)
	car.kudos_changed.connect(_on_car_kudos_changed)
	car.kudos_event.connect(_on_car_kudos_event)

	# React to tile streaming instead of polling a private field every frame.
	tile_manager.tile_loaded.connect(_on_tiles_changed)
	tile_manager.tile_unloaded.connect(_on_tiles_changed)

	# Hold the car still until the world (and its ground colliders) exist. The
	# scene places the car at a flat-world height; with DEM terrain the ground is
	# at the local elevation and tiles stream in a frame or two after startup, so
	# spawning blind would drop the car underground or through empty space.
	car.freeze = true
	# The tile manager is a child, so its _ready (which parses OSM and emits
	# data_loaded) runs before this _ready. If the data is already available we
	# missed the signal and must spawn now; otherwise wait for the signal.
	var osm_data := tile_manager.get_osm_data()
	if osm_data != null:
		_on_world_ready(osm_data)
	else:
		tile_manager.data_loaded.connect(_on_world_ready)

	# Refresh the info label on a fixed cadence rather than accumulating delta.
	var timer := Timer.new()
	timer.wait_time = 0.5
	timer.autostart = true
	add_child(timer)
	timer.timeout.connect(_update_info_label)

	# Wire up the pause menu buttons.
	resume_button.pressed.connect(_set_paused.bind(false))
	quit_button.pressed.connect(_on_quit_pressed)

	# Day/night toggle: reflect the controller's starting state in the checkbox,
	# then let the user flip it. The controller owns the actual transition.
	day_night_toggle.button_pressed = sky_controller.is_day()
	_update_day_night_label(sky_controller.is_day())
	day_night_toggle.toggled.connect(_on_day_night_toggled)

	# Debug-labels toggle: off by default. The asset placer creates labels hidden
	# and adds them to the "debug_labels" group; the toggle flips their visibility
	# and tells the tile manager so newly streamed tiles match.
	debug_labels_toggle.button_pressed = false
	debug_labels_toggle.toggled.connect(_on_debug_labels_toggled)

	# Wet-weather toggle: reflect the controller's starting state, then let the user
	# flip rain on/off. Mirrors the F5 shortcut, which shares the same setter so the
	# checkbox and key never disagree.
	wet_weather_toggle.button_pressed = weather_controller.is_wet()
	wet_weather_toggle.toggled.connect(_on_wet_weather_toggled)

	# Speed-blur toggle: the effect is cosmetic and the most likely thing to turn
	# off on a weak GPU, so it gets its own switch alongside the other effects.
	speed_blur_toggle.button_pressed = speed_blur.enabled
	speed_blur_toggle.toggled.connect(_on_speed_blur_toggled)

	# Driving-assists toggle: the "assists off" preset. Reflect the car's starting
	# state, then let the player switch TCS/ABS/stability (and the countersteer
	# help) off for a rawer, less forgiving car.
	driving_assists_toggle.button_pressed = car.are_driving_assists_enabled()
	driving_assists_toggle.toggled.connect(_on_driving_assists_toggled)

	# Frame-tracer toggle: reflect the tracer's current state (it can be enabled
	# non-interactively via OSMRACER_TRACE=1), then let the user flip it. Shares the
	# same setter as the F3 shortcut. The "Dump Frame Times" button mirrors F4.
	frame_tracer_toggle.button_pressed = FrameTracerScript.is_enabled()
	frame_tracer_toggle.toggled.connect(_on_frame_tracer_toggled)
	dump_frame_times_button.pressed.connect(FrameTracerScript.dump_summary)

	# Headlights and street lamps both follow the time of day automatically: on
	# after dark, off by day. Each owns its own lights; the sky controller decides
	# when it's dark. Wiring them here keeps all three ignorant of each other
	# (composition root). The lamp controller is driven through the same signal
	# even though its lights stream in and out with the tiles — it lights whatever
	# is registered at the time.
	sky_controller.day_night_changed.connect(_on_day_night_changed)
	headlights.set_on(not sky_controller.is_day())
	street_lamp_lights.set_on(not sky_controller.is_day())

	# Build the T-key camera cycle. Chase first because it is the one the scene
	# starts on, so the index and the live camera agree from frame zero.
	_cameras = [car.camera, isometric_camera, top_down_camera]

func _process(delta: float) -> void:
	# Escape toggles the pause state.
	if Input.is_action_just_pressed("ui_cancel"):
		_set_paused(not get_tree().paused)

	# Drive the speed blur from here rather than from the car's speed signal,
	# because the ramp is smoothed and therefore needs a frame delta. Reading the
	# car's velocity directly also means the blur keeps easing back to zero after
	# the car stops emitting changes.
	if not get_tree().paused:
		speed_blur.update_speed(car.linear_velocity.length() * 3.6, delta)

## Debug keys:
##   F3  toggle the frame tracer (also settable via OSMRACER_TRACE=1)
##   F4  dump the per-label timing summary — used to hunt streaming stutters:
##       any main-thread span over the threshold prints "[trace] <label> took
##       N ms", naming the culprit. See scripts/frame_tracer.gd.
##   F5  toggle wet-road weather
##   P   save a screenshot (see scripts/screenshot.gd)
##   T   cycle chase -> isometric -> top-down camera (see top_down_camera.gd)
func _unhandled_key_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo:
		return
	if key.keycode == KEY_F3:
		# Flip the frame tracer via the checkbox so the key and menu stay in sync
		# (setting button_pressed emits toggled, which runs the real handler).
		frame_tracer_toggle.button_pressed = not FrameTracerScript.is_enabled()
	elif key.keycode == KEY_F4:
		FrameTracerScript.dump_summary()
	elif key.keycode == KEY_F5:
		# Flip wet-road weather via the checkbox (keeps key and menu in sync).
		wet_weather_toggle.button_pressed = not weather_controller.is_wet()
	elif key.keycode == KEY_P:
		_take_screenshot()
	elif key.keycode == KEY_T:
		cycle_camera()


## Step to the next camera mode: chase -> isometric -> top-down -> chase.
##
## Setting `current` on a Camera3D is how Godot picks the active camera, and it
## clears the flag on whichever camera held it, so no two can ever be live at
## once — which is why this only has to activate the incoming one and never
## deactivate the outgoing one.
##
## The incoming camera is snapped onto the car as it takes over. Without that it
## would ease in from wherever it was last left, turning every mode change into a
## visible swoop across the map instead of a clean cut.
##
## Public (and returning the new index) so tests can drive the cycle directly
## rather than synthesising key events, which needs a real input stack.
func cycle_camera() -> int:
	if _cameras.is_empty():
		return _camera_index
	_camera_index = (_camera_index + 1) % _cameras.size()
	var cam := _cameras[_camera_index]
	# A missing camera must not park the cycle on a dead entry: leaving `current`
	# on the outgoing camera at least keeps a picture on screen, and the next
	# press moves on.
	if cam == null:
		return _camera_index
	if cam.has_method("snap_to_target"):
		cam.call("snap_to_target")
	cam.current = true
	return _camera_index


## Save a PNG of the current frame and report where it went.
##
## The viewport texture is only valid once the frame has actually been drawn, so
## this waits for frame_post_draw before grabbing it — reading it straight from
## the input callback yields the PREVIOUS frame (or a blank image on the first
## one), which is exactly the sort of off-by-one that makes a capture look like
## it disproves a fix it never showed.
func _take_screenshot() -> void:
	await RenderingServer.frame_post_draw
	var path: String = ScreenshotScript.capture(get_viewport())
	if path != "":
		print("[screenshot] saved %s" % path)

## Pauses or resumes the game. Godot's scene-tree pause cleanly halts car
## physics, tile streaming and HUD updates without the hacky "near-zero
## time_scale" trick; nodes flagged PROCESS_MODE_WHEN_PAUSED/ALWAYS keep running.
func _set_paused(paused: bool) -> void:
	get_tree().paused = paused
	pause_menu.visible = paused
	# Silence the car audio immediately so the engine doesn't drone through the
	# menu. Un-muting lets the sounds restart naturally on the next physics frame.
	car.set_engine_muted(paused)
	# Free the cursor for the menu while paused, recapture it on resume.
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE if paused else Input.MOUSE_MODE_CAPTURED)

## Place the car on the terrain once OSM data is parsed, build the ground under
## it, then release physics. Runs once at startup (data_loaded fires a single
## time after the spatial index is ready).
func _on_world_ready(_osm_data: OSMParser.OSMData) -> void:
	# Force the tiles around the spawn XZ to exist so there is a collider to land
	# on before we drop the car. Keep the car's authored XZ; only Y is corrected.
	var spawn_xz := car.global_position
	tile_manager.ensure_tiles_around(spawn_xz)

	# The terrain collider is a concave trimesh, which is registered into the
	# physics space a frame after add_child. Resolve the spawn height by raycasting
	# down onto the actual collider rather than trusting the sampled height alone:
	# this guarantees we drop onto a live surface and never start below a one-sided
	# trimesh face (which the car would silently fall through).
	await get_tree().physics_frame
	var ground_y := tile_manager.get_terrain_height(spawn_xz)
	var hit_y := _raycast_ground_y(spawn_xz, ground_y)
	if not is_nan(hit_y):
		ground_y = hit_y

	const SPAWN_CLEARANCE := 1.0
	var t := car.global_transform
	t.origin.y = ground_y + SPAWN_CLEARANCE
	car.global_transform = t

	# Zero any velocity accumulated while frozen, then unfreeze on the next step.
	car.linear_velocity = Vector3.ZERO
	car.angular_velocity = Vector3.ZERO
	await get_tree().physics_frame
	car.freeze = false

## Raycast straight down through the spawn column to find the terrain collider's
## surface Y. Starts well above the sampled height and reaches well below it.
## Returns NAN when nothing is hit (e.g. flat world with no collider yet), so the
## caller can fall back to the sampled height.
func _raycast_ground_y(xz: Vector3, approx_y: float) -> float:
	var space := get_world_3d().direct_space_state
	var from := Vector3(xz.x, approx_y + 50.0, xz.z)
	var to := Vector3(xz.x, approx_y - 50.0, xz.z)
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.exclude = [car.get_rid()]
	var hit := space.intersect_ray(query)
	if hit.is_empty():
		return NAN
	return hit.position.y

func _on_quit_pressed() -> void:
	get_tree().quit()

## Menu toggle flipped: tell the sky controller which way to fade and relabel the
## checkbox. The controller animates the actual sky/light/fog transition.
func _on_day_night_toggled(is_day: bool) -> void:
	sky_controller.set_day(is_day)
	_update_day_night_label(is_day)

func _update_day_night_label(is_day: bool) -> void:
	day_night_toggle.text = "Daytime" if is_day else "Nighttime"

## The sky controller changed the time of day (from the menu or otherwise):
## switch the headlights and street lamps on when it's dark and off when it's
## light.
func _on_day_night_changed(is_day: bool) -> void:
	headlights.set_on(not is_day)
	street_lamp_lights.set_on(not is_day)

## Menu toggle flipped: show or hide every debug label in the world and tell the
## tile manager so labels on tiles that stream in later match the setting.
func _on_debug_labels_toggled(enabled: bool) -> void:
	tile_manager.set_show_debug_labels(enabled)
	for label: Node in get_tree().get_nodes_in_group("debug_labels"):
		label.visible = enabled

## Menu toggle (or F5) flipped: drive the world's wetness to the requested state.
## Uses set_wet rather than toggle() so the checkbox's on/off value is authoritative
## and pressing F5 (which sets button_pressed) can't get out of phase.
func _on_wet_weather_toggled(wet: bool) -> void:
	weather_controller.set_wet(wet)

## Menu toggle flipped: enable or disable the radial speed blur. Switching it off
## drives the shader to zero, where it early-outs, so this is also the A/B for
## measuring the effect's frame cost.
func _on_speed_blur_toggled(enabled: bool) -> void:
	speed_blur.enabled = enabled
	if not enabled:
		speed_blur.reset()

## Menu toggle flipped: switch the driver aids on or off as a set.
func _on_driving_assists_toggled(enabled: bool) -> void:
	car.set_driving_assists_enabled(enabled)

## Menu toggle (or F3) flipped: enable/disable the frame tracer.
func _on_frame_tracer_toggled(enabled: bool) -> void:
	FrameTracerScript.set_enabled(enabled)
	print("[trace] frame tracing %s" % ("ON" if enabled else "OFF"))

func _on_car_speed_changed(speed_kmh: float) -> void:
	dial_cluster.set_speed(speed_kmh)

func _on_car_gear_changed(gear: int) -> void:
	dial_cluster.set_gear(gear)

## Running kudos total changed: update the persistent score readout and the combo
## multiplier line. The combo line is hidden at x1 to keep the HUD quiet during
## ordinary driving and only shouts once the player is stringing moves together.
func _on_car_kudos_changed(total: int, combo: float) -> void:
	kudos_label.text = "KUDOS %d" % total
	if combo > 1.01:
		combo_label.text = "x%.1f COMBO" % combo
	else:
		combo_label.text = ""

## A discrete style moment or mistake fired: flash it in the centre of the screen.
## Cool moves are gold, mistakes red. Each event restarts the pop-and-fade tween
## so rapid-fire events always show the latest one cleanly.
func _on_car_kudos_event(label: String, amount: int, is_penalty: bool) -> void:
	var sign_str := "+" if amount >= 0 else ""
	kudos_popup.text = "%s  %s%d" % [label, sign_str, amount]
	kudos_popup.add_theme_color_override(
		"font_color",
		Color(1.0, 0.3, 0.25) if is_penalty else Color(1.0, 0.85, 0.2)
	)
	_play_kudos_popup()

## Pop-and-fade animation for the centre kudos popup: snap to full opacity at a
## slightly enlarged scale, then settle and fade out. A fresh tween is created
## each time (and the previous one killed) so overlapping events don't stack.
func _play_kudos_popup() -> void:
	if _kudos_popup_tween != null and _kudos_popup_tween.is_valid():
		_kudos_popup_tween.kill()
	# Scale around the label's centre so it grows in place rather than off-corner.
	kudos_popup.pivot_offset = kudos_popup.size * 0.5
	kudos_popup.modulate.a = 1.0
	kudos_popup.scale = Vector2(1.3, 1.3)
	_kudos_popup_tween = create_tween()
	_kudos_popup_tween.set_parallel(true)
	_kudos_popup_tween.tween_property(kudos_popup, "scale", Vector2.ONE, 0.18) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_kudos_popup_tween.tween_property(kudos_popup, "modulate:a", 0.0, 0.9) \
		.set_delay(0.35)

func _on_tiles_changed(_tile_key: Vector2i) -> void:
	_update_info_label()

func _update_info_label() -> void:
	var pos := car.global_position
	info_label.text = "Pos: (%.0f, %.0f) | Tiles: %d" % [
		pos.x, pos.z, tile_manager.get_loaded_tile_count()
	]
