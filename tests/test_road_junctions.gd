extends GdUnitTestSuite

## Junction rendering tests.
##
## We render roads the way Mapnik does: every road way is kept FULL-LENGTH and
## simply overlaps other roads where they connect, so junctions read as one
## continuous connected surface with NO gaps. The z-fighting that coplanar
## overlap would otherwise cause is handled at draw time — the asphalt material
## does not write depth and carries a per-highway-class render_priority, so a
## bigger road paints on top of a smaller one at a junction (the 3D analogue of
## Mapnik's "all casings, then all fills" layer order).
##
## These tests pin: (1) roads are no longer trimmed back from shared nodes, and
## (2) the material layering that prevents z-fighting is configured.

const OSMParser := preload("res://scripts/osm_parser.gd")
const OSMWayBuilder := preload("res://scripts/osm_way_builder.gd")
const RoadMaterialFactory := preload("res://scripts/road_material_factory.gd")


func _node(id: int, x: float, z: float) -> OSMParser.OSMNode:
	var n := OSMParser.OSMNode.new()
	n.id = id
	n.local_pos = Vector3(x, 0.0, z)
	return n


func _way(id: int, node_ids: Array, tags: Dictionary) -> OSMParser.OSMWay:
	var w := OSMParser.OSMWay.new()
	w.id = id
	var ids: Array[int] = []
	for n: int in node_ids:
		ids.append(n)
	w.node_ids = ids
	var t := {"sidewalk": "no"}
	t.merge(tags)
	w.tags = t
	return w


func _bounds_of_mesh(mesh: Mesh) -> Dictionary:
	var mdt := MeshDataTool.new()
	if mdt.create_from_surface(mesh, 0) != OK:
		return {}
	var b := {"min_x": INF, "max_x": -INF, "min_z": INF, "max_z": -INF}
	for vi: int in range(mdt.get_vertex_count()):
		var v := mdt.get_vertex(vi)
		b["min_x"] = minf(b["min_x"], v.x)
		b["max_x"] = maxf(b["max_x"], v.x)
		b["min_z"] = minf(b["min_z"], v.z)
		b["max_z"] = maxf(b["max_z"], v.z)
	return b


# ─── Roads are kept full-length (NOT trimmed) so junctions stay connected ────

func test_branch_reaches_the_junction_node() -> void:
	# Side road runs from a shared junction node (0,0) north to (0,40). It must
	# reach ALL the way to Z=0 (the junction), not stop short — connected roads
	# must not have a gap between them.
	var data := OSMParser.OSMData.new()
	data.nodes = {
		1: _node(1, -50, 0), 2: _node(2, 0, 0), 3: _node(3, 50, 0), 4: _node(4, 0, 40),
	}
	data.ways = {
		1: _way(1, [1, 2, 3], {"highway": "residential"}),
		2: _way(2, [2, 4], {"highway": "residential"}),
	}
	var mi := OSMWayBuilder.new().build_road(data.ways[2], data)
	assert_object(mi).is_not_null()
	if mi == null: return
	var b := _bounds_of_mesh(mi.mesh)
	mi.free()
	# The branch's near end must reach the junction (Z≈0), i.e. overlap the
	# through road rather than being pulled back to its edge.
	assert_float(b["min_z"]) \
		.override_failure_message("branch must reach the junction node (Z≈0), got %.3f" % b["min_z"]) \
		.is_less_equal(0.01)
	assert_float(b["max_z"]) \
		.override_failure_message("branch must extend to its far node (Z≈40), got %.3f" % b["max_z"]) \
		.is_greater_equal(39.9)


func test_split_junction_arm_reaches_node() -> void:
	# Split junction: the through road is cut at node 2 (endpoint of two ways),
	# with a branch also ending at node 2. Every arm must still reach node 2.
	var data := OSMParser.OSMData.new()
	data.nodes = {
		1: _node(1, -50, 0), 2: _node(2, 0, 0), 3: _node(3, 50, 0), 4: _node(4, 0, 40),
	}
	data.ways = {
		1: _way(1, [1, 2], {"highway": "residential"}),
		2: _way(2, [2, 3], {"highway": "residential"}),
		3: _way(3, [2, 4], {"highway": "residential"}),
	}
	var mi := OSMWayBuilder.new().build_road(data.ways[3], data)
	assert_object(mi).is_not_null()
	if mi == null: return
	var b := _bounds_of_mesh(mi.mesh)
	mi.free()
	assert_float(b["min_z"]) \
		.override_failure_message("split-junction branch must reach node 2 (Z≈0), got %.3f" % b["min_z"]) \
		.is_less_equal(0.01)


func test_through_road_spans_full_length() -> void:
	var data := OSMParser.OSMData.new()
	data.nodes = {
		1: _node(1, -50, 0), 2: _node(2, 0, 0), 3: _node(3, 50, 0), 4: _node(4, 0, 40),
	}
	data.ways = {
		1: _way(1, [1, 2, 3], {"highway": "residential"}),
		2: _way(2, [2, 4], {"highway": "residential"}),
	}
	var mi := OSMWayBuilder.new().build_road(data.ways[1], data)
	assert_object(mi).is_not_null()
	if mi == null: return
	var b := _bounds_of_mesh(mi.mesh)
	mi.free()
	assert_float(b["min_x"]).override_failure_message("west end at X=-50").is_less_equal(-49.9)
	assert_float(b["max_x"]).override_failure_message("east end at X=+50").is_greater_equal(49.9)


# ─── Draw-order layering that replaces trimming (kills coplanar z-fighting) ──

func test_asphalt_material_does_not_write_depth() -> void:
	# The paved asphalt shader must render_mode depth_draw_never so overlapping
	# coplanar roads don't z-fight; the shader source is the contract.
	var code: String = RoadMaterialFactory.ASPHALT_SHADER.code
	assert_str(code) \
		.override_failure_message("asphalt shader must use depth_draw_never") \
		.contains("depth_draw_never")


func test_bigger_road_paints_on_top_of_smaller() -> void:
	# render_priority orders overlapping roads; a motorway must outrank (paint
	# later than) a residential street, which outranks a footway.
	var motorway := RoadMaterialFactory.render_priority_for("motorway")
	var residential := RoadMaterialFactory.render_priority_for("residential")
	var footway := RoadMaterialFactory.render_priority_for("footway")
	assert_int(motorway).is_greater(residential)
	assert_int(residential).is_greater(footway)


func test_material_carries_render_priority() -> void:
	var res_mat := RoadMaterialFactory.create_road_material("residential", Color.GRAY)
	assert_int(res_mat.render_priority) \
		.is_equal(RoadMaterialFactory.render_priority_for("residential"))
	var prim_mat := RoadMaterialFactory.create_road_material("primary", Color.GRAY)
	assert_int(prim_mat.render_priority).is_greater(res_mat.render_priority)


func test_unpaved_material_disables_depth_write_and_ranks_low() -> void:
	var foot := RoadMaterialFactory.create_road_material("footway", Color.hex(0x000000ff))
	assert_object(foot).is_instanceof(StandardMaterial3D)
	var sm := foot as StandardMaterial3D
	assert_int(sm.depth_draw_mode).is_equal(BaseMaterial3D.DEPTH_DRAW_DISABLED)
	# A footway must rank below a residential carriageway so it never paints over it.
	assert_int(sm.render_priority) \
		.is_less(RoadMaterialFactory.render_priority_for("residential"))
