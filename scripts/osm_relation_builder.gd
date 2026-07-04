class_name OSMRelationBuilder
extends RefCounted

## Builds 3D geometry from OSM relations (multipolygon buildings, etc.)

var _building_builder: OSMBuildingBuilder = null

## Terrain parameters set by the tile manager for terrain-draped area meshes.
var height_provider: HeightProvider = null
var terrain_grid_step: float = 0.0
## Set per-tile before building relations to clip large polygons to tile bounds.
## Array[float] [min_x, max_x, min_z, max_z] or null.
var tile_clip_rect: Variant = null


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

	elif tags.get("type", "") == "building":
		return _build_building_relation(rel, osm_data)

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

	var is_scrub := PolygonUtils.is_scrub(rel.tags)
	var is_forest := PolygonUtils.is_forest(rel.tags)
	var color := PolygonUtils.get_area_color(rel.tags)
	var use_terrain := height_provider != null and height_provider.is_ready() \
		and terrain_grid_step > 0.0

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

		var priority := roundi(PolygonUtils.ground_render_priority(
			rel.tags, PolygonUtils.polygon_area_xz(points)))
		if is_scrub:
			var hp: HeightProvider = height_provider if use_terrain else null
			var gs: float = terrain_grid_step if use_terrain else 0.0
			var scrub_node := PolygonUtils.build_scrub_area(points, hp, gs, 0.01, tile_clip_rect, priority)
			if scrub_node != null:
				scrub_node.name = "ScrubPart_%d" % way_id
				root.add_child(scrub_node)
				has_children = true
		elif is_forest:
			var hp: HeightProvider = height_provider if use_terrain else null
			var gs: float = terrain_grid_step if use_terrain else 0.0
			var forest_node := PolygonUtils.build_forest_area(points, hp, gs, 0.01, tile_clip_rect, priority)
			if forest_node != null:
				forest_node.name = "ForestPart_%d" % way_id
				root.add_child(forest_node)
				has_children = true
		else:
			# Same painter's-algorithm ground rank (priority) as scrub/forest and
			# single-way areas: class order + smaller-patch tiebreak, depth-write
			# disabled downstream so coplanar multipolygon parts don't z-fight the
			# landcover they overlay.
			var mesh_instance: MeshInstance3D
			if use_terrain:
				mesh_instance = PolygonUtils.build_terrain_draped_mesh(
					points, color, height_provider, terrain_grid_step, 0.01, tile_clip_rect, priority)
			else:
				mesh_instance = PolygonUtils.build_flat_polygon_mesh(points, color, 0.01, true, priority)
			if mesh_instance == null:
				continue

			mesh_instance.name = "AreaPart_%d" % way_id
			root.add_child(mesh_instance)
			has_children = true

	if has_children:
		return root
	return null

func _build_building_relation(rel: OSMParser.OSMRelation, osm_data: OSMParser.OSMData) -> Node3D:
	# type=building relation: render parts, skip outline
	var root := Node3D.new()
	root.name = "RelBuilding_%d" % rel.id
	var has_children := false

	# Collect outline tags for defaults
	var outline_tags: Dictionary = {}
	for member: Dictionary in rel.members:
		if member["type"] != "way":
			continue
		if member["role"] == "outline":
			var way_id: int = member["ref"]
			if osm_data.ways.has(way_id):
				outline_tags = osm_data.ways[way_id].tags.duplicate()
			break

	# Merge relation tags over outline tags for defaults
	for k: String in rel.tags:
		outline_tags[k] = rel.tags[k]

	# Build each part member
	for member: Dictionary in rel.members:
		if member["type"] != "way":
			continue
		if member["role"] != "part":
			continue

		var way_id: int = member["ref"]
		if not osm_data.ways.has(way_id):
			continue

		var way: OSMParser.OSMWay = osm_data.ways[way_id]
		var points := PolygonUtils.way_to_points(way.node_ids, osm_data.nodes)

		if points.size() < 3:
			continue

		# Part tags override outline/relation defaults
		var merged_tags := outline_tags.duplicate()
		for k: String in way.tags:
			merged_tags[k] = way.tags[k]

		var building_node := _building_builder.build_building_from_polygon(points, merged_tags, way_id)
		if building_node != null:
			root.add_child(building_node)
			has_children = true

	if has_children:
		return root
	return null
