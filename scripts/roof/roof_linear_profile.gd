class_name RoofLinearProfile
extends RefCounted

## Linear-profile roof family: gabled, gambrel, round, saltbox.
##
## A profile is an array of Vector2(x, y) where x goes from 0.0 to 1.0 across the
## building width (perpendicular to the ridge) and y is the height fraction
## (0.0 = eave, 1.0 = peak). The building polygon is sliced into strips at each
## profile breakpoint (e.g. the ridge for a gabled roof) using
## Geometry2D.intersect_polygons; each strip is triangulated independently so no
## triangle ever crosses a breakpoint line. This prevents the "collapsed ridge"
## artefact that plain 2D triangulation produces on L-shaped / concave buildings.
##
## Extracted from the former monolithic OSMBuildingBuilder. All methods static.

# ─── Gabled ──────────────────────────────────────────────────────────────────
# V-shaped profile [0:0, 0.5:1, 1:0]; the profile system handles edge
# subdivision at the ridge breakpoint so rectangular buildings get a proper peak.

static func gabled(points: PackedVector3Array, base_y: float, roof_h: float,
		roof_color: Color, wall_color: Color, orientation: String,
		roof_direction: float = -1.0) -> Array[Node3D]:
	return build(points, base_y, roof_h, roof_color, wall_color,
		orientation, roof_direction,
		[Vector2(0.0, 0.0), Vector2(0.5, 1.0), Vector2(1.0, 0.0)])

# ─── Gambrel ─────────────────────────────────────────────────────────────────
# Steep lower slope, shallow upper. Profile from UrbanEye3D's LinearProfiles:
# {0.0:0.0, 0.25:0.75, 0.5:1.0, 0.75:0.75, 1.0:0.0}

static func gambrel(points: PackedVector3Array, base_y: float, roof_h: float,
		roof_color: Color, wall_color: Color, orientation: String,
		roof_direction: float = -1.0) -> Array[Node3D]:
	return build(points, base_y, roof_h, roof_color, wall_color,
		orientation, roof_direction,
		[Vector2(0.0, 0.0), Vector2(0.25, 0.75), Vector2(0.5, 1.0), Vector2(0.75, 0.75), Vector2(1.0, 0.0)])

# ─── Round ───────────────────────────────────────────────────────────────────
# Semicircular profile (sampled at 16 segments + endpoints).

static func round_roof(points: PackedVector3Array, base_y: float, roof_h: float,
		roof_color: Color, orientation: String,
		roof_direction: float = -1.0) -> Array[Node3D]:
	var profile: Array[Vector2] = _make_round_profile(16)
	return build(points, base_y, roof_h, roof_color, roof_color,
		orientation, roof_direction, profile)

## Round (semicircular) profile: sin arc from 0 to PI mapped to [0,1] range.
static func _make_round_profile(segments: int) -> Array[Vector2]:
	var profile: Array[Vector2] = []
	for i: int in range(segments + 1):
		var t := float(i) / segments
		var angle := t * PI
		# x position across the width [0,1], height follows sin curve
		profile.append(Vector2(t, sin(angle)))
	return profile

# ─── Saltbox ─────────────────────────────────────────────────────────────────
# Asymmetric profile with the ridge at 1/3. From UrbanEye3D's LinearProfiles.SALTBOX.

static func saltbox(points: PackedVector3Array, base_y: float, roof_h: float,
		roof_color: Color, wall_color: Color, orientation: String,
		roof_direction: float = -1.0) -> Array[Node3D]:
	return build(points, base_y, roof_h, roof_color, wall_color,
		orientation, roof_direction,
		[Vector2(0.0, 0.0), Vector2(0.3333, 1.0), Vector2(1.0, 0.0)])

# ─── Shared linear-profile builder ───────────────────────────────────────────

