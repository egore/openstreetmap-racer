extends GdUnitTestSuite

## Tests for RoadJunctionSolver — the pure-geometry core of the intersection
## system. No scene tree, no SurfaceTool, no terrain: everything here is exact
## arithmetic on plain OSM-shaped data, so a failure points at the maths rather
## than at Godot.
##
## The invariants that matter for the renderer:
##   - only real intersections (3+ arms) are detected,
##   - each arm is trimmed back far enough to clear the crossing,
##   - the cap polygon actually covers the hole the trimming left,
##   - the solution is deterministic (the streaming world re-solves the same
##     junction from several tiles and they must agree exactly).

const OSMParser := preload("res://scripts/osm_parser.gd")
const RoadJunctionSolver := preload("res://scripts/road_junction_solver.gd")


func _node(id: int, x: float, z: float) -> OSMParser.OSMNode:
	var n := OSMParser.OSMNode.new()
	n.id = id
	n.local_pos = Vector3(x, 0.0, z)
	return n


func _way(id: int, node_ids: Array, tags: Dictionary = {}) -> OSMParser.OSMWay:
	var w := OSMParser.OSMWay.new()
	w.id = id
	var ids: Array[int] = []
	for n: int in node_ids:
		ids.append(n)
	w.node_ids = ids
	var t := {"highway": "residential"}
	t.merge(tags, true)
	w.tags = t
	return w


## Every way counts as a road; fixed 8 m width unless the way says otherwise.
func _is_road() -> Callable:
	return func(w: OSMParser.OSMWay) -> bool: return w.tags.has("highway")


func _width(default_w: float = 8.0) -> Callable:
	return func(w: OSMParser.OSMWay) -> float:
		if w.tags.has("width"):
			return String(w.tags["width"]).to_float()
		return default_w


## A classic + shaped crossing: two straight roads intersecting at node 0.
## Node ids: centre 0; arms east 1, north 2, west 3, south 4.
func _cross_data() -> Dictionary:
	var nodes := {
		0: _node(0, 0, 0),
		1: _node(1, 50, 0),
		2: _node(2, 0, -50),
		3: _node(3, -50, 0),
		4: _node(4, 0, 50),
	}
	var ways: Array = [
		_way(1, [3, 0, 1]),   # west -> east, through the centre
		_way(2, [2, 0, 4]),   # north -> south, through the centre
	]
	return {"nodes": nodes, "ways": ways}


# ─── Junction detection ──────────────────────────────────────────────────────

func test_detects_four_way_crossing() -> void:
	var d := _cross_data()
	var found := RoadJunctionSolver.find_junction_nodes(
		d["ways"], d["nodes"], _is_road())
	assert_bool(found.has(0)) \
		.override_failure_message("centre node must be a junction") \
		.is_true()
	assert_int(found.size()) \
		.override_failure_message("only the centre node is a junction") \
		.is_equal(1)


func test_two_ways_meeting_end_to_end_is_not_a_junction() -> void:
	# A road simply continuing into another road (e.g. a tag change) has only
	# two arms. Trimming there would open a gap in a straight street.
	var nodes := {
		0: _node(0, 0, 0), 1: _node(1, 50, 0), 2: _node(2, -50, 0),
	}
	var ways: Array = [_way(1, [2, 0]), _way(2, [0, 1])]
	var found := RoadJunctionSolver.find_junction_nodes(ways, nodes, _is_road())
	assert_bool(found.has(0)) \
		.override_failure_message("2-arm continuation must NOT be a junction") \
		.is_false()


func test_t_junction_is_detected() -> void:
	# Through road west-east, with a spur going north from its middle.
	var nodes := {
		0: _node(0, 0, 0), 1: _node(1, 50, 0),
		2: _node(2, -50, 0), 3: _node(3, 0, -50),
	}
	var ways: Array = [_way(1, [2, 0, 1]), _way(2, [0, 3])]
	var found := RoadJunctionSolver.find_junction_nodes(ways, nodes, _is_road())
	assert_bool(found.has(0)).is_true()


