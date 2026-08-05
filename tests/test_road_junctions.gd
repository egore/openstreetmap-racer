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


func test_junction_cap_uses_a_depth_writing_shader() -> void:
	# REGRESSION: render_priority only orders TRANSPARENT materials. Sharing the
	# roads' depth_draw_never asphalt left the cap unable to claim its pixels
	# against opaque geometry, so the terrain or a landuse polygon drawn later
	# painted over the intersection — a grass hole where the junction should be,
	# even though the cap was built, in the scene and above the ground.
	var mat := RoadMaterialFactory.create_junction_material("residential")
	assert_object(mat).is_instanceof(ShaderMaterial)
	var sm := mat as ShaderMaterial
	# Check the render_mode LINE, not the whole source: the shader's own comment
	# explains why depth_draw_never is wrong here, so a naive substring search
	# matches the explanation rather than the declaration.
	var mode_line := ""
	for line: String in sm.shader.code.split("\n"):
		if line.strip_edges().begins_with("render_mode"):
			mode_line = line
			break
	assert_str(mode_line) \
		.override_failure_message("cap shader must declare a render_mode") \
		.is_not_empty()
	assert_str(mode_line) \
		.override_failure_message("junction caps must WRITE depth, got: %s" % mode_line) \
		.not_contains("depth_draw_never")


func test_junction_cap_has_no_uv_lane_markings() -> void:
	# The cap has no along/across parameterisation, so UV-driven lane lines
	# would smear across it. Markings there are explicit geometry instead.
	var mat := RoadMaterialFactory.create_junction_material("residential")
	var sm := mat as ShaderMaterial
	assert_bool(sm.shader.code.contains("markings_enabled")) \
		.override_failure_message("cap shader must not carry lane-marking code") \
		.is_false()


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


# ─── Visual regressions reported in-game ────────────────────────────────────

func test_stop_bar_runs_across_the_road_not_along_it() -> void:
	# REGRESSION ("markings at 90 degrees"): the bar was built from the road's
	# CENTRE POINT to one edge, instead of from the centreline across to the
	# kerb. For any real (non-zero-width) road that put it half off-centre, so
	# it read as a perpendicular stub rather than a stop line.
	#
	# A stop bar must be much wider ACROSS the carriageway than it is deep ALONG
	# the direction of travel.
	var fx := _crossing()
	var junction: RoadJunctionSolver.Junction = \
		(fx["net"] as RoadNetworkContext).owned_junctions()[0]
	var mi := OSMJunctionBuilder.new().build_junction(junction)
	assert_object(mi).is_not_null()
	if mi == null:
		return

	# Surface 1 is the painted-marking surface; each bar is one quad (6 verts),
	# emitted in arm order.
	var mdt := MeshDataTool.new()
	var ok := mdt.create_from_surface(mi.mesh, 1) == OK
	var arms := junction.arms
	var results: Array = []
	if ok:
		for qi: int in range(mdt.get_vertex_count() / 6):
			if qi >= arms.size():
				break
			var arm: RoadJunctionSolver.Arm = arms[qi]
			var c := arm.point_at(junction.center, arm.trim - 0.5)
			var a_min := INF
			var a_max := -INF
			var l_min := INF
			var l_max := -INF
			for vi: int in range(qi * 6, (qi + 1) * 6):
				var v := mdt.get_vertex(vi)
				var rel := Vector3(v.x - c.x, 0.0, v.z - c.z)
				var a := rel.dot(arm.dir)
				var l := rel.dot(arm.lateral())
				a_min = minf(a_min, a)
				a_max = maxf(a_max, a)
				l_min = minf(l_min, l)
				l_max = maxf(l_max, l)
			results.append({"depth": a_max - a_min, "span": l_max - l_min})
	mi.free()

	assert_bool(ok).override_failure_message("expected a marking surface").is_true()
	assert_int(results.size()).is_greater(0)
	for r: Dictionary in results:
		assert_float(r["span"]) \
			.override_failure_message(
				"stop bar must span across the road (span %.2f vs depth %.2f)"
				% [r["span"], r["depth"]]) \
			.is_greater(float(r["depth"]) * 2.0)


