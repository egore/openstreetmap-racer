class_name RoofHipped
extends RefCounted

## Hip-family roofs: hipped, half-hipped, mansard.
##
## Extracted from the former monolithic OSMBuildingBuilder. All methods static.

# ─── Hipped ──────────────────────────────────────────────────────────────────
# Each polygon edge fans to the nearest ridge point. For edges near the hip
# ends, a triangle connects to the ridge endpoint; for side edges, a quad
# connects to the corresponding ridge segment. Per-vertex projection ensures
# correct geometry on arbitrary ngon shapes.

static func hipped(points: PackedVector3Array, base_y: float, roof_h: float,
		roof_color: Color, orientation: String,
		roof_direction: float = -1.0) -> Array[Node3D]:
	var rg := RoofGeometry.compute_ridge_geometry(points, base_y, roof_h, orientation, roof_direction)

	# Inset the ridge so hip ends slope inward
	var proj_span: float = float(rg["max_proj"]) - float(rg["min_proj"])
	var perp_span := absf(float(rg["max_perp"]) - float(rg["min_perp"]))
	var inset := minf(perp_span * 0.5, proj_span * 0.3)

	var centroid: Vector3 = rg["centroid"]
	var ridge_dir: Vector3 = rg["ridge_dir"]
	var ridge_y: float = rg["ridge_y"]
	var min_proj: float = rg["min_proj"]
	var max_proj: float = rg["max_proj"]

	var ridge_start: Vector3 = centroid + ridge_dir * (min_proj + inset)
	ridge_start.y = ridge_y
	var ridge_end: Vector3 = centroid + ridge_dir * (max_proj - inset)
	ridge_end.y = ridge_y

	var st := RoofGeometry.new_st(roof_color)

	# Fan from each edge to nearest ridge point(s), using per-vertex projection
	var rs_proj: float = min_proj + inset
	var re_proj: float = max_proj - inset
	var ridge_span := re_proj - rs_proj
	for i: int in range(points.size() - 1):
		var p0 := Vector3(points[i].x, base_y, points[i].z)
		var p1 := Vector3(points[i + 1].x, base_y, points[i + 1].z)

		# Per-vertex projections onto the ridge direction
		var proj0 := PolygonUtils.project_xz(p0, centroid, ridge_dir)
		var proj1 := PolygonUtils.project_xz(p1, centroid, ridge_dir)

		# Classify each vertex: before ridge start, on ridge segment, or after ridge end
		# For vertices in the hip zone, connect to the nearest ridge endpoint
		# For vertices along the ridge, connect to the corresponding ridge position
		var r0: Vector3 = _hipped_ridge_point(proj0, rs_proj, re_proj, ridge_span, ridge_start, ridge_end)
		var r1: Vector3 = _hipped_ridge_point(proj1, rs_proj, re_proj, ridge_span, ridge_start, ridge_end)

		# If both vertices map to the same ridge point, it's a triangle
		if r0.distance_to(r1) < 0.01:
			RoofGeometry.add_tri(st, p1, p0, r0)
		else:
			RoofGeometry.add_quad(st, p1, p0, r0, r1)

	var result: Array[Node3D] = []
	result.append(RoofGeometry.make_mesh(st, "Roof"))
	return result

## Map a vertex's ridge-direction projection to its ridge point for hipped roofs.
static func _hipped_ridge_point(proj: float, rs_proj: float, re_proj: float,
		ridge_span: float, ridge_start: Vector3, ridge_end: Vector3) -> Vector3:
	if proj <= rs_proj:
		return ridge_start
	elif proj >= re_proj:
		return ridge_end
	else:
		var t := clampf((proj - rs_proj) / maxf(ridge_span, 0.001), 0.0, 1.0)
		return ridge_start.lerp(ridge_end, t)

# ─── Half-hipped ─────────────────────────────────────────────────────────────
# A gabled roof with small hip triangles replacing the top part of each gable
# end. Uses the strip-sliced approach with additional height blending in the
# hip zones near the building ends.

