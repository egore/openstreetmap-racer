extends Node3D

## Main scene script. Sets up the OSM world and manages high-level game state.

@onready var tile_manager: OSMTileManager = $OSMTileManager
@onready var car: VehicleBody3D = $Car
@onready var speed_label: Label = $HUD/SpeedLabel
@onready var info_label: Label = $HUD/InfoLabel

func _ready() -> void:
	# Capture mouse for camera control
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

	# Dependency injection: the car broadcasts its speed, the HUD reacts.
	car.speed_changed.connect(_on_car_speed_changed)

	# React to tile streaming instead of polling a private field every frame.
	tile_manager.tile_loaded.connect(_on_tiles_changed)
	tile_manager.tile_unloaded.connect(_on_tiles_changed)

	# Refresh the info label on a fixed cadence rather than accumulating delta.
	var timer := Timer.new()
	timer.wait_time = 0.5
	timer.autostart = true
	add_child(timer)
	timer.timeout.connect(_update_info_label)

func _process(_delta: float) -> void:
	# Toggle mouse capture with Escape
	if Input.is_action_just_pressed("ui_cancel"):
		if Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
			Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
		else:
			Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

func _on_car_speed_changed(speed_kmh: float) -> void:
	speed_label.text = "%d km/h" % int(speed_kmh)

func _on_tiles_changed(_tile_key: Vector2i) -> void:
	_update_info_label()

func _update_info_label() -> void:
	var pos := car.global_position
	info_label.text = "Pos: (%.0f, %.0f) | Tiles: %d" % [
		pos.x, pos.z, tile_manager.get_loaded_tile_count()
	]