func test_closed_loop_does_not_self_junction() -> void:
	# A way whose first and last node are the same touches that node twice, but
	# that is one way, not two — it must not register as a junction on its own.
	var nodes := {
		0: _node(0, 0, 0), 1: _node(1, 30, 0), 2: _node(2, 30, 30),
	}
	var ways: Array = [_way(1, [0, 1, 2, 0])]
	var found := RoadJunctionSolver.find_junction_nodes(ways, nodes, _is_road())
	assert_bool(found.has(0)) \
		.override_failure_message("a loop touching itself is not a junction") \
		.is_false()


func test_non_road_ways_are_ignored() -> void:
	var nodes := {
		0: _node(0, 0, 0), 1: _node(1, 50, 0),
		2: _node(2, -50, 0), 3: _node(3, 0, -50),
	}
	var ways: Array = [
		_way(1, [2, 0, 1]),
		_way(2, [0, 3], {"highway": ""}),  # not a road per our predicate
	]
	ways[1].tags = {"waterway": "stream"}
	var found := RoadJunctionSolver.find_junction_nodes(ways, nodes, _is_road())
	assert_bool(found.has(0)) \
		.override_failure_message("a stream crossing a road is not a junction") \
		.is_false()


# ─── Arm collection ──────────────────────────────────────────────────────────

func test_four_way_crossing_has_four_arms() -> void:
	var d := _cross_data()
	var solved := RoadJunctionSolver.solve_all(
		d["ways"], d["nodes"], _is_road(), _width())
	assert_bool(solved.has(0)).is_true()
	var j: RoadJunctionSolver.Junction = solved[0]
	assert_int(j.arms.size()) \
		.override_failure_message("a + crossing has 4 arms, got %d" % j.arms.size()) \
		.is_equal(4)


func test_arms_point_away_from_the_junction() -> void:
	var d := _cross_data()
	var solved := RoadJunctionSolver.solve_all(
		d["ways"], d["nodes"], _is_road(), _width())
	var j: RoadJunctionSolver.Junction = solved[0]
	# Every arm direction must lead away from the centre toward its own node.
	for arm: RoadJunctionSolver.Arm in j.arms:
		var tip := arm.point_at(j.center, 10.0)
		var d_center := Vector2(j.center.x, j.center.z).distance_to(Vector2.ZERO)
		var d_tip := Vector2(tip.x, tip.z).distance_to(Vector2.ZERO)
		assert_float(d_tip) \
			.override_failure_message("arm must lead away from the centre") \
			.is_greater(d_center)


func test_arms_are_sorted_by_bearing() -> void:
	var d := _cross_data()
	var solved := RoadJunctionSolver.solve_all(
		d["ways"], d["nodes"], _is_road(), _width())
	var j: RoadJunctionSolver.Junction = solved[0]
	for i: int in range(j.arms.size() - 1):
		assert_float(j.arms[i].bearing) \
			.override_failure_message("arms must be in ascending bearing order") \
			.is_less_equal(j.arms[i + 1].bearing)


func test_through_way_contributes_two_arms() -> void:
	# Way 1 passes THROUGH the centre, so it leaves in both directions and
	# therefore contributes two arms, one starting and one ending there.
	var d := _cross_data()
	var solved := RoadJunctionSolver.solve_all(
		d["ways"], d["nodes"], _is_road(), _width())
	var j: RoadJunctionSolver.Junction = solved[0]
	var way1_arms := 0
	for arm: RoadJunctionSolver.Arm in j.arms:
		if arm.way_id == 1:
			way1_arms += 1
	assert_int(way1_arms) \
		.override_failure_message("a way passing through contributes 2 arms") \
		.is_equal(2)


# ─── Trim distances ──────────────────────────────────────────────────────────