static func half_hipped(points: PackedVector3Array, base_y: float, roof_h: float,
		roof_color: Color, wall_color: Color, orientation: String,
		roof_direction: float = -1.0) -> Array[Node3D]:
	var rg := RoofGeometry.compute_ridge_geometry(points, base_y, roof_h, orientation, roof_direction)
	var ridge_dir: Vector3 = rg["ridge_dir"]
	var perp_dir: Vector3 = rg["perp_dir"]
	var centroid: Vector3 = rg["centroid"]
	var min_perp: float = rg["min_perp"]
	var max_perp: float = rg["max_perp"]
	var perp_span := absf(max_perp - min_perp)
	var perp_mid := (min_perp + max_perp) / 2.0
	var half_span := perp_span / 2.0

	var min_proj: float = rg["min_proj"]
	var max_proj: float = rg["max_proj"]
	var proj_span := max_proj - min_proj

	# Hip inset: how far from the end the ridge starts
	var inset := minf(perp_span * 0.25, proj_span * 0.15)
	var rs_proj := min_proj + inset
	var re_proj := max_proj - inset

	# Strip-slice the polygon along the ridge line (perp x=0.5)
	var break_xs: Array[float] = [0.5]

	var n := points.size()
	var closed := n > 1 and points[0].distance_to(points[n - 1]) < 0.01
	var inner_n := n - 1 if closed else n
	var poly_2d: PackedVector2Array = []
	for idx: int in range(inner_n):
		poly_2d.append(Vector2(points[idx].x, points[idx].z))

	var perp_2d := Vector2(perp_dir.x, perp_dir.z)
	var ridge_2d := Vector2(ridge_dir.x, ridge_dir.z)
	var centroid_2d := Vector2(centroid.x, centroid.z)
	var extend := proj_span + 20.0

	var boundaries: Array[float] = [0.0]
	boundaries.append_array(break_xs)
	boundaries.append(1.0)

	var st_roof := RoofGeometry.new_st(roof_color)
	var st_gable := RoofGeometry.new_st(wall_color)

	# Triangulate each strip with hip-blended heights
	for si: int in range(boundaries.size() - 1):
		var bx0 := boundaries[si]
		var bx1 := boundaries[si + 1]
		var perp0_off := min_perp + bx0 * perp_span
		var perp1_off := min_perp + bx1 * perp_span

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
					var dist_from_centre := absf(perp - perp_mid)
					var t := 1.0 - clampf(dist_from_centre / maxf(half_span, 0.001), 0.0, 1.0)
					var h := base_y + roof_h * t
					# Hip blending near ends
					var proj := (cp.x - centroid.x) * ridge_dir.x + (cp.y - centroid.z) * ridge_dir.z
					if proj < rs_proj:
						var end_t := clampf((proj - min_proj) / maxf(inset, 0.001), 0.0, 1.0)
						h = lerpf(base_y, h, end_t)
					elif proj > re_proj:
						var end_t := clampf((max_proj - proj) / maxf(inset, 0.001), 0.0, 1.0)
						h = lerpf(base_y, h, end_t)
					v.append(Vector3(cp.x, h, cp.y))
				RoofGeometry.add_tri(st_roof, v[0], v[1], v[2])

	# Gable/hip wall patches
	var sub_points := RoofGeometry.subdivide_at_profile_breaks(points, centroid, perp_dir, min_perp, perp_span, break_xs)
	var n_sub := sub_points.size()
	for i: int in range(n_sub - 1):
		var p0 := sub_points[i]
		var p1 := sub_points[i + 1]
		var perp_v0 := PolygonUtils.project_xz(p0, centroid, perp_dir)
		var perp_v1 := PolygonUtils.project_xz(p1, centroid, perp_dir)
		var dist0 := absf(perp_v0 - perp_mid)
		var dist1 := absf(perp_v1 - perp_mid)
		var t0 := 1.0 - clampf(dist0 / maxf(half_span, 0.001), 0.0, 1.0)
		var t1 := 1.0 - clampf(dist1 / maxf(half_span, 0.001), 0.0, 1.0)
		var ry0 := base_y + roof_h * t0
		var ry1 := base_y + roof_h * t1
		# Hip blending
		var proj0 := PolygonUtils.project_xz(p0, centroid, ridge_dir)
		var proj1 := PolygonUtils.project_xz(p1, centroid, ridge_dir)
		if proj0 < rs_proj:
			ry0 = lerpf(base_y, ry0, clampf((proj0 - min_proj) / maxf(inset, 0.001), 0.0, 1.0))
		elif proj0 > re_proj:
			ry0 = lerpf(base_y, ry0, clampf((max_proj - proj0) / maxf(inset, 0.001), 0.0, 1.0))
		if proj1 < rs_proj:
			ry1 = lerpf(base_y, ry1, clampf((proj1 - min_proj) / maxf(inset, 0.001), 0.0, 1.0))
		elif proj1 > re_proj:
			ry1 = lerpf(base_y, ry1, clampf((max_proj - proj1) / maxf(inset, 0.001), 0.0, 1.0))

		if ry0 > base_y + 0.01 or ry1 > base_y + 0.01:
			var bl := Vector3(p0.x, base_y, p0.z)
			var br := Vector3(p1.x, base_y, p1.z)
			var top_r := Vector3(p1.x, ry1, p1.z)
			var tl := Vector3(p0.x, ry0, p0.z)
			if ry0 <= base_y + 0.01:
				RoofGeometry.add_tri(st_gable, bl, top_r, br)
			elif ry1 <= base_y + 0.01:
				RoofGeometry.add_tri(st_gable, bl, tl, br)
			else:
				RoofGeometry.add_tri(st_gable, bl, top_r, br)
				RoofGeometry.add_tri(st_gable, bl, tl, top_r)

	var result: Array[Node3D] = []
	result.append(RoofGeometry.make_mesh(st_roof, "Roof"))
	result.append(RoofGeometry.make_mesh(st_gable, "Gables"))
	return result

