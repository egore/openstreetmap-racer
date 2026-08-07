class_name RoadJunctionSolver
extends RefCounted

## Solves real road intersections from OSM data: which nodes are junctions, which
## road arms meet there, how far back each arm must be trimmed, and the polygon
## that fills the resulting hole.
##
## ── Why this exists ──────────────────────────────────────────────────────────
## The previous renderer drew every way as a full-length ribbon and let them
## OVERLAP at shared nodes (the Mapnik model): z-fighting was avoided by not
## writing depth and painting bigger classes last. That reads acceptably from
## above, but at street level it is obviously wrong — there is no intersection
## surface, lane lines run straight through the crossing, and kerbs stop dead in
## mid-air where two roads meet.
##
## Instead we now do what a game like GTA does: every junction is REAL geometry.
## Each arm is pulled back from the shared node, and the hole that leaves is
## filled with a dedicated intersection polygon whose corners are rounded.
##
## ── The model ────────────────────────────────────────────────────────────────
## For a junction node N with arms A0..An-1 (each a road leaving N in some
## direction, with its own half-width):
##
##   1. Sort the arms by bearing around N. This gives the cyclic order of the
##      intersection's corners.
##   2. For each ADJACENT pair of arms, compute where their near edges cross.
##      That crossing point is the corner of the intersection. The further apart
##      in angle the pair is, the closer the corner sits to N; a very acute pair
##      pushes its corner far out (clamped, see MAX_TRIM).
##   3. Each arm's trim distance is how far along it we must travel so its
##      section clears every corner it participates in. That is the max over its
##      two neighbouring corners, plus a small setback so the cap has some depth.
##   4. The cap polygon walks the arms in bearing order emitting, per arm, its
##      two trimmed edge points (left then right), joined to the next arm by a
##      straight chamfer. The cap is a simple 2n-gon threaded through the arm
##      mouths — every vertex is one an actual road put there.
##
## Everything here is PURE: it takes plain node/way data and returns plain
## structs. No SurfaceTool, no scene tree, no HeightProvider — so the geometry
## can be unit-tested exactly (see tests/test_road_junction_solver.gd) without
## standing up Godot. The mesh emission lives in OSMWayBuilder.