## Build a roof by sweeping `profile` perpendicular to the ridge, strip-slicing
## the polygon at each interior breakpoint. Returns ["Roof", "Gables"] meshes.
static func build(points: PackedVector3Array, base_y: float, roof_h: float,
		roof_color: Color, wall_color: Color, orientation: String,
		roof_direction: float, profile: Array[Vector2]) -> Array[Node3D]:
	var rg := RoofGeometry.compute_ridge_geometry(points, base_y, roof_h, orientation, roof_direction)
	var perp_dir: Vector3 = rg["perp_dir"]
	var centroid: Vector3 = rg["centroid"]
	var min_perp: float = rg["min_perp"]
	var max_perp: float = rg["max_perp"]
	var perp_span := absf(max_perp - min_perp)
	var min_proj: float = rg["min_proj"]
	var max_proj: float = rg["max_proj"]
	var proj_span := max_proj - min_proj

	# Collect the interior profile breakpoint x-values (excluding 0 and 1)
	var break_xs: Array[float] = []
	for bp: Vector2 in profile:
		if bp.x > 0.001 and bp.x < 0.999:
			break_xs.append(bp.x)
	break_xs.sort()

	# Build the list of strip boundaries: [0.0, break1, break2, ..., 1.0]
	var boundaries: Array[float] = [0.0]
	boundaries.append_array(break_xs)
	boundaries.append(1.0)

	# Convert polygon to 2D (XZ → XY) for clipping, stripping closing vertex
	var n := points.size()
	var closed := n > 1 and points[0].distance_to(points[n - 1]) < 0.01
	var inner_n := n - 1 if closed else n
	var poly_2d: PackedVector2Array = []
	for idx: int in range(inner_n):
		poly_2d.append(Vector2(points[idx].x, points[idx].z))

	# 2D axes for building the clip rectangles
	var perp_2d := Vector2(perp_dir.x, perp_dir.z)
	var ridge_dir: Vector3 = rg["ridge_dir"]
	var ridge_2d := Vector2(ridge_dir.x, ridge_dir.z)
	var centroid_2d := Vector2(centroid.x, centroid.z)
	# Extend clip rectangles well past the building along the ridge
	var extend := proj_span + 20.0

	var st_roof := RoofGeometry.new_st(roof_color)
	var st_gable := RoofGeometry.new_st(wall_color)

	# For each strip between adjacent profile breakpoints, clip the polygon
	# to that strip, then triangulate the clipped region.
	for si: int in range(boundaries.size() - 1):
		var bx0 := boundaries[si]
		var bx1 := boundaries[si + 1]

		# The strip runs between two lines at perp positions bx0 and bx1.
		# Convert to world-space offsets from centroid.
		var perp0_off := min_perp + bx0 * perp_span  # offset from centroid along perp_dir
		var perp1_off := min_perp + bx1 * perp_span

		# Build clip rectangle: a wide band along the ridge direction
		# between the two perp lines. Corners at:
		#   centroid + perp_dir * perp_off ± ridge_dir * extend
		var c0 := centroid_2d + perp_2d * perp0_off - ridge_2d * extend
		var c1 := centroid_2d + perp_2d * perp0_off + ridge_2d * extend
		var c2 := centroid_2d + perp_2d * perp1_off + ridge_2d * extend
		var c3 := centroid_2d + perp_2d * perp1_off - ridge_2d * extend
		var clip_rect := PackedVector2Array([c0, c1, c2, c3])

		var clips := Geometry2D.intersect_polygons(poly_2d, clip_rect)
		for clip: PackedVector2Array in clips:
			var tri_indices := Geometry2D.triangulate_polygon(clip)
			if tri_indices.is_empty():
				continue
			for ti: int in range(0, tri_indices.size(), 3):
				var v: Array[Vector3] = []
				for vi: int in range(3):
					var cp := clip[tri_indices[ti + vi]]
					var perp := (cp.x - centroid.x) * perp_dir.x + (cp.y - centroid.z) * perp_dir.z
					var px := clampf((perp - min_perp) / maxf(perp_span, 0.001), 0.0, 1.0)
					var h_frac := RoofGeometry.sample_profile(profile, px)
					v.append(Vector3(cp.x, base_y + roof_h * h_frac, cp.y))
				RoofGeometry.add_tri(st_roof, v[0], v[1], v[2])

	# Gable wall patches: use the subdivided polygon for edge-by-edge patches.
	var sub_points := RoofGeometry.subdivide_at_profile_breaks(points, centroid, perp_dir, min_perp, perp_span, break_xs)
	var n_sub := sub_points.size()
	for i: int in range(n_sub - 1):
		var p0 := sub_points[i]
		var p1 := sub_points[i + 1]
		var perp_v0 := PolygonUtils.project_xz(p0, centroid, perp_dir)
		var perp_v1 := PolygonUtils.project_xz(p1, centroid, perp_dir)
		var px0 := clampf((perp_v0 - min_perp) / maxf(perp_span, 0.001), 0.0, 1.0)
		var px1 := clampf((perp_v1 - min_perp) / maxf(perp_span, 0.001), 0.0, 1.0)
		var ry0 := base_y + roof_h * RoofGeometry.sample_profile(profile, px0)
		var ry1 := base_y + roof_h * RoofGeometry.sample_profile(profile, px1)

		if ry0 > base_y + 0.01 or ry1 > base_y + 0.01:
			var bl := Vector3(p0.x, base_y, p0.z)
			var br := Vector3(p1.x, base_y, p1.z)
			var tr := Vector3(p1.x, ry1, p1.z)
			var tl := Vector3(p0.x, ry0, p0.z)
			if ry0 <= base_y + 0.01:
				RoofGeometry.add_tri(st_gable, bl, tr, br)
			elif ry1 <= base_y + 0.01:
				RoofGeometry.add_tri(st_gable, bl, tl, br)
			else:
				RoofGeometry.add_tri(st_gable, bl, tr, br)
				RoofGeometry.add_tri(st_gable, bl, tl, tr)

	var result: Array[Node3D] = []
	result.append(RoofGeometry.make_mesh(st_roof, "Roof"))
	result.append(RoofGeometry.make_mesh(st_gable, "Gables"))
	return result
