extends CanvasLayer

const InterfaceTheme := preload("res://scripts/interface_theme.gd")

func _ready() -> void:
	for node in get_children():
		if node is Control:
			node.theme = InterfaceTheme.create()
	var title := Label.new()
	title.text = "OPENSTREETMAP / RACER"
	title.position = Vector2(78, 25)
	title.add_theme_font_override("font", InterfaceTheme.DISPLAY)
	title.add_theme_font_size_override("font_size", 24)
	title.add_theme_color_override("font_color", InterfaceTheme.PAPER)
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(title)
	var mark := TextureRect.new()
	mark.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	mark.texture = preload("res://assets/ui/racer-mark.svg")
	mark.position = Vector2(28, 24)
	mark.size = Vector2(36, 36)
	mark.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(mark)
	var hint := Label.new()
	hint.text = "WASD  DRIVE     SPACE  HANDBRAKE     T  CAMERA     ESC  PAUSE"
	hint.theme = InterfaceTheme.create()
	hint.add_theme_font_size_override("font_size", 12)
	hint.add_theme_color_override("font_color", InterfaceTheme.MUTED)
	hint.add_theme_stylebox_override("normal", InterfaceTheme.panel(Color(0.067, 0.098, 0.11, 0.9), Color("344448"), 10))
	hint.set_anchors_and_offsets_preset(Control.PRESET_CENTER_BOTTOM)
	hint.offset_left = -218
	hint.offset_right = 218
	hint.offset_top = -50
	hint.offset_bottom = -24
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(hint)
	var caption := Label.new()
	caption.text = "LOCAL MAP  /  200 m"
	caption.theme = InterfaceTheme.create()
	caption.add_theme_font_size_override("font_size", 12)
	caption.add_theme_color_override("font_color", InterfaceTheme.MUTED)
	caption.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_RIGHT)
	caption.offset_left = -248
	caption.offset_right = -28
	caption.offset_top = -264
	caption.offset_bottom = -242
	caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	caption.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(caption)
