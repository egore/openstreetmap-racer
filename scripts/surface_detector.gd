class_name SurfaceDetector
extends RefCounted

## Determines the surface type under a world position by checking whether a
## road mesh covers that point. Road MeshInstance3D nodes are added to the
## "road_surface" scene-tree group by the road handler so we can find them
## quickly without walking the entire tile hierarchy.
##
## The check is intentionally cheap: we test the mesh's world-space AABB (with
## a small vertical tolerance) rather than intersecting individual triangles.
## Road ribbons are narrow and tightly-fitting, so the AABB is a good-enough
## proxy — the occasional false positive at a sharp bend is invisible under
## particle effects.
##
## Performance: the road group can hold hundreds of meshes. To keep the per-
## frame cost low we skip meshes whose AABB centre is farther than a generous
## cutoff distance before doing the full containment test.

enum Surface {
	ROAD,
	GRASS,
}

## Vertical half-height of the AABB slab test. The road mesh sits ~0.02 m
## above the ground, so a generous window catches it even on sloped terrain.
const _Y_TOLERANCE := 1.0

## Maximum XZ distance from query point to AABB centre before we skip the
## full containment test. Roads are at most ~12 m wide and individual mesh
## segments rarely exceed ~30 m in length, so 50 m is very conservative.
const _CULL_DISTANCE_SQ := 2500.0  # 50 m, squared

## Cached reference to the scene tree, set once via init().
var _tree: SceneTree = null


## Bind to the scene tree. Call once from the car's _ready().
func init(tree: SceneTree) -> void:
	_tree = tree


## Returns the surface type at the given world XZ position. The Y component
## is used only for the vertical slab check (wheel contact point).
func detect(world_pos: Vector3) -> Surface:
	if _tree == null:
		return Surface.GRASS

	var roads := _tree.get_nodes_in_group(&"road_surface")
	for node: Node in roads:
		var mi := node as MeshInstance3D
		if mi == null or mi.mesh == null:
			continue
		var aabb: AABB = mi.get_aabb()
		# Transform the AABB into world space. Road mesh vertices are already
		# in world-space coordinates (the builders emit geometry at real XZ),
		# so the global transform is typically identity. The multiplication
		# still matters when the parent chain has a non-zero origin.
		var world_aabb := mi.global_transform * aabb
		# Quick distance pre-check against the AABB centre — NOT
		# global_position, which is (0,0,0) because the mesh node itself has
		# no local offset (the geometry carries the world coords instead).
		var center := world_aabb.get_center()
		var dx := center.x - world_pos.x
		var dz := center.z - world_pos.z
		if dx * dx + dz * dz > _CULL_DISTANCE_SQ:
			continue
		# Inflate vertically so a wheel slightly above or below the ribbon
		# still registers as "on road".
		var min_y := world_aabb.position.y - _Y_TOLERANCE
		var max_y := world_aabb.end.y + _Y_TOLERANCE
		if world_pos.x >= world_aabb.position.x and world_pos.x <= world_aabb.end.x \
				and world_pos.z >= world_aabb.position.z and world_pos.z <= world_aabb.end.z \
				and world_pos.y >= min_y and world_pos.y <= max_y:
			return Surface.ROAD

	return Surface.GRASS
