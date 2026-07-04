extends GdUnitTestSuite

## Unit tests for building collision in OSMBuildingBuilder.
##
## Buildings must block the car instead of letting it drive through. These tests
## pin the collider contract:
##   1. A regular walled building gets a StaticBody3D collider.
##   2. The collider is a cheap ConvexPolygonShape3D (extruded footprint), NOT a
##      trimesh — this is the FPS-safety guarantee: no per-tile concave cook.
##   3. The convex hull spans the full building height (base .. top).
##   4. An open canopy (building=roof) does NOT get a full-footprint collider;
##      instead each support post carries its own small box collider so the car
##      can drive under the canopy but still hit a post.
##   5. Very short "buildings" (map noise) get no collider.
##   6. enable_collision = false restores the old visual-only behaviour.

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


## Find the first direct-child StaticBody3D named "Collision" (walled buildings
## attach the collider directly to the building root).
func _find_root_collider(root: Node3D) -> StaticBody3D:
	for child in root.get_children():
		if child is StaticBody3D and (child as Node).name == "Collision":
			return child
	return null


## Collect every StaticBody3D anywhere in the subtree (used for canopy posts,
## whose colliders are nested under the support-post meshes).
func _all_collision_bodies(node: Node) -> Array:
	var out: Array = []
	if node is StaticBody3D and node.name == "Collision":
		out.append(node)
	for child in node.get_children():
		out.append_array(_all_collision_bodies(child))
	return out


func _first_shape(body: StaticBody3D) -> Shape3D:
	for child in body.get_children():
		if child is CollisionShape3D:
			return (child as CollisionShape3D).shape
	return null


# ─── Tests ───────────────────────────────────────────────────────────────────

func test_regular_building_has_collider() -> void:
	var builder := OSMBuildingBuilder.new()
	var tags := {"building": "yes", "height": "10"}
	var root := builder.build_building_from_polygon(_square(), tags, 1) as Node3D
	assert_object(root).override_failure_message("building builds a node").is_not_null()
	if root == null:
		return
	var body := _find_root_collider(root)
	assert_object(body) \
		.override_failure_message("building=yes gets a StaticBody3D collider").is_not_null()
	root.free()


func test_collider_is_convex_not_trimesh() -> void:
	# The FPS-safety guarantee: colliders must be convex hulls, never concave
	# trimeshes (which carry a per-tile cook cost). If someone swaps in a trimesh
	# this test fails loudly.
	var builder := OSMBuildingBuilder.new()
	var tags := {"building": "yes", "height": "12"}
	var root := builder.build_building_from_polygon(_square(), tags, 2) as Node3D
	if root == null:
		fail("building builds a node")
		return
	var body := _find_root_collider(root)
	assert_object(body).override_failure_message("collider present").is_not_null()
	if body == null:
		return
	var shape := _first_shape(body)
	assert_bool(shape is ConvexPolygonShape3D) \
		.override_failure_message("collider must be ConvexPolygonShape3D (cheap), got %s" % [shape]) \
		.is_true()
	assert_bool(shape is ConcavePolygonShape3D) \
		.override_failure_message("collider must NOT be a trimesh (FPS hot spot)").is_false()
	root.free()


func test_collider_spans_full_height() -> void:
	var builder := OSMBuildingBuilder.new()
	var height := 15.0
	var tags := {"building": "yes", "height": str(height), "roof:shape": "flat"}
	var root := builder.build_building_from_polygon(_square(), tags, 3) as Node3D
	if root == null:
		fail("building builds a node")
		return
	var body := _find_root_collider(root)
	var shape := _first_shape(body) as ConvexPolygonShape3D
	assert_object(shape).override_failure_message("convex shape present").is_not_null()
	if shape == null:
		return
	var lo := INF
	var hi := -INF
	for p: Vector3 in shape.points:
		lo = minf(lo, p.y)
		hi = maxf(hi, p.y)
	assert_float(lo).override_failure_message("collider base at ground (y=%.2f)" % lo).is_equal_approx(0.0, 0.01)
	assert_float(hi).override_failure_message("collider reaches building top (y=%.2f)" % hi).is_equal_approx(height, 0.01)
	root.free()


func test_short_building_has_no_collider() -> void:
	# Kerb-height map noise should not spend physics.
	var builder := OSMBuildingBuilder.new()
	var tags := {"building": "yes", "height": "0.5"}
	var root := builder.build_building_from_polygon(_square(), tags, 4) as Node3D
	if root == null:
		fail("building builds a node")
		return
	assert_object(_find_root_collider(root)) \
		.override_failure_message("sub-1m building gets no collider").is_null()
	root.free()


func test_open_roof_posts_have_colliders_not_footprint() -> void:
	# A canopy must be drivable-under: no full-footprint collider on the root, but
	# each support post gets its own small box collider.
	var builder := OSMBuildingBuilder.new()
	var tags := {"building": "roof", "height": "5"}
	var root := builder.build_building_from_polygon(_square(), tags, 5) as Node3D
	if root == null:
		fail("building=roof builds a node")
		return
	# No collider attached directly to the root (that would block driving under it).
	assert_object(_find_root_collider(root)) \
		.override_failure_message("open canopy has NO full-footprint collider").is_null()
	# But posts carry box colliders.
	var bodies := _all_collision_bodies(root)
	assert_int(bodies.size()) \
		.override_failure_message("canopy support posts have box colliders (one per corner)") \
		.is_greater_equal(3)
	for b: StaticBody3D in bodies:
		assert_bool(_first_shape(b) is BoxShape3D) \
			.override_failure_message("post collider is a BoxShape3D").is_true()
	root.free()


func test_collision_can_be_disabled() -> void:
	var builder := OSMBuildingBuilder.new()
	builder.enable_collision = false
	var tags := {"building": "yes", "height": "10"}
	var root := builder.build_building_from_polygon(_square(), tags, 6) as Node3D
	if root == null:
		fail("building builds a node")
		return
	assert_int(_all_collision_bodies(root).size()) \
		.override_failure_message("no colliders when collision disabled").is_equal(0)
	root.free()