## One road arm leaving a junction node.
class Arm extends RefCounted:
	## OSM way id this arm belongs to (for debugging / stable ordering).
	var way_id: int = 0
	## The junction node this arm leaves from.
	var node_id: int = 0
	## Unit direction in XZ pointing AWAY from the junction, along the arm.
	var dir: Vector3 = Vector3.ZERO
	## Bearing of `dir` in radians, atan2(dir.z, dir.x). Used for cyclic sort.
	var bearing: float = 0.0
	## Half the carriageway width of this arm in metres.
	var half_width: float = 0.0
	## Highway class, so the cap can adopt the dominant arm's look.
	var highway_type: String = ""
	## True when this arm's way STARTS at the junction (node is way.node_ids[0]).
	## When false the arm arrives at the junction from its far end. The ribbon
	## builder needs this to know which end of the polyline to trim.
	var at_way_start: bool = true
	## How far along this arm (metres from the junction node) the ribbon must be
	## cut back. Filled in by solve(); 0 until then.
	var trim: float = 0.0
	## The way's real centreline leaving this junction: index 0 IS the junction
	## node, subsequent points run outward along the arm. Only XZ is used.
	##
	## ── Why an arm is not a straight ray ─────────────────────────────────────
	## `dir` is the chord to the next node, which is the arm's direction only for
	## the first few metres. OSMWayBuilder cuts the ribbon by ARC LENGTH along
	## this same centreline, so whenever a way bends WITHIN the trim distance —
	## very common, OSM litters nodes a metre or two from a junction — the mouth
	## lands on a later segment pointing somewhere else entirely.
	##
	## A cap built from the straight ray then meets that mouth at both the wrong
	## POSITION and the wrong ANGLE: the two cuts cross, opening a wedge of bare
	## ground on one side while the ribbon's corner juts past the cap on the
	## other. Walking the real polyline makes the two agree by construction, the
	## same "one source of truth" reasoning that put widths in RoadProfile.
	##
	## Empty when no polyline was supplied, in which case every accessor below
	## degrades to the straight-ray behaviour this class had before.
	var polyline: PackedVector3Array = PackedVector3Array()

	## Point `distance` metres from the junction, measured ALONG THE CENTRELINE —
	## the same measure OSMWayBuilder trims by, so the cap mouth and the ribbon
	## mouth land on exactly the same spot.
	func point_at(origin: Vector3, distance: float) -> Vector3:
		if polyline.size() >= 2:
			var p := _walk(distance)
			return Vector3(p.x, origin.y, p.z)
		return Vector3(
			origin.x + dir.x * distance,
			origin.y,
			origin.z + dir.z * distance)

	## Unit direction the arm actually runs in `distance` metres out, i.e. the
	## tangent of the segment the mouth falls on.
	##
	## This mirrors OSMWayBuilder._miter_offset's endpoint rule exactly: the
	## ribbon's first point is the interpolated cut and its second is the next
	## original vertex, so the end cap is square to the segment CONTAINING the
	## cut. The `+ 0.01` matches _slice_polyline's vertex-skip epsilon, so a cut
	## landing precisely on a vertex picks the same segment on both sides.
	func dir_at(distance: float) -> Vector3:
		var n := polyline.size()
		if n < 2:
			return dir
		var travelled := 0.0
		var last := dir
		for i: int in range(n - 1):
			var seg := _seg_dir(i)
			if seg == Vector3.ZERO:
				continue
			last = seg
			var seg_len := _seg_len(i)
			if travelled + seg_len > distance + 0.01:
				return last
			travelled += seg_len
		return last

	## Right-hand lateral (unit, XZ) looking away from the junction, at the
	## junction node. Matches OSMWayBuilder's convention: right = (-dir.z, 0, dir.x).
	func lateral() -> Vector3:
		return Vector3(-dir.z, 0.0, dir.x)

	## Right-hand lateral `distance` metres out, square to the arm's real
	## direction there. This is what the mouth's two edge corners are offset by.
	func lateral_at(distance: float) -> Vector3:
		var d := dir_at(distance)
		return Vector3(-d.z, 0.0, d.x)

	## Position at arc length `distance` along the polyline. Distances past the
	## end extrapolate along the last usable segment, so a way shorter than its
	## own trim still yields a mouth pointing the right way instead of stopping
	## dead at its final node.
	func _walk(distance: float) -> Vector3:
		var n := polyline.size()
		if distance <= 0.0:
			return polyline[0]
		var travelled := 0.0
		var last_i := -1
		for i: int in range(n - 1):
			var seg_len := _seg_len(i)
			if seg_len <= 0.0001:
				continue
			last_i = i
			if travelled + seg_len >= distance:
				return polyline[i].lerp(
					polyline[i + 1], (distance - travelled) / seg_len)
			travelled += seg_len
		if last_i < 0:
			return polyline[0]
		var tail := polyline[last_i + 1]
		var over := distance - travelled
		var d := _seg_dir(last_i)
		return Vector3(tail.x + d.x * over, tail.y, tail.z + d.z * over)

	## XZ length of polyline segment i.
	func _seg_len(i: int) -> float:
		var a := polyline[i]
		var b := polyline[i + 1]
		var dx := b.x - a.x
		var dz := b.z - a.z
		return sqrt(dx * dx + dz * dz)

	## Unit XZ direction of polyline segment i, or ZERO when degenerate.
	func _seg_dir(i: int) -> Vector3:
		var a := polyline[i]
		var b := polyline[i + 1]
		var d := Vector3(b.x - a.x, 0.0, b.z - a.z)
		if d.length_squared() < 0.000001:
			return Vector3.ZERO
		return d.normalized()


