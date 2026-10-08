extends CanvasLayer

## Covers the screen while a drive starts, and shows real progress through it:
##
##   1. Loading the world scene and its models on a background thread.
##   2. Booting it. The tile source opens and traffic builds its road graph in
##      the world's _ready; that blocks the main thread, so the stage label is
##      drawn first and holds still meanwhile.
##   3. Building the streets around the spawn and settling the car, reported by
##      the world itself through its loading_progress signal.
##
## Then the world becomes the current scene and this fades out and frees itself.

const InterfaceTheme := preload("res://scripts/interface_theme.gd")
const RunSessionScript := preload("res://scripts/run_session.gd")

## Emitted once the world is built and the overlay has begun to lift.
signal finished(world: Node)

## The world scene to load. Must emit loading_progress(fraction, status) and
## world_ready; tests point this at a lightweight stand-in.
@export_file("*.tscn") var scene_path: String = "res://scenes/main.tscn"
## Handed to the world as its game_mode before it enters the tree.
var game_mode: RunSessionScript.Mode = RunSessionScript.Mode.FREE_DRIVE

## How the overall bar is split between the three stages above.
const _ASSETS_SHARE := 0.3
const _BOOT_SHARE := 0.1
const _FADE_TIME := 0.45
const _TIP_INTERVAL := 4.5

const TIPS: Array[String] = [
	"Hold SPACE to throw the rear out. Drifts build your combo.",
	"Brush past traffic or walls at speed for a NEAR MISS bonus.",
	"Stuck or upside down? Press R to get back on the road.",
	"Press T to switch between the chase, isometric and top-down cameras.",
	"A crash wipes your combo multiplier. Clean lines pay.",
	"Switch the driving assists off in the pause menu for a rawer car.",
	"Every street, building and lamp post comes from OpenStreetMap.",
	"F5 brings the rain. Wet roads mirror the city lights.",
	"Sprinting? Head for the beam of light. The minimap traces the course.",
	"Sprint courses are planned through the real streets. Know a shortcut? Gates still count in order.",
]

var _root: Control
var _stage_label: Label
var _location_label: Label
var _percent_label: Label
var _bar: ProgressBar
var _tip_label: Label
var _pulse: ColorRect

var _target_progress: float = 0.0
var _shown_progress: float = 0.0
var _tip_index: int = 0
var _tip_elapsed: float = 0.0
var _time: float = 0.0
var _world: Node = null
var _done: bool = false


func _ready() -> void:
	layer = 50
	# The world below pauses with the tree; the overlay must not.
	process_mode = Node.PROCESS_MODE_ALWAYS
	_tip_index = randi() % TIPS.size()
	_build_ui()
	_set_stage("Loading", 0.0)
	_run.call_deferred()


func _process(delta: float) -> void:
	_time += delta
	# Ease the bar toward the latest report; it never runs backwards.
	_shown_progress = move_toward(_shown_progress, _target_progress, delta * 1.5)
	_shown_progress = maxf(_shown_progress, _target_progress - 0.25)
	_bar.value = _shown_progress
	_percent_label.text = "%d%%" % int(round(_shown_progress * 100.0))
	_pulse.modulate.a = 0.35 + 0.65 * (0.5 + 0.5 * sin(_time * 5.0))

	_tip_elapsed += delta
	if _tip_elapsed >= _TIP_INTERVAL:
		_tip_elapsed = 0.0
		_tip_index = (_tip_index + 1) % TIPS.size()
		_tip_label.text = TIPS[_tip_index]


## Progress shown on the bar, 0..1. Exposed for tests.
func get_progress() -> float:
	return _target_progress


func get_stage() -> String:
	return _stage_label.text


func _run() -> void:
	var packed := await _load_scene()
	if packed == null:
		_set_stage("Could not load the world", _target_progress)
		return

	_set_stage("Reading map data", _ASSETS_SHARE)
	# The world's _ready blocks the main thread; make sure this label is on screen
	# before it starts, or the player stares at the previous stage instead.
	# Two frames: the first lays out the new text, the second has drawn it.
	await get_tree().process_frame
	await get_tree().process_frame

	_world = packed.instantiate()
	if "game_mode" in _world:
		_world.set("game_mode", game_mode)
	_world.connect("loading_progress", _on_world_progress)
	_world.connect("world_ready", _on_world_ready, CONNECT_ONE_SHOT)
	get_tree().root.add_child(_world)
	_show_location()


func _load_scene() -> PackedScene:
	if ResourceLoader.load_threaded_request(scene_path, "PackedScene", true) != OK:
		return null
	var progress: Array = []
	while true:
		var status := ResourceLoader.load_threaded_get_status(scene_path, progress)
		match status:
			ResourceLoader.THREAD_LOAD_LOADED:
				return ResourceLoader.load_threaded_get(scene_path) as PackedScene
			ResourceLoader.THREAD_LOAD_IN_PROGRESS:
				var fraction: float = progress[0] if not progress.is_empty() else 0.0
				_set_stage("Loading the garage", fraction * _ASSETS_SHARE)
			_:
				return null
		await get_tree().process_frame
	return null