func test_every_arm_is_trimmed_back() -> void:
	var d := _cross_data()
	var solved := RoadJunctionSolver.solve_all(
		d["ways"], d["nodes"], _is_road(), _width())
	var j: RoadJunctionSolver.Junction = solved[0]
	for arm: RoadJunctionSolver.Arm in j.arms:
		assert_float(arm.trim) \
			.override_failure_message("arm must be trimmed back from the node") \
			.is_greater(0.0)


func test_trim_clears_the_crossing_roads_halfwidth() -> void:
	# At a + crossing of two 8 m roads, each arm must pull back at least the
	# other road's half-width (4 m) or the ribbon would poke into the crossing.
	var d := _cross_data()
	var solved := RoadJunctionSolver.solve_all(
		d["ways"], d["nodes"], _is_road(), _width(8.0))
	var j: RoadJunctionSolver.Junction = solved[0]
	for arm: RoadJunctionSolver.Arm in j.arms:
		assert_float(arm.trim) \
			.override_failure_message(
				"trim %.2f must clear the crossing half-width 4.0" % arm.trim) \
			.is_greater_equal(4.0)


func test_wider_crossing_road_forces_a_deeper_trim() -> void:
	# Widening the crossing road must push the other road's arms further back.
	var narrow := _cross_data()
	var narrow_solved := RoadJunctionSolver.solve_all(
		narrow["ways"], narrow["nodes"], _is_road(), _width(6.0))
	var narrow_trim: float = (narrow_solved[0] as RoadJunctionSolver.Junction).arms[0].trim

	var wide := _cross_data()
	var wide_solved := RoadJunctionSolver.solve_all(
		wide["ways"], wide["nodes"], _is_road(), _width(20.0))
	var wide_trim: float = (wide_solved[0] as RoadJunctionSolver.Junction).arms[0].trim

	assert_float(wide_trim) \
		.override_failure_message("a wider junction must trim arms further back") \
		.is_greater(narrow_trim)


func test_trim_is_clamped_for_acute_angles() -> void:
	# Two arms leaving at a very shallow angle have their edge crossing far away
	# (parallel lines never meet). Without clamping this would eat a whole road.
	var nodes := {
		0: _node(0, 0, 0),
		1: _node(1, 100, 0),
		2: _node(2, 100, 2),    # ~1 degree from arm 1
		3: _node(3, -100, 0),
	}
	var ways: Array = [_way(1, [0, 1]), _way(2, [0, 2]), _way(3, [0, 3])]
	var solved := RoadJunctionSolver.solve_all(
		ways, nodes, _is_road(), _width())
	if not solved.has(0):
		return  # near-duplicate arms may collapse this junction; that is fine
	var j: RoadJunctionSolver.Junction = solved[0]
	for arm: RoadJunctionSolver.Arm in j.arms:
		assert_float(arm.trim) \
			.override_failure_message("trim must be clamped to MAX_TRIM") \
			.is_less_equal(RoadJunctionSolver.MAX_TRIM)


# ─── Cap polygon ─────────────────────────────────────────────────────────────

func test_cap_polygon_is_built() -> void:
	var d := _cross_data()
	var solved := RoadJunctionSolver.solve_all(
		d["ways"], d["nodes"], _is_road(), _width())
	var j: RoadJunctionSolver.Junction = solved[0]
	assert_int(j.cap.size()) \
		.override_failure_message("cap must have at least a triangle") \
		.is_greater_equal(3)


func test_cap_covers_the_junction_centre() -> void:
	# The whole point of the cap: it must fill the hole trimming left behind,
	# which means it has to contain the junction node itself.
	var d := _cross_data()
	var solved := RoadJunctionSolver.solve_all(
		d["ways"], d["nodes"], _is_road(), _width())
	var j: RoadJunctionSolver.Junction = solved[0]
	assert_bool(_point_in_polygon(j.center, j.cap)) \
		.override_failure_message("cap polygon must cover the junction centre") \
		.is_true()