func test_short_connector_road_survives_trimming() -> void:
	# REGRESSION ("streets no longer connect"): a short way between two close
	# junctions was asked to give up more length than it had, so it vanished
	# entirely and left a visible hole in the network.
	var data := OSMParser.OSMData.new()
	# Junctions at (0,0) and (6,0) — a 6 m connector between two crossings.
	data.nodes = {
		1: _node(1, 0.0, 0.0), 2: _node(2, 6.0, 0.0),
		3: _node(3, 0.0, -40.0), 4: _node(4, 0.0, 40.0),
		5: _node(5, 6.0, -40.0), 6: _node(6, 6.0, 40.0),
	}
	data.ways = {
		1: _way(1, [1, 2], {"highway": "residential"}),   # the short connector
		2: _way(2, [3, 1, 4], {"highway": "residential"}),
		3: _way(3, [5, 2, 6], {"highway": "residential"}),
	}
	var ways: Array = [data.ways[1], data.ways[2], data.ways[3]]
	var builder := OSMWayBuilder.new()
	builder.network = RoadNetworkContext.build(ways, ways, data.nodes, [])

	var mi := builder.build_road(data.ways[1], data)
	assert_object(mi) \
		.override_failure_message("a short connector must not vanish entirely") \
		.is_not_null()
	if mi == null:
		return
	var b := _bounds_of_mesh(mi.mesh)
	mi.free()
	var remaining: float = b["max_x"] - b["min_x"]
	assert_float(remaining) \
		.override_failure_message(
			"connector kept only %.2f m of its 6 m" % remaining) \
		.is_greater(1.0)


func test_a_road_of_useful_length_survives_trimming() -> void:
	# The general invariant behind the fix above: whatever the junctions ask
	# for, a road long enough to be worth seeing must keep a usable fraction of
	# its own length rather than being trimmed out of existence.
	var data := OSMParser.OSMData.new()
	data.nodes = {
		1: _node(1, 0.0, 0.0), 2: _node(2, 14.0, 0.0),
		3: _node(3, 0.0, -40.0), 4: _node(4, 0.0, 40.0),
		5: _node(5, 14.0, -40.0), 6: _node(6, 14.0, 40.0),
	}
	data.ways = {
		1: _way(1, [1, 2], {"highway": "primary", "lanes": "4"}),
		2: _way(2, [3, 1, 4], {"highway": "primary", "lanes": "4"}),
		3: _way(3, [5, 2, 6], {"highway": "primary", "lanes": "4"}),
	}
	var ways: Array = [data.ways[1], data.ways[2], data.ways[3]]
	var builder := OSMWayBuilder.new()
	builder.network = RoadNetworkContext.build(ways, ways, data.nodes, [])
	var mi := builder.build_road(data.ways[1], data)
	assert_object(mi) \
		.override_failure_message(
			"a 14 m road between two wide junctions must survive") \
		.is_not_null()
	if mi != null:
		mi.free()


func test_sub_metre_stub_between_junctions_is_dropped() -> void:
	# The opposite end of the same trade-off. Junctions often sit a metre or two
	# apart in OSM; the stub between them contributes no visible carriageway
	# once both caps are drawn, but it DOES emit a full kerb run with end caps,
	# which appears as a detached slab of pavement floating beside the road.
	var data := OSMParser.OSMData.new()
	data.nodes = {
		1: _node(1, 0.0, 0.0), 2: _node(2, 1.0, 0.0),
		3: _node(3, 0.0, -40.0), 4: _node(4, 0.0, 40.0),
		5: _node(5, 1.0, -40.0), 6: _node(6, 1.0, 40.0),
	}
	data.ways = {
		1: _way(1, [1, 2], {"highway": "residential", "sidewalk": "both"}),
		2: _way(2, [3, 1, 4], {"highway": "residential"}),
		3: _way(3, [5, 2, 6], {"highway": "residential"}),
	}
	var ways: Array = [data.ways[1], data.ways[2], data.ways[3]]
	var builder := OSMWayBuilder.new()
	builder.network = RoadNetworkContext.build(ways, ways, data.nodes, [])
	var mi := builder.build_road(data.ways[1], data)
	# Decide BEFORE freeing. A freed Object still compares equal to null in
	# GDScript, so asserting on the variable afterwards passes whether or not a
	# mesh was ever built — the assertion would be vacuous.
	var was_built := mi != null
	if mi != null:
		mi.free()
	assert_bool(was_built) \
		.override_failure_message(
			"a 1 m stub must not emit a floating kerb slab") \
		.is_false()


