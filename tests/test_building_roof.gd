extends GdUnitTestSuite

## Unit tests for building=roof handling in OSMBuildingBuilder.
##
## building=roof is an open structure (canopy/porch/petrol-station roof): a roof
## held up by thin supports, NOT a solid enclosed block. See
## https://wiki.openstreetmap.org/wiki/Tag:building%3Droof
##
## These tests pin:
##   1. A building=roof produces support posts + a roof, but NO enclosing walls.
##   2. A regular building (building=yes) still produces walls.
##   3. building:part=roof is a real roof part and still gets walls (it is part
##      of a larger building, not an open canopy).

const OSMBuildingBuilder := preload("res://scripts/osm_building_builder.gd")


# ─── Fixtures ────────────────────────────────────────────────────────────────

## A simple square footprint (closed ring), 10m x 10m, flat on the ground.
func _square() -> PackedVector3Array:
	return PackedVector3Array([
		Vector3(0.0, 0.0, 0.0),
		Vector3(10.0, 0.0, 0.0),
		Vector3(10.0, 0.0, 10.0),
		Vector3(0.0, 0.0, 10.0),
		Vector3(0.0, 0.0, 0.0),
	])


## Count direct children whose name starts with the given prefix.
func _count_named(root: Node3D, prefix: String) -> int:
	var n := 0
	for child in root.get_children():
		if (child as Node).name.begins_with(prefix):
			n += 1
	return n


## Gather the flat triangle-soup vertices of every child mesh whose name starts
## with the given prefix. Returns a PackedVector3Array of 3*N vertices.
func _mesh_faces_named(root: Node3D, prefix: String) -> PackedVector3Array:
	var faces: PackedVector3Array = []
	for child in root.get_children():
		if not (child as Node).name.begins_with(prefix):
			continue
		var mi := child as MeshInstance3D
		if mi == null or mi.mesh == null:
			continue
		faces.append_array(mi.mesh.get_faces())
	return faces


## Count how many side triangles face OUTWARD vs INWARD relative to the roof's
## vertical centroid axis. A face is "inward" when Godot's culling front normal
## (Plane(a,b,c).normal == (c-a).cross(b-a)) points toward the centroid axis in
## XZ — such a face is backface-culled from outside and only visible from within.
## Near-horizontal faces (top/bottom slabs) are ignored via a horizontal-normal
## threshold, since their winding does not cause the "only visible inside" bug.
func _side_face_orientation(faces: PackedVector3Array, centroid: Vector3) -> Dictionary:
	var outward := 0
	var inward := 0
	for ti in range(0, faces.size(), 3):
		var a := faces[ti]
		var b := faces[ti + 1]
		var c := faces[ti + 2]
		# Godot culling front normal.
		var front := (c - a).cross(b - a)
		var horiz := Vector3(front.x, 0.0, front.z)
		if horiz.length() < 0.01:
			continue  # near-horizontal face: not a "side", skip
		var tri_centroid := (a + b + c) / 3.0
		var outdir := Vector3(tri_centroid.x - centroid.x, 0.0, tri_centroid.z - centroid.z)
		if outdir.length() < 0.01:
			continue
		if horiz.normalized().dot(outdir.normalized()) >= 0.0:
			outward += 1
		else:
			inward += 1
	return {"outward": outward, "inward": inward}


# ─── Tests ───────────────────────────────────────────────────────────────────

func test_open_roof_has_no_walls() -> void:
	var builder := OSMBuildingBuilder.new()
	var tags := {"building": "roof", "height": "5"}
	var root := builder.build_building_from_polygon(_square(), tags, 1) as Node3D
	assert_object(root).override_failure_message("building=roof builds a node").is_not_null()
	if root == null:
		return
	assert_int(_count_named(root, "Walls")) \
		.override_failure_message("building=roof has NO walls").is_equal(0)
	assert_int(_count_named(root, "Support")) \
		.override_failure_message("building=roof has support posts (one per footprint corner)") \
		.is_greater_equal(3)
	assert_int(_count_named(root, "Roof")) \
		.override_failure_message("building=roof has a roof").is_greater_equal(1)
	root.free()


func test_regular_building_has_walls() -> void:
	var builder := OSMBuildingBuilder.new()
	var tags := {"building": "yes", "height": "5"}
	var root := builder.build_building_from_polygon(_square(), tags, 2) as Node3D
	assert_object(root).override_failure_message("building=yes builds a node").is_not_null()
	if root == null:
		return
	assert_int(_count_named(root, "Walls")) \
		.override_failure_message("building=yes has walls").is_greater_equal(1)
	assert_int(_count_named(root, "Support")) \
		.override_failure_message("building=yes has no support posts").is_equal(0)
	root.free()


