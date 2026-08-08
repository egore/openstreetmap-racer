class_name OSMJunctionBuilder
extends RefCounted

const RoadProfileScript := preload("res://scripts/road_profile.gd")
const RoadJunctionSolverScript := preload("res://scripts/road_junction_solver.gd")

## Turns a solved RoadJunctionSolverScript.Junction into actual scene geometry: the
## intersection surface, the kerb corners that wrap around it, and the painted
## stop bars on each approach.
##
## The solver decides WHERE everything goes (pure maths, exactly testable); this
## class decides how it is drawn (SurfaceTool, terrain draping, materials). The
## split keeps the hard geometry unit-testable without a scene, and keeps the
## Godot-specific mesh code out of the maths.
##
## ── What a junction is made of ───────────────────────────────────────────────
##   1. The CAP — a triangulated polygon covering the hole left by the trimmed
##      arms. Drawn as asphalt, terrain-draped like the ribbons so it sits flush.
##   2. KERB CORNERS — for each gap between two adjacent arms, a wedge of raised
##      pavement joining the two arms' kerb lines around the corner. Without
##      these, sidewalks stop dead at the intersection mouth in mid-air.
##   3. KERB RAMPS — where a kerb corner meets an arm, the pavement drops to
##      road level over a short run so the corner reads as a dropped crossing
##      rather than a cliff.
##   4. STOP BARS — a painted transverse bar across each approach, just inside
##      the cap. Explicit geometry (not shader UVs) because the cap has no
##      along/across parameterisation to paint into.

## Height the junction surface sits above the terrain. Slightly above the road
## ribbons (RoadProfileScript.ROAD_Y) so the cap always wins the coplanar contest at
## the mouth where the two meet, leaving no shimmer.
const CAP_Y := RoadProfileScript.ROAD_Y + 0.004

## Height of painted markings above the cap surface.
const PAINT_Y := 0.006

## Colour of road markings. Matches the asphalt shader's marking_color so paint
## on the cap and paint on the ribbons look like the same paint.
const MARKING_COLOR := Color(0.85, 0.82, 0.62)

## Depth (metres, along the approach) of the stop bar painted on each arm.
const STOP_BAR_DEPTH := 0.4

## Highway classes that carry a painted stop line where they meet a junction.
##
## Deliberately limited to through-roads. Service roads, driveways, alleys and
## living streets do not get a painted bar in reality, and drawing one on every
## arm of every junction turned each intersection into a ring of white blocks —
## far more visually prominent than the asphalt itself.
const STOP_BAR_TYPES := {
	"motorway": true,
	"trunk": true,
	"primary": true,
	"secondary": true,
	"tertiary": true,
	"residential": true,
	"unclassified": true,
}

## How far inside the cap mouth the stop bar sits, so it reads as being at the
## junction rather than floating in the middle of it.
const STOP_BAR_INSET := 0.5

## Length (metres) over which a kerb corner ramps down to road level where it
## meets an arm. This is the dropped-kerb / wheelchair ramp.
const KERB_RAMP_RUN := 1.2

## Points used to tessellate each Bezier kerb corner.
##
## The kerb corner is genuinely curved (a real kerb turns on a radius), unlike
## the asphalt cap beneath it, which is a straight-edged polygon. This used to
## borrow the solver's FILLET_SEGMENTS; that constant is now 0 because the cap
## has no arcs at all, so reusing it would silently flatten every kerb corner
## into a single straight chord.
const KERB_CORNER_SEGMENTS := 4

## Terrain sampling. Set by the tile manager exactly as on OSMWayBuilder, so the
## junction drapes onto the same surface the ribbons do.
var height_provider: HeightProvider = null
var terrain_grid_step: float = 0.0

## Where in the world this map is, which decides the side of the carriageway an
## approach's markings span. Defaults to right-hand traffic, so a caller that
## never sets it gets the convention most of the world uses.
var region: RoadRegion = RoadRegion.new()