func _on_world_progress(fraction: float, status: String) -> void:
	var start := _ASSETS_SHARE + _BOOT_SHARE
	_set_stage(status, lerpf(start, 1.0, clampf(fraction, 0.0, 1.0)))


func _on_world_ready() -> void:
	if _done:
		return
	_done = true
	_set_stage("Ready", 1.0)
	_shown_progress = 1.0
	get_tree().current_scene = _world
	finished.emit(_world)
	var tween := create_tween()
	tween.tween_interval(0.15)
	tween.tween_property(_root, "modulate:a", 0.0, _FADE_TIME)
	tween.tween_callback(queue_free)


func _set_stage(status: String, progress: float) -> void:
	_stage_label.text = status.to_upper()
	_target_progress = maxf(_target_progress, progress)


## Where in the world we are, once the world has opened its map.
func _show_location() -> void:
	var tile_manager := _world.get_node_or_null("OSMTileManager")
	if tile_manager == null or not tile_manager.has_method("get_osm_data"):
		return
	var data: OSMParser.OSMData = tile_manager.get_osm_data()
	if data == null:
		return
	_location_label.text = "%.4f° %s   ·   %.4f° %s" % [
		absf(data.center_lat), "N" if data.center_lat >= 0.0 else "S",
		absf(data.center_lon), "E" if data.center_lon >= 0.0 else "W",
	]


func _build_ui() -> void:
	_root = Control.new()
	_root.name = "Root"
	_root.theme = InterfaceTheme.create()
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	# Swallow clicks so nothing reaches the world underneath.
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_root)

	var backdrop := ColorRect.new()
	backdrop.color = InterfaceTheme.INK
	backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.add_child(backdrop)

	var art := TextureRect.new()
	art.texture = preload("res://assets/ui/route-art.svg")
	art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	art.modulate = Color(1, 1, 1, 0.22)
	art.set_anchors_and_offsets_preset(Control.PRESET_RIGHT_WIDE)
	art.offset_left = -760
	art.offset_right = 40
	_root.add_child(art)

	var mark := TextureRect.new()
	mark.texture = preload("res://assets/ui/racer-mark.svg")
	mark.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	mark.position = Vector2(64, 56)
	mark.size = Vector2(36, 36)
	_root.add_child(mark)

	var brand := InterfaceTheme.label("OPENSTREETMAP / RACER", 24, InterfaceTheme.PAPER, true)
	brand.position = Vector2(114, 57)
	_root.add_child(brand)

	var column := VBoxContainer.new()
	column.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_WIDE)
	column.offset_left = 64
	column.offset_right = -64
	column.offset_top = -268
	column.offset_bottom = -56
	column.add_theme_constant_override("separation", 10)
	_root.add_child(column)

	var eyebrow_row := HBoxContainer.new()
	eyebrow_row.add_theme_constant_override("separation", 10)
	column.add_child(eyebrow_row)
	_pulse = ColorRect.new()
	_pulse.color = InterfaceTheme.ACCENT
	_pulse.custom_minimum_size = Vector2(8, 8)
	_pulse.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	eyebrow_row.add_child(_pulse)
	eyebrow_row.add_child(InterfaceTheme.label(
		"PREPARING  /  " + RunSessionScript.mode_name(game_mode), 13, InterfaceTheme.ACCENT))

	_stage_label = InterfaceTheme.label("", 64, InterfaceTheme.PAPER, true)
	_stage_label.name = "Stage"
	column.add_child(_stage_label)

	_location_label = InterfaceTheme.label("", 14, InterfaceTheme.MUTED)
	_location_label.name = "Location"
	column.add_child(_location_label)

	var bar_row := HBoxContainer.new()
	bar_row.add_theme_constant_override("separation", 16)
	column.add_child(bar_row)
	_bar = ProgressBar.new()
	_bar.name = "Bar"
	_bar.min_value = 0.0
	_bar.max_value = 1.0
	_bar.step = 0.0
	_bar.show_percentage = false
	_bar.custom_minimum_size = Vector2(0, 6)
	_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_bar.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_bar.add_theme_stylebox_override("background", _bar_style(Color("263337")))
	_bar.add_theme_stylebox_override("fill", _bar_style(InterfaceTheme.ACCENT))
	bar_row.add_child(_bar)
	_percent_label = InterfaceTheme.label("0%", 22, InterfaceTheme.PAPER, true)
	_percent_label.custom_minimum_size = Vector2(64, 0)
	_percent_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	bar_row.add_child(_percent_label)

	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, 14)
	column.add_child(spacer)

	var tip_row := HBoxContainer.new()
	tip_row.add_theme_constant_override("separation", 14)
	column.add_child(tip_row)
	tip_row.add_child(InterfaceTheme.label("TIP", 13, InterfaceTheme.ACCENT, true))
	_tip_label = InterfaceTheme.label(TIPS[_tip_index], 15, InterfaceTheme.MUTED)
	_tip_label.name = "Tip"
	tip_row.add_child(_tip_label)


func _bar_style(color: Color) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.set_corner_radius_all(3)
	return style