## A solved intersection: where it is, which arms meet, and its cap outline.
class Junction extends RefCounted:
	## OSM node id at the centre of the intersection.
	var node_id: int = 0
	## World position of the junction node.
	var center: Vector3 = Vector3.ZERO
	## Arms in bearing order (counter-clockwise in XZ).
	var arms: Array[Arm] = []
	## Closed polygon (XZ, y = center.y) filling the hole left by the trimmed
	## arms, corners rounded. Empty when the junction is degenerate. This is the
	## polygon the renderer uses, after any repair (see raw_cap).
	var cap: PackedVector3Array = PackedVector3Array()
	## The cap exactly as walked from the arms, BEFORE the convex-hull repair
	## that rescues self-intersecting acute forks. Exposed so tests can verify
	## the corner geometry is correct by construction: asserting only on `cap`
	## would pass even with the corner maths wrong, because the repair would
	## quietly paper over it.
	var raw_cap: PackedVector3Array = PackedVector3Array()
	## Highway class of the widest arm — the cap renders as this class so a
	## junction between a primary and a residential looks like primary asphalt.
	var dominant_type: String = ""
	## Largest half-width among the arms; used for cap sizing heuristics.
	var max_half_width: float = 0.0

	## Trim distance for a given way at this junction, or 0.0 when that way has
	## no arm here. When a way both enters and leaves (it passes THROUGH the
	## junction) the caller must disambiguate with at_way_start.
	func trim_for(way_id: int, at_way_start: bool) -> float:
		for arm: Arm in arms:
			if arm.way_id == way_id and arm.at_way_start == at_way_start:
				return arm.trim
		return 0.0


## Minimum number of arms for a node to count as an intersection. Two arms is
## just a road continuing (possibly changing tags), which needs no cap — the
## ribbons already join seamlessly there via the miter join.
const MIN_ARMS := 3

## Hard cap on how far back an arm may be trimmed, in metres. Two arms leaving at
## a very shallow angle have their edge-crossing far from the node (in the limit,
## parallel arms never cross), which would eat an entire street. Clamping trades
## a geometrically exact corner for a sane one.
const MAX_TRIM := 14.0

## Extra setback added to every arm's trim beyond the bare corner distance.
##
## Was 1.2 m, to give the cap "some depth" when the corner maths put every mouth
## almost on top of the node. The cap gets its depth from the arm mouths
## themselves, so this only pushed all four mouths outward and inflated the
## intersection: removing it took a real residential T-junction from 90 m^2 to
## 61 m^2 against an ideal carriageway box of ~49 m^2.
##
## Kept as a named constant rather than deleted because the corner distance is a
## clamped approximation and a small positive setback is the obvious first knob
## if mouths ever land inside the cap. Metres.
const TRIM_SETBACK := 0.0

## Number of points used to draw each corner between adjacent arms.
##
## The cap is now a straight-edged polygon, so this is 0: each arm contributes
## exactly two vertices (its left and right mouth corners) and consecutive arms
## are joined by a single straight chamfer.
##
## It used to be 4, feeding a "fillet arc" that was not a corner round-off at all
## but an arc swept about the junction CENTRE at the mouth radius — in other
## words a disc. Every cap was a circle of asphalt bulging into the verge on any
## side without a road, which is what read in-game as a black puddle beside
## T-junctions. Across 1406 real junctions that made caps 4.7x the ideal
## carriageway box; the straight polygon is 1.7x.
##
## OSMJunctionBuilder still reads this to decide how finely to tessellate its
## kerb corners, which ARE genuinely curved, so it clamps to a sane minimum.
const FILLET_SEGMENTS := 0

## Two arms whose bearings differ by less than this (radians) are treated as the
## same direction — a way doubling back on itself, or duplicate geometry. The
## narrower one is dropped so it can't produce a degenerate corner.
const MIN_ARM_SEPARATION := 0.12  # ~7 degrees

## Relaxation passes used to place a corner between two arms (_corner_distance).
##
## An arm is a polyline, so the edge line to intersect depends on how far along
## the arm the corner turns out to be — a fixed point we solve by iterating.
##
## A straight arm converges on the first pass (its direction never changes), so
## this only costs anything at genuinely bent junctions. Four is comfortably
## more than real road bends need; the loop also exits early once it settles.
const CORNER_SOLVE_PASSES := 4


