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


## A T-junction at node 0: a through-road running west-east, with a single stem
## leaving SOUTH (+Z). Nothing at all to the north.
##
## The asymmetry is the point. A symmetric + crossing is congruent under the
## rotation that maps each arm onto the next, so a cap that is far too big is
## still a plausible-looking shape and every corner is wrong in the same way. A T
## has an OPEN side with no road on it, which is precisely where an over-sized
## cap spills onto the verge and becomes visible.
func _t_junction_data() -> Dictionary:
	var nodes := {
		0: _node(0, 0, 0),
		1: _node(1, 50, 0),
		2: _node(2, -50, 0),
		3: _node(3, 0, 50),
	}
	var ways: Array = [
		_way(1, [2, 0, 1]),   # west -> east, through the centre
		_way(2, [0, 3]),      # stem leaving south
	]
	return {"nodes": nodes, "ways": ways}


## A three-arm junction with no right angles anywhere: arms leave at roughly
## 0, 130 and 235 degrees.
##
## Needed because right-angle corners are a degenerate case for the cap — the two
## facing mouth corners coincide and collapse to a single vertex. Both the +
## crossing and a square T hit that case on every corner, so neither can show
## whether each arm really contributes two points.
func _skew_fork_data() -> Dictionary:
	var nodes := {
		0: _node(0, 0, 0),
		1: _node(1, 50, 0),
		2: _node(2, -32, 38),
		3: _node(3, -29, -41),
	}
	var ways: Array = [
		_way(1, [0, 1]),
		_way(2, [0, 2]),
		_way(3, [0, 3]),
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


func test_cap_has_exactly_two_points_per_arm() -> void:
	# REGRESSION: the cap used to insert a multi-point "fillet arc" between every
	# pair of arms, which turned a 4-arm crossing into a 20-gon. Each arm should
	# contribute only the two vertices it actually justifies — its left and right
	# mouth corners — with consecutive arms joined by a straight chamfer.
	#
	# A SKEWED junction is used deliberately. Wherever two arms meet at a right
	# angle their facing mouth corners coincide and are deduplicated, so both the
	# + crossing and a square T collapse and the "two per arm" rule is invisible.
	# Only an oblique fork keeps every chamfer at non-zero length.
	var d := _skew_fork_data()
	var solved := RoadJunctionSolver.solve_all(
		d["ways"], d["nodes"], _is_road(), _width())
	var j: RoadJunctionSolver.Junction = solved[0]
	assert_int(j.raw_cap.size()) \
		.override_failure_message(
			"a %d-arm junction must yield a %d-gon, got %d points" % [
				j.arms.size(), j.arms.size() * 2, j.raw_cap.size()]) \
		.is_equal(j.arms.size() * 2)


func test_right_angle_crossing_collapses_to_a_square() -> void:
	# The flip side of the rule above. At a clean + crossing adjacent arms are
	# trimmed to the same distance and their facing mouth corners land on exactly
	# the same point, so the chamfer between them has zero length. The cap really
	# is a square there, and must be emitted as four points rather than four
	# doubled ones — a repeated vertex makes a zero-area triangle that shades with
	# a garbage normal.
	#
	# Note this pins the DEDUPLICATION, not the fillet removal: a right-angle
	# crossing is the one case where the old arc collapsed too, so this test
	# passes either way. The two tests either side of it are what catch the disc.
	var d := _cross_data()
	var solved := RoadJunctionSolver.solve_all(
		d["ways"], d["nodes"], _is_road(), _width())
	var j: RoadJunctionSolver.Junction = solved[0]
	assert_int(j.raw_cap.size()) \
		.override_failure_message(
			"a right-angle crossing must cap as a square, got %d points" % \
				j.raw_cap.size()) \
		.is_equal(4)


func test_t_junction_cap_does_not_cross_the_open_side() -> void:
	# REGRESSION: the black puddle. The cap's "fillet" swept an arc about the
	# junction CENTRE at the mouth radius, making every cap a disc. At a T there
	# is no road on the fourth side, so that disc bulged onto the verge — asphalt
	# spilling onto the grass beside the junction.
	#
	# This is a CONTAINMENT test rather than an area one on purpose. Measured
	# areas were tried first and rejected: on these fixtures the disc is only
	# ~1.1x the straight polygon, well inside any threshold loose enough to allow
	# legitimately skewed junctions, so an area assertion passed with the bug
	# present and would have been pure decoration.
	var d := _t_junction_data()
	var solved := RoadJunctionSolver.solve_all(
		d["ways"], d["nodes"], _is_road(), _width())
	var j: RoadJunctionSolver.Junction = solved[0]
	# _t_junction_data's stem runs south (+Z), so the open side is due north (-Z).
	# _width() gives 8 m roads, so the through-road's kerb is 4 m out; anything
	# past that on the open side is verge.
	var half_w := 4.0
	for extra: float in [0.5, 1.0, 2.0]:
		var probe := Vector3(
			j.center.x, j.center.y, j.center.z - (half_w + extra))
		assert_bool(_point_in_polygon(probe, j.cap)) \
			.override_failure_message(
				"cap spills %.1f m onto the verge on the open side of a T" % \
					extra) \
			.is_false()


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


# ─── Regressions found against real OSM data ────────────────────────────────

func test_asymmetric_junction_triangulates() -> void:
	# REGRESSION: _corner_distance originally paired the OPPOSITE edges to the
	# ones _build_cap joins with its fillet. A symmetric + crossing hides that
	# (all four corners are congruent), but on a real asymmetric junction the
	# mouths landed in the wrong places and the cap self-intersected — it would
	# not triangulate, so the intersection rendered as a hole in the road.
	#
	# These bearings are taken from a real failing junction in the Netherlands
	# extract (node 924168444): arms at -149, -25, 31 and 120 degrees.
	var nodes := {0: _node(0, 0, 0)}
	var ways: Array = []
	var next_node := 1
	for deg: float in [-149.3, -25.3, 30.7, 120.3]:
		var rad := deg_to_rad(deg)
		nodes[next_node] = _node(next_node, cos(rad) * 80.0, sin(rad) * 80.0)
		ways.append(_way(next_node, [0, next_node]))
		next_node += 1

	var solved := RoadJunctionSolver.solve_all(ways, nodes, _is_road(), _width(7.0))
	assert_bool(solved.has(0)).is_true()
	var j: RoadJunctionSolver.Junction = solved[0]
	# Assert on the RAW walk, not the repaired cap: the convex-hull fallback
	# would rescue a broken corner calculation and hide the regression.
	assert_int(Geometry2D.triangulate_polygon(_flatten(j.raw_cap)).size()) \
		.override_failure_message(
			"an asymmetric junction must be built simple, not rescued by repair") \
		.is_greater_equal(3)


func test_acute_fork_still_produces_a_usable_cap() -> void:
	# REGRESSION: when two arms meet at a very sharp angle they must be trimmed
	# further back than MAX_TRIM allows. The clamp then leaves their mouths
	# overlapping and the cap walk crosses itself. Rather than render nothing
	# (a hole in the road), the solver falls back to the convex hull.
	var nodes := {0: _node(0, 0, 0)}
	var ways: Array = []
	var next_node := 1
	# Two arms only ~18 degrees apart, plus one opposing arm.
	for deg: float in [-176.4, -10.2, 158.3]:
		var rad := deg_to_rad(deg)
		nodes[next_node] = _node(next_node, cos(rad) * 80.0, sin(rad) * 80.0)
		ways.append(_way(next_node, [0, next_node]))
		next_node += 1

	var solved := RoadJunctionSolver.solve_all(ways, nodes, _is_road(), _width(7.0))
	assert_bool(solved.has(0)).is_true()
	var j: RoadJunctionSolver.Junction = solved[0]
	assert_int(Geometry2D.triangulate_polygon(_flatten(j.cap)).size()) \
		.override_failure_message("an acute fork must still yield a usable cap") \
		.is_greater_equal(3)
	assert_bool(_point_in_polygon(j.center, j.cap)) \
		.override_failure_message("the fallback cap must still cover the node") \
		.is_true()


# ─── Arms follow the road's real shape, not a straight ray ──────────────────

## A junction whose south arm BENDS inside its own trim distance.
##
## The stem leaves the node due south, but its first node is only 3 m out — well
## inside the ~4 m trim a crossing of 8 m roads produces — and from there the
## road swings away to the south-east. So the point the ribbon is actually cut
## at lies on the SECOND segment, pointing about 25 degrees off the direction the
## arm leaves the node in.
##
## This is the shape the whole "arm is a polyline" change exists for, and it is
## extremely common in real OSM data: mappers put a node a metre or two past a
## junction wherever a road starts to curve.
func _bent_arm_data() -> Dictionary:
	var nodes := {
		0: _node(0, 0, 0),
		1: _node(1, 50, 0),      # through road, east
		2: _node(2, -50, 0),     # through road, west
		# Stem: 3 m due south, then bending south-east.
		3: _node(3, 0, 3),
		4: _node(4, 8, 20),
		5: _node(5, 20, 60),
	}
	var ways: Array = [
		_way(1, [2, 0, 1]),
		_way(2, [0, 3, 4, 5]),
	]
	return {"nodes": nodes, "ways": ways}


func _bent_stem(width: float = 8.0) -> RoadJunctionSolver.Arm:
	var d := _bent_arm_data()
	var j: RoadJunctionSolver.Junction = RoadJunctionSolver.solve_all(
		d["ways"], d["nodes"], _is_road(), _width(width))[0]
	for arm: RoadJunctionSolver.Arm in j.arms:
		if arm.way_id == 2:
			return arm
	return null


func test_arm_mouth_follows_the_bend_instead_of_a_straight_ray() -> void:
	# REGRESSION (the visible bug): the solver placed the mouth by walking a
	# STRAIGHT RAY from the node, while OSMWayBuilder cuts the ribbon by ARC
	# LENGTH along the real polyline. On a way that bends inside its trim the two
	# land in different places, so the cap and the ribbon do not meet.
	var arm := _bent_stem()
	assert_object(arm).is_not_null()
	if arm == null:
		return

	var centre := Vector3.ZERO
	var mouth := arm.point_at(centre, arm.trim)
	# The straight-ray answer is due south of the node with x == 0. Following the
	# actual road must carry the mouth measurably east of that.
	assert_float(mouth.x) \
		.override_failure_message(
			"mouth stayed on the straight ray (x=%.3f); it must follow the bend"
			% mouth.x) \
		.is_greater(0.1)


func test_arm_mouth_is_the_correct_arc_length_along_the_road() -> void:
	# The mouth must sit exactly `trim` metres along the CENTRELINE, because that
	# is the measure the ribbon builder trims by. Measuring along the polyline is
	# what makes the two agree; a straight-line distance would be shorter.
	var arm := _bent_stem()
	assert_object(arm).is_not_null()
	if arm == null:
		return

	var mouth := arm.point_at(Vector3.ZERO, arm.trim)
	# Walk the arm's own polyline and measure how far along the mouth landed.
	var travelled := 0.0
	var found := -1.0
	for i: int in range(arm.polyline.size() - 1):
		var a: Vector3 = arm.polyline[i]
		var b: Vector3 = arm.polyline[i + 1]
		var seg := Vector2(b.x - a.x, b.z - a.z)
		var to_mouth := Vector2(mouth.x - a.x, mouth.z - a.z)
		var seg_len := seg.length()
		if seg_len < 0.0001:
			continue
		var t := to_mouth.dot(seg / seg_len)
		# Is the mouth on this segment (allowing a hair of numerical slack)?
		if t >= -0.01 and t <= seg_len + 0.01:
			var perp := absf(to_mouth.cross(seg / seg_len))
			if perp < 0.01:
				found = travelled + t
				break
		travelled += seg_len
	assert_float(found) \
		.override_failure_message("mouth is not on the arm's centreline at all") \
		.is_greater_equal(0.0)
	assert_float(found) \
		.override_failure_message(
			"mouth sits %.3f m along the road, expected the trim %.3f m"
			% [found, arm.trim]) \
		.is_equal_approx(arm.trim, 0.01)


func test_arm_direction_at_the_mouth_is_the_segment_it_lands_on() -> void:
	# The cap is cut square to dir_at(trim), and the ribbon's end cap is square
	# to the segment containing the cut (OSMWayBuilder._miter_offset). Those must
	# be the same vector or the two meet at different angles — the wedge of bare
	# ground in the screenshot.
	var arm := _bent_stem()
	assert_object(arm).is_not_null()
	if arm == null:
		return

	# The mouth falls on the 2nd segment: (0,3) -> (8,20).
	var expected := Vector3(8.0 - 0.0, 0.0, 20.0 - 3.0).normalized()
	var actual := arm.dir_at(arm.trim)
	assert_float(actual.dot(expected)) \
		.override_failure_message(
			"mouth direction (%.3f, %.3f) is not the segment it lands on"
			% [actual.x, actual.z]) \
		.is_equal_approx(1.0, 0.001)

	# And it must genuinely differ from the direction at the NODE, or this
	# fixture would not be exercising the bug at all.
	assert_float(actual.dot(arm.dir)) \
		.override_failure_message(
			"fixture is not bent: node and mouth directions agree") \
		.is_less(0.99)


func test_cap_mouth_edge_is_square_to_the_road_at_the_mouth() -> void:
	# The two cap vertices for an arm are its mouth's left and right kerb
	# corners. The edge between them must be PERPENDICULAR to the road where it
	# is cut, exactly like the ribbon's square end cap.
	var d := _bent_arm_data()
	var j: RoadJunctionSolver.Junction = RoadJunctionSolver.solve_all(
		d["ways"], d["nodes"], _is_road(), _width())[0]

	var arm: RoadJunctionSolver.Arm = null
	var index := -1
	for i: int in range(j.arms.size()):
		if j.arms[i].way_id == 2:
			arm = j.arms[i]
			index = i
	assert_object(arm).is_not_null()
	if arm == null:
		return

	# raw_cap emits two points per arm in arm order: left mouth then right.
	var left: Vector3 = j.raw_cap[index * 2]
	var right: Vector3 = j.raw_cap[index * 2 + 1]
	var edge := Vector2(right.x - left.x, right.z - left.z)
	assert_float(edge.length()) \
		.override_failure_message("mouth edge collapsed to a point") \
		.is_greater(0.1)

	var road := arm.dir_at(arm.trim)
	var dot := edge.normalized().dot(Vector2(road.x, road.z))
	assert_float(absf(dot)) \
		.override_failure_message(
			"cap mouth edge is %.1f degrees off square to the road"
			% rad_to_deg(acos(clampf(1.0 - absf(dot), -1.0, 1.0)))) \
		.is_less(0.01)

	# The mouth edge must also be the full carriageway width, not a foreshortened
	# slice of it — the failure mode if the lateral were taken at the node.
	assert_float(edge.length()) \
		.override_failure_message(
			"mouth edge is %.2f m wide, expected the carriageway 8.0 m"
			% edge.length()) \
		.is_equal_approx(8.0, 0.01)


func test_straight_arms_are_unchanged_by_the_polyline_walk() -> void:
	# The polyline walk must be a no-op on a straight road: the classic + is the
	# case everything else is tuned against, so it has to give the same square
	# cap it always did.
	var d := _cross_data()
	var j: RoadJunctionSolver.Junction = RoadJunctionSolver.solve_all(
		d["ways"], d["nodes"], _is_road(), _width())[0]
	for arm: RoadJunctionSolver.Arm in j.arms:
		var walked := arm.point_at(j.center, arm.trim)
		var ray := Vector3(
			j.center.x + arm.dir.x * arm.trim, j.center.y,
			j.center.z + arm.dir.z * arm.trim)
		assert_float(Vector2(walked.x, walked.z).distance_to(
				Vector2(ray.x, ray.z))) \
			.override_failure_message(
				"a straight arm must walk exactly along its own ray") \
			.is_less(0.001)
	assert_int(j.raw_cap.size()) \
		.override_failure_message("a straight + must still cap as a square") \
		.is_equal(4)


func test_arm_without_a_polyline_falls_back_to_the_straight_ray() -> void:
	# Arm is constructed directly in a couple of places (and by tests); with no
	# centreline supplied it must behave exactly as it did before this change
	# rather than dividing by zero or returning the origin.
	var arm := RoadJunctionSolver.Arm.new()
	arm.dir = Vector3(0.0, 0.0, 1.0)
	arm.half_width = 4.0
	var p := arm.point_at(Vector3(5.0, 0.0, 5.0), 10.0)
	assert_float(p.x).is_equal_approx(5.0, 0.001)
	assert_float(p.z).is_equal_approx(15.0, 0.001)
	assert_float(arm.dir_at(10.0).dot(arm.dir)).is_equal_approx(1.0, 0.001)
	assert_float(arm.lateral_at(10.0).dot(arm.lateral())) \
		.is_equal_approx(1.0, 0.001)


func test_arm_polyline_stops_banking_past_max_trim() -> void:
	# The centreline is copied per arm, so a long rural way must not drag its
	# entire length into every junction it touches. Nothing beyond MAX_TRIM can
	# affect any answer.
	var nodes := {0: _node(0, 0, 0), 1: _node(1, -50, 0)}
	var ids: Array = [0]
	# 40 nodes at 2 m spacing = 80 m of road, far beyond MAX_TRIM (14 m).
	for k: int in range(1, 41):
		nodes[100 + k] = _node(100 + k, 0, k * 2)
		ids.append(100 + k)
	var ways: Array = [_way(1, [1, 0]), _way(2, ids), _way(3, [0, 1])]
	var solved := RoadJunctionSolver.solve_all(ways, nodes, _is_road(), _width())
	if not solved.has(0):
		return
	var j: RoadJunctionSolver.Junction = solved[0]
	for arm: RoadJunctionSolver.Arm in j.arms:
		if arm.way_id != 2:
			continue
		var banked := 0.0
		for i: int in range(arm.polyline.size() - 1):
			var a: Vector3 = arm.polyline[i]
			var b: Vector3 = arm.polyline[i + 1]
			banked += Vector2(a.x, a.z).distance_to(Vector2(b.x, b.z))
		assert_float(banked) \
			.override_failure_message(
				"arm banked %.1f m of centreline; MAX_TRIM is %.1f"
				% [banked, RoadJunctionSolver.MAX_TRIM]) \
			.is_less(RoadJunctionSolver.MAX_TRIM + 4.0)


func test_bent_junction_still_covers_its_centre_and_triangulates() -> void:
	# The invariants the straight-ray cap already had must survive the change:
	# the cap still fills the hole, and is still a simple polygon built by
	# construction rather than rescued by the convex-hull repair.
	var d := _bent_arm_data()
	var j: RoadJunctionSolver.Junction = RoadJunctionSolver.solve_all(
		d["ways"], d["nodes"], _is_road(), _width())[0]
	assert_bool(_point_in_polygon(j.center, j.cap)) \
		.override_failure_message("bent junction cap must cover the node") \
		.is_true()
	assert_int(Geometry2D.triangulate_polygon(_flatten(j.raw_cap)).size()) \
		.override_failure_message(
			"bent junction must build simple, not need the hull repair") \
		.is_greater_equal(3)


## Cap points as a flat XZ polygon, for triangulation checks.
func _flatten(cap: PackedVector3Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	for p: Vector3 in cap:
		out.append(Vector2(p.x, p.z))
	return out