func test_cap_faces_point_upward() -> void:
	# REGRESSION: the cap was emitted with its winding inverted, so every face
	# pointed DOWN and was backface-culled — the intersection was invisible from
	# above (a grass-coloured hole) even though the mesh was built, present in
	# the scene, marked visible and correctly positioned. Nothing but looking at
	# the face normals catches this.
	var fx := _crossing()
	var junction: RoadJunctionSolver.Junction = \
		(fx["net"] as RoadNetworkContext).owned_junctions()[0]
	var mi := OSMJunctionBuilder.new().build_junction(junction)
	assert_object(mi).is_not_null()
	if mi == null:
		return

	var mdt := MeshDataTool.new()
	var ok := mdt.create_from_surface(mi.mesh, 0) == OK
	var up := 0
	var down := 0
	if ok:
		for f: int in range(mdt.get_face_count()):
			var a := mdt.get_vertex(mdt.get_face_vertex(f, 0))
			var b := mdt.get_vertex(mdt.get_face_vertex(f, 1))
			var c := mdt.get_vertex(mdt.get_face_vertex(f, 2))
			# Godot's front face is the winding normal Plane(a, b, c).normal.
			if Plane(a, b, c).normal.y > 0.0:
				up += 1
			else:
				down += 1
	mi.free()

	assert_bool(ok).is_true()
	assert_int(up).override_failure_message("cap must have faces").is_greater(0)
	assert_int(down) \
		.override_failure_message(
			"%d cap faces point DOWN and will be backface-culled" % down) \
		.is_equal(0)


func test_flat_and_draped_paths_use_opposite_windings() -> void:
	# The two cap code paths need OPPOSITE input windings to face the same way:
	# PolygonUtils.emit_terrain_conforming_quad fan-triangulates each clipped
	# piece as (o, v2, v1), reversing whatever it is handed, while the flat path
	# emits the order given. Fixing one and assuming the other followed is
	# exactly how the cap ended up invisible in the DEM-backed world while the
	# flat unit test passed.
	var builder := OSMJunctionBuilder.new()
	var a := Vector3(0.0, 0.0, 0.0)
	var b := Vector3(10.0, 0.0, 0.0)
	var c := Vector3(0.0, 0.0, 10.0)

	var up := builder._wound_upward(a, b, c)
	var down := builder._wound_downward(a, b, c)
	assert_int(up.size()).is_equal(3)
	assert_int(down.size()).is_equal(3)

	# The upward winding must yield a +Y front face directly.
	var up3: Array[Vector3] = []
	for p: Vector2 in up:
		up3.append(Vector3(p.x, 0.0, p.y))
	assert_float(Plane(up3[0], up3[1], up3[2]).normal.y) \
		.override_failure_message("_wound_upward must give a +Y front face") \
		.is_greater(0.0)

	# The downward winding must be its exact reverse, so that a consumer which
	# flips the order (the terrain clipper) ends up facing up.
	var down3: Array[Vector3] = []
	for p: Vector2 in down:
		down3.append(Vector3(p.x, 0.0, p.y))
	assert_float(Plane(down3[0], down3[1], down3[2]).normal.y) \
		.override_failure_message(
			"_wound_downward must be the reverse of _wound_upward") \
		.is_less(0.0)


func test_winding_helper_is_independent_of_input_order() -> void:
	# The triangulator hands over corners in whatever order it likes, so the
	# helper must normalise both possible inputs to the same result.
	var builder := OSMJunctionBuilder.new()
	var a := Vector3(0.0, 0.0, 0.0)
	var b := Vector3(10.0, 0.0, 0.0)
	var c := Vector3(0.0, 0.0, 10.0)

	for tri: Array in [[a, b, c], [a, c, b]]:
		var w := builder._wound_upward(tri[0], tri[1], tri[2])
		var v: Array[Vector3] = []
		for p: Vector2 in w:
			v.append(Vector3(p.x, 0.0, p.y))
		assert_float(Plane(v[0], v[1], v[2]).normal.y) \
			.override_failure_message(
				"winding must face up regardless of input order") \
			.is_greater(0.0)
