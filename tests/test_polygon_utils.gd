extends SceneTree

## Headless unit tests for PolygonUtils winding-order helpers.
##
## OSM ways are authored clockwise or counter-clockwise arbitrarily, so all
## winding normalization is funneled through PolygonUtils. These tests pin the
## behavior of that shared logic so future refactors can't silently invert
## faces or break the CW/CCW normalization.
##
## Run with:
##   godot --headless --path . --script res://tests/test_polygon_utils.gd
##
## Exits with code 0 when all tests pass, 1 otherwise (CI-friendly).

const PolygonUtils := preload("res://scripts/polygon_utils.gd")

var _failures: int = 0
var _checks: int = 0


func _init() -> void:
	_run_all()
	if _failures == 0:
		print("PASS: all %d checks passed" % _checks)
		quit(0)
	else:
		print("FAIL: %d of %d checks failed" % [_failures, _checks])
		quit(1)


func _run_all() -> void:
	_test_is_polygon_ccw()
	_test_reverse_polygon_preserves_closure()
	_test_reverse_polygon_open()
	_test_normalize_to_ccw_idempotent()
	_test_normalize_to_ccw_flips_cw()
	_test_add_tri_building_convention()
	_test_add_quad_facing_visible_front()
	_test_add_quad_facing_shading_matches_desired()


# ─── Assertion helpers ───────────────────────────────────────────────────────

func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error("CHECK FAILED: %s" % message)
		print("  FAIL: %s" % message)


func _check_vec_dir(actual: Vector3, expected_dir: Vector3, message: String) -> void:
	# Passes when `actual` points in (roughly) the same direction as expected_dir.
	_check(actual.normalized().dot(expected_dir.normalized()) > 0.99, message)


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

func _test_is_polygon_ccw() -> void:
	var ccw := _ccw_square()
	var cw := _cw_square()
	_check(PolygonUtils.is_polygon_ccw(ccw), "is_polygon_ccw(ccw) is true")
	_check(not PolygonUtils.is_polygon_ccw(cw), "is_polygon_ccw(cw) is false")
	# Reversing a polygon must flip its reported orientation.
	_check(
		PolygonUtils.is_polygon_ccw(PolygonUtils.reverse_polygon(cw)),
		"reverse of CW polygon reports CCW"
	)


func _test_reverse_polygon_preserves_closure() -> void:
	var cw := _cw_square()
	var reversed := PolygonUtils.reverse_polygon(cw)
	_check(reversed.size() == cw.size(), "reverse preserves vertex count for closed polygon")
	_check(
		reversed[0].distance_to(reversed[reversed.size() - 1]) < 0.01,
		"reverse keeps the closing duplicate vertex"
	)
	# Reversing twice restores the original winding (still CW).
	var twice := PolygonUtils.reverse_polygon(reversed)
	_check(not PolygonUtils.is_polygon_ccw(twice), "double reverse restores original winding")


func _test_reverse_polygon_open() -> void:
	# An open polyline (no closing duplicate) must not gain one.
	var open_line := PackedVector3Array([
		Vector3(0, 0, 0),
		Vector3(1, 0, 0),
		Vector3(2, 0, 1),
	])
	var reversed := PolygonUtils.reverse_polygon(open_line)
	_check(reversed.size() == open_line.size(), "reverse preserves count for open polyline")
	_check(reversed[0] == open_line[open_line.size() - 1], "open reverse starts at old last vertex")
	_check(reversed[reversed.size() - 1] == open_line[0], "open reverse ends at old first vertex")


func _test_normalize_to_ccw_idempotent() -> void:
	var ccw := _ccw_square()
	var result := PolygonUtils.normalize_to_ccw(ccw)
	_check(PolygonUtils.is_polygon_ccw(result), "normalize_to_ccw(ccw) stays CCW")


func _test_normalize_to_ccw_flips_cw() -> void:
	var cw := PolygonUtils.reverse_polygon(_ccw_square())
	var result := PolygonUtils.normalize_to_ccw(cw)
	_check(PolygonUtils.is_polygon_ccw(result), "normalize_to_ccw(cw) becomes CCW")


func _test_add_tri_building_convention() -> void:
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
	_check(mdt.get_vertex_normal(0).y > 0.0, "add_tri roof normal points upward (+Y)")


func _test_add_quad_facing_visible_front() -> void:
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
				_check(
					mdt.get_face_normal(f).dot(desired) > 0.0,
					"add_quad_facing cull-front faces desired=%s (input winding %s)" % [desired, quad]
				)


func _test_add_quad_facing_shading_matches_desired() -> void:
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
			_check_vec_dir(
				mdt.get_vertex_normal(vi),
				desired,
				"add_quad_facing shading normal matches desired"
			)