# ─── Mansard ─────────────────────────────────────────────────────────────────
# Steep sloped sides with a flat or nearly-flat top. Uses centroid-based inset
# scaling (like UrbanEye3D's MesherMansard) to create the inner polygon, so
# vertex correspondence is correct on any ngon shape. The lower steep faces
# connect outer and inner polygon edges 1:1, then a hipped upper portion sits
# on top.

static func mansard(points: PackedVector3Array, base_y: float, roof_h: float,
		roof_color: Color, _orientation: String) -> Array[Node3D]:
	var centroid := PolygonUtils.polygon_centroid(points)
	var n := points.size() - 1  # exclude closing vertex
	if n < 3:
		return RoofConicProfile.pyramidal(points, base_y, roof_h, roof_color)

	# Inset polygon by scaling toward centroid (like UrbanEye3D).
	# This preserves vertex count and correspondence, unlike Geometry2D.offset_polygon
	# which may change vertex count.
	var inset_frac := 0.3  # scale inner polygon to 70% of outer
	var lower_h := roof_h * 0.5  # lower steep part is half the roof height
	var lower_y := base_y + lower_h
	var top_y := base_y + roof_h

	var inner_points: PackedVector3Array = []
	for i: int in range(n):
		var px := centroid.x + (points[i].x - centroid.x) * (1.0 - inset_frac)
		var pz := centroid.z + (points[i].z - centroid.z) * (1.0 - inset_frac)
		inner_points.append(Vector3(px, 0.0, pz))
	inner_points.append(inner_points[0])  # close polygon

	var st := RoofGeometry.new_st(roof_color)

	# Lower steep side faces: quads connecting outer base edge to inner edge at lower_y
	for i: int in range(n):
		var ni := (i + 1) % n
		var p0 := Vector3(points[i].x, base_y, points[i].z)
		var p1 := Vector3(points[ni].x, base_y, points[ni].z)
		var t0 := Vector3(inner_points[i].x, lower_y, inner_points[i].z)
		var t1 := Vector3(inner_points[ni].x, lower_y, inner_points[ni].z)
		RoofGeometry.add_quad(st, p1, p0, t0, t1)

	# Upper portion: pyramidal from inner polygon to apex
	var apex := Vector3(centroid.x, top_y, centroid.z)
	for i: int in range(n):
		var ni := (i + 1) % n
		var t0 := Vector3(inner_points[i].x, lower_y, inner_points[i].z)
		var t1 := Vector3(inner_points[ni].x, lower_y, inner_points[ni].z)
		RoofGeometry.add_tri(st, t1, t0, apex)

	var result: Array[Node3D] = []
	result.append(RoofGeometry.make_mesh(st, "Roof"))
	return result
