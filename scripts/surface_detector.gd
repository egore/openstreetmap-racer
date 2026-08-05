class_name SurfaceDetector
extends RefCounted

## Determines the surface type under a world position by testing whether a road
## mesh actually covers that point. Road and junction MeshInstance3D nodes are
## added to the "road_surface" scene-tree group by their builders so we can find
## them without walking the entire tile hierarchy.
##
## ── Why this is a real containment test ──────────────────────────────────────
## This used to test only each mesh's world-space AABB. That was a defensible
## approximation while roads were long, full-length ribbons: a box around a
## narrow strip is mostly strip.
##
## It stopped being defensible once roads gained real intersections:
##
##   • A DIAGONAL road's AABB is mostly not road. A 45° street has an AABB whose
##     area is roughly twice the carriageway, so the car reads "on tarmac" while
##     visibly driving across grass beside it.
##   • Junction caps are compact polygons whose AABB includes the four corner
##     quadrants that are explicitly NOT part of the intersection — precisely the
##     pavement corners we now build.
##   • Roads are no longer one mesh per street: trimming splits them, so there
##     are more, smaller boxes and more chances for a false positive.
##
## So we now test the mesh triangles themselves, with an AABB pre-filter to keep
## the cost close to the old one for the overwhelming majority of meshes that are
## nowhere near the query point.
##
## ── Cost ─────────────────────────────────────────────────────────────────────
## The triangle test only runs for meshes whose AABB already contains the point,
## which in practice is one or two meshes. Triangle arrays are cached per mesh
## (keyed by RID) because the wheels query every few physics ticks and the same
## handful of road meshes answer almost every time.

enum Surface {
	ROAD,
	GRASS,
}

## Vertical half-height of the slab test. Road surfaces sit ~0.02 m above the
## ground, so a generous window catches them even on sloped terrain.
const _Y_TOLERANCE := 1.0

## Maximum XZ distance from query point to AABB centre before we skip the mesh
## entirely. Roads are at most ~12 m wide and trimmed segments rarely exceed
## ~30 m, so 50 m is conservative.
const _CULL_DISTANCE_SQ := 2500.0  # 50 m, squared

## Small outward tolerance (metres) applied to the triangle test, so a wheel
## exactly on the painted edge of the carriageway still reads as on-road rather
## than flickering between surfaces.
const _EDGE_TOLERANCE := 0.15

## Cached reference to the scene tree, set once via init().
var _tree: SceneTree = null

## mesh RID -> PackedVector3Array of triangle vertices (world space, XZ used).
## Road meshes are static once built, so this is safe to hold until the mesh is
## freed; entries for freed meshes are dropped lazily in _triangles_of.
var _triangle_cache: Dictionary = {}


## Bind to the scene tree. Call once from the car's _ready().
func init(tree: SceneTree) -> void:
	_tree = tree


## Returns the surface type at the given world XZ position. The Y component is
## used only for the vertical slab check (wheel contact point).
func detect(world_pos: Vector3) -> Surface:
	if _tree == null:
		return Surface.GRASS

	var roads := _tree.get_nodes_in_group(&"road_surface")
	for node: Node in roads:
		var mi := node as MeshInstance3D
		if mi == null or mi.mesh == null:
			continue

		# Road geometry is emitted in world coordinates, so the node transform is
		# usually identity — but bridges carry a Y offset and tile roots may not
		# sit at the origin, so go through the global transform regardless.
		var world_aabb := mi.global_transform * mi.get_aabb()

		var center := world_aabb.get_center()
		var dx := center.x - world_pos.x
		var dz := center.z - world_pos.z
		if dx * dx + dz * dz > _CULL_DISTANCE_SQ:
			continue

		# Cheap reject: outside the box means outside the geometry.
		if not _in_aabb_xz(world_aabb, world_pos):
			continue

		# Inside the box — now confirm the point is really on the surface, not
		# in the empty corner of a diagonal road or beside a junction cap.
		if _covers_point(mi, world_pos):
			return Surface.ROAD

	return Surface.GRASS


## AABB containment in XZ, with the vertical slab inflated by _Y_TOLERANCE.
func _in_aabb_xz(box: AABB, p: Vector3) -> bool:
	var min_y := box.position.y - _Y_TOLERANCE
	var max_y := box.end.y + _Y_TOLERANCE
	return p.x >= box.position.x - _EDGE_TOLERANCE \
		and p.x <= box.end.x + _EDGE_TOLERANCE \
		and p.z >= box.position.z - _EDGE_TOLERANCE \
		and p.z <= box.end.z + _EDGE_TOLERANCE \
		and p.y >= min_y and p.y <= max_y


## True when any triangle of the mesh contains the point in the XZ plane.
func _covers_point(mi: MeshInstance3D, p: Vector3) -> bool:
	var tris := _triangles_of(mi)
	var count := tris.size()
	var i := 0
	while i + 2 < count:
		if _point_in_triangle_xz(p, tris[i], tris[i + 1], tris[i + 2]):
			return true
		i += 3
	return false


## World-space triangle vertices of a road mesh, cached per mesh resource.
##
## Uses Mesh.get_faces(), which returns every surface's triangles in one array —
## important here because a junction mesh carries its cap, its painted markings
## and its kerbs as separate surfaces, and the drivable surface is only the cap.
## Including the markings is harmless (they lie on the cap) and the kerbs raise
## no false positives because the vertical slab test rejects them only when the
## wheel is far below, which is the correct answer for a kerb anyway.
func _triangles_of(mi: MeshInstance3D) -> PackedVector3Array:
	var mesh := mi.mesh
	if mesh == null:
		return PackedVector3Array()

	var key := mesh.get_rid()
	if _triangle_cache.has(key):
		return _triangle_cache[key]

	var faces := mesh.get_faces()
	# Bake the node transform in once here rather than per query. Road geometry
	# is static, so this stays valid for the mesh's lifetime.
	var xform := mi.global_transform
	if not xform.is_equal_approx(Transform3D.IDENTITY):
		var moved := PackedVector3Array()
		moved.resize(faces.size())
		for i: int in range(faces.size()):
			moved[i] = xform * faces[i]
		faces = moved

	_triangle_cache[key] = faces
	return faces


## Barycentric point-in-triangle test in the XZ plane, with a small outward
## tolerance so edges read as covered rather than flickering.
func _point_in_triangle_xz(p: Vector3, a: Vector3, b: Vector3, c: Vector3) -> bool:
	var v0x := c.x - a.x
	var v0z := c.z - a.z
	var v1x := b.x - a.x
	var v1z := b.z - a.z
	var v2x := p.x - a.x
	var v2z := p.z - a.z

	var dot00 := v0x * v0x + v0z * v0z
	var dot01 := v0x * v1x + v0z * v1z
	var dot02 := v0x * v2x + v0z * v2z
	var dot11 := v1x * v1x + v1z * v1z
	var dot12 := v1x * v2x + v1z * v2z

	var denom := dot00 * dot11 - dot01 * dot01
	if absf(denom) < 0.0000001:
		return false  # degenerate triangle

	var inv := 1.0 / denom
	var u := (dot11 * dot02 - dot01 * dot12) * inv
	var v := (dot00 * dot12 - dot01 * dot02) * inv

	# Tolerance is expressed in barycentric space via the triangle's scale, so a
	# large triangle doesn't get a disproportionately fat border.
	var scale := sqrt(maxf(dot00, dot11))
	var eps := 0.0 if scale < 0.0001 else _EDGE_TOLERANCE / scale

	return u >= -eps and v >= -eps and u + v <= 1.0 + eps
