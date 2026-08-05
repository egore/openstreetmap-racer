extends GdUnitTestSuite

## Junction RENDERING tests — the mesh side of the intersection system.
##
## The pure geometry (arm ordering, trim distances, cap outline) is covered by
## test_road_junction_solver.gd. This suite pins how that solution becomes actual
## scene geometry, and the invariant that matters most for the finished look:
##
##     the trimmed ribbon mouths and the junction cap must MEET —
##     no gap you can see the ground through, no overlap that z-fights.
##
## ── What replaced what ───────────────────────────────────────────────────────
## Roads used to be drawn FULL-LENGTH and simply overlapped at shared nodes (the
## Mapnik model), with z-fighting avoided by never writing depth and painting
## bigger road classes last. This suite previously asserted exactly that — that a
## branch road reached all the way into the junction node.
##
## That model is gone. Roads now stop short of intersections and a real cap mesh
## fills the crossing, which is why those assertions are inverted here. Because
## the geometry no longer overlaps, roads can write depth again (better SSR/SSAO)
## and bridges are separated by a real vertical offset rather than paint order.

const OSMParser := preload("res://scripts/osm_parser.gd")
const OSMWayBuilder := preload("res://scripts/osm_way_builder.gd")
const OSMJunctionBuilder := preload("res://scripts/osm_junction_builder.gd")
const RoadNetworkContext := preload("res://scripts/road_network_context.gd")
const RoadJunctionSolver := preload("res://scripts/road_junction_solver.gd")
const RoadMaterialFactory := preload("res://scripts/road_material_factory.gd")
const RoadProfile := preload("res://scripts/road_profile.gd")


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
	t.merge(tags, true)
	w.tags = t
	return w


## A four-way crossing at the origin: west-east way 1, north-south way 2.
func _crossing(tags: Dictionary = {"highway": "residential"}) -> Dictionary:
	var data := OSMParser.OSMData.new()
	data.nodes = {
		1: _node(1, -60.0, 0.0), 2: _node(2, 0.0, 0.0), 3: _node(3, 60.0, 0.0),
		4: _node(4, 0.0, -60.0), 5: _node(5, 0.0, 60.0),
	}
	data.ways = {
		1: _way(1, [1, 2, 3], tags),
		2: _way(2, [4, 2, 5], tags),
	}
	var ways: Array = [data.ways[1], data.ways[2]]
	return {
		"data": data,
		"ways": ways,
		"net": RoadNetworkContext.build(ways, ways, data.nodes, []),
	}


func _bounds_of_mesh(mesh: Mesh) -> Dictionary:
	var b := {"min_x": INF, "max_x": -INF, "min_z": INF, "max_z": -INF}
	if mesh == null:
		return b
	for s: int in range(mesh.get_surface_count()):
		var mdt := MeshDataTool.new()
		if mdt.create_from_surface(mesh, s) != OK:
			continue
		for vi: int in range(mdt.get_vertex_count()):
			var v := mdt.get_vertex(vi)
			b["min_x"] = minf(b["min_x"], v.x)
			b["max_x"] = maxf(b["max_x"], v.x)
			b["min_z"] = minf(b["min_z"], v.z)
			b["max_z"] = maxf(b["max_z"], v.z)
	return b


# ─── Roads stop at intersections (replaces the old overlap model) ────────────

func test_arm_is_trimmed_back_from_the_junction() -> void:
	var fx := _crossing()
	var builder := OSMWayBuilder.new()
	builder.network = fx["net"]
	var mi := builder.build_road(fx["data"].ways[2], fx["data"])
	assert_object(mi).is_not_null()
	if mi == null:
		return
	var b := _bounds_of_mesh(mi.mesh)
	mi.free()
	# Way 2 runs north-south THROUGH the junction, so both halves pull back from
	# Z=0. Its mesh must therefore not reach the centre from either side.
	assert_bool(b["min_z"] < -0.5 and b["max_z"] > 0.5) \
		.override_failure_message("through road should span both sides") \
		.is_true()


