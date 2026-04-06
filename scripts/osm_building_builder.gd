class_name OSMBuildingBuilder
extends RefCounted

## Builds 3D building meshes from OSM ways and relations tagged with "building".

const DEFAULT_HEIGHT := 8.0       # meters if no height/levels tag
const FLOOR_HEIGHT := 3.0         # meters per floor
const BUILDING_Y := 0.0
const ROOF_COLOR := Color(0.55, 0.35, 0.3)

const BUILDING_COLORS := {
	"residential": Color(0.75, 0.7, 0.6),
	"commercial": Color(0.65, 0.65, 0.7),
	"industrial": Color(0.6, 0.58, 0.55),
	"retail": Color(0.7, 0.65, 0.6),
	"apartments": Color(0.72, 0.68, 0.6),
	"house": Color(0.78, 0.72, 0.62),
	"garage": Color(0.6, 0.6, 0.58),
	"church": Color(0.8, 0.78, 0.72),
	"school": Color(0.7, 0.72, 0.65),
	"yes": Color(0.7, 0.68, 0.62),
}

const DEFAULT_BUILDING_COLOR := Color(0.7, 0.68, 0.62)

func build_building_from_way(way: OSMParser.OSMWay, osm_data: OSMParser.OSMData) -> Node3D:
	var points: PackedVector3Array = []
	for nid: int in way.node_ids:
		if osm_data.nodes.has(nid):
			var node: OSMParser.OSMNode = osm_data.nodes[nid]
			points.append(node.local_pos)

	if points.size() < 3:
		return null

	return _build_building_mesh(points, way.tags, way.id)

func build_building_from_polygon(points: PackedVector3Array, tags: Dictionary, id: int) -> Node3D:
	if points.size() < 3:
		return null
	return _build_building_mesh(points, tags, id)

func _build_building_mesh(points: PackedVector3Array, tags: Dictionary, id: int) -> Node3D:
	var height := _get_building_height(tags)
	var building_type: String = tags.get("building", "yes")
	var wall_color: Color = BUILDING_COLORS.get(building_type, DEFAULT_BUILDING_COLOR)

	var root := Node3D.new()
	root.name = "Building_%d" % id

	# Build walls
	var wall_mesh := _build_walls(points, height, wall_color)
	if wall_mesh != null:
		root.add_child(wall_mesh)

	# Build roof (flat)
	var roof_mesh := _build_roof(points, height)
	if roof_mesh != null:
		root.add_child(roof_mesh)

	return root

func _get_building_height(tags: Dictionary) -> float:
	if tags.has("height"):
		var h: float = tags["height"].to_float()
		if h > 0.0:
			return h
	if tags.has("building:levels"):
		var levels: int = tags["building:levels"].to_int()
		if levels > 0:
			return levels * FLOOR_HEIGHT
	return DEFAULT_HEIGHT

func _build_walls(points: PackedVector3Array, height: float, color: Color) -> MeshInstance3D:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	st.set_material(mat)

	for i: int in range(points.size() - 1):
		var p0 := points[i]
		var p1 := points[i + 1]

		var bl := Vector3(p0.x, BUILDING_Y, p0.z)
		var br := Vector3(p1.x, BUILDING_Y, p1.z)
		var tr := Vector3(p1.x, BUILDING_Y + height, p1.z)
		var tl := Vector3(p0.x, BUILDING_Y + height, p0.z)

		# Compute wall normal
		var wall_dir := (br - bl).normalized()
		var normal := Vector3(wall_dir.z, 0.0, -wall_dir.x).normalized()

		# Triangle 1 (reversed winding for outward-facing normals)
		st.set_normal(normal)
		st.add_vertex(bl)
		st.set_normal(normal)
		st.add_vertex(tr)
		st.set_normal(normal)
		st.add_vertex(br)

		# Triangle 2
		st.set_normal(normal)
		st.add_vertex(bl)
		st.set_normal(normal)
		st.add_vertex(tl)
		st.set_normal(normal)
		st.add_vertex(tr)

	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = "Walls"
	mesh_instance.mesh = st.commit()
	return mesh_instance

func _build_roof(points: PackedVector3Array, height: float) -> MeshInstance3D:
	var pts_2d: PackedVector2Array = []
	for p: Vector3 in points:
		pts_2d.append(Vector2(p.x, p.z))

	var indices := Geometry2D.triangulate_polygon(pts_2d)
	if indices.size() == 0:
		return null

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)

	var mat := StandardMaterial3D.new()
	mat.albedo_color = ROOF_COLOR
	st.set_material(mat)

	for i: int in range(indices.size()):
		var idx: int = indices[i]
		st.set_normal(Vector3.UP)
		st.add_vertex(Vector3(points[idx].x, BUILDING_Y + height, points[idx].z))

	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = "Roof"
	mesh_instance.mesh = st.commit()
	return mesh_instance
