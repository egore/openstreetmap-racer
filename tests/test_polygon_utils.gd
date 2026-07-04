extends GdUnitTestSuite

## Unit tests for PolygonUtils winding-order helpers.
##
## OSM ways are authored clockwise or counter-clockwise arbitrarily, so all
## winding normalization is funneled through PolygonUtils. These tests pin the
## behavior of that shared logic so future refactors can't silently invert
## faces or break the CW/CCW normalization.

const PolygonUtils := preload("res://scripts/polygon_utils.gd")


# ─── Fixtures ────────────────────────────────────────────────────────────────

func _cw_square() -> PackedVector3Array:
	# A closed unit square in the XZ plane wound so that is_polygon_ccw() reports
	# false. (is_polygon_ccw uses the shoelace convention signed_area < 0 == CCW;
	# for this vertex order in XZ that evaluates to CW.) Its reverse is CCW.
	return PackedVector3Array([
		Vector3(0, 0, 0),
		Vector3(1, 0, 0),
		Vector3(1, 0, 1),
		Vector3(0, 0, 1),
		Vector3(0, 0, 0),
	])


func _ccw_square() -> PackedVector3Array:
	return PolygonUtils.reverse_polygon(_cw_square())


func _commit_quad(a: Vector3, b: Vector3, c: Vector3, d: Vector3, desired: Vector3) -> MeshDataTool:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	PolygonUtils.add_quad_facing(st, a, b, c, d, desired)
	var mesh := st.commit()
	var mdt := MeshDataTool.new()
	mdt.create_from_surface(mesh, 0)
	return mdt


# ─── Tests ───────────────────────────────────────────────────────────────────

func test_is_polygon_ccw() -> void:
	var ccw := _ccw_square()
	var cw := _cw_square()
	assert_bool(PolygonUtils.is_polygon_ccw(ccw)) \
		.override_failure_message("is_polygon_ccw(ccw) is true").is_true()
	assert_bool(PolygonUtils.is_polygon_ccw(cw)) \
		.override_failure_message("is_polygon_ccw(cw) is false").is_false()
	# Reversing a polygon must flip its reported orientation.
	assert_bool(PolygonUtils.is_polygon_ccw(PolygonUtils.reverse_polygon(cw))) \
		.override_failure_message("reverse of CW polygon reports CCW").is_true()


func test_reverse_polygon_preserves_closure() -> void:
	var cw := _cw_square()
	var reversed := PolygonUtils.reverse_polygon(cw)
	assert_int(reversed.size()) \
		.override_failure_message("reverse preserves vertex count for closed polygon") \
		.is_equal(cw.size())
	assert_bool(reversed[0].distance_to(reversed[reversed.size() - 1]) < 0.01) \
		.override_failure_message("reverse keeps the closing duplicate vertex").is_true()
	# Reversing twice restores the original winding (still CW).
	var twice := PolygonUtils.reverse_polygon(reversed)
	assert_bool(PolygonUtils.is_polygon_ccw(twice)) \
		.override_failure_message("double reverse restores original winding").is_false()


func test_reverse_polygon_open() -> void:
	# An open polyline (no closing duplicate) must not gain one.
	var open_line := PackedVector3Array([
		Vector3(0, 0, 0),
		Vector3(1, 0, 0),
		Vector3(2, 0, 1),
	])
	var reversed := PolygonUtils.reverse_polygon(open_line)
	assert_int(reversed.size()) \
		.override_failure_message("reverse preserves count for open polyline") \
		.is_equal(open_line.size())
	assert_vector(reversed[0]) \
		.override_failure_message("open reverse starts at old last vertex") \
		.is_equal(open_line[open_line.size() - 1])
	assert_vector(reversed[reversed.size() - 1]) \
		.override_failure_message("open reverse ends at old first vertex") \
		.is_equal(open_line[0])


func test_normalize_to_ccw_idempotent() -> void:
	var ccw := _ccw_square()
	var result := PolygonUtils.normalize_to_ccw(ccw)
	assert_bool(PolygonUtils.is_polygon_ccw(result)) \
		.override_failure_message("normalize_to_ccw(ccw) stays CCW").is_true()