## Build the complete geometry for one junction, or null when it is degenerate.
##
## `sidewalk_lookup` maps way_id -> { "left": bool, "right": bool } so the corner
## builder knows which arms actually carry kerbs; a corner is only drawn between
## two arms that both have pavement facing that corner. Pass an empty dictionary
## to skip all kerb geometry.
func build_junction(
		junction: RoadJunctionSolverScript.Junction,
		sidewalk_lookup: Dictionary = {}) -> MeshInstance3D:
	if junction == null or junction.cap.size() < 3:
		return null

	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = "Junction_%d" % junction.node_id

	var surface_st := SurfaceTool.new()
	surface_st.begin(Mesh.PRIMITIVE_TRIANGLES)
	surface_st.set_material(RoadMaterialFactory.create_junction_material(
		junction.dominant_type))

	var built := _emit_cap(surface_st, junction)
	if not built:
		return null

	var mesh := surface_st.commit()

	# Painted markings ride on their own surface so they can use an unlit-ish
	# paint material without disturbing the asphalt underneath.
	var paint_st := SurfaceTool.new()
	paint_st.begin(Mesh.PRIMITIVE_TRIANGLES)
	paint_st.set_material(RoadMaterialFactory.create_marking_material())
	if _emit_stop_bars(paint_st, junction):
		mesh = paint_st.commit(mesh)

	# Kerb corners wrapping the intersection.
	if not sidewalk_lookup.is_empty():
		var kerb_st := SurfaceTool.new()
		kerb_st.begin(Mesh.PRIMITIVE_TRIANGLES)
		kerb_st.set_material(RoadMaterialFactory.create_sidewalk_material())
		if _emit_kerb_corners(kerb_st, junction, sidewalk_lookup):
			mesh = kerb_st.commit(mesh)

	mesh_instance.mesh = mesh
	return mesh_instance


## Triangulate and emit the intersection surface. Returns false when the polygon
## could not be triangulated (self-intersecting from pathological input).
func _emit_cap(st: SurfaceTool, junction: RoadJunctionSolverScript.Junction) -> bool:
	var cap := junction.cap
	var indices := PolygonUtils.triangulate_xz(cap)
	if indices.size() < 3:
		return false

	var conform := height_provider != null and height_provider.is_ready() \
		and terrain_grid_step > 0.0

	for i: int in range(0, indices.size(), 3):
		var a: Vector3 = cap[indices[i]]
		var b: Vector3 = cap[indices[i + 1]]
		var c: Vector3 = cap[indices[i + 2]]
		if conform:
			# Clip each triangle against the terrain grid so the intersection
			# follows the ground exactly, the same treatment the ribbons get.
			# Reusing the quad path keeps one well-tested clipper rather than a
			# second triangle-specific one.
			#
			# The clipper fan-triangulates each clipped piece as (o, v2, v1) —
			# i.e. it REVERSES the order it is handed. So it must be given the
			# opposite winding to the flat path below to end up facing the same
			# way. Getting this wrong emitted a cap whose every face pointed
			# DOWN: backface-culled, so the intersection was invisible from above
			# even though the mesh was built, in the scene, marked visible and
			# correctly positioned.
			var tri := _wound_downward(a, b, c)
			PolygonUtils.emit_terrain_conforming_quad(
				st, tri, height_provider, terrain_grid_step, CAP_Y)
		else:
			# Same requirement on the flat path: Godot's front face is
			# Plane(a, b, c).normal, so the triangle must be ordered such that
			# this points +Y.
			var up_tri := _wound_upward(a, b, c)
			_add_flat_tri(
				st,
				Vector3(up_tri[0].x, 0.0, up_tri[0].y),
				Vector3(up_tri[1].x, 0.0, up_tri[1].y),
				Vector3(up_tri[2].x, 0.0, up_tri[2].y),
				CAP_Y)
	return true


## The three XZ corners of a triangle, ordered so its front face points UP.
##
## Godot culls by the winding-front normal Plane(a, b, c).normal. For the signed
## area (b-a)x(c-a) evaluated in XZ, a POSITIVE area already yields a +Y front
## face; a negative one must be reversed. (Verified directly: the triangle
## (0,0) (1,0) (0,1) has area +1 and Plane normal +Y.)
func _wound_upward(a: Vector3, b: Vector3, c: Vector3) -> PackedVector2Array:
	var area := (b.x - a.x) * (c.z - a.z) - (c.x - a.x) * (b.z - a.z)
	if area < 0.0:
		return PackedVector2Array([
			Vector2(a.x, a.z), Vector2(c.x, c.z), Vector2(b.x, b.z),
		])
	return PackedVector2Array([
		Vector2(a.x, a.z), Vector2(b.x, b.z), Vector2(c.x, c.z),
	])


