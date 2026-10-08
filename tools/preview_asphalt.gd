extends SceneTree

## Render a fixed five-metre carriageway for reproducible shader comparisons.
## Optional arguments after --: shader source path, output PNG path.

func _initialize() -> void:
	call_deferred("_capture")

func _capture() -> void:
	root.size = Vector2i(1280, 720)
	RenderingServer.global_shader_parameter_set("wetness", 0.0)
	var world := Node3D.new()
	root.add_child(world)
	var environment := WorldEnvironment.new()
	environment.environment = Environment.new()
	environment.environment.background_mode = Environment.BG_COLOR
	environment.environment.background_color = Color("a9bfd3")
	environment.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.environment.ambient_light_color = Color.WHITE
	environment.environment.ambient_light_energy = 0.5
	world.add_child(environment)
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-40, -30, 0)
	world.add_child(light)
	var args := OS.get_cmdline_user_args()
	var shader := load("res://scripts/shaders/asphalt.gdshader") as Shader
	if not args.is_empty():
		shader = Shader.new()
		shader.code = FileAccess.get_file_as_string(args[0])
	var material := ShaderMaterial.new()
	material.shader = shader
	material.set_shader_parameter("base_color", Color(0.2, 0.2, 0.2))
	var road := MeshInstance3D.new()
	var plane := PlaneMesh.new()
	plane.size = Vector2(5, 100)
	road.mesh = plane
	road.material_override = material
	road.position.z = -40
	world.add_child(road)
	for side in [-1, 1]:
		for z in range(-40, 8, 4):
			var marker := MeshInstance3D.new()
			var box := BoxMesh.new()
			box.size = Vector3(0.15, 0.5, 0.15)
			marker.mesh = box
			marker.position = Vector3(side * 2.65, 0.25, z)
			world.add_child(marker)
	var camera := Camera3D.new()
	world.add_child(camera)
	camera.position = Vector3(0, 4, 8)
	camera.look_at(Vector3(0, 0, -12))
	camera.current = true
	await process_frame
	await RenderingServer.frame_post_draw
	var output := args[1] if args.size() > 1 else "user://asphalt-preview.png"
	root.get_texture().get_image().save_png(output)
	print("Asphalt preview: ", output)
	if args.is_empty():
		camera.position = Vector3(0, 0.3, 0.4)
		camera.look_at(Vector3(0, 0, -0.3))
		await process_frame
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png("user://asphalt-closeup.png")
		material.shader = load("res://scripts/shaders/asphalt_junction.gdshader")
		material.set_shader_parameter("base_color", Color(0.2, 0.2, 0.2))
		RenderingServer.global_shader_parameter_set("wetness", 1.0)
		await process_frame
		await RenderingServer.frame_post_draw
		root.get_texture().get_image().save_png("user://asphalt-wet-junction.png")
	world.free()
	quit()
