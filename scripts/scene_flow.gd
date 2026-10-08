extends RefCounted

## Moves the player between the front end and a drive:
##
##   title screen  --start_drive-->  loading screen  -->  main (the world)
##        ^                                                 |
##        +-------------------- go_to_title ----------------+
##
## Static helpers rather than an autoload, so main.tscn still runs on its own
## from the editor (F6) and in tests, with nothing global to set up first.

const RunSessionScript := preload("res://scripts/run_session.gd")

const TITLE_SCENE := "res://scenes/title_screen.tscn"
const LOADING_SCENE := "res://scenes/loading_screen.tscn"


## Leave the current scene for the loading screen, which builds the world and
## hands over to it.
static func start_drive(
		tree: SceneTree,
		mode: RunSessionScript.Mode = RunSessionScript.Mode.FREE_DRIVE) -> void:
	tree.paused = false
	var loading: Node = (load(LOADING_SCENE) as PackedScene).instantiate()
	loading.set("game_mode", mode)
	_replace_current_scene(tree, loading)


static func go_to_title(tree: SceneTree) -> void:
	tree.paused = false
	tree.change_scene_to_file(TITLE_SCENE)


## Like change_scene_to_packed, but with the instance in hand so the caller can
## configure it before it enters the tree.
static func _replace_current_scene(tree: SceneTree, scene: Node) -> void:
	var old := tree.current_scene
	tree.root.add_child(scene)
	tree.current_scene = scene
	if old != null:
		old.queue_free()
