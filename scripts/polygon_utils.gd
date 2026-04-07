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