## The same three corners wound the OTHER way, for consumers that reverse the
## order themselves (PolygonUtils.emit_terrain_conforming_quad fan-triangulates
## as (o, v2, v1), so feeding it an upward winding yields downward faces).
func _wound_downward(a: Vector3, b: Vector3, c: Vector3) -> PackedVector2Array:
	var up := _wound_upward(a, b, c)
	return PackedVector2Array([up[0], up[2], up[1]])


## Emit one upward-facing triangle at `y_offset` above the terrain.
func _add_flat_tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3,
		y_offset: float) -> void:
	for v: Vector3 in [a, b, c]:
		st.set_normal(Vector3.UP)
		st.add_vertex(Vector3(v.x, _height_at(v.x, v.z) + y_offset, v.z))


## Terrain elevation at a world XZ, falling back to flat ground.
func _height_at(x: float, z: float) -> float:
	if height_provider != null and height_provider.is_ready():
		return height_provider.sample_mesh_height(x, z)
	return 0.0


## Paint a stop bar across every approach that should have one.
##
## The bar spans the arm's width at its mouth, oriented across the arm, so it
## follows whatever angle the street meets the junction at. Returns true when
## anything was emitted.
func _emit_stop_bars(
		st: SurfaceTool, junction: RoadJunctionSolverScript.Junction) -> bool:
	# A two-arm junction is a bend, not a crossing — no stop line belongs there.
	if junction.arms.size() < RoadJunctionSolverScript.MIN_ARMS:
		return false

	var emitted := false
	for arm: RoadJunctionSolverScript.Arm in junction.arms:
		# Only real streets get a painted stop line. A driveway or alley meeting
		# a road has no bar in reality, and painting one on every arm of every
		# junction made the intersections read as a grid of white blocks rather
		# than as road surface.
		if not STOP_BAR_TYPES.has(arm.highway_type):
			continue
		# The bar sits just inside the arm's mouth, running ACROSS the direction
		# of travel: its long axis is the arm's lateral, its short axis (the
		# paint depth) is the arm's direction.
		var d := arm.trim - STOP_BAR_INSET
		if d <= 0.1:
			continue
		var centre := arm.point_at(junction.center, d)
		# Square to the arm where the BAR is, not where the junction node is: on
		# a road that bends just past the crossing the two differ, and a bar
		# drawn at the node's angle sits visibly skewed across the carriageway.
		var fwd := arm.dir_at(d)

		# Span only the half of the carriageway traffic APPROACHES on, so the bar
		# does not run across the oncoming lane too.
		#
		# ── Which half that is ────────────────────────────────────────────────
		# `arm.dir` points AWAY from the junction (RoadJunctionSolver.Arm.dir),
		# and lateral_at is the right-hand side OF THAT direction. But traffic
		# arriving at the junction travels along -dir: it comes toward you as you
		# look outward. So the approaching driver's right-hand side is the arm's
		# -lateral, not +lateral.
		#
		# The previous code used +lateral, reasoning that "looking outward from
		# the junction, the approaching lane is on the arm's right" — which
		# inverts the frame, since looking outward you face the oncoming traffic
		# and its right is your left. The bar was painted across the lane LEAVING
		# the junction, in every right-hand-traffic country rather than only the
		# Dutch map it was noticed on.
		#
		# The span must run from the road's CENTRELINE to that edge. Previously
		# one end was left at the arm's centre point and the other pushed out by
		# half_width, which is the same thing only for a road of zero width: on a
		# real street the bar sat half off-centre and read as a perpendicular
		# stub rather than a stop line.
		var lat := arm.lateral_at(d) * -region.lateral_sign()
		var inner := centre                              # centreline
		var outer := centre + lat * arm.half_width       # approach-side kerb
		var half_depth := STOP_BAR_DEPTH * 0.5
		var back := fwd * half_depth

		var p0 := inner - back
		var p1 := outer - back
		var p2 := outer + back
		var p3 := inner + back
		_add_flat_quad(st, p0, p1, p2, p3, CAP_Y + PAINT_Y)
		emitted = true
	return emitted


## Emit an upward-facing quad at a fixed offset above the terrain.
func _add_flat_quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3,
		d: Vector3, y_offset: float) -> void:
	_add_flat_tri(st, a, c, b, y_offset)
	_add_flat_tri(st, a, d, c, y_offset)