## Find every node where MIN_ARMS or more road ARMS meet.
##
## `ways` is an Array of OSMParser.OSMWay; `nodes` is the id -> OSMNode dict.
## `is_road_fn` is a predicate (way) -> bool selecting which ways participate,
## so the caller controls whether footways/cycleways form junctions.
##
## Counting ARMS rather than ways is essential: a classic + crossing is only TWO
## ways, but each passes THROUGH the node and so leaves in two directions —
## four arms in total. Counting ways would score that junction as 2 and miss it,
## while a road merely continuing into another way (a tag change) also scores 2
## but has just two arms and must NOT be treated as an intersection.
##
##   way ending/starting at the node → 1 arm
##   way passing through the node    → 2 arms
##
## Returns a Dictionary used as a set: node_id -> true.
static func find_junction_nodes(
		ways: Array, nodes: Dictionary, is_road_fn: Callable) -> Dictionary:
	var arm_count: Dictionary = {}
	for way: OSMParser.OSMWay in ways:
		if not is_road_fn.call(way):
			continue
		var n := way.node_ids.size()
		if n < 2:
			continue
		# Count each node's arms within THIS way, so a node visited twice by the
		# same way (a closed loop returning to its start) accumulates correctly
		# without being mistaken for two independent streets.
		var seen: Dictionary = {}
		for i: int in range(n):
			var nid: int = way.node_ids[i]
			if not nodes.has(nid):
				continue
			# Interior node → the way leaves in both directions (2 arms);
			# terminal node → a single arm.
			var arms_here := 2 if (i > 0 and i < n - 1) else 1
			# A closed way's repeated first/last node contributes one arm from
			# each visit, which together correctly read as a through-node.
			seen[nid] = int(seen.get(nid, 0)) + arms_here
		for nid: int in seen:
			arm_count[nid] = int(arm_count.get(nid, 0)) + int(seen[nid])

	var junctions: Dictionary = {}
	for nid: int in arm_count:
		if int(arm_count[nid]) >= MIN_ARMS:
			junctions[nid] = true
	return junctions


## Build and solve every junction among `ways`.
##
## `width_fn` is (way) -> float returning the carriageway width in metres, so the
## solver stays independent of OSMWayBuilder's width rules (and tests can inject
## simple widths). Returns node_id -> Junction, only for nodes that produced a
## valid (non-degenerate) intersection.
static func solve_all(
		ways: Array, nodes: Dictionary,
		is_road_fn: Callable, width_fn: Callable) -> Dictionary:
	var junction_nodes := find_junction_nodes(ways, nodes, is_road_fn)
	if junction_nodes.is_empty():
		return {}

	# Collect the arms that meet at each junction node.
	var arms_by_node: Dictionary = {}   # node_id -> Array[Arm]
	for way: OSMParser.OSMWay in ways:
		if not is_road_fn.call(way):
			continue
		for arm: Arm in _arms_of_way(way, nodes, junction_nodes, width_fn):
			if not arms_by_node.has(arm.node_id):
				arms_by_node[arm.node_id] = ([] as Array[Arm])
			(arms_by_node[arm.node_id] as Array[Arm]).append(arm)

	var out: Dictionary = {}
	for nid: int in arms_by_node:
		var junction := _solve_one(nid, arms_by_node[nid], nodes[nid].local_pos)
		if junction != null:
			out[nid] = junction
	return out


