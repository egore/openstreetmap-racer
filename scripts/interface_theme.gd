extends RefCounted

const BODY := preload("res://assets/ui/fonts/Barlow-Medium.ttf")
const DISPLAY := preload("res://assets/ui/fonts/BarlowCondensed-SemiBold.ttf")
const INK := Color("11191c")
const PAPER := Color("f5f2e8")
const MUTED := Color("a5b1b0")
const ACCENT := Color("d5f36b")

static func panel(fill: Color, border: Color = Color("344448"), padding: float = 16.0) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = fill
	style.border_color = border
	style.set_border_width_all(1)
	style.set_corner_radius_all(8)
	style.content_margin_left = padding
	style.content_margin_right = padding
	style.content_margin_top = padding
	style.content_margin_bottom = padding
	return style

static func create() -> Theme:
	var theme := Theme.new()
	theme.default_font = BODY
	theme.default_font_size = 16
	theme.set_color("font_color", "Label", PAPER)
	theme.set_color("font_color", "Button", PAPER)
	theme.set_color("font_hover_color", "Button", PAPER)
	theme.set_color("font_pressed_color", "Button", ACCENT)
	theme.set_stylebox("panel", "PanelContainer", panel(INK))
	for type in ["Button", "CheckButton"]:
		theme.set_stylebox("normal", type, panel(Color("1b272b"), Color("344448"), 12))
		theme.set_stylebox("hover", type, panel(Color("29383c"), Color("8a9b79"), 12))
		theme.set_stylebox("pressed", type, panel(Color("27352a"), ACCENT, 12))
		var focus := panel(Color(0, 0, 0, 0), ACCENT, 0)
		focus.set_border_width_all(2)
		theme.set_stylebox("focus", type, focus)
		theme.set_color("font_color", type, PAPER)
		theme.set_color("font_hover_color", type, PAPER)
		theme.set_color("font_pressed_color", type, PAPER)
		theme.set_color("font_focus_color", type, PAPER)
	for icon in ["checked", "checked_mirrored"]:
		theme.set_icon(icon, "CheckButton", preload("res://assets/ui/toggle-on.svg"))
	for icon in ["unchecked", "unchecked_mirrored"]:
		theme.set_icon(icon, "CheckButton", preload("res://assets/ui/toggle-off.svg"))
	theme.set_constant("h_separation", "CheckButton", 18)
	theme.set_constant("separation", "VBoxContainer", 8)
	return theme
