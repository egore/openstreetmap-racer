class_name PolygonUtils
extends RefCounted

## Shared polygon geometry utilities for building flat meshes, resolving area colors, etc.

const AREA_COLORS := {
	"landuse": {
		"residential": Color(0.7, 0.7, 0.65),
		"industrial": Color(0.6, 0.55, 0.5),
		"commercial": Color(0.75, 0.65, 0.6),
		"farmland": Color(0.55, 0.7, 0.35),
		"forest": Color(0.2, 0.5, 0.15),
		"grass": Color(0.4, 0.7, 0.3),
	},
	"natural": {
		"water": Color(0.2, 0.4, 0.8),
		"wood": Color(0.15, 0.45, 0.1),
		"scrub": Color(0.4, 0.55, 0.25),
	},
	"leisure": {
		"park": Color(0.35, 0.7, 0.3),
		"pitch": Color(0.3, 0.65, 0.25),
	},
}

const DEFAULT_AREA_COLOR := Color(0.3, 0.6, 0.3)

## Resolve an area color from OSM tags. Returns DEFAULT_AREA_COLOR when no match.
static func get_area_color(tags: Dictionary) -> Color:
	for category: String in AREA_COLORS:
		if tags.has(category):
			var value: String = tags[category]
			var sub: Dictionary = AREA_COLORS[category]
			if sub.has(value):
				return sub[value]
			return DEFAULT_AREA_COLOR
	return DEFAULT_AREA_COLOR

## Collect world positions for a way's node_ids from osm_data.
static func way_to_points(way_node_ids: Array[int], osm_data_nodes: Dictionary) -> PackedVector3Array:
	var points: PackedVector3Array = []
	for nid: int in way_node_ids:
		if osm_data_nodes.has(nid):
			points.append(osm_data_nodes[nid].local_pos)
	return points

## Triangulate a 3D polygon (XZ plane) and return the index array.
## Returns an empty array when triangulation fails.
static func triangulate_xz(points: PackedVector3Array) -> PackedInt32Array:
	var pts_2d: PackedVector2Array = []
	for p: Vector3 in points:
		pts_2d.append(Vector2(p.x, p.z))
	return Geometry2D.triangulate_polygon(pts_2d)

## Build a flat colored MeshInstance3D from a 3D polygon at the given Y height.
## Returns null when fewer than 3 points or triangulation fails.
static func build_flat_polygon_mesh(points: PackedVector3Array, color: Color, y: float = 0.01) -> MeshInstance3D:
	if points.size() < 3:
		return null

	var indices := triangulate_xz(points)
	if indices.size() == 0:
		return null

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	st.set_material(mat)

	for i: int in range(indices.size()):
		var idx: int = indices[i]
		st.set_normal(Vector3.UP)
		st.add_vertex(Vector3(points[idx].x, y, points[idx].z))

	var mesh_instance := MeshInstance3D.new()
	mesh_instance.mesh = st.commit()
	return mesh_instance

## Check if the XZ-projected polygon winds counter-clockwise (shoelace formula).
static func is_polygon_ccw(points: PackedVector3Array) -> bool:
	var signed_area := 0.0
	for i: int in range(points.size() - 1):
		signed_area += points[i].x * points[i + 1].z - points[i + 1].x * points[i].z
	return signed_area < 0.0

## Compute the centroid of a polygon in the XZ plane.
static func polygon_centroid(points: PackedVector3Array) -> Vector3:
	var cx := 0.0
	var cz := 0.0
	var count := points.size()
	# Exclude the closing duplicate vertex if present
	if count > 1 and points[0].distance_to(points[count - 1]) < 0.01:
		count -= 1
	if count == 0:
		return Vector3.ZERO
	for i: int in range(count):
		cx += points[i].x
		cz += points[i].z
	return Vector3(cx / count, 0.0, cz / count)

## Return the AABB min/max in XZ plane as [min_x, max_x, min_z, max_z].
static func polygon_bounds_xz(points: PackedVector3Array) -> Array[float]:
	var min_x := INF
	var max_x := -INF
	var min_z := INF
	var max_z := -INF
	for p: Vector3 in points:
		min_x = min(min_x, p.x)
		max_x = max(max_x, p.x)
		min_z = min(min_z, p.z)
		max_z = max(max_z, p.z)
	return [min_x, max_x, min_z, max_z]

## Find the direction along the longest edge of the polygon (XZ plane, normalized).
static func polygon_longest_edge_dir(points: PackedVector3Array) -> Vector3:
	var best_len := 0.0
	var best_dir := Vector3(1, 0, 0)
	for i: int in range(points.size() - 1):
		var d := points[i + 1] - points[i]
		d.y = 0.0
		var l := d.length()
		if l > best_len:
			best_len = l
			best_dir = d / l
	return best_dir

## Shrink (inset) a polygon in the XZ plane by a fixed distance.
## Returns empty array if the polygon degenerates.
static func shrink_polygon_xz(points: PackedVector3Array, amount: float) -> PackedVector3Array:
	var pts2d: PackedVector2Array = []
	var count := points.size()
	if count > 1 and points[0].distance_to(points[count - 1]) < 0.01:
		count -= 1
	for i: int in range(count):
		pts2d.append(Vector2(points[i].x, points[i].z))
	var result := Geometry2D.offset_polygon(pts2d, -amount)
	if result.size() == 0:
		return PackedVector3Array()
	var out: PackedVector3Array = []
	for p2: Vector2 in result[0]:
		out.append(Vector3(p2.x, 0.0, p2.y))
	# Close the polygon
	if out.size() > 0:
		out.append(out[0])
	return out

## Project a 3D point onto a line defined by origin + direction in XZ, return signed distance.
static func project_xz(point: Vector3, origin: Vector3, direction: Vector3) -> float:
	return (point.x - origin.x) * direction.x + (point.z - origin.z) * direction.z

## Lerp a point along the ridge axis: returns 0.0 at min projection, 1.0 at max projection.
static func ridge_t(point: Vector3, origin: Vector3, direction: Vector3, min_proj: float, max_proj: float) -> float:
	var proj := project_xz(point, origin, direction)
	var span := max_proj - min_proj
	if abs(span) < 0.001:
		return 0.5
	return clampf((proj - min_proj) / span, 0.0, 1.0)