## Wrap kerbs around the intersection corners.
##
## Between each adjacent pair of arms there is a corner of pavement. We build it
## as a fan from the outer corner point (where the two arms' outer kerb lines
## would meet) across to each arm's kerb end, raised to kerb height, with the
## last stretch ramping down to road level so the corner has a dropped kerb.
##
## Returns true when any corner geometry was emitted.
func _emit_kerb_corners(
		st: SurfaceTool, junction: RoadJunctionSolverScript.Junction,
		sidewalk_lookup: Dictionary) -> bool:
	var arms := junction.arms
	var count := arms.size()
	if count < RoadJunctionSolverScript.MIN_ARMS:
		return false

	var emitted := false
	for i: int in range(count):
		var a: RoadJunctionSolverScript.Arm = arms[i]
		var b: RoadJunctionSolverScript.Arm = arms[(i + 1) % count]
		# Corner between arm a's RIGHT side and arm b's LEFT side — the same
		# pairing the cap's fillet uses (see RoadJunctionSolver._build_cap), so
		# the kerb wraps the corner the cap actually has.
		#
		# BOTH sides must carry pavement. Relaxing this to "either side" was
		# tried and is wrong: it draws a corner running from a kerbed street
		# round to one with no pavement at all, so the far half of the corner
		# has nothing to connect to and reads as a detached wedge of pavement
		# floating beside the road. A corner is a join between two pavements; if
		# there is only one, there is nothing to join.
		if not _arm_side_has_kerb(a, sidewalk_lookup, true):
			continue
		if not _arm_side_has_kerb(b, sidewalk_lookup, false):
			continue
		if _emit_one_corner(st, junction, a, b):
			emitted = true
	return emitted


## Whether the given side of an arm carries a kerb.
##
## `want_right` selects which side of the ARM (looking outward from the
## junction). That has to be mapped back to the WAY's left/right, which flip
## depending on whether the arm leaves the junction along the way's direction or
## against it.
func _arm_side_has_kerb(
		arm: RoadJunctionSolverScript.Arm, sidewalk_lookup: Dictionary,
		want_right: bool) -> bool:
	var sides: Dictionary = sidewalk_lookup.get(arm.way_id, {})
	if sides.is_empty():
		return false
	# An arm at the way's start points along the way, so arm-right == way-right.
	# An arm at the way's end points backwards, so the sides swap.
	var side_is_right := want_right if arm.at_way_start else not want_right
	return bool(sides.get("right" if side_is_right else "left", false))


## Build the pavement wedge for a single corner between two arms.
func _emit_one_corner(
		st: SurfaceTool, junction: RoadJunctionSolverScript.Junction,
		a: RoadJunctionSolverScript.Arm, b: RoadJunctionSolverScript.Arm) -> bool:
	var centre := junction.center

	# Inner edge of the corner = the cap boundary between the two arm mouths,
	# i.e. arm a's RIGHT edge round to arm b's LEFT edge.
	# Mouth position AND direction both come from the arm's real centreline, so
	# the kerb corner starts exactly where the ribbon's kerb run stopped. Using
	# the junction-node direction instead leaves the corner offset sideways from
	# the pavement it is supposed to continue.
	var a_mouth := a.point_at(centre, a.trim)
	var b_mouth := b.point_at(centre, b.trim)
	var a_dir := a.dir_at(a.trim)
	var b_dir := b.dir_at(b.trim)
	var a_inner := a_mouth + a.lateral_at(a.trim) * a.half_width   # a's right edge
	var b_inner := b_mouth - b.lateral_at(b.trim) * b.half_width   # b's left edge

	# Turn the corner along the KERB LINES of the two arms rather than along a
	# circle about the junction centre.
	#
	# A centre-arc looks wrong for the same reason it is easy to reach for: the
	# two kerb ends are roughly equidistant from the node, so an arc joins them
	# — but it bulges out into the middle of the intersection instead of hugging
	# the corner, which reads as a curved sliver of pavement floating in the
	# junction. A real kerb runs straight along each road and turns only at the
	# corner itself, so the curve must be tangent to both kerb lines: a quadratic
	# Bezier whose control point is where those two lines actually meet.
	var corner := _kerb_lines_meet(a_inner, a_dir, b_inner, b_dir)
	var inner_pts := _bezier_arc(a_inner, corner, b_inner, KERB_CORNER_SEGMENTS)
	if inner_pts.size() < 2:
		return false

	# The outer edge is the inner curve pushed away from the carriageway. The
	# offset direction is the curve's own outward normal, so the pavement keeps a
	# constant depth all the way round instead of pinching where the curve turns
	# fastest (which a radial push from the junction centre does).
	var depth := RoadProfileScript.SIDEWALK_WIDTH
	var outer_pts := _offset_curve_outward(inner_pts, centre, depth)

	var kerb_h := RoadProfileScript.SIDEWALK_HEIGHT
	# Ramp profile: full kerb height through the middle of the corner, dropping
	# to zero at both ends where the pavement meets each arm's own kerb run.
	# That is the dropped kerb pedestrians actually cross at.
	var n := inner_pts.size()
	for i: int in range(n - 1):
		var h0 := _ramp_height(i, n, kerb_h)
		var h1 := _ramp_height(i + 1, n, kerb_h)

		var i0 := inner_pts[i]
		var i1 := inner_pts[i + 1]
		var o0 := outer_pts[i]
		var o1 := outer_pts[i + 1]

		# Top surface of the pavement.
		_add_raised_quad(st, i0, i1, o1, o0, h0, h1, h1, h0)
		# Kerb face toward the road, which is what gives the corner its edge.
		_add_kerb_face(st, i0, i1, h0, h1)
	return true