func test_normalize_to_ccw_flips_cw() -> void:
	var cw := PolygonUtils.reverse_polygon(_ccw_square())
	var result := PolygonUtils.normalize_to_ccw(cw)
	assert_bool(PolygonUtils.is_polygon_ccw(result)) \
		.override_failure_message("normalize_to_ccw(cw) becomes CCW").is_true()


func test_add_tri_building_convention() -> void:
	# The building builder authors roof triangles assuming add_tri's shading
	# normal is (b - a) x (c - a). A roof apex triangle built with the call
	# pattern _add_tri(st, p1, p0, apex) must yield an upward-facing normal.
	var p0 := Vector3(0, 0, 0)
	var p1 := Vector3(2, 0, 0)
	var apex := Vector3(1, 3, 1)
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	PolygonUtils.add_tri(st, p1, p0, apex)
	var mesh := st.commit()
	var mdt := MeshDataTool.new()
	mdt.create_from_surface(mesh, 0)
	assert_float(mdt.get_vertex_normal(0).y) \
		.override_failure_message("add_tri roof normal points upward (+Y)").is_greater(0.0)


func test_add_quad_facing_visible_front() -> void:
	# The visible (non-culled) front face must point along desired_normal for
	# BOTH input windings. get_face_normal() uses Godot's winding/culling
	# convention, which is what determines visibility.
	var a := Vector3(0, 0, 0)
	var b := Vector3(1, 0, 0)
	var c := Vector3(1, 1, 0)
	var d := Vector3(0, 1, 0)
	var windings := [[a, b, c, d], [a, d, c, b]]  # CCW and CW input
	var desired_normals := [Vector3(0, 0, 1), Vector3(0, 0, -1)]
	for desired: Vector3 in desired_normals:
		for quad: Array in windings:
			var mdt := _commit_quad(quad[0], quad[1], quad[2], quad[3], desired)
			for f: int in range(mdt.get_face_count()):
				assert_float(mdt.get_face_normal(f).dot(desired)) \
					.override_failure_message(
						"add_quad_facing cull-front faces desired=%s (input winding %s)" % [desired, quad]) \
					.is_greater(0.0)


func test_add_quad_facing_shading_matches_desired() -> void:
	# Shading normals must match the requested facing direction so lighting and
	# culling agree (no inside-out lit faces).
	var a := Vector3(0, 0, 0)
	var b := Vector3(1, 0, 0)
	var c := Vector3(1, 1, 0)
	var d := Vector3(0, 1, 0)
	var desired := Vector3(0, 0, 1)
	var mdt := _commit_quad(a, b, c, d, desired)
	for f: int in range(mdt.get_face_count()):
		for i: int in range(3):
			var vi := mdt.get_face_vertex(f, i)
			# Passes when the shading normal points roughly along desired.
			assert_float(mdt.get_vertex_normal(vi).normalized().dot(desired.normalized())) \
				.override_failure_message("add_quad_facing shading normal matches desired") \
				.is_greater(0.99)


# ─── clip_polyline_to_rect (per-tile ribbon clipping) ────────────────────────
#
# A way spanning many tiles is present in every tile's bucket; without clipping,
# build_road rebuilds the whole (subdivided, draped) ribbon per tile (~107 ms on
# a long primary road). clip_polyline_to_rect trims the centreline to the tile so
# only the in-tile portion is built. These pin the clip's correctness.

func test_clip_polyline_fully_inside_is_unchanged() -> void:
	# A polyline wholly within the rect returns one part with the same points.
	var pts := PackedVector3Array([Vector3(10, 0, 10), Vector3(20, 0, 20), Vector3(30, 0, 15)])
	var parts := PolygonUtils.clip_polyline_to_rect(pts, [0.0, 100.0, 0.0, 100.0], 0.0)
	assert_int(parts.size()).override_failure_message("one part when fully inside").is_equal(1)
	var part: PackedVector3Array = parts[0]
	assert_int(part.size()).override_failure_message("all points kept").is_equal(3)


