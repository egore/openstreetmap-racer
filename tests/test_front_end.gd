extends GdUnitTestSuite

## The front end: title screen and the loading screen that hands over to the
## world. The loading screen is driven against a stand-in world
## (tests/fixtures/stub_world.tscn) so the hand-over can be tested end to end
## without streaming a real map.

const LoadingScene := preload("res://scenes/loading_screen.tscn")
const TitleScene := preload("res://scenes/title_screen.tscn")
const StubWorldScript := preload("res://tests/fixtures/stub_world.gd")
const STUB_WORLD := "res://tests/fixtures/stub_world.tscn"

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


func test_title_screen_offers_a_drive_and_focuses_it() -> void:
	var title: Control = auto_free(TitleScene.instantiate())
	add_child(title)
	await _frames(2)
	assert_object(title.free_drive_button).is_not_null()
	assert_object(title.quit_button).is_not_null()
	assert_bool(title.free_drive_button.has_focus()).is_true()
