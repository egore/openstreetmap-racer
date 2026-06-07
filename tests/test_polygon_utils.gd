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
