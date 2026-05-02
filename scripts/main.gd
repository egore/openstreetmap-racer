extends Node3D

## Main scene script. Sets up the OSM world and manages high-level game state.

@onready var tile_manager: OSMTileManager = $OSMTileManager
@onready var car: VehicleBody3D = $Car
@onready var speed_label: Label = $HUD/SpeedLabel
@onready var info_label: Label = $HUD/InfoLabel

var _tile_count_timer: float = 0.0

func _ready() -> void:
	# Capture mouse for camera control
	Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

func _process(delta: float) -> void:
	# Toggle mouse capture with Escape
	if Input.is_action_just_pressed("ui_cancel"):
		if Input.get_mouse_mode() == Input.MOUSE_MODE_CAPTURED:
			Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
		else:
			Input.set_mouse_mode(Input.MOUSE_MODE_CAPTURED)

	# Update info label periodically
	_tile_count_timer += delta
	if _tile_count_timer > 0.5:
		_tile_count_timer = 0.0
		var pos := car.global_position
		info_label.text = "Pos: (%.0f, %.0f) | Tiles: %d" % [
			pos.x, pos.z, tile_manager._loaded_tiles.size()
		]
