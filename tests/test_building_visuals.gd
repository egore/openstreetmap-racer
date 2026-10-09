extends GdUnitTestSuite


func _rectangle(origin: Vector3 = Vector3.ZERO, size: Vector2 = Vector2(10, 8), angle: float = 0.0) -> PackedVector3Array:
	var points := PackedVector3Array()
	for p: Vector3 in [Vector3.ZERO, Vector3(size.x, 0, 0), Vector3(size.x, 0, size.y), Vector3(0, 0, size.y), Vector3.ZERO]:
		points.append(origin + p.rotated(Vector3.UP, angle))
	return points


func _way(data: OSMParser.OSMData, id: int, points: PackedVector3Array, tags: Dictionary) -> OSMParser.OSMWay:
	var way := OSMParser.OSMWay.new()
	way.id = id
	way.tags = tags
	for i: int in range(points.size() - 1):
		var node := OSMParser.OSMNode.new()
		node.id = id * 100 + i
		node.local_pos = points[i]
		data.nodes[node.id] = node
		way.node_ids.append(node.id)
	way.node_ids.append(way.node_ids[0])
	data.ways[id] = way
	return way


func test_styles_are_stable_varied_and_do_not_mutate_osm() -> void:
	var tags := {"building": "house"}
	var styles := {}
	for id: int in range(20):
		var a := BuildingStyleResolver.resolve(tags, _rectangle(), id)
		var b := BuildingStyleResolver.resolve(tags, _rectangle(), id)
		assert_bool(a == b).is_true()
		styles[a.tags["building:colour"]] = true
	assert_int(styles.size()).is_greater(3)
	assert_int(tags.size()).is_equal(1)


func test_explicit_attributes_override_inference() -> void:
	var tags := {"building": "house", "height": "7.5", "building:colour": "#124578", "building:material": "wood", "roof:shape": "flat", "roof:material": "copper", "roof:colour": "#123456"}
	var style := BuildingStyleResolver.resolve(tags, _rectangle(), 31)
	for key: String in tags:
		assert_str(str(style.tags[key])).is_equal(str(tags[key]))
	var root := auto_free(OSMBuildingBuilder.new().build_building_from_polygon(_rectangle(), tags, 31)) as Node3D
	var walls := root.get_node("Walls") as MeshInstance3D
	assert_bool(walls.material_override.get_shader_parameter("base_color").is_equal_approx(Color("124578"))).is_true()
	var black := auto_free(OSMBuildingBuilder.new().build_building_from_polygon(_rectangle(), {"building": "house", "building:colour": "#000000", "roof:colour": "#000000"}, 32)) as Node3D
	for name_str: String in ["Walls", "Roof"]:
		assert_bool((black.get_node(name_str) as MeshInstance3D).material_override.get_shader_parameter("base_color").is_equal_approx(Color.BLACK)).is_true()


func test_roof_inference_is_conservative_and_keeps_facade_floors() -> void:
	var style := BuildingStyleResolver.resolve({"building": "house", "building:levels": "2"}, _rectangle(), 1)
	assert_str(style.tags["roof:shape"]).is_equal("gabled")
	for roof_tags: Dictionary in [{"building": "house", "building:levels": "2"}, {"building": "house", "building:levels": "2", "roof:shape": "gabled", "roof:height": "2.5"}]:
		var root := auto_free(OSMBuildingBuilder.new().build_building_from_polygon(_rectangle(), roof_tags, 1)) as Node3D
		assert_float((root.get_node("Walls") as MeshInstance3D).mesh.get_aabb().size.y).is_equal_approx(6.0, 0.001)
	var concave := PackedVector3Array([Vector3.ZERO, Vector3(10, 0, 0), Vector3(10, 0, 3), Vector3(3, 0, 3), Vector3(3, 0, 10), Vector3(0, 0, 10), Vector3.ZERO])
	for tags: Dictionary in [{"building": "warehouse"}, {"building:part": "yes"}, {"building": "house", "height": "3"}]:
		assert_str(BuildingStyleResolver.resolve(tags, _rectangle(), 1).tags["roof:shape"]).is_equal("flat")
	assert_str(BuildingStyleResolver.resolve({"building": "house"}, concave, 1).tags["roof:shape"]).is_equal("flat")