func test_building_part_roof_has_walls() -> void:
	# building:part=roof is part of a larger building, not an open canopy, so it
	# must still extrude walls like a normal building part.
	var builder := OSMBuildingBuilder.new()
	var tags := {"building:part": "roof", "height": "5", "roof:shape": "flat"}
	var root := builder.build_building_from_polygon(_square(), tags, 3) as Node3D
	assert_object(root).override_failure_message("building:part=roof builds a node").is_not_null()
	if root == null:
		return
	assert_int(_count_named(root, "Walls")) \
		.override_failure_message("building:part=roof still has walls").is_greater_equal(1)
	assert_int(_count_named(root, "Support")) \
		.override_failure_message("building:part=roof has no support posts").is_equal(0)
	root.free()


## Regression: conic-profile roof sides (pyramidal, dome, onion) must face
## OUTWARD. They were previously wound backwards, so their culling front faces
## pointed inward — the sides were backface-culled and only visible from inside.
func _assert_roof_sides_face_outward(roof_shape: String) -> void:
	var builder := OSMBuildingBuilder.new()
	var tags := {"building": "yes", "height": "5", "roof:shape": roof_shape, "roof:height": "4"}
	var root := builder.build_building_from_polygon(_square(), tags, 10) as Node3D
	assert_object(root) \
		.override_failure_message("%s roof builds a node" % roof_shape).is_not_null()
	if root == null:
		return
	var faces := _mesh_faces_named(root, "Roof")
	assert_int(faces.size()) \
		.override_failure_message("%s roof has geometry" % roof_shape).is_greater(0)
	# Footprint centroid is (5, *, 5) for the 10x10 square.
	var counts := _side_face_orientation(faces, Vector3(5.0, 0.0, 5.0))
	assert_int(counts["inward"]) \
		.override_failure_message(
			"%s roof sides must face outward (found %d inward, %d outward)"
			% [roof_shape, counts["inward"], counts["outward"]]) \
		.is_equal(0)
	assert_int(counts["outward"]) \
		.override_failure_message("%s roof has outward-facing sides" % roof_shape) \
		.is_greater(0)
	root.free()


func test_pyramidal_roof_sides_face_outward() -> void:
	_assert_roof_sides_face_outward("pyramidal")


func test_dome_roof_sides_face_outward() -> void:
	_assert_roof_sides_face_outward("dome")


func test_onion_roof_sides_face_outward() -> void:
	_assert_roof_sides_face_outward("onion")


## Regression: the open-roof (building=roof) slab is a solid disc with side
## faces around its perimeter. Those side quads were wound backwards, so their
## culling front faces pointed inward — the slab edges were only visible from
## underneath the roof, not from outside.
func test_open_roof_slab_sides_face_outward() -> void:
	var builder := OSMBuildingBuilder.new()
	var tags := {"building": "roof", "height": "5"}
	var root := builder.build_building_from_polygon(_square(), tags, 11) as Node3D
	assert_object(root) \
		.override_failure_message("building=roof builds a node").is_not_null()
	if root == null:
		return
	var faces := _mesh_faces_named(root, "Roof")
	assert_int(faces.size()) \
		.override_failure_message("open roof slab has geometry").is_greater(0)
	# Footprint centroid is (5, *, 5) for the 10x10 square.
	var counts := _side_face_orientation(faces, Vector3(5.0, 0.0, 5.0))
	assert_int(counts["inward"]) \
		.override_failure_message(
			"open roof slab sides must face outward (found %d inward, %d outward)"
			% [counts["inward"], counts["outward"]]) \
		.is_equal(0)
	assert_int(counts["outward"]) \
		.override_failure_message("open roof slab has outward-facing sides") \
		.is_greater(0)
	root.free()


func test_open_roof_floats_above_ground() -> void:
	# The roof slab should sit near the top of the structure (its underside well
	# above the ground), not span the whole height like a solid block.
	var builder := OSMBuildingBuilder.new()
	var tags := {"building": "roof", "height": "6"}
	var root := builder.build_building_from_polygon(_square(), tags, 4) as Node3D
	assert_object(root) \
		.override_failure_message("building=roof builds a node (float test)").is_not_null()
	if root == null:
		return
	# Find the Roof node's vertical extent specifically.
	var lo := INF
	var hi := -INF
	for child in root.get_children():
		if not (child as Node).name.begins_with("Roof"):
			continue
		var mi := child as MeshInstance3D
		if mi == null or mi.mesh == null:
			continue
		for v in mi.mesh.get_faces():
			lo = minf(lo, v.y)
			hi = maxf(hi, v.y)
	assert_float(lo) \
		.override_failure_message("roof underside floats above ground (got y=%.2f)" % lo) \
		.is_greater(1.0)
	assert_float(hi) \
		.override_failure_message("roof top does not exceed building height (got y=%.2f)" % hi) \
		.is_less_equal(6.01)
	root.free()