## Every arm a single way contributes. A way contributes an arm wherever it
## touches a junction node:
##   - at its first node  → one arm leaving toward node_ids[1]
##   - at its last node   → one arm leaving toward node_ids[n-2]
##   - at an INTERIOR junction node → TWO arms (the way passes through, leaving
##     in both directions), because the ribbon is cut in half there.
static func _arms_of_way(
		way: OSMParser.OSMWay, nodes: Dictionary,
		junction_nodes: Dictionary, width_fn: Callable) -> Array[Arm]:
	var out: Array[Arm] = []
	var n := way.node_ids.size()
	if n < 2:
		return out

	var width: float = width_fn.call(way)
	if width <= 0.0:
		return out
	var half_w := width * 0.5
	var highway_type: String = way.tags.get("highway", "unclassified")

	for i: int in range(n):
		var nid: int = way.node_ids[i]
		if not junction_nodes.has(nid) or not nodes.has(nid):
			continue
		var here: Vector3 = nodes[nid].local_pos

		# Leaving forward (toward the next node) — exists unless this is the
		# way's last node. The ribbon on that side starts AT this junction.
		if i < n - 1:
			var fwd := _dir_between(here, nodes, way.node_ids, i, 1)
			if fwd != Vector3.ZERO:
				var arm := _make_arm(
					way.id, nid, fwd, half_w, highway_type, true)
				arm.polyline = _centreline_from(way, nodes, i, 1)
				out.append(arm)

		# Leaving backward (toward the previous node) — exists unless this is
		# the way's first node. The ribbon on that side ENDS at this junction.
		if i > 0:
			var bwd := _dir_between(here, nodes, way.node_ids, i, -1)
			if bwd != Vector3.ZERO:
				var arm := _make_arm(
					way.id, nid, bwd, half_w, highway_type, false)
				arm.polyline = _centreline_from(way, nodes, i, -1)
				out.append(arm)
	return out


## The way's centreline starting at node index `i` and walking `step` (+1 = along
## the way, -1 = against it), as world positions with the junction node first.
##
## Missing and coincident nodes are skipped, so a partially-loaded tile still
## yields a usable centreline rather than a zero-length segment.
##
## The walk stops once it has banked MAX_TRIM metres: no arm can ever be trimmed
## further than that, so trailing points cannot change any answer, and a long
## rural way would otherwise copy its whole length into every arm.
##
## Note this does NOT stop at an intervening junction. It does not need to: the
## trim computed here is always the one this junction asked for, and where two
## junctions sit closer together than their trims, OSMWayBuilder._append_span
## already scales both down to fit the span between them.
static func _centreline_from(
		way: OSMParser.OSMWay, nodes: Dictionary, i: int,
		step: int) -> PackedVector3Array:
	var out := PackedVector3Array()
	if not nodes.has(way.node_ids[i]):
		return out
	out.append(nodes[way.node_ids[i]].local_pos)

	var banked := 0.0
	var j := i + step
	while j >= 0 and j < way.node_ids.size():
		var nid: int = way.node_ids[j]
		if nodes.has(nid):
			var p: Vector3 = nodes[nid].local_pos
			var prev := out[out.size() - 1]
			var dx := p.x - prev.x
			var dz := p.z - prev.z
			var seg := sqrt(dx * dx + dz * dz)
			if seg > 0.0001:
				out.append(p)
				banked += seg
				if banked >= MAX_TRIM:
					break
		j += step
	return out


## Unit XZ direction from the node at index `i` toward its neighbour `step` away
## (+1 = next, -1 = previous), skipping over coincident/missing nodes so a
## duplicated node in the way doesn't yield a zero direction. Vector3.ZERO when
## no usable neighbour exists.
static func _dir_between(
		here: Vector3, nodes: Dictionary, node_ids: Array[int],
		i: int, step: int) -> Vector3:
	var j := i + step
	while j >= 0 and j < node_ids.size():
		var nid: int = node_ids[j]
		if nodes.has(nid):
			var there: Vector3 = nodes[nid].local_pos
			var d := Vector3(there.x - here.x, 0.0, there.z - here.z)
			if d.length_squared() > 0.000001:
				return d.normalized()
		j += step
	return Vector3.ZERO


static func _make_arm(
		way_id: int, node_id: int, dir: Vector3, half_width: float,
		highway_type: String, at_way_start: bool) -> Arm:
	var arm := Arm.new()
	arm.way_id = way_id
	arm.node_id = node_id
	arm.dir = dir
	arm.bearing = atan2(dir.z, dir.x)
	arm.half_width = half_width
	arm.highway_type = highway_type
	arm.at_way_start = at_way_start
	return arm