func test_clip_polyline_fully_outside_is_empty() -> void:
	# A polyline entirely outside the rect yields no parts.
	var pts := PackedVector3Array([Vector3(500, 0, 500), Vector3(600, 0, 600)])
	var parts := PolygonUtils.clip_polyline_to_rect(pts, [0.0, 100.0, 0.0, 100.0], 0.0)
	assert_int(parts.size()).override_failure_message("nothing inside the rect").is_equal(0)


func test_clip_polyline_crossing_boundary_is_trimmed() -> void:
	# A straight line from inside to far outside is trimmed at the rect edge, so
	# the clipped part's endpoint lies on (or within) the boundary.
	var pts := PackedVector3Array([Vector3(50, 0, 50), Vector3(250, 0, 50)])
	var parts := PolygonUtils.clip_polyline_to_rect(pts, [0.0, 100.0, 0.0, 100.0], 0.0)
	assert_int(parts.size()).override_failure_message("one clipped part").is_equal(1)
	var part: PackedVector3Array = parts[0]
	# Enters at x=50 (inside), exits where it crosses x=100.
	assert_float(part[0].x).override_failure_message("start kept inside").is_equal_approx(50.0, 0.01)
	assert_float(part[part.size() - 1].x).override_failure_message("clipped at x=100 boundary").is_equal_approx(100.0, 0.01)


func test_clip_polyline_reentering_yields_two_parts() -> void:
	# A polyline that dips out of the rect and comes back produces two separate
	# in-tile runs (so the ribbon isn't bridged across the gap).
	var pts := PackedVector3Array([
		Vector3(50, 0, 50),    # inside
		Vector3(50, 0, 250),   # outside (below)
		Vector3(80, 0, 250),   # outside
		Vector3(80, 0, 50),    # inside again
	])
	var parts := PolygonUtils.clip_polyline_to_rect(pts, [0.0, 100.0, 0.0, 100.0], 0.0)
	assert_int(parts.size()).override_failure_message("two separate in-tile runs").is_equal(2)


func test_clip_polyline_margin_extends_bounds() -> void:
	# The margin expands the rect, so a point just outside the raw rect but within
	# the margin is retained — this is what overlaps adjacent tiles' ribbons so
	# there's no seam gap.
	var pts := PackedVector3Array([Vector3(50, 0, 50), Vector3(102, 0, 50)])
	# Without margin the end is clipped at 100; with a 5 m margin it survives to 102.
	var parts := PolygonUtils.clip_polyline_to_rect(pts, [0.0, 100.0, 0.0, 100.0], 5.0)
	assert_int(parts.size()).is_equal(1)
	var part: PackedVector3Array = parts[0]
	assert_float(part[part.size() - 1].x).override_failure_message("margin keeps point past raw edge").is_equal_approx(102.0, 0.01)


# ─── Ground layer ordering (z-fighting fix) ──────────────────────────────────

func _square(size: float) -> PackedVector3Array:
	# Closed axis-aligned square of side `size` in the XZ plane, area == size².
	return PackedVector3Array([
		Vector3(0, 0, 0),
		Vector3(size, 0, 0),
		Vector3(size, 0, size),
		Vector3(0, 0, size),
		Vector3(0, 0, 0),
	])


func test_polygon_area_xz_matches_side_squared() -> void:
	# Shoelace area of a 10x10 closed square is 100, winding-agnostic.
	assert_float(PolygonUtils.polygon_area_xz(_square(10.0))) \
		.override_failure_message("10x10 square area is 100").is_equal_approx(100.0, 0.001)
	# Reversed winding must give the same (absolute) area.
	assert_float(PolygonUtils.polygon_area_xz(PolygonUtils.reverse_polygon(_square(10.0)))) \
		.override_failure_message("area is winding-agnostic").is_equal_approx(100.0, 0.001)
	# Degenerate (<3 pts) is zero, not a crash.
	assert_float(PolygonUtils.polygon_area_xz(PackedVector3Array([Vector3.ZERO, Vector3.ONE]))) \
		.override_failure_message("degenerate polygon area is 0").is_equal(0.0)