## Kerb height at position `i` of `n`, ramping down over KERB_RAMP_RUN worth of
## samples at each end so the corner has dropped kerbs where it meets the roads.
func _ramp_height(i: int, n: int, full_height: float) -> float:
	if n <= 2:
		return full_height
	# Number of samples the ramp occupies at each end (at least one).
	var ramp := maxi(1, int(round(float(n) * 0.34)))
	var from_start := i
	var from_end := (n - 1) - i
	var edge_dist := mini(from_start, from_end)
	if edge_dist >= ramp:
		return full_height
	return full_height * (float(edge_dist) / float(ramp))


## Where the two arms' kerb lines would meet if extended past the junction.
##
## Each kerb line runs along its arm's direction through that arm's mouth edge.
## Their intersection is the sharp corner the pavement turns at, and so the
## control point for the rounded fillet. Near-parallel arms have no usable
## intersection; the midpoint is then a safe stand-in (the fillet degenerates to
## a gentle curve, which is correct for two roads meeting head-on).
func _kerb_lines_meet(
		a_point: Vector3, a_dir: Vector3,
		b_point: Vector3, b_dir: Vector3) -> Vector3:
	var denom := a_dir.x * b_dir.z - a_dir.z * b_dir.x
	if absf(denom) < 0.0001:
		return a_point.lerp(b_point, 0.5)
	var dx := b_point.x - a_point.x
	var dz := b_point.z - a_point.z
	var t := (dx * b_dir.z - dz * b_dir.x) / denom
	# Clamp how far the corner may sit from the kerb ends. A very acute pair
	# throws the intersection a long way out, which would balloon the fillet
	# across the whole junction.
	var span := Vector2(a_point.x - b_point.x, a_point.z - b_point.z).length()
	t = clampf(t, -span * 2.0, span * 2.0)
	return Vector3(a_point.x + a_dir.x * t, a_point.y, a_point.z + a_dir.z * t)


## Quadratic Bezier from `from` to `to` bending toward `control`, inclusive of
## both endpoints. Tangent to both kerb lines at the ends, which is what makes
## the corner flow out of the straight pavement rather than kinking.
func _bezier_arc(
		from: Vector3, control: Vector3, to: Vector3,
		segments: int) -> PackedVector3Array:
	var out := PackedVector3Array()
	var steps: int = maxi(segments, 1)
	for s: int in range(steps + 1):
		var t := float(s) / float(steps)
		var inv := 1.0 - t
		# B(t) = (1-t)^2 P0 + 2(1-t)t P1 + t^2 P2
		var w0 := inv * inv
		var w1 := 2.0 * inv * t
		var w2 := t * t
		out.append(Vector3(
			from.x * w0 + control.x * w1 + to.x * w2,
			from.y,
			from.z * w0 + control.z * w1 + to.z * w2))
	return out


