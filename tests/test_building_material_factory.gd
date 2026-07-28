extends GdUnitTestSuite

## Unit tests for BuildingMaterialFactory — the procedural-PBR wall/roof material
## builder (the building-side analogue of RoadMaterialFactory).
##
## The class is pure/static: it classifies an OSM material string into a shader
## "surface kind", builds a shared-shader ShaderMaterial tinted by colour+kind,
## and (apply_to_building) routes those materials onto a finished mesh subtree by
## node name. Tests drive each piece directly — no OSM data, no geometry, no
## renderer — building a synthetic Building_/Walls/Roof node tree where needed.



# ─── Material classification ─────────────────────────────────────────────────

## Masonry materials map to the MASONRY wall kind.
func test_masonry_materials_classify() -> void:
	for m: String in ["brick", "stone", "sandstone", "granite", "marble", "cement_block"]:
		assert_int(BuildingMaterialFactory.wall_kind_for(m)) \
			.override_failure_message("'%s' is masonry" % m) \
			.is_equal(BuildingMaterialFactory.WallKind.MASONRY)


## Panel materials (concrete/metal/glass) map to PANEL.
func test_panel_materials_classify() -> void:
	for m: String in ["concrete", "metal", "steel", "glass"]:
		assert_int(BuildingMaterialFactory.wall_kind_for(m)) \
			.override_failure_message("'%s' is a panel wall" % m) \
			.is_equal(BuildingMaterialFactory.WallKind.PANEL)


## Plaster/render/wood and anything unknown fall back to SMOOTH.
func test_wall_default_is_smooth() -> void:
	for m: String in ["plaster", "render", "stucco", "wood", "", "unobtanium"]:
		assert_int(BuildingMaterialFactory.wall_kind_for(m)) \
			.override_failure_message("'%s' → smooth wall" % m) \
			.is_equal(BuildingMaterialFactory.WallKind.SMOOTH)


## Wall classification ignores case and surrounding whitespace.
func test_wall_kind_is_case_and_space_insensitive() -> void:
	assert_int(BuildingMaterialFactory.wall_kind_for("  BRICK ")).is_equal(BuildingMaterialFactory.WallKind.MASONRY)
	assert_int(BuildingMaterialFactory.wall_kind_for("Concrete")).is_equal(BuildingMaterialFactory.WallKind.PANEL)


## Tile/slate/thatch roofs map to TILES.
func test_tile_roofs_classify() -> void:
	for m: String in ["roof_tiles", "tile", "tiles", "slate", "thatch"]:
		assert_int(BuildingMaterialFactory.roof_kind_for(m)) \
			.override_failure_message("'%s' is a tiled roof" % m) \
			.is_equal(BuildingMaterialFactory.RoofKind.TILES)


## Metal roof coverings map to METAL.
func test_metal_roofs_classify() -> void:
	for m: String in ["metal", "zinc", "tin", "copper"]:
		assert_int(BuildingMaterialFactory.roof_kind_for(m)) \
			.override_failure_message("'%s' is a metal roof" % m) \
			.is_equal(BuildingMaterialFactory.RoofKind.METAL)


## Membrane/gravel/grass/concrete roofs map to FLAT.
func test_flat_roofs_classify() -> void:
	for m: String in ["tar_paper", "gravel", "grass", "concrete", "glass", "eternit"]:
		assert_int(BuildingMaterialFactory.roof_kind_for(m)) \
			.override_failure_message("'%s' is a flat-membrane roof" % m) \
			.is_equal(BuildingMaterialFactory.RoofKind.FLAT)


## Unknown/empty roof material defaults to TILES.
func test_roof_default_is_tiles() -> void:
	assert_int(BuildingMaterialFactory.roof_kind_for("")).is_equal(BuildingMaterialFactory.RoofKind.TILES)
	assert_int(BuildingMaterialFactory.roof_kind_for("mystery")).is_equal(BuildingMaterialFactory.RoofKind.TILES)


# ─── Material construction ───────────────────────────────────────────────────

