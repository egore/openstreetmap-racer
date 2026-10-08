extends Control

## The front door: what the game is, and the way into a drive.

const InterfaceTheme := preload("res://scripts/interface_theme.gd")
const SceneFlowScript := preload("res://scripts/scene_flow.gd")
const RunSessionScript := preload("res://scripts/run_session.gd")
const ProfileStoreScript := preload("res://scripts/profile_store.gd")

var kudos_attack_button: Button
var free_drive_button: Button
var quit_button: Button
var best_label: Label

## Where records are read from. Tests point this at a scratch file before _ready.
var profile_path: String = ProfileStoreScript.DEFAULT_PATH


func _ready() -> void:
	theme = InterfaceTheme.create()
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	_build_ui()
	_show_records()
	kudos_attack_button.pressed.connect(_start.bind(RunSessionScript.Mode.KUDOS_ATTACK))
	free_drive_button.pressed.connect(_start.bind(RunSessionScript.Mode.FREE_DRIVE))
	quit_button.pressed.connect(_on_quit_pressed)
	kudos_attack_button.grab_focus.call_deferred()


func _start(mode: RunSessionScript.Mode) -> void:
	SceneFlowScript.start_drive(get_tree(), mode)


func _on_quit_pressed() -> void:
	get_tree().quit()


func _show_records() -> void:
	var profile := ProfileStoreScript.new(profile_path)
	var best := profile.best_score(RunSessionScript.record_key(RunSessionScript.Mode.KUDOS_ATTACK))
	var runs := profile.runs(RunSessionScript.record_key(RunSessionScript.Mode.KUDOS_ATTACK))
	if runs == 0:
		best_label.text = "THREE MINUTES. SCORE AS MUCH STYLE AS YOU CAN."
	else:
		best_label.text = "PERSONAL BEST  %s     ·     %d %s" % [
			RunSessionScript.format_score(best), runs, "RUN" if runs == 1 else "RUNS"]


func _build_ui() -> void:
	var backdrop := ColorRect.new()
	backdrop.color = InterfaceTheme.INK
	backdrop.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(backdrop)

	var art := TextureRect.new()
	art.texture = preload("res://assets/ui/route-art.svg")
	art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	art.modulate = Color(1, 1, 1, 0.55)
	art.set_anchors_and_offsets_preset(Control.PRESET_RIGHT_WIDE)
	art.offset_left = -700
	art.offset_right = -24
	art.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(art)

	var column := VBoxContainer.new()
	column.set_anchors_and_offsets_preset(Control.PRESET_LEFT_WIDE)
	column.offset_left = 72
	column.offset_right = 72 + 460
	column.offset_top = 48
	column.offset_bottom = -64
	column.alignment = BoxContainer.ALIGNMENT_CENTER
	column.add_theme_constant_override("separation", 14)
	add_child(column)

	var mark := TextureRect.new()
	mark.texture = preload("res://assets/ui/racer-mark.svg")
	mark.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	mark.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT
	mark.custom_minimum_size = Vector2(52, 52)
	mark.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	column.add_child(mark)

	column.add_child(InterfaceTheme.label("REAL STREETS  /  YOUR RACING LINE", 13, InterfaceTheme.ACCENT))
	var title := InterfaceTheme.label("OPENSTREETMAP\nRACER", 92, InterfaceTheme.PAPER, true)
	title.add_theme_constant_override("line_spacing", -18)
	column.add_child(title)
	column.add_child(InterfaceTheme.label(
		"Drive a real city, built live from OpenStreetMap. Drift, thread the\n"
		+ "traffic and chase kudos through streets you might know.",
		16, InterfaceTheme.MUTED))

	var gap := Control.new()
	gap.custom_minimum_size = Vector2(0, 12)
	column.add_child(gap)

	var menu := VBoxContainer.new()
	menu.name = "Menu"
	menu.custom_minimum_size = Vector2(360, 0)
	menu.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	menu.add_theme_constant_override("separation", 10)
	column.add_child(menu)

	kudos_attack_button = Button.new()
	kudos_attack_button.name = "KudosAttackButton"
	kudos_attack_button.text = "KUDOS ATTACK  →"
	InterfaceTheme.style_primary(kudos_attack_button)
	menu.add_child(kudos_attack_button)

	best_label = InterfaceTheme.label("", 12, InterfaceTheme.MUTED)
	best_label.name = "BestLabel"
	menu.add_child(best_label)

	free_drive_button = Button.new()
	free_drive_button.name = "FreeDriveButton"
	free_drive_button.text = "FREE DRIVE"
	free_drive_button.custom_minimum_size = Vector2(0, 48)
	free_drive_button.add_theme_font_override("font", InterfaceTheme.DISPLAY)
	free_drive_button.add_theme_font_size_override("font_size", 22)
	menu.add_child(free_drive_button)

	quit_button = Button.new()
	quit_button.name = "QuitButton"
	quit_button.text = "Quit game"
	quit_button.custom_minimum_size = Vector2(0, 38)
	quit_button.add_theme_font_size_override("font_size", 13)
	menu.add_child(quit_button)

	var controls := InterfaceTheme.label(
		"WASD  DRIVE     SPACE  HANDBRAKE     R  RECOVER     T  CAMERA     ESC  PAUSE",
		12, InterfaceTheme.MUTED)
	controls.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	controls.offset_left = 72
	controls.offset_top = -48
	controls.offset_bottom = -28
	add_child(controls)

	# ODbL requires the attribution wherever the map data is shown.
	var credit := InterfaceTheme.label("Map data © OpenStreetMap contributors", 12, InterfaceTheme.MUTED)
	credit.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	credit.offset_left = -320
	credit.offset_right = -32
	credit.offset_top = -48
	credit.offset_bottom = -28
	credit.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	add_child(credit)
