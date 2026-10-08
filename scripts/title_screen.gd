extends Control

## The front door: what the game is, and the way into a drive.

const InterfaceTheme := preload("res://scripts/interface_theme.gd")
const SceneFlowScript := preload("res://scripts/scene_flow.gd")

var free_drive_button: Button
var quit_button: Button

## The column the drive buttons live in, so modes can be added in one place.
var _menu: VBoxContainer


func _ready() -> void:
	theme = InterfaceTheme.create()
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	Input.set_mouse_mode(Input.MOUSE_MODE_VISIBLE)
	_build_ui()
	free_drive_button.pressed.connect(_on_free_drive_pressed)
	quit_button.pressed.connect(_on_quit_pressed)
	free_drive_button.grab_focus.call_deferred()


func _on_free_drive_pressed() -> void:
	SceneFlowScript.start_drive(get_tree())


func _on_quit_pressed() -> void:
	get_tree().quit()


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
	column.offset_top = 64
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

	column.add_child(_label("REAL STREETS  /  YOUR RACING LINE", 13, InterfaceTheme.ACCENT))
	var title := _label("OPENSTREETMAP\nRACER", 92, InterfaceTheme.PAPER, true)
	title.add_theme_constant_override("line_spacing", -18)
	column.add_child(title)
	var blurb := _label(
		"Drive a real city, built live from OpenStreetMap. Drift, thread the\n"
		+ "traffic and chase kudos through streets you might know.",
		16, InterfaceTheme.MUTED)
	column.add_child(blurb)

	var gap := Control.new()
	gap.custom_minimum_size = Vector2(0, 18)
	column.add_child(gap)

	_menu = VBoxContainer.new()
	_menu.name = "Menu"
	_menu.custom_minimum_size = Vector2(340, 0)
	_menu.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	_menu.add_theme_constant_override("separation", 10)
	column.add_child(_menu)

	free_drive_button = _primary_button("FREE DRIVE  →")
	free_drive_button.name = "FreeDriveButton"
	_menu.add_child(free_drive_button)

	quit_button = Button.new()
	quit_button.name = "QuitButton"
	quit_button.text = "Quit game"
	quit_button.custom_minimum_size = Vector2(0, 38)
	quit_button.add_theme_font_size_override("font_size", 13)
	_menu.add_child(quit_button)

	var controls := _label(
		"WASD  DRIVE     SPACE  HANDBRAKE     R  RECOVER     T  CAMERA     ESC  PAUSE",
		12, InterfaceTheme.MUTED)
	controls.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT)
	controls.offset_left = 72
	controls.offset_top = -48
	controls.offset_bottom = -28
	add_child(controls)

	# ODbL requires the attribution wherever the map data is shown.
	var credit := _label("Map data © OpenStreetMap contributors", 12, InterfaceTheme.MUTED)
	credit.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	credit.offset_left = -320
	credit.offset_right = -32
	credit.offset_top = -48
	credit.offset_bottom = -28
	credit.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	add_child(credit)


## A big accent button, styled like the pause menu's resume button.
func _primary_button(text: String) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size = Vector2(0, 56)
	button.add_theme_font_override("font", InterfaceTheme.DISPLAY)
	button.add_theme_font_size_override("font_size", 26)
	button.add_theme_stylebox_override("normal", InterfaceTheme.panel(InterfaceTheme.ACCENT, InterfaceTheme.ACCENT, 12))
	button.add_theme_stylebox_override("hover", InterfaceTheme.panel(Color("e4ff92"), InterfaceTheme.ACCENT, 12))
	button.add_theme_stylebox_override("pressed", InterfaceTheme.panel(Color("b9d65a"), InterfaceTheme.ACCENT, 12))
	button.add_theme_stylebox_override("focus", _focus_ring())
	for state: String in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color"]:
		button.add_theme_color_override(state, InterfaceTheme.INK)
	return button


func _focus_ring() -> StyleBoxFlat:
	var ring := InterfaceTheme.panel(Color(0, 0, 0, 0), InterfaceTheme.PAPER, 0)
	ring.set_border_width_all(2)
	return ring


func _label(text: String, size: int, color: Color, display: bool = false) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", size)
	label.add_theme_color_override("font_color", color)
	if display:
		label.add_theme_font_override("font", InterfaceTheme.DISPLAY)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return label
