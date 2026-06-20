extends Node3D

## Main scene script. Sets up the OSM world and manages high-level game state.
## Acts as the composition root: it wires the car and tile manager to the HUD
## via signals instead of having those nodes reach across the tree themselves.

@onready var tile_manager: OSMTileManager = $OSMTileManager
@onready var car: CarController = $Car
@onready var speed_label: Label = $HUD/SpeedLabel
@onready var gear_label: Label = $HUD/GearLabel
@onready var info_label: Label = $HUD/InfoLabel
@onready var pause_menu: CanvasLayer = $PauseMenu
@onready var resume_button: Button = $PauseMenu/CenterContainer/Panel/ResumeButton
@onready var quit_button: Button = $PauseMenu/CenterContainer/Panel/QuitButton
@onready var sky_controller: SkyController = $SkyController
@onready var day_night_toggle: CheckButton = $PauseMenu/CenterContainer/Panel/DayNightToggle
@onready var debug_labels_toggle: CheckButton = $PauseMenu/CenterContainer/Panel/DebugLabelsToggle
@onready var headlights: Headlights = $Car/Headlights
@onready var street_lamp_lights: StreetLampLights = $StreetLampLights

func _ready() -> void:
	# Keep handling input even while the tree is paused so Escape can resume.
	process_mode = Node.PROCESS_MODE_ALWAYS

	# Capture mouse for camera control
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

	# Dependency injection: the car broadcasts its speed and gear, the HUD reacts.
	car.speed_changed.connect(_on_car_speed_changed)
	car.gear_changed.connect(_on_car_gear_changed)

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

	# Headlights and street lamps both follow the time of day automatically: on
	# after dark, off by day. Each owns its own lights; the sky controller decides
	# when it's dark. Wiring them here keeps all three ignorant of each other
	# (composition root). The lamp controller is driven through the same signal
	# even though its lights stream in and out with the tiles — it lights whatever
	# is registered at the time.
	sky_controller.day_night_changed.connect(_on_day_night_changed)
	headlights.set_on(not sky_controller.is_day())
	street_lamp_lights.set_on(not sky_controller.is_day())

func _process(_delta: float) -> void:
	# Escape toggles the pause state.
	if Input.is_action_just_pressed("ui_cancel"):
		_set_paused(not get_tree().paused)

## Pauses or resumes the game. Godot's scene-tree pause cleanly halts car
## physics, tile streaming and HUD updates without the hacky "near-zero
## time_scale" trick; nodes flagged PROCESS_MODE_WHEN_PAUSED/ALWAYS keep running.
func _set_paused(paused: bool) -> void:
	get_tree().paused = paused
	pause_menu.visible = paused
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

func _on_car_speed_changed(speed_kmh: float) -> void:
	speed_label.text = "%d km/h" % int(speed_kmh)

func _on_car_gear_changed(gear: int) -> void:
	gear_label.text = Transmission.gear_label(gear)

func _on_tiles_changed(_tile_key: Vector2i) -> void:
	_update_info_label()

func _update_info_label() -> void:
	var pos := car.global_position
	info_label.text = "Pos: (%.0f, %.0f) | Tiles: %d" % [
		pos.x, pos.z, tile_manager.get_loaded_tile_count()
	]
