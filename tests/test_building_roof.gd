extends SceneTree

## Headless unit tests for building=roof handling in OSMBuildingBuilder.
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
##
## Run with:
##   godot --headless --path . --script res://tests/test_building_roof.gd

const OSMBuildingBuilder := preload("res://scripts/osm_building_builder.gd")

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
	_test_open_roof_has_no_walls()
	_test_regular_building_has_walls()
	_test_building_part_roof_has_walls()
	_test_open_roof_floats_above_ground()


# ─── Assertion helpers ───────────────────────────────────────────────────────

func _check(condition: bool, message: String) -> void:
	_checks += 1
	if not condition:
		_failures += 1
		push_error("CHECK FAILED: %s" % message)
		print("  FAIL: %s" % message)


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


## Find the lowest and highest Y vertex across all MeshInstance3D descendants.
func _vertical_extent(root: Node3D) -> Vector2:
	var lo := INF
	var hi := -INF
	for child in root.get_children():
		var mi := child as MeshInstance3D
		if mi == null or mi.mesh == null:
			continue
		var faces := mi.mesh.get_faces()
		for v in faces:
			lo = minf(lo, v.y)
			hi = maxf(hi, v.y)
	return Vector2(lo, hi)


# ─── Tests ───────────────────────────────────────────────────────────────────

func _test_open_roof_has_no_walls() -> void:
	var builder := OSMBuildingBuilder.new()
	var tags := {"building": "roof", "height": "5"}
	var root := builder.build_building_from_polygon(_square(), tags, 1) as Node3D
	_check(root != null, "building=roof builds a node")
	if root == null:
		return
	_check(_count_named(root, "Walls") == 0,
		"building=roof has NO walls")
	_check(_count_named(root, "Support") >= 3,
		"building=roof has support posts (one per footprint corner)")
	_check(_count_named(root, "Roof") >= 1,
		"building=roof has a roof")
	root.free()


func _test_regular_building_has_walls() -> void:
	var builder := OSMBuildingBuilder.new()
	var tags := {"building": "yes", "height": "5"}
	var root := builder.build_building_from_polygon(_square(), tags, 2) as Node3D
	_check(root != null, "building=yes builds a node")
	if root == null:
		return
	_check(_count_named(root, "Walls") >= 1,
		"building=yes has walls")
	_check(_count_named(root, "Support") == 0,
		"building=yes has no support posts")
	root.free()


func _test_building_part_roof_has_walls() -> void:
	# building:part=roof is part of a larger building, not an open canopy, so it
	# must still extrude walls like a normal building part.
	var builder := OSMBuildingBuilder.new()
	var tags := {"building:part": "roof", "height": "5", "roof:shape": "flat"}
	var root := builder.build_building_from_polygon(_square(), tags, 3) as Node3D
	_check(root != null, "building:part=roof builds a node")
	if root == null:
		return
	_check(_count_named(root, "Walls") >= 1,
		"building:part=roof still has walls")
	_check(_count_named(root, "Support") == 0,
		"building:part=roof has no support posts")
	root.free()


func _test_open_roof_floats_above_ground() -> void:
	# The roof slab should sit near the top of the structure (its underside well
	# above the ground), not span the whole height like a solid block.
	var builder := OSMBuildingBuilder.new()
	var tags := {"building": "roof", "height": "6"}
	var root := builder.build_building_from_polygon(_square(), tags, 4) as Node3D
	if root == null:
		_check(false, "building=roof builds a node (float test)")
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
	_check(lo > 1.0,
		"roof underside floats above ground (got y=%.2f)" % lo)
	_check(hi <= 6.01,
		"roof top does not exceed building height (got y=%.2f)" % hi)
	root.free()