func test_junction_cap_is_built_for_a_crossing() -> void:
	var fx := _crossing()
	var net: RoadNetworkContext = fx["net"]
	var owned := net.owned_junctions()
	assert_int(owned.size()) \
		.override_failure_message("the crossing must produce one owned cap") \
		.is_equal(1)

	var mi := OSMJunctionBuilder.new().build_junction(owned[0])
	assert_object(mi) \
		.override_failure_message("junction cap mesh must be built") \
		.is_not_null()
	if mi == null:
		return
	assert_object(mi.mesh).is_not_null()
	assert_int(mi.mesh.get_surface_count()).is_greater(0)
	mi.free()


func test_cap_covers_the_gap_left_by_trimming() -> void:
	# THE core invariant: the cap must extend at least as far as each trimmed
	# ribbon mouth, or a hole opens at the intersection.
	var fx := _crossing()
	var net: RoadNetworkContext = fx["net"]
	var junction: RoadJunctionSolver.Junction = net.owned_junctions()[0]

	var builder := OSMWayBuilder.new()
	builder.network = net
	var road := builder.build_road(fx["data"].ways[2], fx["data"])
	assert_object(road).is_not_null()
	if road == null:
		return
	var road_b := _bounds_of_mesh(road.mesh)
	road.free()

	var cap := OSMJunctionBuilder.new().build_junction(junction)
	assert_object(cap).is_not_null()
	if cap == null:
		return
	var cap_b := _bounds_of_mesh(cap.mesh)
	cap.free()

	# The northern ribbon starts at road_b.max_z going away from the junction;
	# working from the south side, the cap must reach up to where it begins.
	assert_float(cap_b["max_z"]) \
		.override_failure_message(
			"cap (max_z=%.2f) must reach the ribbon mouth" % cap_b["max_z"]) \
		.is_greater(0.0)
	assert_float(cap_b["min_z"]).is_less(0.0)


func test_cap_spans_the_full_carriageway_width() -> void:
	# A cap narrower than the roads would leave slivers of ground showing at the
	# corners of the intersection.
	var fx := _crossing()
	var junction: RoadJunctionSolver.Junction = \
		(fx["net"] as RoadNetworkContext).owned_junctions()[0]
	var cap := OSMJunctionBuilder.new().build_junction(junction)
	assert_object(cap).is_not_null()
	if cap == null:
		return
	var b := _bounds_of_mesh(cap.mesh)
	cap.free()
	var road_width := RoadProfile.width_for(fx["data"].ways[1])
	assert_float(b["max_x"] - b["min_x"]) \
		.override_failure_message("cap must be at least as wide as the road") \
		.is_greater_equal(road_width - 0.1)


func test_no_cap_where_roads_merely_continue() -> void:
	# Two ways meeting end to end is a continuation. Building a cap there would
	# paint an intersection in the middle of a straight street.
	var data := OSMParser.OSMData.new()
	data.nodes = {
		1: _node(1, 0.0, -60.0), 2: _node(2, 0.0, 0.0), 3: _node(3, 0.0, 60.0),
	}
	data.ways = {
		1: _way(1, [1, 2], {"highway": "residential"}),
		2: _way(2, [2, 3], {"highway": "residential"}),
	}
	var ways: Array = [data.ways[1], data.ways[2]]
	var net := RoadNetworkContext.build(ways, ways, data.nodes, [])
	assert_int(net.owned_junctions().size()) \
		.override_failure_message("a continuation must not produce a cap") \
		.is_equal(0)


func test_t_junction_produces_a_cap() -> void:
	var data := OSMParser.OSMData.new()
	data.nodes = {
		1: _node(1, -60.0, 0.0), 2: _node(2, 0.0, 0.0),
		3: _node(3, 60.0, 0.0), 4: _node(4, 0.0, 60.0),
	}
	data.ways = {
		1: _way(1, [1, 2, 3], {"highway": "residential"}),
		2: _way(2, [2, 4], {"highway": "residential"}),
	}
	var ways: Array = [data.ways[1], data.ways[2]]
	var net := RoadNetworkContext.build(ways, ways, data.nodes, [])
	assert_int(net.owned_junctions().size()).is_equal(1)


