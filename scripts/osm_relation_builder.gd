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
		var points := PolygonUtils.way_to_points(way.node_ids, osm_data.nodes)

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

	var color := PolygonUtils.get_area_color(rel.tags)

	for member: Dictionary in rel.members:
		if member["type"] != "way":
			continue
		if member["role"] != "outer":
			continue

		var way_id: int = member["ref"]
		if not osm_data.ways.has(way_id):
			continue

		var way: OSMParser.OSMWay = osm_data.ways[way_id]
		var points := PolygonUtils.way_to_points(way.node_ids, osm_data.nodes)

		var mesh_instance := PolygonUtils.build_flat_polygon_mesh(points, color)
		if mesh_instance == null:
			continue

		mesh_instance.name = "AreaPart_%d" % way_id
		root.add_child(mesh_instance)
		has_children = true

	if has_children:
		return root
	return null