## Solve one junction: order the arms, compute trims, build the cap polygon.
## Returns null when the junction is degenerate (too few usable arms).
static func _solve_one(node_id: int, arms_in: Array, center: Vector3) -> Junction:
	var arms: Array[Arm] = []
	for a: Arm in arms_in:
		arms.append(a)
	if arms.size() < MIN_ARMS:
		return null

	# Counter-clockwise cyclic order around the node. Ties broken by way id so
	# the result is deterministic across rebuilds (important: the streaming
	# world re-solves the same junction from different tiles and must agree).
	arms.sort_custom(func(a: Arm, b: Arm) -> bool:
		if is_equal_approx(a.bearing, b.bearing):
			return a.way_id < b.way_id
		return a.bearing < b.bearing)

	arms = _drop_near_duplicate_arms(arms)
	if arms.size() < MIN_ARMS:
		return null

	# Corner between each adjacent pair: how far from the node the two arms'
	# facing edges cross. corner_dist[i] belongs to the pair (arms[i], arms[i+1]).
	var count := arms.size()
	var corner_dist: Array[float] = []
	corner_dist.resize(count)
	for i: int in range(count):
		var a: Arm = arms[i]
		var b: Arm = arms[(i + 1) % count]
		corner_dist[i] = _corner_distance(a, b, center)

	# Each arm is trimmed past BOTH the corners it touches, plus a setback so the
	# cap has depth. Corner i-1 is on the arm's right, corner i on its left.
	for i: int in range(count):
		var prev_corner: float = corner_dist[(i - 1 + count) % count]
		var here_corner: float = corner_dist[i]
		var trim := maxf(prev_corner, here_corner) + TRIM_SETBACK
		arms[i].trim = clampf(trim, 0.0, MAX_TRIM)

	var junction := Junction.new()
	junction.node_id = node_id
	junction.center = center
	junction.arms = arms
	junction.raw_cap = _build_cap_walk(arms, center)
	junction.cap = _ensure_simple(junction.raw_cap, center)
	for arm: Arm in arms:
		if arm.half_width > junction.max_half_width:
			junction.max_half_width = arm.half_width
			junction.dominant_type = arm.highway_type
	return junction


## Remove arms pointing in essentially the same direction as their neighbour,
## keeping the WIDER of the pair. Two coincident arms would otherwise produce a
## corner at infinity (parallel edges never cross) and a self-intersecting cap.
static func _drop_near_duplicate_arms(arms: Array[Arm]) -> Array[Arm]:
	if arms.size() < 2:
		return arms
	var out: Array[Arm] = []
	for arm: Arm in arms:
		var merged := false
		for i: int in range(out.size()):
			if _angle_between(out[i].bearing, arm.bearing) < MIN_ARM_SEPARATION:
				# Same direction as one we already kept: keep the wider one.
				if arm.half_width > out[i].half_width:
					out[i] = arm
				merged = true
				break
		if not merged:
			out.append(arm)
	return out


## Smallest absolute angle between two bearings, in [0, PI].
static func _angle_between(a: float, b: float) -> float:
	var d := fposmod(a - b, TAU)
	if d > PI:
		d = TAU - d
	return d