## A wall material is a ShaderMaterial carrying the tint and kind uniforms.
func test_wall_material_carries_colour_and_kind() -> void:
	var c := Color(0.6, 0.3, 0.2)
	var mat := BuildingMaterialFactory.create_wall_material(c, BuildingMaterialFactory.WallKind.MASONRY)
	assert_object(mat).is_not_null()
	assert_object(mat.shader).override_failure_message("wall mat has a shader").is_not_null()
	var bc = mat.get_shader_parameter("base_color")
	assert_vector(Vector3(bc.r, bc.g, bc.b)) \
		.is_equal_approx(Vector3(c.r, c.g, c.b), Vector3.ONE * 0.001)
	assert_float(float(mat.get_shader_parameter("surface_kind"))) \
		.override_failure_message("surface_kind matches the requested masonry kind") \
		.is_equal_approx(float(BuildingMaterialFactory.WallKind.MASONRY), 0.001)


## A roof material likewise carries its tint and kind.
func test_roof_material_carries_colour_and_kind() -> void:
	var c := Color(0.5, 0.5, 0.55)
	var mat := BuildingMaterialFactory.create_roof_material(c, BuildingMaterialFactory.RoofKind.METAL)
	assert_object(mat.shader).is_not_null()
	assert_float(float(mat.get_shader_parameter("surface_kind"))) \
		.is_equal_approx(float(BuildingMaterialFactory.RoofKind.METAL), 0.001)


## Wall and roof shaders are distinct resources (not accidentally the same).
func test_wall_and_roof_use_different_shaders() -> void:
	var w := BuildingMaterialFactory.create_wall_material(Color.WHITE)
	var r := BuildingMaterialFactory.create_roof_material(Color.WHITE)
	assert_bool(w.shader == r.shader) \
		.override_failure_message("wall and roof use different shaders").is_false()


# ─── Weathering defaults ─────────────────────────────────────────────────────

## Every wall material carries a weathering strength in the shader's [0,1] range.
func test_wall_material_sets_weathering_in_range() -> void:
	for kind: int in [BuildingMaterialFactory.WallKind.SMOOTH,
			BuildingMaterialFactory.WallKind.MASONRY,
			BuildingMaterialFactory.WallKind.PANEL]:
		var w = BuildingMaterialFactory.create_wall_material(Color.WHITE, kind)
		var wv = float(w.get_shader_parameter("weathering"))
		assert_float(wv) \
			.override_failure_message("wall weathering for kind %d in [0,1]" % kind) \
			.is_between(0.0, 1.0)


## Masonry weathers more than a glass/metal panel (brick soaks up grime; panels
## self-clean). Pins the intended relative ordering, not exact magnitudes.
func test_masonry_weathers_more_than_panel() -> void:
	var masonry := BuildingMaterialFactory.create_wall_material(Color.WHITE, BuildingMaterialFactory.WallKind.MASONRY)
	var panel := BuildingMaterialFactory.create_wall_material(Color.WHITE, BuildingMaterialFactory.WallKind.PANEL)
	assert_float(float(masonry.get_shader_parameter("weathering"))) \
		.override_failure_message("masonry grimes up more than a panel wall") \
		.is_greater(float(panel.get_shader_parameter("weathering")))


## Every roof material carries a weathering strength in the shader's [0,1] range.
func test_roof_material_sets_weathering_in_range() -> void:
	for kind: int in [BuildingMaterialFactory.RoofKind.TILES,
			BuildingMaterialFactory.RoofKind.FLAT,
			BuildingMaterialFactory.RoofKind.METAL]:
		var r = BuildingMaterialFactory.create_roof_material(Color.WHITE, kind)
		assert_float(float(r.get_shader_parameter("weathering"))) \
			.override_failure_message("roof weathering for kind %d in [0,1]" % kind) \
			.is_between(0.0, 1.0)


## Tiled roofs moss/fade more than a metal roof.
func test_tiles_weather_more_than_metal() -> void:
	var tiles := BuildingMaterialFactory.create_roof_material(Color.WHITE, BuildingMaterialFactory.RoofKind.TILES)
	var metal := BuildingMaterialFactory.create_roof_material(Color.WHITE, BuildingMaterialFactory.RoofKind.METAL)
	assert_float(float(tiles.get_shader_parameter("weathering"))) \
		.override_failure_message("tiled roofs weather more than metal") \
		.is_greater(float(metal.get_shader_parameter("weathering")))


# ─── apply_to_building over a subtree ────────────────────────────────────────

## A MeshInstance3D named `n` carrying a flat StandardMaterial3D of `color` on
## its (single) surface — mimics what the geometry builders produce.
func _flat_mesh(n: String, color: Color) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = n
	var arr_mesh := ArrayMesh.new()
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector3Array([Vector3.ZERO, Vector3.RIGHT, Vector3.UP])
	arr_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var m := StandardMaterial3D.new()
	m.albedo_color = color
	arr_mesh.surface_set_material(0, m)
	mi.mesh = arr_mesh
	return mi


