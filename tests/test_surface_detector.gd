extends GdUnitTestSuite

## Unit tests for SurfaceDetector.
##
## SurfaceDetector determines whether a world position is over a road or on
## grass by testing the triangles of the meshes in the "road_surface" group.
## These tests exercise:
##   1. Bare detector (no scene tree) defaults to GRASS.
##   2. A position inside a road mesh returns ROAD.
##   3. A position outside all road meshes returns GRASS.
##   4. Vertical tolerance works (wheel slightly above/below road ribbon).
##   5. A position inside a DIAGONAL road's bounding box but off the actual
##      carriageway returns GRASS -- the case the old AABB-only test got wrong.


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
	var root: Node3D = auto_free(Node3D.new())
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
	var root: Node3D = auto_free(Node3D.new())
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
	var root: Node3D = auto_free(Node3D.new())
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
	var root: Node3D = auto_free(Node3D.new())
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


# ─── Real geometry, not just bounding boxes ─────────────────────────────────

## Build a flat triangulated quad (world-space vertices) in the road group. This
## is the shape a real road ribbon segment has, unlike the axis-aligned BoxMesh
## used by the tests above.
func _add_road_quad(parent: Node, a: Vector3, b: Vector3, c: Vector3,
		d: Vector3) -> MeshInstance3D:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for v: Vector3 in [a, b, c, a, c, d]:
		st.set_normal(Vector3.UP)
		st.add_vertex(v)
	var mi := MeshInstance3D.new()
	mi.name = "Road_Quad"
	mi.mesh = st.commit()
	mi.add_to_group(&"road_surface")
	parent.add_child(mi)
	return mi


func test_diagonal_road_does_not_claim_its_empty_corners() -> void:
	# REGRESSION: a 45-degree road's bounding box is roughly twice the area of
	# the carriageway. The old AABB-only test reported ROAD for the empty
	# corners, so the car read "on tarmac" while visibly driving over grass.
	var root: Node3D = auto_free(Node3D.new())
	add_child(root)
	# A 4 m wide ribbon running diagonally from (0,0) to (40,40).
	_add_road_quad(root,
		Vector3(-1.4, 0.0, 1.4), Vector3(1.4, 0.0, -1.4),
		Vector3(41.4, 0.0, 38.6), Vector3(38.6, 0.0, 41.4))

	var det := SurfaceDetector.new()
	det.init(get_tree())
	# (40, 0) is deep inside the AABB but far off the diagonal carriageway.
	assert_int(det.detect(Vector3(40.0, 0.0, 0.0))) \
		.override_failure_message(
			"a corner of a diagonal road's bounding box is NOT road") \
		.is_equal(SurfaceDetector.Surface.GRASS)


func test_diagonal_road_still_detects_its_centreline() -> void:
	var root: Node3D = auto_free(Node3D.new())
	add_child(root)
	_add_road_quad(root,
		Vector3(-1.4, 0.0, 1.4), Vector3(1.4, 0.0, -1.4),
		Vector3(41.4, 0.0, 38.6), Vector3(38.6, 0.0, 41.4))

	var det := SurfaceDetector.new()
	det.init(get_tree())
	assert_int(det.detect(Vector3(20.0, 0.0, 20.0))) \
		.override_failure_message("the middle of the road IS road") \
		.is_equal(SurfaceDetector.Surface.ROAD)


func test_point_on_the_carriageway_edge_reads_as_road() -> void:
	# Wheels ride near the painted edge; the surface must not flicker there.
	var root: Node3D = auto_free(Node3D.new())
	add_child(root)
	# Axis-aligned 6 m wide ribbon along Z, centred on X=0.
	_add_road_quad(root,
		Vector3(-3.0, 0.0, 0.0), Vector3(3.0, 0.0, 0.0),
		Vector3(3.0, 0.0, 40.0), Vector3(-3.0, 0.0, 40.0))

	var det := SurfaceDetector.new()
	det.init(get_tree())
	assert_int(det.detect(Vector3(2.98, 0.0, 20.0))) \
		.override_failure_message("a wheel on the edge line is still on road") \
		.is_equal(SurfaceDetector.Surface.ROAD)


func test_just_past_the_edge_is_grass() -> void:
	var root: Node3D = auto_free(Node3D.new())
	add_child(root)
	_add_road_quad(root,
		Vector3(-3.0, 0.0, 0.0), Vector3(3.0, 0.0, 0.0),
		Vector3(3.0, 0.0, 40.0), Vector3(-3.0, 0.0, 40.0))

	var det := SurfaceDetector.new()
	det.init(get_tree())
	assert_int(det.detect(Vector3(4.0, 0.0, 20.0))) \
		.override_failure_message("a metre off the carriageway is grass") \
		.is_equal(SurfaceDetector.Surface.GRASS)


func test_junction_cap_is_drivable_surface() -> void:
	# Intersection caps join the road_surface group, so driving across a
	# junction must not read as leaving the road.
	var root: Node3D = auto_free(Node3D.new())
	add_child(root)
	# A small square standing in for a junction cap around the origin.
	_add_road_quad(root,
		Vector3(-5.0, 0.0, -5.0), Vector3(5.0, 0.0, -5.0),
		Vector3(5.0, 0.0, 5.0), Vector3(-5.0, 0.0, 5.0))

	var det := SurfaceDetector.new()
	det.init(get_tree())
	assert_int(det.detect(Vector3(0.0, 0.0, 0.0))) \
		.override_failure_message("the middle of an intersection is road") \
		.is_equal(SurfaceDetector.Surface.ROAD)


func test_repeated_queries_are_consistent() -> void:
	# The triangle cache must not change the answer between calls.
	var root: Node3D = auto_free(Node3D.new())
	add_child(root)
	_add_road_quad(root,
		Vector3(-3.0, 0.0, 0.0), Vector3(3.0, 0.0, 0.0),
		Vector3(3.0, 0.0, 40.0), Vector3(-3.0, 0.0, 40.0))

	var det := SurfaceDetector.new()
	det.init(get_tree())
	var first := det.detect(Vector3(0.0, 0.0, 20.0))
	for _i: int in range(5):
		assert_int(det.detect(Vector3(0.0, 0.0, 20.0))) \
			.override_failure_message("cached queries must stay consistent") \
			.is_equal(first)