## Distance from the junction node at which the facing edges of two adjacent
## arms cross.
##
## lateral() is (-dir.z, 0, dir.x), which in this bearing convention
## (atan2(dir.z, dir.x)) points toward INCREASING bearing — that is, toward the
## next arm counter-clockwise. So for an adjacent pair (a, b) taken in sorted
## order, the two edges facing each other across the corner are:
##
##     a's +lateral edge   and   b's -lateral edge
##
## This MUST match the pairing _build_cap uses to place its fillet, or the trim
## would be computed for one corner and the geometry drawn at another. A
## symmetric crossing hides the mistake (all four corners are congruent), but on
## a real asymmetric junction the mouths end up in the wrong place and the cap
## self-intersects instead of triangulating.
##
## Each edge is a line offset laterally from its arm's axis; we intersect them
## and project the hit back onto each arm. The larger projection is the distance
## both arms must clear. Direct line intersection is used rather than the closed
## trig form because it stays stable across the wide range of angles real streets
## produce, with an explicit guard for the near-parallel case.
##
## ── Why this iterates ────────────────────────────────────────────────────────
## An arm is a polyline, not a ray (see Arm.polyline). Its edge near the node
## runs along the FIRST segment, but the corner may well land past the bend, on a
## segment pointing somewhere else — so the edge line depends on the very
## distance we are solving for.
##
## We therefore relax: take the current estimate of each mouth, build both edge
## lines square to the road THERE, intersect, and step each arm to the crossing.
## A handful of passes is plenty; real bends are gentle and this converges fast.
##
## For a STRAIGHT arm the direction never varies, so the first pass already lands
## on the exact closed-form answer and the rest are no-ops — the classic +
## crossing gets bit-for-bit the geometry it always did.
static func _corner_distance(a: Arm, b: Arm, center: Vector3) -> float:
	var theta := _angle_between(a.bearing, b.bearing)
	# Near-parallel arms: edges barely converge, corner runs away to infinity.
	if theta < MIN_ARM_SEPARATION or theta > PI - 0.001:
		return maxf(a.half_width, b.half_width)

	var floor_d := maxf(a.half_width, b.half_width)
	var ta := 0.0
	var tb := 0.0
	for _pass: int in range(CORNER_SOLVE_PASSES):
		# The two edges facing each other across this corner, each square to its
		# own road at the current mouth estimate.
		var a_dir := a.dir_at(ta)
		var b_dir := b.dir_at(tb)
		var a_edge := a.point_at(center, ta) + a.lateral_at(ta) * a.half_width
		var b_edge := b.point_at(center, tb) - b.lateral_at(tb) * b.half_width

		var hit := _ray_intersect_xz(a_edge, a_dir, b_edge, b_dir)
		if not hit.hit:
			return floor_d
		var p := hit.point

		# Advance each arm to where its own edge meets the crossing. Distances
		# are signed, so a corner already behind the mouth pulls the trim back.
		var next_a := ta + (p.x - a_edge.x) * a_dir.x + (p.z - a_edge.z) * a_dir.z
		var next_b := tb + (p.x - b_edge.x) * b_dir.x + (p.z - b_edge.z) * b_dir.z
		next_a = clampf(next_a, 0.0, MAX_TRIM)
		next_b = clampf(next_b, 0.0, MAX_TRIM)
		# Settled: further passes cannot move it.
		if absf(next_a - ta) < 0.001 and absf(next_b - tb) < 0.001:
			ta = next_a
			tb = next_b
			break
		ta = next_a
		tb = next_b

	# A crossing BEHIND the node (negative projection) means the arms diverge;
	# the minimum sensible clearance is then just the widths.
	return clampf(maxf(ta, tb), floor_d, MAX_TRIM)


## Result of a line/line intersection: whether the lines actually met, and where.
## A tiny struct rather than a nullable Variant so the whole solver stays
## statically typed (this project compiles with warnings-as-errors).
class LineHit extends RefCounted:
	var hit: bool = false
	var point: Vector3 = Vector3.ZERO

	func _init(p_hit: bool = false, p_point: Vector3 = Vector3.ZERO) -> void:
		hit = p_hit
		point = p_point


## Intersection of two XZ lines given as (point, unit direction). `hit` is false
## when the lines are parallel (no unique intersection).
static func _ray_intersect_xz(
		p0: Vector3, d0: Vector3, p1: Vector3, d1: Vector3) -> LineHit:
	var denom := d0.x * d1.z - d0.z * d1.x
	if absf(denom) < 0.000001:
		return LineHit.new(false)
	var dx := p1.x - p0.x
	var dz := p1.z - p0.z
	var t := (dx * d1.z - dz * d1.x) / denom
	return LineHit.new(true, Vector3(p0.x + d0.x * t, 0.0, p0.z + d0.z * t))