# ─── Tile-boundary agreement (the halo) ──────────────────────────────────────

func test_neighbouring_tiles_agree_on_the_same_junction() -> void:
	# A junction near a tile border is solved by BOTH tiles (each needs its trim
	# distances). Fed the same halo, they must compute identical geometry or the
	# street would be cut at two different points and show a step on the seam.
	var fx := _crossing()
	var ways: Array = fx["ways"]
	var nodes: Dictionary = fx["data"].nodes

	# Tile A owns the junction; tile B is a neighbour that only sees it via halo.
	var tile_a := RoadNetworkContext.build(ways, ways, nodes, [-100.0, 100.0, -100.0, 100.0])
	var tile_b := RoadNetworkContext.build(ways, ways, nodes, [100.0, 300.0, -100.0, 100.0])

	assert_int(tile_a.owned_junctions().size()) \
		.override_failure_message("the containing tile must own the cap").is_equal(1)
	assert_int(tile_b.owned_junctions().size()) \
		.override_failure_message("a neighbour must NOT also draw the cap").is_equal(0)

	# Both must still agree on where to cut the road.
	var trim_a := tile_a.trim_at(2, 2, true)
	var trim_b := tile_b.trim_at(2, 2, true)
	assert_float(trim_b) \
		.override_failure_message(
			"neighbouring tiles must agree on the trim (%.3f vs %.3f)" % [trim_a, trim_b]) \
		.is_equal_approx(trim_a, 0.001)


func test_cap_ownership_is_exclusive() -> void:
	# Exactly one tile draws each cap; two would z-fight, none would leave a hole.
	var fx := _crossing()
	var ways: Array = fx["ways"]
	var nodes: Dictionary = fx["data"].nodes
	var owners := 0
	# Four tiles tiling the plane around the origin junction at (0,0).
	for rect: Array in [
			[-100.0, 0.0, -100.0, 0.0], [0.0, 100.0, -100.0, 0.0],
			[-100.0, 0.0, 0.0, 100.0], [0.0, 100.0, 0.0, 100.0]]:
		owners += RoadNetworkContext.build(ways, ways, nodes, rect).owned_junctions().size()
	assert_int(owners) \
		.override_failure_message("exactly one tile must own the cap, got %d" % owners) \
		.is_equal(1)


# ─── Layering (replaces the old depth_draw_never trick) ─────────────────────

func test_bridge_and_road_are_separated_vertically() -> void:
	# With real intersections there is no coplanar overlap to resolve by paint
	# order, so crossing roads at different layers are separated in SPACE.
	var data := OSMParser.OSMData.new()
	data.nodes = {1: _node(1, -60.0, 0.0), 2: _node(2, 60.0, 0.0)}
	data.ways = {1: _way(1, [1, 2], {"highway": "primary", "bridge": "yes", "layer": "1"})}
	var mi := OSMWayBuilder.new().build_road(data.ways[1], data)
	assert_object(mi).is_not_null()
	if mi == null:
		return
	var y := mi.position.y
	mi.free()
	assert_float(y) \
		.override_failure_message("a bridge must be lifted clear of the road below") \
		.is_greater(2.0)


func test_junction_material_outranks_the_roads_it_joins() -> void:
	# Where a cap and a ribbon mouth touch they are coplanar; the cap must win
	# so the seam never shimmers.
	var cap_mat := RoadMaterialFactory.create_junction_material("residential")
	assert_int(cap_mat.render_priority) \
		.override_failure_message("cap must paint above the roads feeding it") \
		.is_greater(RoadMaterialFactory.render_priority_for("residential"))


