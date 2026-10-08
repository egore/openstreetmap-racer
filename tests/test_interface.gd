extends GdUnitTestSuite

const InterfaceTheme := preload("res://scripts/interface_theme.gd")
const MainScene := preload("res://scenes/main.tscn")
const SETTINGS := "CenterContainer/Panel/Margin/Columns/Settings/"

func _make_menu() -> CanvasLayer:
	var scene := MainScene.instantiate()
	# The car parents its engine in _ready, which this UI-only fixture never runs.
	scene.get_node("Car")._engine_sound.free()
	var menu: CanvasLayer = scene.get_node("PauseMenu")
	scene.remove_child(menu)
	scene.free()
	add_child(menu)
	auto_free(menu)
	return menu

func test_menu_keeps_all_game_controls() -> void:
	var menu := _make_menu()
	for name in ["DayNightToggle", "WetWeatherToggle", "SpeedBlurToggle", "DrivingAssistsToggle", "DebugLabelsToggle", "FrameTracerToggle"]:
		assert_object(menu.get_node(SETTINGS + name)).is_instanceof(CheckButton)
	for name in ["ResumeButton", "QuitButton", "DumpFrameTimesButton"]:
		assert_object(menu.get_node(SETTINGS + name)).is_instanceof(Button)

func test_opening_menu_focuses_resume() -> void:
	var menu := _make_menu()
	menu.visible = true
	await get_tree().process_frame
	var resume: Button = menu.get_node(SETTINGS + "ResumeButton")
	assert_bool(resume.has_focus()).is_true()

func test_menu_fits_default_viewport_height() -> void:
	var menu := _make_menu()
	menu.visible = true
	await get_tree().process_frame
	var panel: Control = menu.get_node("CenterContainer/Panel")
	assert_float(panel.get_combined_minimum_size().y).is_less_equal(664.0)
	assert_float(panel.get_combined_minimum_size().x).is_less_equal(900.0)

func test_theme_bundles_fonts_and_switch_icons() -> void:
	var theme := InterfaceTheme.create()
	assert_object(theme.default_font).is_not_null()
	assert_bool(theme.has_icon("checked", "CheckButton")).is_true()
	assert_bool(theme.has_icon("unchecked", "CheckButton")).is_true()
	assert_bool(theme.has_stylebox("focus", "Button")).is_true()