func test_uv_metres_and_normals_follow_rotated_elevated_geometry() -> void:
	var tags := {"building": "house", "height": "9", "roof:shape": "gabled", "roof:height": "3"}
	var root := auto_free(OSMBuildingBuilder.new().build_building_from_polygon(_rectangle(Vector3(300, 42, 600), Vector2(10, 8), PI / 4.0), tags, 7)) as Node3D
	assert_float(root.position.y).is_equal_approx(42.0, 0.001)
	for name_str: String in ["Walls", "Roof", "Gables"]:
		var mesh := (root.get_node(name_str) as MeshInstance3D).mesh
		var arrays := mesh.surface_get_arrays(0)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		var uv: PackedVector2Array = arrays[Mesh.ARRAY_TEX_UV]
		assert_int(arrays[Mesh.ARRAY_TANGENT].size()).is_equal(vertices.size() * 4)
		for i: int in range(0, vertices.size(), 3):
			var front := (vertices[i + 2] - vertices[i]).cross(vertices[i + 1] - vertices[i]).normalized()
			assert_float(front.dot(normals[i])).is_greater(0.99)
			for j: int in [1, 2]:
				assert_float(uv[i].distance_to(uv[i + j])).is_equal_approx(vertices[i].distance_to(vertices[i + j]), 0.002)


func test_party_walls_have_no_openings_but_exposed_walls_do() -> void:
	var data := OSMParser.OSMData.new()
	var way := _way(data, 1, _rectangle(), {"building": "house", "height": "6", "roof:shape": "flat"})
	_way(data, 2, _rectangle(Vector3(10, 0, 0)), {"building": "house", "height": "6"})
	var root := auto_free(OSMBuildingBuilder.new().build_building_from_way(way, data)) as Node3D
	var mesh := root.get_node("Openings") as MeshInstance3D
	assert_int(mesh.mesh.get_faces().size()).is_greater(0)
	for p: Vector3 in mesh.mesh.get_faces():
		assert_float(p.x).is_less(10.01)


func test_containing_outline_does_not_hide_part_windows() -> void:
	var data := OSMParser.OSMData.new()
	_way(data, 10, _rectangle(Vector3(-1, 0, -1), Vector2(12, 10)), {"building": "yes"})
	var part := _way(data, 11, _rectangle(), {"building:part": "yes", "height": "6"})
	var root := auto_free(OSMBuildingBuilder.new().build_building_from_way(part, data)) as Node3D
	assert_object(root.get_node_or_null("Openings")).is_not_null()


func test_tagged_entrance_controls_door_position() -> void:
	var data := OSMParser.OSMData.new()
	var way := _way(data, 1, _rectangle(), {"building": "house", "height": "6", "roof:shape": "flat"})
	var entrance := OSMParser.OSMNode.new()
	entrance.id = 999
	entrance.tags = {"entrance": "main"}
	entrance.local_pos = Vector3(7, 0, 0)
	data.nodes[999] = entrance
	way.node_ids.insert(1, 999)
	var root := auto_free(OSMBuildingBuilder.new().build_building_from_way(way, data)) as Node3D
	var arrays := (root.get_node("Openings") as MeshInstance3D).mesh.surface_get_arrays(0)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var colors: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
	var door_vertices := PackedVector3Array()
	for i: int in range(vertices.size()):
		if colors[i].g > 0.4:
			door_vertices.append(vertices[i])
	assert_int(door_vertices.size()).is_equal(6)
	var center := Vector3.ZERO
	for p: Vector3 in door_vertices:
		center += p / 6.0
	assert_float(center.x).is_equal_approx(7.0, 0.01)
	assert_float(center.z).is_equal_approx(-0.025, 0.01)


func test_fallback_door_faces_nearby_street() -> void:
	var data := OSMParser.OSMData.new()
	var way := _way(data, 1, _rectangle(), {"building": "house", "height": "6"})
	_way(data, 2, PackedVector3Array([Vector3(-20, 0, -5), Vector3(30, 0, -5), Vector3(-20, 0, -5)]), {"highway": "residential"})
	var root := auto_free(OSMBuildingBuilder.new().build_building_from_way(way, data)) as Node3D
	var arrays := (root.get_node("Openings") as MeshInstance3D).mesh.surface_get_arrays(0)
	var colors: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
	var door_count := 0
	for i: int in range(colors.size()):
		if colors[i].g > 0.4:
			assert_float(arrays[Mesh.ARRAY_VERTEX][i].z).is_equal_approx(-0.025, 0.01)
			door_count += 1
	assert_int(door_count).is_equal(6)