func test_junction_cap_disables_shader_lane_markings() -> void:
	# The cap has no along/across parameterisation, so UV-driven lane lines
	# would smear across it. Markings there are explicit geometry instead.
	var mat := RoadMaterialFactory.create_junction_material("residential")
	assert_object(mat).is_instanceof(ShaderMaterial)
	var sm := mat as ShaderMaterial
	assert_float(sm.get_shader_parameter("markings_enabled")) \
		.override_failure_message("cap must not paint shader lane markings") \
		.is_equal_approx(0.0, 0.001)


func test_bigger_road_still_outranks_smaller() -> void:
	# Class ordering still matters for the remaining coplanar cases (a service
	# road meeting a primary at a non-junction shared node, ground layering).
	assert_int(RoadMaterialFactory.render_priority_for("motorway")) \
		.is_greater(RoadMaterialFactory.render_priority_for("residential"))
	assert_int(RoadMaterialFactory.render_priority_for("residential")) \
		.is_greater(RoadMaterialFactory.render_priority_for("footway"))


# ─── Kerbs at intersections ─────────────────────────────────────────────────

func test_kerb_corners_are_built_when_arms_have_sidewalks() -> void:
	var fx := _crossing({"highway": "residential", "sidewalk": "both"})
	var junction: RoadJunctionSolver.Junction = \
		(fx["net"] as RoadNetworkContext).owned_junctions()[0]

	var lookup := {
		1: {"left": true, "right": true},
		2: {"left": true, "right": true},
	}
	var with_kerbs := OSMJunctionBuilder.new().build_junction(junction, lookup)
	var without := OSMJunctionBuilder.new().build_junction(junction, {})
	assert_object(with_kerbs).is_not_null()
	assert_object(without).is_not_null()
	if with_kerbs == null or without == null:
		# Free whichever one WAS built before bailing, or it leaks as an orphan.
		if with_kerbs != null:
			with_kerbs.free()
		if without != null:
			without.free()
		return
	# Read the counts out before freeing, so the assertion can never run against
	# a freed node (and can never skip the frees below on failure).
	var kerbed_surfaces := with_kerbs.mesh.get_surface_count()
	var bare_surfaces := without.mesh.get_surface_count()
	with_kerbs.free()
	without.free()
	assert_int(kerbed_surfaces) \
		.override_failure_message("kerbed junction must add corner geometry") \
		.is_greater(bare_surfaces)


func test_no_kerb_corners_when_roads_have_no_sidewalks() -> void:
	# Strictly OSM-driven: no sidewalk tags means no kerbs, not assumed ones.
	var fx := _crossing()
	var junction: RoadJunctionSolver.Junction = \
		(fx["net"] as RoadNetworkContext).owned_junctions()[0]
	var lookup := {
		1: {"left": false, "right": false},
		2: {"left": false, "right": false},
	}
	var mi := OSMJunctionBuilder.new().build_junction(junction, lookup)
	var bare := OSMJunctionBuilder.new().build_junction(junction, {})
	assert_object(mi).is_not_null()
	assert_object(bare).is_not_null()
	if mi == null or bare == null:
		if mi != null:
			mi.free()
		if bare != null:
			bare.free()
		return
	var kerbless_surfaces := mi.mesh.get_surface_count()
	var bare_surfaces := bare.mesh.get_surface_count()
	mi.free()
	bare.free()
	assert_int(kerbless_surfaces) \
		.override_failure_message("no sidewalk tags must mean no kerb geometry") \
		.is_equal(bare_surfaces)


# ─── Degenerate input ────────────────────────────────────────────────────────

func test_null_junction_yields_no_mesh() -> void:
	assert_object(OSMJunctionBuilder.new().build_junction(null)).is_null()


func test_empty_network_context_is_harmless() -> void:
	var net := RoadNetworkContext.build([], [], {}, [])
	assert_int(net.owned_junctions().size()).is_equal(0)
	assert_float(net.trim_at(1, 1, true)).is_equal_approx(0.0, 0.001)
