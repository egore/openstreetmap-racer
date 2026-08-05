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

## How far inside the cap mouth the stop bar sits, so it reads as being at the
## junction rather than floating in the middle of it.
const STOP_BAR_INSET := 0.5

## Length (metres) over which a kerb corner ramps down to road level where it
## meets an arm. This is the dropped-kerb / wheelchair ramp.
const KERB_RAMP_RUN := 1.2

## Terrain sampling. Set by the tile manager exactly as on OSMWayBuilder, so the
## junction drapes onto the same surface the ribbons do.
var height_provider: HeightProvider = null
var terrain_grid_step: float = 0.0


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
			# Reusing the quad path with a degenerate 4th corner keeps one
			# well-tested clipper rather than a second triangle-specific one.
			var tri := PackedVector2Array([
				Vector2(a.x, a.z), Vector2(b.x, b.z), Vector2(c.x, c.z),
			])
			PolygonUtils.emit_terrain_conforming_quad(
				st, tri, height_provider, terrain_grid_step, CAP_Y)
		else:
			# Winding: the solver walks the cap counter-clockwise in XZ, which
			# after Godot's Y-up convention presents as a downward face. Emit
			# reversed so the surface faces up.
			_add_flat_tri(st, a, c, b, CAP_Y)
	return true


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
		# The bar sits just inside the arm's mouth, running ACROSS the direction
		# of travel: its long axis is the arm's lateral, its short axis (the
		# paint depth) is the arm's direction.
		var d := arm.trim - STOP_BAR_INSET
		if d <= 0.1:
			continue
		var centre := arm.point_at(junction.center, d)
		var fwd := arm.dir

		# Span the half of the carriageway that traffic APPROACHES on, so the bar
		# does not run across the oncoming lane too. Traffic drives on the right,
		# so looking OUTWARD from the junction along this arm, the approaching
		# lane is the one on the arm's right — i.e. +lateral.
		#
		# The span must run from the road's CENTRELINE to that edge. Previously
		# one end was left at the arm's centre point and the other pushed out by
		# half_width, which is the same thing only for a road of zero width: on a
		# real street the bar sat half off-centre and read as a perpendicular
		# stub rather than a stop line.
		var lat := arm.lateral()
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
		# the kerb wraps the corner the cap actually has. Only drawn when both
		# of those sides carry pavement, or a kerb would appear against a road
		# that has none.
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
	var a_mouth := a.point_at(centre, a.trim)
	var b_mouth := b.point_at(centre, b.trim)
	var a_inner := a_mouth + a.lateral() * a.half_width       # a's right edge
	var b_inner := b_mouth - b.lateral() * b.half_width       # b's left edge

	# Sweep the corner as an arc so the pavement turns smoothly rather than
	# forming a spike. Matching the cap's own fillet keeps the two concentric.
	var segments := RoadJunctionSolverScript.FILLET_SEGMENTS
	var inner_pts := _arc_between(a_inner, b_inner, centre, segments)
	if inner_pts.size() < 2:
		return false

	# The outer edge is the inner arc pushed RADIALLY outward from the junction
	# centre. Offsetting along each arm's lateral instead would move the two ends
	# toward each other around the corner, inverting the sweep direction and
	# producing a pavement that wraps the wrong way around the intersection.
	var depth := RoadProfileScript.SIDEWALK_WIDTH
	var outer_pts := PackedVector3Array()
	for p: Vector3 in inner_pts:
		var radial := Vector3(p.x - centre.x, 0.0, p.z - centre.z)
		if radial.length_squared() < 0.000001:
			radial = Vector3(1.0, 0.0, 0.0)
		radial = radial.normalized()
		outer_pts.append(Vector3(
			p.x + radial.x * depth, p.y, p.z + radial.z * depth))

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