## Build the closed cap polygon from solved arms.
##
## Arms are ordered by increasing bearing = atan2(dir.z, dir.x), which sweeps
## from +X toward +Z. In Godot's Y-up frame that is the direction of POSITIVE
## polygon area in the XZ plane — the same winding the road ribbons use for their
## up-facing quads (see OSMWayBuilder._emit_road_ribbon).
##
## Walking in that order, each arm contributes exactly TWO points — its mouth's
## LEFT edge then its RIGHT edge — and consecutive arms are joined by the
## straight edge from one arm's RIGHT corner to the next arm's LEFT corner. The
## cap is therefore a simple 2n-gon threaded through the arm mouths: no more
## points than the roads themselves justify.
##
## Getting this pairing the wrong way round does not merely mirror the shape: it
## connects each arm to the far side of the junction, producing a self-
## intersecting star that will not triangulate at all.
##
## Earlier versions inserted a "fillet arc" between consecutive arms. It was not
## a corner round-off: it swept about the junction CENTRE at the mouth radius, so
## the cap came out as a disc that bulged into the verge wherever no road left
## the node — the black puddle beside every T-junction. Straight chamfers are
## both correct and cheaper.
static func _build_cap_walk(arms: Array[Arm], center: Vector3) -> PackedVector3Array:
	var walk := PackedVector3Array()
	var count := arms.size()
	if count < MIN_ARMS:
		return walk

	for i: int in range(count):
		var arm: Arm = arms[i]
		var mouth := arm.point_at(center, arm.trim)
		# Square to the arm's direction AT THE MOUTH, not at the junction node.
		# On a way that bends inside its own trim these differ, and the ribbon's
		# end cap follows the mouth segment (OSMWayBuilder._miter_offset), so
		# using the node direction here cuts the cap at a different angle from
		# the ribbon it must meet — a visible wedge of ground at the join.
		var lat := arm.lateral_at(arm.trim) * arm.half_width
		walk.append(Vector3(mouth.x - lat.x, center.y, mouth.z - lat.z))
		walk.append(Vector3(mouth.x + lat.x, center.y, mouth.z + lat.z))
	return _drop_coincident(walk)


## Drop points that repeat their predecessor (cyclically).
##
## With straight chamfers a chamfer can legitimately have ZERO length: at a clean
## right-angle crossing, adjacent arms are trimmed to the same distance and their
## facing mouth corners land on exactly the same spot. That is the correct
## geometry — the cap really is a square there — but emitting the point twice
## makes a zero-area triangle, which the triangulator may reject and which shades
## with a garbage normal if it doesn't.
##
## The old fillet arc always inserted points between the two, so this case never
## arose and the cap could not express a square corner without a wobble in it.
static func _drop_coincident(poly: PackedVector3Array) -> PackedVector3Array:
	var out := PackedVector3Array()
	var n := poly.size()
	for i: int in range(n):
		var p := poly[i]
		var q := poly[(i + 1) % n]
		if Vector2(p.x, p.z).distance_to(Vector2(q.x, q.z)) > 0.001:
			out.append(p)
	return out


## Guarantee the cap is a simple (non-self-intersecting) polygon.
##
## Two arms meeting at a very acute angle need to be trimmed a long way back
## before their mouths stop overlapping — sometimes further than MAX_TRIM allows.
## When the clamp bites, the two mouths still overlap and the walk above crosses
## itself, which will not triangulate: the junction would render as nothing at
## all, leaving a hole in the road.
##
## Rather than let that happen (or raise MAX_TRIM and eat whole streets), we fall
## back to the convex hull of the cap points. The hull is slightly larger than
## the ideal cap at such a junction, which is the right way to be wrong here: a
## fraction of a metre of extra asphalt at a sharp fork is invisible, whereas a
## missing intersection is not. Affects roughly 1% of real junctions.
static func _ensure_simple(
		cap: PackedVector3Array, center: Vector3) -> PackedVector3Array:
	if cap.size() < 3:
		return cap
	# Godot's triangulator rejects self-intersecting rings, which is exactly the
	# condition we need to detect.
	var flat := PackedVector2Array()
	for p: Vector3 in cap:
		flat.append(Vector2(p.x, p.z))
	if Geometry2D.triangulate_polygon(flat).size() >= 3:
		return cap

	var hull := Geometry2D.convex_hull(flat)
	if hull.size() < 3:
		return cap  # nothing better to offer; caller skips a degenerate cap
	var out := PackedVector3Array()
	for p: Vector2 in hull:
		out.append(Vector3(p.x, center.y, p.y))
	# convex_hull repeats the first point to close the ring; drop it so the cap
	# keeps the same open-ring convention as the normal path.
	if out.size() > 1 and out[0].distance_to(out[out.size() - 1]) < 0.001:
		out.remove_at(out.size() - 1)
	return out
