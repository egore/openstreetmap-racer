extends GdUnitTestSuite

## Tests that the road builder emits marking-ready geometry and materials:
##   • the asphalt ShaderMaterial gets the lane-marking uniforms from the tags
##   • the ribbon carries UVs (metres-along, fraction-across) the shader needs
##   • unpaved types stay a plain matte material with markings disabled

const OSMParser := preload("res://scripts/osm_parser.gd")
const OSMWayBuilder := preload("res://scripts/osm_way_builder.gd")
const RoadMaterialFactory := preload("res://scripts/road_material_factory.gd")
const RoadLaneSpec := preload("res://scripts/road_lane_spec.gd")


func _node(id: int, x: float, z: float) -> OSMParser.OSMNode:
	var n := OSMParser.OSMNode.new()
	n.id = id
	n.local_pos = Vector3(x, 0.0, z)
	return n


## A single straight residential road (no junctions), flat world.
func _make_road(tags: Dictionary) -> Dictionary:
	var data := OSMParser.OSMData.new()
	data.nodes = {1: _node(1, 0.0, 0.0), 2: _node(2, 0.0, 100.0)}
	var way := OSMParser.OSMWay.new()
	way.id = 1
	way.node_ids = [1, 2] as Array[int]
	way.tags = tags
	data.ways = {1: way}
	return {"data": data, "way": way}


func test_material_factory_enables_markings_for_paved() -> void:
	var spec := RoadLaneSpec.from_tags("primary", {"lanes": "4"})
	var mat := RoadMaterialFactory.create_road_material(
		"primary", Color(0.17, 0.17, 0.18), spec, 14.0, 100.0)
	assert_object(mat).is_instanceof(ShaderMaterial)
	var sm := mat as ShaderMaterial
	assert_float(sm.get_shader_parameter("markings_enabled")).is_equal(1.0)
	assert_float(sm.get_shader_parameter("lane_count")).is_equal(4.0)
	assert_float(sm.get_shader_parameter("forward_lanes")).is_equal(2.0)
	assert_float(sm.get_shader_parameter("road_width")).is_equal(14.0)
	assert_float(sm.get_shader_parameter("one_way")).is_equal(0.0)


func test_material_factory_oneway_sets_flag() -> void:
	var spec := RoadLaneSpec.from_tags("primary", {"lanes": "3", "oneway": "yes"})
	var mat := RoadMaterialFactory.create_road_material(
		"primary", Color(0.17, 0.17, 0.18), spec, 10.5, 200.0) as ShaderMaterial
	assert_float(mat.get_shader_parameter("one_way")).is_equal(1.0)


func test_material_factory_unpaved_is_plain_matte() -> void:
	var spec := RoadLaneSpec.from_tags("footway", {})
	var mat := RoadMaterialFactory.create_road_material(
		"footway", Color(0.32, 0.27, 0.21), spec, 1.5, 50.0)
	assert_object(mat).is_instanceof(StandardMaterial3D)


func test_road_mesh_has_across_uvs_spanning_zero_to_one() -> void:
	# The ribbon UVs must span the carriageway: UV.y ~0 on one edge, ~1 on the
	# other, so the shader can place markings across the road.
	var fx := _make_road({"highway": "residential", "sidewalk": "no", "lanes": "2"})
	var builder := OSMWayBuilder.new()
	var mesh_inst := builder.build_road(fx["way"], fx["data"])
	assert_object(mesh_inst).is_not_null()
	if mesh_inst == null:
		return

	var mdt := MeshDataTool.new()
	assert_int(mdt.create_from_surface(mesh_inst.mesh, 0)).is_equal(OK)
	var min_v := INF
	var max_v := -INF
	var max_u := -INF
	for vi: int in range(mdt.get_vertex_count()):
		var uv := mdt.get_vertex_uv(vi)
		min_v = minf(min_v, uv.y)
		max_v = maxf(max_v, uv.y)
		max_u = maxf(max_u, uv.x)
	mesh_inst.free()

	assert_float(min_v).override_failure_message("left edge UV.y ~ 0").is_less_equal(0.01)
	assert_float(max_v).override_failure_message("right edge UV.y ~ 1").is_greater_equal(0.99)
	# UV.x is metres along a 100 m road → the far end should be ~100.
	assert_float(max_u).override_failure_message("UV.x reaches road length").is_greater_equal(99.0)


# ─── Junction trimming rebases markings ─────────────────────────────────────

func test_markings_rebase_when_the_road_is_trimmed() -> void:
	# REGRESSION: marking distances are measured from the way's ORIGINAL start,
	# but junction trimming moves the ribbon's UV origin down the road. Without
	# rebasing, every marking on a road meeting an intersection was painted
	# `trim` metres too far along — crossings drifted, some landing out in the
	# intersection itself.
	var spec := RoadMarkingSpec.new()
	spec.markings.append(RoadMarkingSpec.Marking.new(20.0, RoadMarkingSpec.Kind.ZEBRA))
	spec.markings.append(RoadMarkingSpec.Marking.new(50.0, RoadMarkingSpec.Kind.STOP))

	var rebased := spec.rebased(4.7)
	assert_int(rebased.markings.size()).is_equal(2)
	assert_float(rebased.markings[0].along) \
		.override_failure_message("marking must shift back by the trim distance") \
		.is_equal_approx(15.3, 0.001)
	assert_float(rebased.markings[1].along).is_equal_approx(45.3, 0.001)
	# Kinds must survive the rebase.
	assert_int(rebased.markings[1].kind).is_equal(RoadMarkingSpec.Kind.STOP)


func test_rebase_drops_markings_swallowed_by_the_junction() -> void:
	# A marking that now sits before the ribbon start lay inside the
	# intersection; the cap covers that ground and paints its own markings.
	var spec := RoadMarkingSpec.new()
	spec.markings.append(RoadMarkingSpec.Marking.new(2.0, RoadMarkingSpec.Kind.ZEBRA))
	spec.markings.append(RoadMarkingSpec.Marking.new(30.0, RoadMarkingSpec.Kind.ZEBRA))

	var rebased := spec.rebased(10.0)
	assert_int(rebased.markings.size()) \
		.override_failure_message("a marking inside the junction must be dropped") \
		.is_equal(1)
	assert_float(rebased.markings[0].along).is_equal_approx(20.0, 0.001)


func test_rebase_by_zero_is_a_no_op() -> void:
	var spec := RoadMarkingSpec.new()
	spec.markings.append(RoadMarkingSpec.Marking.new(12.0, RoadMarkingSpec.Kind.ZEBRA))
	var rebased := spec.rebased(0.0)
	assert_int(rebased.markings.size()).is_equal(1)
	assert_float(rebased.markings[0].along).is_equal_approx(12.0, 0.001)