func test_cap_reaches_each_arm_mouth() -> void:
	# Each trimmed arm mouth must lie on (or inside) the cap, otherwise a gap
	# opens between the ribbon end and the intersection surface.
	var d := _cross_data()
	var solved := RoadJunctionSolver.solve_all(
		d["ways"], d["nodes"], _is_road(), _width())
	var j: RoadJunctionSolver.Junction = solved[0]
	for arm: RoadJunctionSolver.Arm in j.arms:
		# Sample just INSIDE the mouth so a point exactly on the boundary
		# doesn't make the containment test ambiguous.
		var probe := arm.point_at(j.center, arm.trim - 0.05)
		assert_bool(_point_in_polygon(probe, j.cap)) \
			.override_failure_message(
				"cap must reach arm mouth of way %d" % arm.way_id) \
			.is_true()


func test_cap_is_convex_for_a_symmetric_crossing() -> void:
	# A symmetric + crossing must produce a convex cap; a concave result would
	# mean a corner folded back into the intersection.
	var d := _cross_data()
	var solved := RoadJunctionSolver.solve_all(
		d["ways"], d["nodes"], _is_road(), _width())
	var j: RoadJunctionSolver.Junction = solved[0]
	assert_bool(_is_convex(j.cap)) \
		.override_failure_message("symmetric crossing cap must be convex") \
		.is_true()


func test_cap_has_no_duplicate_consecutive_points() -> void:
	# Duplicated points triangulate into degenerate (zero-area) triangles.
	var d := _cross_data()
	var solved := RoadJunctionSolver.solve_all(
		d["ways"], d["nodes"], _is_road(), _width())
	var j: RoadJunctionSolver.Junction = solved[0]
	for i: int in range(j.cap.size()):
		var a: Vector3 = j.cap[i]
		var b: Vector3 = j.cap[(i + 1) % j.cap.size()]
		var dist := Vector2(a.x, a.z).distance_to(Vector2(b.x, b.z))
		assert_float(dist) \
			.override_failure_message("cap has duplicate point at index %d" % i) \
			.is_greater(0.001)


func test_cap_scales_with_road_width() -> void:
	var narrow := _cross_data()
	var narrow_j: RoadJunctionSolver.Junction = RoadJunctionSolver.solve_all(
		narrow["ways"], narrow["nodes"], _is_road(), _width(6.0))[0]
	var wide := _cross_data()
	var wide_j: RoadJunctionSolver.Junction = RoadJunctionSolver.solve_all(
		wide["ways"], wide["nodes"], _is_road(), _width(20.0))[0]
	assert_float(_polygon_area(wide_j.cap)) \
		.override_failure_message("a wider junction must have a bigger cap") \
		.is_greater(_polygon_area(narrow_j.cap))


# ─── Determinism (streaming correctness) ─────────────────────────────────────

func test_solution_is_deterministic_regardless_of_way_order() -> void:
	# The same junction is solved from several tiles, each of which may iterate
	# its ways in a different order. The geometry MUST come out identical or
	# neighbouring tiles would disagree and leave a visible seam.
	var d := _cross_data()
	var forward: Array = d["ways"]
	var reversed_ways: Array = [d["ways"][1], d["ways"][0]]

	var a: RoadJunctionSolver.Junction = RoadJunctionSolver.solve_all(
		forward, d["nodes"], _is_road(), _width())[0]
	var b: RoadJunctionSolver.Junction = RoadJunctionSolver.solve_all(
		reversed_ways, d["nodes"], _is_road(), _width())[0]

	assert_int(b.cap.size()) \
		.override_failure_message("cap vertex count must not depend on way order") \
		.is_equal(a.cap.size())
	for i: int in range(a.cap.size()):
		assert_float(Vector2(a.cap[i].x, a.cap[i].z).distance_to(
				Vector2(b.cap[i].x, b.cap[i].z))) \
			.override_failure_message("cap point %d differs between orderings" % i) \
			.is_less(0.001)


