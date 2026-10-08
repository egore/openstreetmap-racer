extends CanvasLayer

## The timed run's overlay: the clock at the top of the screen and the big
## "3, 2, 1, GO!" in the middle. Display only; the run controller feeds it.

const InterfaceTheme := preload("res://scripts/interface_theme.gd")
const RunSessionScript := preload("res://scripts/run_session.gd")

## Under this many seconds left the clock turns red and pulses.
const WARNING_SECONDS := 10.0
const WARNING_COLOR := Color("ff806b")

var _clock_panel: PanelContainer
var _mode_label: Label
var _time_label: Label
var _count_label: Label
var _count_tween: Tween = null
var _shown_count: int = -1
var _pulse_time: float = 0.0


func _ready() -> void:
	layer = 2
	_build_ui()


func set_mode_name(text: String) -> void:
	_mode_label.text = text


func set_clock_visible(clock_visible: bool) -> void:
	_clock_panel.visible = clock_visible


## Show the countdown number. Pops each time the number changes.
func show_count(number: int) -> void:
	if number == _shown_count or number <= 0:
		return
	_shown_count = number
	_pop(str(number), InterfaceTheme.PAPER, 0.85)


func show_go() -> void:
	_shown_count = -1
	_pop("GO!", InterfaceTheme.ACCENT, 0.7)


func show_finish() -> void:
	_shown_count = -1
	_pop("TIME!", WARNING_COLOR, 1.2)


func set_time(seconds: float, delta: float = 0.0) -> void:
	_time_label.text = RunSessionScript.format_time(seconds)
	var warning := seconds <= WARNING_SECONDS and seconds > 0.0
	_time_label.add_theme_color_override(
		"font_color", WARNING_COLOR if warning else InterfaceTheme.PAPER)
	if warning:
		_pulse_time += delta
		_time_label.modulate.a = 0.6 + 0.4 * (0.5 + 0.5 * cos(_pulse_time * TAU))
	else:
		_pulse_time = 0.0
		_time_label.modulate.a = 1.0


func get_time_text() -> String:
	return _time_label.text


func get_count_text() -> String:
	return _count_label.text if _count_label.modulate.a > 0.0 else ""


func _pop(text: String, color: Color, hold: float) -> void:
	if _count_tween != null and _count_tween.is_valid():
		_count_tween.kill()
	_count_label.text = text
	_count_label.add_theme_color_override("font_color", color)
	_count_label.pivot_offset = _count_label.size * 0.5
	_count_label.scale = Vector2(1.6, 1.6)
	_count_label.modulate.a = 1.0
	_count_tween = create_tween()
	_count_tween.tween_property(_count_label, "scale", Vector2.ONE, 0.25) \
		.set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	_count_tween.tween_interval(hold - 0.25)
	_count_tween.tween_property(_count_label, "modulate:a", 0.0, 0.2)


func _build_ui() -> void:
	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.theme = InterfaceTheme.create()
	add_child(root)

	_clock_panel = PanelContainer.new()
	_clock_panel.name = "Clock"
	var style := InterfaceTheme.panel(Color(0.067, 0.098, 0.11, 0.9), Color("344448"), 0)
	style.content_margin_left = 22
	style.content_margin_right = 22
	style.content_margin_top = 6
	style.content_margin_bottom = 6
	style.border_width_bottom = 3
	style.border_color = InterfaceTheme.ACCENT
	_clock_panel.add_theme_stylebox_override("panel", style)
	_clock_panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER_TOP)
	_clock_panel.offset_left = -90
	_clock_panel.offset_right = 90
	_clock_panel.offset_top = 22
	_clock_panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_clock_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(_clock_panel)

	var stack := VBoxContainer.new()
	stack.add_theme_constant_override("separation", -4)
	stack.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_clock_panel.add_child(stack)
	_mode_label = InterfaceTheme.label("", 11, InterfaceTheme.ACCENT)
	_mode_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	stack.add_child(_mode_label)
	_time_label = InterfaceTheme.label("0:00", 40, InterfaceTheme.PAPER, true)
	_time_label.name = "Time"
	_time_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	stack.add_child(_time_label)

	_count_label = InterfaceTheme.label("", 150, InterfaceTheme.PAPER, true)
	_count_label.name = "Count"
	_count_label.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	_count_label.add_theme_constant_override("outline_size", 10)
	_count_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_count_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_count_label.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	_count_label.offset_left = -300
	_count_label.offset_right = 300
	_count_label.offset_top = -140
	_count_label.offset_bottom = 60
	_count_label.modulate.a = 0.0
	root.add_child(_count_label)
