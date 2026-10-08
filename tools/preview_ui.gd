extends SceneTree

## Capture the actual HUD and pause menu without loading the streamed 3D world.
## Run with: godot --path . --script tools/preview_ui.gd

func _initialize() -> void:
	call_deferred("_capture")

func _capture() -> void:
	root.size = Vector2i(1280, 720)
	var backdrop := ColorRect.new()
	backdrop.color = Color("35454b")
	backdrop.size = Vector2(1280, 720)
	root.add_child(backdrop)
	var scene := load("res://scenes/main.tscn").instantiate() as Node
	# The UI-only preview does not run the car's _ready to parent its engine.
	scene.get_node("Car")._engine_sound.free()
	var hud := scene.get_node("HUD")
	var menu := scene.get_node("PauseMenu")
	scene.remove_child(hud)
	scene.remove_child(menu)
	scene.free()
	root.add_child(hud)
	root.add_child(menu)
	var car := VehicleBody3D.new()
	root.add_child(car)
	var map: Minimap = hud.get_node("Minimap")
	map.car_node_path = NodePath()
	map.tile_manager_node_path = NodePath()
	map._car = car
	map.queue_redraw()
	await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("user://hud-preview.png")
	menu.visible = true
	await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("user://pause-preview.png")
	print("UI previews: ", ProjectSettings.globalize_path("user://"))
	hud.free()
	menu.free()
	car.free()
	backdrop.free()
	quit()
