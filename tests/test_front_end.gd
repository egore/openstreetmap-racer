extends GdUnitTestSuite

## The front end: title screen and the loading screen that hands over to the
## world. The loading screen is driven against a stand-in world
## (tests/fixtures/stub_world.tscn) so the hand-over can be tested end to end
## without streaming a real map.

const LoadingScene := preload("res://scenes/loading_screen.tscn")
const TitleScene := preload("res://scenes/title_screen.tscn")
const StubWorldScript := preload("res://tests/fixtures/stub_world.gd")
const STUB_WORLD := "res://tests/fixtures/stub_world.tscn"
const RunSessionScript := preload("res://scripts/run_session.gd")
const ProfileStoreScript := preload("res://scripts/profile_store.gd")

var _previous_scene: Node


func before_test() -> void:
	_previous_scene = get_tree().current_scene
	StubWorldScript.hold = false


func after_test() -> void:
	# The loading screen makes the world the current scene; give the runner back.
	StubWorldScript.hold = false
	var current := get_tree().current_scene
	if current != _previous_scene and is_instance_valid(current):
		current.queue_free()
	get_tree().current_scene = _previous_scene


func _start_loading() -> CanvasLayer:
	var loading: CanvasLayer = LoadingScene.instantiate()
	loading.scene_path = STUB_WORLD
	get_tree().root.add_child(loading)
	return loading


func _frames(n: int) -> void:
	for _i in n:
		await get_tree().process_frame


func test_loading_screen_reports_world_progress() -> void:
	StubWorldScript.hold = true
	var loading := _start_loading()
	await _frames(20)
	# The world's own 50% lands in the share after asset loading and boot.
	assert_float(loading.get_progress()).is_between(0.5, 0.9)
	assert_str(loading.get_stage()).is_equal("BUILDING STREETS")
	StubWorldScript.hold = false
	await _frames(5)
	if is_instance_valid(loading):
		await loading.tree_exited


func test_loading_screen_hands_over_to_the_world_and_frees_itself() -> void:
	var loading := _start_loading()
	var handed_over: Array[Node] = []
	loading.finished.connect(func(world: Node) -> void: handed_over.append(world))
	for _i in 300:
		if not handed_over.is_empty():
			break
		await get_tree().process_frame
	assert_int(handed_over.size()).is_equal(1)
	assert_float(loading.get_progress()).is_equal(1.0)
	assert_str(get_tree().current_scene.scene_file_path).is_equal(STUB_WORLD)
	await loading.tree_exited
	await get_tree().process_frame
	assert_bool(is_instance_valid(loading)).is_false()


func _make_title(profile_path: String) -> Control:
	var title: Control = auto_free(TitleScene.instantiate())
	title.profile_path = profile_path
	add_child(title)
	return title


func test_title_screen_offers_both_modes_and_focuses_the_run() -> void:
	var title := _make_title("user://_test_no_profile.cfg")
	await _frames(2)
	assert_object(title.free_drive_button).is_not_null()
	assert_object(title.sprint_button).is_not_null()
	assert_object(title.quit_button).is_not_null()
	assert_bool(title.kudos_attack_button.has_focus()).is_true()
	assert_str(title.best_label.text).contains("THREE MINUTES")


func test_title_screen_shows_the_personal_best() -> void:
	var path := "user://_test_title_profile.cfg"
	var profile := ProfileStoreScript.new(path)
	profile.submit_score("kudos_attack", 12345)
	profile.save()
	var title := _make_title(path)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
	assert_str(title.best_label.text).contains("12,345")
	assert_str(title.best_label.text).contains("1 RUN")


func test_loading_screen_hands_the_mode_to_the_world() -> void:
	var loading: CanvasLayer = LoadingScene.instantiate()
	loading.scene_path = STUB_WORLD
	loading.game_mode = RunSessionScript.Mode.KUDOS_ATTACK
	get_tree().root.add_child(loading)
	var handed_over: Array[Node] = []
	loading.finished.connect(func(world: Node) -> void: handed_over.append(world))
	for _i in 300:
		if not handed_over.is_empty():
			break
		await get_tree().process_frame
	assert_int(handed_over[0].game_mode).is_equal(RunSessionScript.Mode.KUDOS_ATTACK)
	await loading.tree_exited


func test_title_menu_clears_the_footer() -> void:
	# canvas_items stretching lays the UI out at the 1280 x 720 design size.
	var title := _make_title("user://_test_no_profile.cfg")
	title.size = Vector2(1280, 720)
	await _frames(2)
	var quit_bottom: float = title.quit_button.get_global_rect().end.y
	# The controls line sits 40 px above the bottom edge.
	assert_float(quit_bottom).is_less_equal(720.0 - 40.0)
