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
