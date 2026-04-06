class_name OSMRelationBuilder
extends RefCounted

## Builds 3D geometry from OSM relations (multipolygon buildings, etc.)

var _building_builder: OSMBuildingBuilder = null

func _init() -> void:
	_building_builder = OSMBuildingBuilder.new()

func build_relation(rel: OSMParser.OSMRelation, osm_data: OSMParser.OSMData) -> Node3D:
	var tags := rel.tags

	# Multipolygon relations
	if tags.get("type", "") == "multipolygon":
		if tags.has("building"):
			return _build_multipolygon_building(rel, osm_data)
		elif tags.has("landuse") or tags.has("natural") or tags.has("leisure"):
			return _build_multipolygon_area(rel, osm_data)

	# Route relations (could visualize bus routes, etc.) - skip for now
	# Boundary relations - skip for now

	return null

func _build_multipolygon_building(rel: OSMParser.OSMRelation, osm_data: OSMParser.OSMData) -> Node3D:
	# Collect outer ways and build buildings from them
	var root := Node3D.new()
	root.name = "RelBuilding_%d" % rel.id
	var has_children := false

	for member: Dictionary in rel.members:
		if member["type"] != "way":
			continue
		if member["role"] != "outer":
			continue

		var way_id: int = member["ref"]
		if not osm_data.ways.has(way_id):
			continue

		var way: OSMParser.OSMWay = osm_data.ways[way_id]
		var points: PackedVector3Array = []
		for nid: int in way.node_ids:
			if osm_data.nodes.has(nid):
				points.append(osm_data.nodes[nid].local_pos)

		if points.size() < 3:
			continue

		# Merge relation tags with way tags (relation tags take priority)
		var merged_tags := way.tags.duplicate()
		for k: String in rel.tags:
			merged_tags[k] = rel.tags[k]

		var building_node := _building_builder.build_building_from_polygon(points, merged_tags, way_id)
		if building_node != null:
			root.add_child(building_node)
			has_children = true

	if has_children:
		return root
	return null

func _build_multipolygon_area(rel: OSMParser.OSMRelation, osm_data: OSMParser.OSMData) -> Node3D:
	var root := Node3D.new()
	root.name = "RelArea_%d" % rel.id
	var has_children := false

	var color := Color(0.3, 0.6, 0.3)
	if rel.tags.has("landuse"):
		match rel.tags["landuse"]:
			"residential": color = Color(0.7, 0.7, 0.65)
			"industrial": color = Color(0.6, 0.55, 0.5)
			"commercial": color = Color(0.75, 0.65, 0.6)
			"farmland": color = Color(0.55, 0.7, 0.35)
			"forest": color = Color(0.2, 0.5, 0.15)
			"grass": color = Color(0.4, 0.7, 0.3)
	elif rel.tags.has("natural"):
		match rel.tags["natural"]:
			"water": color = Color(0.2, 0.4, 0.8)
			"wood": color = Color(0.15, 0.45, 0.1)
	elif rel.tags.has("leisure"):
		match rel.tags["leisure"]:
			"park": color = Color(0.35, 0.7, 0.3)

	for member: Dictionary in rel.members:
		if member["type"] != "way":
			continue
		if member["role"] != "outer":
			continue

		var way_id: int = member["ref"]
		if not osm_data.ways.has(way_id):
			continue

		var way: OSMParser.OSMWay = osm_data.ways[way_id]
		var points: PackedVector3Array = []
		for nid: int in way.node_ids:
			if osm_data.nodes.has(nid):
				points.append(osm_data.nodes[nid].local_pos)

		if points.size() < 3:
			continue

		var pts_2d: PackedVector2Array = []
		for p: Vector3 in points:
			pts_2d.append(Vector2(p.x, p.z))

		var indices := Geometry2D.triangulate_polygon(pts_2d)
		if indices.size() == 0:
			continue

		var mesh_instance := MeshInstance3D.new()
		mesh_instance.name = "AreaPart_%d" % way_id

		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		var mat := StandardMaterial3D.new()
		mat.albedo_color = color
		st.set_material(mat)

		for i: int in range(indices.size()):
			var idx: int = indices[i]
			st.set_normal(Vector3.UP)
			st.add_vertex(Vector3(points[idx].x, 0.01, points[idx].z))

		mesh_instance.mesh = st.commit()
		root.add_child(mesh_instance)
		has_children = true

	if has_children:
		return root
	return null
