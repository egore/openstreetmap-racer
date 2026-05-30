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

	# Refresh the info label on a fixed cadence rather than accumulating delta.
	var timer := Timer.new()
	timer.wait_time = 0.5
	timer.autostart = true
	add_child(timer)
	timer.timeout.connect(_update_info_label)

	# Wire up the pause menu buttons.
	resume_button.pressed.connect(_set_paused.bind(false))
	quit_button.pressed.connect(_on_quit_pressed)

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

func _on_quit_pressed() -> void:
	get_tree().quit()

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