## Offset a curve away from the carriageway by `depth`, using each point's own
## outward normal so the pavement keeps a constant width around the bend.
##
## "Outward" is disambiguated by the junction centre: the normal is flipped when
## it points back toward the intersection, so the pavement always lands on the
## far side of the kerb from the road.
func _offset_curve_outward(
		curve: PackedVector3Array, centre: Vector3,
		depth: float) -> PackedVector3Array:
	var out := PackedVector3Array()
	var n := curve.size()
	for i: int in range(n):
		# Local tangent from the neighbouring samples (one-sided at the ends).
		var prev: Vector3 = curve[maxi(i - 1, 0)]
		var next: Vector3 = curve[mini(i + 1, n - 1)]
		var tangent := Vector3(next.x - prev.x, 0.0, next.z - prev.z)
		if tangent.length_squared() < 0.000001:
			tangent = Vector3(1.0, 0.0, 0.0)
		tangent = tangent.normalized()
		var normal := Vector3(-tangent.z, 0.0, tangent.x)
		# Point it away from the junction centre.
		var p: Vector3 = curve[i]
		var to_centre := Vector3(centre.x - p.x, 0.0, centre.z - p.z)
		if normal.dot(to_centre) > 0.0:
			normal = -normal
		out.append(Vector3(
			p.x + normal.x * depth, p.y, p.z + normal.z * depth))
	return out


## Points along an arc from `from` to `to` about `centre`, inclusive of both
## endpoints. Mirrors RoadJunctionSolver's fillet sweep so kerb corners stay
## concentric with the cap corner they sit against.
func _arc_between(
		from: Vector3, to: Vector3, centre: Vector3,
		segments: int) -> PackedVector3Array:
	var out := PackedVector3Array()
	var v0 := Vector3(from.x - centre.x, 0.0, from.z - centre.z)
	var v1 := Vector3(to.x - centre.x, 0.0, to.z - centre.z)
	var r0 := v0.length()
	var r1 := v1.length()
	if r0 < 0.001 or r1 < 0.001:
		out.append(from)
		out.append(to)
		return out

	var a0 := atan2(v0.z, v0.x)
	var a1 := atan2(v1.z, v1.x)
	var delta := fposmod(a1 - a0, TAU)
	if delta > PI:
		# Reflex sweep: the two arms are nearly coincident. A straight join is
		# safer than an arc looping right around the junction.
		out.append(from)
		out.append(to)
		return out

	var steps: int = maxi(segments, 1)
	for s: int in range(steps + 1):
		var t := float(s) / float(steps)
		var ang := a0 + delta * t
		var rad: float = lerpf(r0, r1, t)
		out.append(Vector3(
			centre.x + cos(ang) * rad, centre.y, centre.z + sin(ang) * rad))
	return out


## Emit a quad whose four corners each carry their own height above the terrain.
func _add_raised_quad(
		st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3,
		ha: float, hb: float, hc: float, hd: float) -> void:
	var va := Vector3(a.x, _height_at(a.x, a.z) + ha, a.z)
	var vb := Vector3(b.x, _height_at(b.x, b.z) + hb, b.z)
	var vc := Vector3(c.x, _height_at(c.x, c.z) + hc, c.z)
	var vd := Vector3(d.x, _height_at(d.x, d.z) + hd, d.z)
	PolygonUtils.add_quad_facing(st, va, vb, vc, vd, Vector3.UP)


## Emit the vertical kerb face along the inner (road-facing) edge of a corner.
## Zero-height stretches (the dropped-kerb ramps) are skipped so the ramp reads
## as flush with the road rather than as a paper-thin wall.
func _add_kerb_face(
		st: SurfaceTool, p0: Vector3, p1: Vector3,
		h0: float, h1: float) -> void:
	if h0 <= 0.001 and h1 <= 0.001:
		return
	var base0 := Vector3(p0.x, _height_at(p0.x, p0.z), p0.z)
	var base1 := Vector3(p1.x, _height_at(p1.x, p1.z), p1.z)
	var top0 := Vector3(base0.x, base0.y + h0, base0.z)
	var top1 := Vector3(base1.x, base1.y + h1, base1.z)
	# Face points away from the junction centre (toward the road it kerbs).
	var outward := (p1 - p0).cross(Vector3.UP).normalized()
	PolygonUtils.add_quad_facing(st, base0, base1, top1, top0, outward)
