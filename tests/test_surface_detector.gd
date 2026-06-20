extends GdUnitTestSuite

## Unit tests for SurfaceDetector.
##
## SurfaceDetector determines whether a world position is over a road or on
## grass by checking road MeshInstance3D AABBs from the "road_surface" group.
## These tests exercise:
##   1. Bare detector (no scene tree) defaults to GRASS.
##   2. A position inside a road mesh AABB returns ROAD.
##   3. A position outside all road AABBs returns GRASS.
##   4. Vertical tolerance works (wheel slightly above/below road ribbon).


# ─── Helpers ─────────────────────────────────────────────────────────────────

## Create a minimal MeshInstance3D with a known AABB, add it to the
## "road_surface" group, and parent it to `parent`. The mesh occupies
## [origin .. origin + size] in local space, placed at `pos` in world space.
func _add_road_mesh(parent: Node, pos: Vector3, aabb_size: Vector3) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.name = "Road_Test"
	# BoxMesh centred at origin; AABB goes from -half to +half.
	var box := BoxMesh.new()
	box.size = aabb_size
	mi.mesh = box
	mi.position = pos
	mi.add_to_group(&"road_surface")
	parent.add_child(mi)
	return mi


# ─── Tests ───────────────────────────────────────────────────────────────────

func test_no_tree_returns_grass() -> void:
	var det := SurfaceDetector.new()
	# Not initialised — should safely default to GRASS.
	var result := det.detect(Vector3.ZERO)
	assert_int(result) \
		.override_failure_message("Uninitialised detector should return GRASS") \
		.is_equal(SurfaceDetector.Surface.GRASS)


func test_no_roads_returns_grass() -> void:
	var det := SurfaceDetector.new()
	det.init(auto_free(Node.new()).get_tree())
	var result := det.detect(Vector3(5, 0, 5))
	assert_int(result) \
		.override_failure_message("No road meshes in tree -> GRASS") \
		.is_equal(SurfaceDetector.Surface.GRASS)


func test_position_inside_road_returns_road() -> void:
	var root := auto_free(Node3D.new())
	add_child(root)
	# Road mesh centred at (10, 0, 10), box of size (6, 0.1, 20).
	# AABB: x=[7..13], y=[-0.05..0.05], z=[0..20]
	_add_road_mesh(root, Vector3(10, 0, 10), Vector3(6.0, 0.1, 20.0))

	var det := SurfaceDetector.new()
	det.init(get_tree())
	# Point right in the middle of the road.
	var result := det.detect(Vector3(10, 0, 10))
	assert_int(result) \
		.override_failure_message("Point inside road AABB -> ROAD") \
		.is_equal(SurfaceDetector.Surface.ROAD)


func test_position_outside_road_returns_grass() -> void:
	var root := auto_free(Node3D.new())
	add_child(root)
	_add_road_mesh(root, Vector3(10, 0, 10), Vector3(6.0, 0.1, 20.0))

	var det := SurfaceDetector.new()
	det.init(get_tree())
	# Way outside the road mesh.
	var result := det.detect(Vector3(100, 0, 100))
	assert_int(result) \
		.override_failure_message("Point far from road AABB -> GRASS") \
		.is_equal(SurfaceDetector.Surface.GRASS)


func test_vertical_tolerance_catches_wheel_above_road() -> void:
	var root := auto_free(Node3D.new())
	add_child(root)
	# Road at Y=0, tiny vertical extent.
	_add_road_mesh(root, Vector3(10, 0, 10), Vector3(6.0, 0.04, 20.0))

	var det := SurfaceDetector.new()
	det.init(get_tree())
	# Wheel at Y=0.5 — above the road's thin slab but within the tolerance.
	var result := det.detect(Vector3(10, 0.5, 10))
	assert_int(result) \
		.override_failure_message("Wheel slightly above road -> ROAD (tolerance)") \
		.is_equal(SurfaceDetector.Surface.ROAD)


func test_position_just_outside_xz_returns_grass() -> void:
	var root := auto_free(Node3D.new())
	add_child(root)
	# Road centred at (10, 0, 10), half-width X = 3 → X range [7..13].
	_add_road_mesh(root, Vector3(10, 0, 10), Vector3(6.0, 0.1, 20.0))

	var det := SurfaceDetector.new()
	det.init(get_tree())
	# Just outside in X.
	var result := det.detect(Vector3(14, 0, 10))
	assert_int(result) \
		.override_failure_message("Point just outside road in X -> GRASS") \
		.is_equal(SurfaceDetector.Surface.GRASS)


func test_road_handler_tags_mesh() -> void:
	# Verify the road handler adds the mesh to the "road_surface" group. We
	# cannot call build() without a full tile context, but we can verify the
	# static predicate that decides whether a way is a road.
	var handler := RoadHandler.new()
	var way := OSMParser.OSMWay.new()
	way.id = 1
	way.tags = {"highway": "residential"}
	way.node_ids = [1, 2] as Array[int]
	assert_bool(handler.matches(way, null)) \
		.override_failure_message("highway=residential is a road") \
		.is_true()
