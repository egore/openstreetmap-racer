extends CanvasLayer

const InterfaceTheme := preload("res://scripts/interface_theme.gd")

func _ready() -> void:
	$CenterContainer.theme = InterfaceTheme.create()
	var resume: Button = $CenterContainer/Panel/Margin/Columns/Settings/ResumeButton
	resume.add_theme_stylebox_override("normal", InterfaceTheme.panel(InterfaceTheme.ACCENT, InterfaceTheme.ACCENT, 12))
	resume.add_theme_stylebox_override("hover", InterfaceTheme.panel(Color("e4ff92"), InterfaceTheme.ACCENT, 12))
	resume.add_theme_color_override("font_color", InterfaceTheme.INK)
	resume.add_theme_color_override("font_hover_color", InterfaceTheme.INK)
	resume.add_theme_color_override("font_focus_color", InterfaceTheme.INK)
	visibility_changed.connect(_focus_resume)

func _focus_resume() -> void:
	if not visible:
		return
	# Layout can assign focus to the first toggle when the menu is first revealed.
	await get_tree().process_frame
	if visible:
		$CenterContainer/Panel/Margin/Columns/Settings/ResumeButton.grab_focus()