func test_ground_base_priority_follows_layer_stack() -> void:
	# Water paints above dry landcover; parking above water; landcover lowest.
	var grass := PolygonUtils.ground_base_priority({"landuse": "grass"})
	var water := PolygonUtils.ground_base_priority({"natural": "water"})
	var parking := PolygonUtils.ground_base_priority({"amenity": "parking"})
	assert_int(water).override_failure_message("water paints above grass").is_greater(grass)
	assert_int(parking).override_failure_message("parking paints above water").is_greater(water)


func test_ground_base_priority_wildcard_and_default() -> void:
	# playground=* wildcard resolves; an untabled closed ring falls back to default.
	assert_int(PolygonUtils.ground_base_priority({"playground": "sandpit"})) \
		.override_failure_message("playground wildcard resolves") \
		.is_equal(PolygonUtils.GROUND_LAYER_PRIORITY["playground=*"])
	assert_int(PolygonUtils.ground_base_priority({"shop": "supermarket"})) \
		.override_failure_message("untabled area falls back to default") \
		.is_equal(PolygonUtils.DEFAULT_GROUND_PRIORITY)


func test_smaller_patch_wins_within_same_class() -> void:
	# Two grass polygons of the same class: the SMALLER one must get a strictly
	# higher render_priority so it paints last and wins (the requested behaviour).
	var tags := {"landuse": "grass"}
	var big := PolygonUtils.ground_render_priority(tags, 40000.0)   # ref area ⇒ ~no bonus
	var small := PolygonUtils.ground_render_priority(tags, 25.0)    # tiny patch ⇒ big bonus
	assert_float(small).override_failure_message("smaller grass patch paints on top").is_greater(big)


func test_class_order_dominates_area_tiebreak() -> void:
	# A big water polygon must still paint above a tiny grass patch — the class
	# layer order dominates; the area tiebreak (< 1 rank) can't cross classes.
	var big_water := PolygonUtils.ground_render_priority({"natural": "water"}, 1000000.0)
	var tiny_grass := PolygonUtils.ground_render_priority({"landuse": "grass"}, 1.0)
	assert_float(big_water).override_failure_message("water class beats grass regardless of size").is_greater(tiny_grass)


func test_ground_tiebreak_bonus_bounds() -> void:
	# Bonus is within [0, span): huge area ⇒ ~0, tiny/degenerate ⇒ full span.
	assert_float(PolygonUtils.ground_tiebreak_bonus(1e9)) \
		.override_failure_message("huge area gets no bonus").is_equal_approx(0.0, 0.001)
	assert_float(PolygonUtils.ground_tiebreak_bonus(0.0)) \
		.override_failure_message("degenerate area gets full span") \
		.is_equal_approx(PolygonUtils._GROUND_TIEBREAK_SPAN, 0.001)


func test_flat_polygon_mesh_disables_depth_write_when_layered() -> void:
	# Passing a real ground priority must produce a material that drops depth-write
	# (so coplanar patches are ordered by paint order, not z-fighting) and carries
	# that priority. Without it (roof path) depth-write stays on.
	var layered := PolygonUtils.build_flat_polygon_mesh(_square(10.0), Color.WHITE, 0.01, false, -30)
	assert_object(layered).is_not_null()
	var lmat := layered.mesh.surface_get_material(0) as BaseMaterial3D
	assert_int(lmat.depth_draw_mode) \
		.override_failure_message("layered ground disables depth write") \
		.is_equal(BaseMaterial3D.DEPTH_DRAW_DISABLED)
	assert_int(lmat.render_priority).override_failure_message("render_priority applied").is_equal(-30)

	var roof := PolygonUtils.build_flat_polygon_mesh(_square(10.0), Color.WHITE, 0.01, false)
	var rmat := roof.mesh.surface_get_material(0) as BaseMaterial3D
	assert_int(rmat.depth_draw_mode) \
		.override_failure_message("non-ground caller keeps default depth draw") \
		.is_not_equal(BaseMaterial3D.DEPTH_DRAW_DISABLED)