## apply_to_building puts the ROOF shader on "Roof" nodes and the WALL shader on
## everything else, and reports the count of meshes it touched.
func test_apply_routes_roof_vs_wall_by_name() -> void:
	var root := Node3D.new()
	root.name = "Building_1"
	var walls := _flat_mesh("Walls", Color(0.7, 0.68, 0.62))
	var roof := _flat_mesh("Roof", Color(0.7, 0.35, 0.25))
	var gables := _flat_mesh("Gables", Color(0.7, 0.68, 0.62))
	root.add_child(walls)
	root.add_child(roof)
	root.add_child(gables)
	add_child(root)

	var count := BuildingMaterialFactory.apply_to_building(root, BuildingMaterialFactory.WallKind.MASONRY, BuildingMaterialFactory.RoofKind.METAL)
	assert_int(count).override_failure_message("all three meshes reassigned").is_equal(3)

	# Roof uses the roof shader at the metal kind.
	var roof_mat := roof.material_override as ShaderMaterial
	assert_object(roof_mat).override_failure_message("roof got a ShaderMaterial").is_not_null()
	assert_float(float(roof_mat.get_shader_parameter("surface_kind"))) \
		.is_equal_approx(float(BuildingMaterialFactory.RoofKind.METAL), 0.001)

	# Walls and gables use the wall shader at the masonry kind.
	for wall_node: MeshInstance3D in [walls, gables]:
		var wm := wall_node.material_override as ShaderMaterial
		assert_object(wm).override_failure_message("%s got a wall ShaderMaterial" % wall_node.name).is_not_null()
		assert_float(float(wm.get_shader_parameter("surface_kind"))) \
			.is_equal_approx(float(BuildingMaterialFactory.WallKind.MASONRY), 0.001)

	root.free()


## The per-building/roof tints baked by the geometry builders carry through into
## the new shader materials' base_color.
func test_apply_preserves_existing_tints() -> void:
	var root := Node3D.new()
	var wall_c := Color(0.65, 0.35, 0.25)
	var roof_c := Color(0.35, 0.35, 0.4)
	var walls := _flat_mesh("Walls", wall_c)
	var roof := _flat_mesh("Roof", roof_c)
	root.add_child(walls)
	root.add_child(roof)
	add_child(root)

	BuildingMaterialFactory.apply_to_building(root, BuildingMaterialFactory.WallKind.SMOOTH, BuildingMaterialFactory.RoofKind.TILES)

	var wc = (walls.material_override as ShaderMaterial).get_shader_parameter("base_color")
	assert_vector(Vector3(wc.r, wc.g, wc.b)) \
		.override_failure_message("wall tint carried through") \
		.is_equal_approx(Vector3(wall_c.r, wall_c.g, wall_c.b), Vector3.ONE * 0.001)
	var rc = (roof.material_override as ShaderMaterial).get_shader_parameter("base_color")
	assert_vector(Vector3(rc.r, rc.g, rc.b)) \
		.override_failure_message("roof tint carried through") \
		.is_equal_approx(Vector3(roof_c.r, roof_c.g, roof_c.b), Vector3.ONE * 0.001)

	root.free()


## Skillion/sawtooth wall pieces (named "*Walls") are treated as walls.
func test_apply_treats_named_walls_as_walls() -> void:
	var root := Node3D.new()
	var skillion := _flat_mesh("SkillionWalls", Color(0.7, 0.68, 0.62))
	root.add_child(skillion)
	add_child(root)

	BuildingMaterialFactory.apply_to_building(root, BuildingMaterialFactory.WallKind.PANEL, BuildingMaterialFactory.RoofKind.TILES)
	var m := skillion.material_override as ShaderMaterial
	assert_object(m).is_not_null()
	assert_float(float(m.get_shader_parameter("surface_kind"))) \
		.override_failure_message("SkillionWalls uses the wall (panel) kind") \
		.is_equal_approx(float(BuildingMaterialFactory.WallKind.PANEL), 0.001)
	root.free()


## An empty subtree paints nothing and doesn't error.
func test_apply_on_empty_tree() -> void:
	var root := Node3D.new()
	add_child(root)
	assert_int(BuildingMaterialFactory.apply_to_building(root, BuildingMaterialFactory.WallKind.SMOOTH, BuildingMaterialFactory.RoofKind.TILES)).is_equal(0)
	root.free()
