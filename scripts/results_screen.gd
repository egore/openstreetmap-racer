extends CanvasLayer

## End-of-run card: the score, whether it is a new best, how the run went, and
## where to go next. Shown over the paused world.

const InterfaceTheme := preload("res://scripts/interface_theme.gd")

signal retry_pressed
signal free_drive_pressed
signal main_menu_pressed

var retry_button: Button
var free_drive_button: Button
var main_menu_button: Button

var _eyebrow: Label
var _headline: Label
var _caption: Label
var _score_label: Label
var _best_label: Label
var _stats: GridContainer


func _ready() -> void:
	layer = 20
	process_mode = Node.PROCESS_MODE_ALWAYS
	visible = false
	_build_ui()
	retry_button.pressed.connect(retry_pressed.emit)
	free_drive_button.pressed.connect(free_drive_pressed.emit)
	main_menu_button.pressed.connect(main_menu_pressed.emit)


## Show the card. `card` holds: eyebrow, headline ("TIME'S UP."), caption and
## value (the result, e.g. "KUDOS" / "12,345"), is_new_best, best (text shown
## when it isn't a new best), and stats: an array of [title, value] pairs.
func present(card: Dictionary) -> void:
	_eyebrow.text = card.get("eyebrow", "")
	_headline.text = card.get("headline", "")
	_caption.text = card.get("caption", "")
	_score_label.text = card.get("value", "")
	if card.get("is_new_best", false):
		_best_label.text = "NEW PERSONAL BEST"
		_best_label.add_theme_color_override("font_color", InterfaceTheme.ACCENT)
	else:
		_best_label.text = card.get("best", "")
		_best_label.add_theme_color_override("font_color", InterfaceTheme.MUTED)

	for child: Node in _stats.get_children():
		_stats.remove_child(child)
		child.queue_free()
	for stat: Array in card.get("stats", []):
		_add_stat(stat[0], stat[1])

	visible = true
	retry_button.grab_focus.call_deferred()


func get_score_text() -> String:
	return _score_label.text


func get_best_text() -> String:
	return _best_label.text


func _add_stat(title: String, value: String) -> void:
	var cell := VBoxContainer.new()
	cell.add_theme_constant_override("separation", 0)
	cell.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cell.add_child(InterfaceTheme.label(title, 11, InterfaceTheme.MUTED))
	cell.add_child(InterfaceTheme.label(value, 26, InterfaceTheme.PAPER, true))
	_stats.add_child(cell)


func _build_ui() -> void:
	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.theme = InterfaceTheme.create()
	add_child(root)

	var dimmer := ColorRect.new()
	dimmer.color = Color(0.025, 0.045, 0.05, 0.8)
	dimmer.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(dimmer)

	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(center)

	var panel := PanelContainer.new()
	panel.name = "Panel"
	panel.custom_minimum_size = Vector2(820, 0)
	var style := InterfaceTheme.panel(Color(0.067, 0.098, 0.11, 0.98), Color("344448"), 0)
	style.set_corner_radius_all(12)
	style.shadow_color = Color(0, 0, 0, 0.35)
	style.shadow_size = 32
	panel.add_theme_stylebox_override("panel", style)
	center.add_child(panel)

	var margin := MarginContainer.new()
	for side: String in ["left", "right"]:
		margin.add_theme_constant_override("margin_" + side, 36)
	for side: String in ["top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 30)
	panel.add_child(margin)

	var columns := HBoxContainer.new()
	columns.add_theme_constant_override("separation", 40)
	margin.add_child(columns)

	var left := VBoxContainer.new()
	left.custom_minimum_size = Vector2(340, 0)
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left.add_theme_constant_override("separation", 6)
	columns.add_child(left)

	_eyebrow = InterfaceTheme.label("", 12, InterfaceTheme.ACCENT)
	left.add_child(_eyebrow)
	_headline = InterfaceTheme.label("", 64, InterfaceTheme.PAPER, true)
	left.add_child(_headline)
	var gap := Control.new()
	gap.custom_minimum_size = Vector2(0, 8)
	left.add_child(gap)
	_caption = InterfaceTheme.label("", 13, InterfaceTheme.MUTED)
	left.add_child(_caption)
	_score_label = InterfaceTheme.label("0", 84, InterfaceTheme.PAPER, true)
	_score_label.name = "Score"
	_score_label.add_theme_constant_override("line_spacing", -12)
	left.add_child(_score_label)
	_best_label = InterfaceTheme.label("", 14, InterfaceTheme.MUTED)
	_best_label.name = "Best"
	left.add_child(_best_label)

	var right := VBoxContainer.new()
	right.custom_minimum_size = Vector2(340, 0)
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.add_theme_constant_override("separation", 10)
	columns.add_child(right)

	right.add_child(InterfaceTheme.label("YOUR RUN", 26, InterfaceTheme.PAPER, true))
	_stats = GridContainer.new()
	_stats.columns = 2
	_stats.add_theme_constant_override("h_separation", 24)
	_stats.add_theme_constant_override("v_separation", 12)
	right.add_child(_stats)

	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	spacer.custom_minimum_size = Vector2(0, 12)
	right.add_child(spacer)

	retry_button = Button.new()
	retry_button.name = "RetryButton"
	retry_button.text = "RUN IT BACK  →"
	InterfaceTheme.style_primary(retry_button, 24)
	right.add_child(retry_button)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	right.add_child(row)
	free_drive_button = _secondary_button("Keep driving")
	free_drive_button.name = "FreeDriveButton"
	row.add_child(free_drive_button)
	main_menu_button = _secondary_button("Main menu")
	main_menu_button.name = "MainMenuButton"
	row.add_child(main_menu_button)


func _secondary_button(text: String) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size = Vector2(0, 38)
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.add_theme_font_size_override("font_size", 13)
	return button
