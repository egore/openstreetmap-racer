extends SceneTree

# godot --path . -s tools/building_preview.gd -- --output-dir /path/to/captures

var _world: Node3D
var _camera: Camera3D
var _sky: SkyController


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var output := "user://building-preview"
	var args := OS.get_cmdline_user_args()
	var index := args.find("--output-dir")
	if index >= 0 and index + 1 < args.size():
		output = args[index + 1]
	DirAccess.make_dir_recursive_absolute(output)
	root.size = Vector2i(1280, 720)
	_world = Node3D.new()
	root.add_child(_world)
	var environment := WorldEnvironment.new()
	environment.name = "Environment"
	environment.environment = Environment.new()
	environment.environment.background_mode = Environment.BG_SKY
	environment.environment.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	environment.environment.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	environment.environment.ssao_enabled = true
	environment.environment.glow_enabled = true
	environment.environment.sky = Sky.new()
	var sky_material := ShaderMaterial.new()
	sky_material.shader = load("res://scripts/shaders/sky.gdshader")
	environment.environment.sky.sky_material = sky_material
	_world.add_child(environment)
	var sun := DirectionalLight3D.new()
	sun.name = "Sun"
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 200.0
	_world.add_child(sun)
	_sky = SkyController.new()
	_sky.world_environment_path = NodePath("../Environment")
	_sky.sun_light_path = NodePath("../Sun")
	_world.add_child(_sky)
	_camera = Camera3D.new()
	_camera.fov = 65.0
	_camera.far = 1000.0
	_world.add_child(_camera)
	_camera.current = true
	_box(Vector3(20, -0.3, 0), Vector3(300, 0.5, 200), Color("656d52"))
	_box(Vector3(20, -0.02, -8), Vector3(250, 0.05, 10), Color("363a3d"))
	_box(Vector3(20, 0.03, -2), Vector3(180, 0.14, 2.0), Color("a19e92"))
	for x: int in range(-70, 100, 6):
		_box(Vector3(x, 0.02, -8), Vector3(2.5, 0.02, 0.12), Color("dddac8"))
	var data := OSMParser.OSMData.new()
	var specs := [
		{"building": "house", "building:levels": "2"},
		{"building": "house", "building:material": "plaster", "building:colour": "#d9d2bc", "roof:shape": "hipped", "height": "9"},
		{"building": "retail", "building:levels": "2", "roof:shape": "gabled", "roof:levels": "1"},
		{"building": "apartments", "building:levels": "4"},
		{"building": "warehouse", "height": "7"},
	]
	for i: int in range(specs.size()):
		var way := OSMParser.OSMWay.new()
		way.id = 100 + i
		way.tags = specs[i]
		var x := i * 13.0
		var points := [Vector3(x, 0, 0), Vector3(x + 10, 0, 0), Vector3(x + 10, 0, 10), Vector3(x, 0, 10)]
		for j: int in range(4):
			var node := OSMParser.OSMNode.new()
			node.id = way.id * 10 + j
			node.local_pos = points[j]
			data.nodes[node.id] = node
			way.node_ids.append(node.id)
		way.node_ids.append(way.node_ids[0])
		data.ways[way.id] = way
	var road := OSMParser.OSMWay.new()
	road.id = 900
	road.tags = {"highway": "residential"}
	for i: int in range(2):
		var node := OSMParser.OSMNode.new()
		node.id = 9000 + i
		node.local_pos = Vector3(-50 + i * 200, 0, -8)
		data.nodes[node.id] = node
		road.node_ids.append(node.id)
	data.ways[road.id] = road
	var builder := OSMBuildingBuilder.new()
	var start := Time.get_ticks_usec()
	for way: OSMParser.OSMWay in data.ways.values():
		if way.tags.has("building"):
			_world.add_child(builder.build_building_from_way(way, data))
	print("Preview buildings built in %.2f ms" % ((Time.get_ticks_usec() - start) / 1000.0))
	_camera.position = Vector3(21, 6, -31)
	_camera.look_at(Vector3(25, 4, 3))
	await _capture(output.path_join("day.png"))
	_camera.position = Vector3(2, 3, -13)
	_camera.look_at(Vector3(10, 4, 2))
	await _capture(output.path_join("close.png"))
	_camera.position = Vector3(25, 16, -145)
	_camera.look_at(Vector3(25, 4, 3))
	await _capture(output.path_join("distant.png"))
	_camera.position = Vector3(21, 6, -31)
	_camera.look_at(Vector3(25, 4, 3))
	_sky.set_day(false)
	await create_timer(1.7).timeout
	await _capture(output.path_join("night.png"))
	quit()


func _box(position: Vector3, size: Vector3, color: Color) -> void:
	var instance := MeshInstance3D.new()
	var mesh := BoxMesh.new()
	mesh.size = size
	instance.mesh = mesh
	instance.position = position
	instance.material_override = BuildingDetailGeometry.matte(color)
	_world.add_child(instance)


func _capture(path: String) -> void:
	for frame: int in range(12):
		await process_frame
	await RenderingServer.frame_post_draw
	var image := root.get_texture().get_image()
	var error := image.save_png(path)
	if error != OK:
		push_error("Could not save preview: %s" % path)
		quit(1)
	print("Saved ", path)