func test_dominant_type_is_the_widest_arm() -> void:
	var nodes := {
		0: _node(0, 0, 0), 1: _node(1, 50, 0),
		2: _node(2, -50, 0), 3: _node(3, 0, -50),
	}
	var ways: Array = [
		_way(1, [2, 0, 1], {"highway": "primary", "width": "16"}),
		_way(2, [0, 3], {"highway": "residential", "width": "5"}),
	]
	var j: RoadJunctionSolver.Junction = RoadJunctionSolver.solve_all(
		ways, nodes, _is_road(), _width())[0]
	assert_str(j.dominant_type) \
		.override_failure_message("cap should adopt the widest arm's class") \
		.is_equal("primary")


# ─── Degenerate input ────────────────────────────────────────────────────────

func test_missing_nodes_do_not_crash() -> void:
	var nodes := {0: _node(0, 0, 0), 1: _node(1, 50, 0)}
	# Ways reference nodes 7/8/9 which are absent from the dict.
	var ways: Array = [_way(1, [0, 1]), _way(2, [0, 7]), _way(3, [0, 8, 9])]
	var solved := RoadJunctionSolver.solve_all(ways, nodes, _is_road(), _width())
	assert_object(solved).is_not_null()


func test_zero_length_way_is_ignored() -> void:
	var nodes := {0: _node(0, 0, 0), 1: _node(1, 50, 0), 2: _node(2, -50, 0)}
	var ways: Array = [
		_way(1, [2, 0, 1]),
		_way(2, [0, 0]),        # degenerate: same node twice
		_way(3, [0]),           # degenerate: single node
	]
	var solved := RoadJunctionSolver.solve_all(ways, nodes, _is_road(), _width())
	assert_object(solved).is_not_null()


func test_empty_input_yields_no_junctions() -> void:
	var solved := RoadJunctionSolver.solve_all([], {}, _is_road(), _width())
	assert_int(solved.size()).is_equal(0)


# ─── Helpers ─────────────────────────────────────────────────────────────────

## Even-odd point-in-polygon test in the XZ plane.
func _point_in_polygon(p: Vector3, poly: PackedVector3Array) -> bool:
	var inside := false
	var n := poly.size()
	if n < 3:
		return false
	var j := n - 1
	for i: int in range(n):
		var pi: Vector3 = poly[i]
		var pj: Vector3 = poly[j]
		if ((pi.z > p.z) != (pj.z > p.z)) and \
				(p.x < (pj.x - pi.x) * (p.z - pi.z) / (pj.z - pi.z) + pi.x):
			inside = not inside
		j = i
	return inside


## True when every turn of the polygon has the same sign (convex, XZ plane).
func _is_convex(poly: PackedVector3Array) -> bool:
	var n := poly.size()
	if n < 3:
		return false
	var sign_seen := 0
	for i: int in range(n):
		var a: Vector3 = poly[i]
		var b: Vector3 = poly[(i + 1) % n]
		var c: Vector3 = poly[(i + 2) % n]
		var cross := (b.x - a.x) * (c.z - b.z) - (b.z - a.z) * (c.x - b.x)
		if absf(cross) < 0.0001:
			continue
		var s := 1 if cross > 0.0 else -1
		if sign_seen == 0:
			sign_seen = s
		elif s != sign_seen:
			return false
	return true


## Absolute area of an XZ polygon (shoelace).
func _polygon_area(poly: PackedVector3Array) -> float:
	var n := poly.size()
	if n < 3:
		return 0.0
	var acc := 0.0
	for i: int in range(n):
		var a: Vector3 = poly[i]
		var b: Vector3 = poly[(i + 1) % n]
		acc += a.x * b.z - b.x * a.z
	return absf(acc) * 0.5