func test_canopies_and_roof_parts_have_no_fake_windows() -> void:
	for tags: Dictionary in [{"building": "roof"}, {"building:part": "roof"}, {"building": "greenhouse"}, {"building": "house", "windows": "no"}]:
		var root := auto_free(OSMBuildingBuilder.new().build_building_from_polygon(_rectangle(), tags, 1)) as Node3D
		assert_object(root.get_node_or_null("Openings")).is_null()


func test_details_are_batched_bounded_and_distance_limited() -> void:
	var root := auto_free(OSMBuildingBuilder.new().build_building_from_polygon(_rectangle(Vector3.ZERO, Vector2(150, 80)), {"building": "apartments", "height": "180"}, 1)) as Node3D
	var openings := root.get_node("Openings") as MeshInstance3D
	var trim := root.get_node("WindowTrim") as MeshInstance3D
	assert_int(openings.mesh.get_faces().size()).is_less_equal(BuildingFacadeBuilder.MAX_OPENINGS * 6)
	assert_int(root.get_child_count()).is_less(12)
	assert_float(openings.visibility_range_end).is_equal(0.0)
	assert_float(trim.visibility_range_end).is_equal(BuildingFacadeBuilder.DETAIL_DISTANCE)
	assert_int(trim.visibility_range_fade_mode).is_equal(GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF)
	assert_bool(openings.material_override.shader == BuildingFacadeBuilder.OPENING_SHADER).is_true()


func test_window_variation_survives_vertex_color_packing_and_reload() -> void:
	var tags := {"building": "house", "height": "6", "roof:shape": "flat"}
	var first := auto_free(OSMBuildingBuilder.new().build_building_from_polygon(_rectangle(), tags, 123)) as Node3D
	var second := auto_free(OSMBuildingBuilder.new().build_building_from_polygon(_rectangle(), tags, 123)) as Node3D
	var colors: PackedColorArray = (first.get_node("Openings") as MeshInstance3D).mesh.surface_get_arrays(0)[Mesh.ARRAY_COLOR]
	var reloaded: PackedColorArray = (second.get_node("Openings") as MeshInstance3D).mesh.surface_get_arrays(0)[Mesh.ARRAY_COLOR]
	assert_bool(colors == reloaded).is_true()
	var variants := {}
	for color: Color in colors:
		if color.g < 0.1:
			variants[roundi(color.r * 255.0)] = true
	assert_int(variants.size()).is_greater(4)


func test_roof_edges_extend_silhouette() -> void:
	var root := auto_free(OSMBuildingBuilder.new().build_building_from_polygon(_rectangle(), {"building": "house", "height": "9", "roof:shape": "gabled", "roof:height": "3"}, 1)) as Node3D
	var trim := root.get_node("RoofTrim") as MeshInstance3D
	var bounds := trim.mesh.get_aabb()
	assert_float(bounds.position.x).is_less(0.0)
	assert_float(bounds.end.x).is_greater(10.0)
	assert_object(root.get_node_or_null("RoofCaps")).is_not_null()
	assert_object(root.get_node_or_null("Gutters")).is_not_null()


func test_building_meshes_keep_a_cpu_copy_instead_of_reading_the_gpu_back() -> void:
	for tags: Dictionary in [{"building": "house", "roof:shape": "gabled", "roof:height": "3", "height": "9"}, {"building": "house", "roof:shape": "flat", "height": "6"}]:
		var root := auto_free(OSMBuildingBuilder.new().build_building_from_polygon(_rectangle(), tags, 1)) as Node3D
		for name_str: String in ["Walls", "Roof"]:
			var mi := root.get_node(name_str) as MeshInstance3D
			assert_bool(mi.has_meta(BuildingSurfaceUV.CPU_SURFACES_META)).is_true()
			assert_int(BuildingSurfaceUV.faces_of(mi).size()).is_equal(mi.mesh.get_faces().size())


func test_buildings_with_the_same_look_share_materials() -> void:
	var tags := {"building": "house", "height": "6", "roof:shape": "gabled", "roof:height": "2", "building:colour": "#805044", "roof:colour": "#4b4c50"}
	var first := auto_free(OSMBuildingBuilder.new().build_building_from_polygon(_rectangle(), tags, 1)) as Node3D
	var second := auto_free(OSMBuildingBuilder.new().build_building_from_polygon(_rectangle(Vector3(40, 0, 0)), tags, 1)) as Node3D
	for name_str: String in ["Walls", "Roof", "WindowTrim", "RoofCaps"]:
		var a := first.get_node(name_str) as MeshInstance3D
		var b := second.get_node(name_str) as MeshInstance3D
		assert_bool(a.material_override == b.material_override).is_true()
