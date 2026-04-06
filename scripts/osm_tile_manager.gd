class_name OSMTileManager
extends Node3D

## Manages a grid of tiles around the camera. Loads/unloads tiles dynamically.

@export var osm_file_path: String = "res://data/map.osm"
@export var tile_size: float = 200.0  # meters per tile edge
@export var load_radius: int = 2      # tiles in each direction to keep loaded
@export var unload_radius: int = 3    # tiles beyond this are freed

var _osm_data: OSMParser.OSMData = null
var _spatial_index: Dictionary = {}   # Vector2i tile_key -> { ways: [], nodes: [], relations: [] }
var _loaded_tiles: Dictionary = {}    # Vector2i tile_key -> Node3D (tile root)
var _current_tile: Vector2i = Vector2i(999999, 999999)

var _road_builder: OSMRoadBuilder = null
var _building_builder: OSMBuildingBuilder = null
var _asset_placer: OSMAssetPlacer = null
var _relation_builder: OSMRelationBuilder = null

func _ready() -> void:
	_road_builder = OSMRoadBuilder.new()
	_building_builder = OSMBuildingBuilder.new()
	_asset_placer = OSMAssetPlacer.new()
	_relation_builder = OSMRelationBuilder.new()

	_load_osm_data()

func _load_osm_data() -> void:
	print("OSMTileManager: Loading OSM data from %s" % osm_file_path)
	_osm_data = OSMParser.parse_file(osm_file_path)
	if _osm_data == null:
		push_error("OSMTileManager: Failed to load OSM data")
		return
	_build_spatial_index()
	print("OSMTileManager: Spatial index built, ready for tile loading")

func _build_spatial_index() -> void:
	_spatial_index.clear()

	# Index standalone nodes (nodes with tags that aren't just part of ways)
	var way_node_ids := {}
	for way: OSMParser.OSMWay in _osm_data.ways.values():
		for nid: int in way.node_ids:
			way_node_ids[nid] = true

	for node: OSMParser.OSMNode in _osm_data.nodes.values():
		if node.tags.size() > 0:
			var tkey := _pos_to_tile(node.local_pos)
			_ensure_tile_bucket(tkey)
			_spatial_index[tkey]["nodes"].append(node)

	# Index ways: add to every tile their nodes touch
	for way: OSMParser.OSMWay in _osm_data.ways.values():
		var tiles_touched := {}
		for nid: int in way.node_ids:
			if _osm_data.nodes.has(nid):
				var node: OSMParser.OSMNode = _osm_data.nodes[nid]
				var tkey := _pos_to_tile(node.local_pos)
				tiles_touched[tkey] = true
		for tkey: Vector2i in tiles_touched:
			_ensure_tile_bucket(tkey)
			_spatial_index[tkey]["ways"].append(way)

	# Index relations: add to tiles based on member nodes
	for rel: OSMParser.OSMRelation in _osm_data.relations.values():
		var tiles_touched := {}
		for member: Dictionary in rel.members:
			if member["type"] == "way":
				var ref_id: int = member["ref"]
				if _osm_data.ways.has(ref_id):
					var w: OSMParser.OSMWay = _osm_data.ways[ref_id]
					for nid: int in w.node_ids:
						if _osm_data.nodes.has(nid):
							var node: OSMParser.OSMNode = _osm_data.nodes[nid]
							var tkey := _pos_to_tile(node.local_pos)
							tiles_touched[tkey] = true
			elif member["type"] == "node":
				var ref_id: int = member["ref"]
				if _osm_data.nodes.has(ref_id):
					var node: OSMParser.OSMNode = _osm_data.nodes[ref_id]
					var tkey := _pos_to_tile(node.local_pos)
					tiles_touched[tkey] = true
		for tkey: Vector2i in tiles_touched:
			_ensure_tile_bucket(tkey)
			_spatial_index[tkey]["relations"].append(rel)

func _ensure_tile_bucket(tkey: Vector2i) -> void:
	if not _spatial_index.has(tkey):
		_spatial_index[tkey] = { "nodes": [], "ways": [], "relations": [] }

func _pos_to_tile(pos: Vector3) -> Vector2i:
	return Vector2i(
		floori(pos.x / tile_size),
		floori(pos.z / tile_size)
	)

func _process(_delta: float) -> void:
	if _osm_data == null:
		return

	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return

	var cam_tile := _pos_to_tile(camera.global_position)
	if cam_tile == _current_tile:
		return

	_current_tile = cam_tile
	_update_tiles()

func _update_tiles() -> void:
	# Load tiles within radius
	for dx: int in range(-load_radius, load_radius + 1):
		for dz: int in range(-load_radius, load_radius + 1):
			var tkey := Vector2i(_current_tile.x + dx, _current_tile.y + dz)
			if not _loaded_tiles.has(tkey):
				_load_tile(tkey)

	# Unload tiles outside unload_radius
	var to_unload: Array[Vector2i] = []
	for tkey: Vector2i in _loaded_tiles:
		var dist: int = max(abs(tkey.x - _current_tile.x), abs(tkey.y - _current_tile.y))
		if dist > unload_radius:
			to_unload.append(tkey)

	for tkey: Vector2i in to_unload:
		_unload_tile(tkey)

func _load_tile(tkey: Vector2i) -> void:
	if not _spatial_index.has(tkey):
		# Empty tile, still mark as loaded so we don't retry
		_loaded_tiles[tkey] = null
		return

	var bucket: Dictionary = _spatial_index[tkey]
	var tile_root := Node3D.new()
	tile_root.name = "Tile_%d_%d" % [tkey.x, tkey.y]
	add_child(tile_root)

	# Build ground plane for the tile
	_build_ground(tile_root, tkey)

	# Process ways (roads, buildings from ways, etc.)
	var processed_way_ids := {}
	for way: OSMParser.OSMWay in bucket["ways"]:
		if processed_way_ids.has(way.id):
			continue
		processed_way_ids[way.id] = true

		if _is_road(way):
			var mesh_instance := _road_builder.build_road(way, _osm_data)
			if mesh_instance != null:
				tile_root.add_child(mesh_instance)
		elif _is_building(way):
			var mesh_instance := _building_builder.build_building_from_way(way, _osm_data)
			if mesh_instance != null:
				tile_root.add_child(mesh_instance)
		elif _is_area(way):
			var mesh_instance := _build_area(way)
			if mesh_instance != null:
				tile_root.add_child(mesh_instance)

	# Process standalone nodes (traffic lights, trees, etc.)
	for node: OSMParser.OSMNode in bucket["nodes"]:
		var placeholder := _asset_placer.place_asset(node)
		if placeholder != null:
			tile_root.add_child(placeholder)

	# Process relations (multipolygon buildings, etc.)
	var processed_rel_ids := {}
	for rel: OSMParser.OSMRelation in bucket["relations"]:
		if processed_rel_ids.has(rel.id):
			continue
		processed_rel_ids[rel.id] = true
		var rel_node := _relation_builder.build_relation(rel, _osm_data)
		if rel_node != null:
			tile_root.add_child(rel_node)

	_loaded_tiles[tkey] = tile_root

func _unload_tile(tkey: Vector2i) -> void:
	var tile_node: Node3D = _loaded_tiles[tkey]
	if tile_node != null:
		tile_node.queue_free()
	_loaded_tiles.erase(tkey)

func _build_ground(parent: Node3D, tkey: Vector2i) -> void:
	var ground := MeshInstance3D.new()
	ground.name = "Ground"
	var plane := PlaneMesh.new()
	plane.size = Vector2(tile_size, tile_size)
	ground.mesh = plane

	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.35, 0.55, 0.25)  # grass green
	ground.material_override = mat

	ground.position = Vector3(
		(tkey.x + 0.5) * tile_size,
		-0.05,
		(tkey.y + 0.5) * tile_size
	)
	parent.add_child(ground)

func _is_road(way: OSMParser.OSMWay) -> bool:
	return way.tags.has("highway")

func _is_building(way: OSMParser.OSMWay) -> bool:
	return way.tags.has("building")

func _is_area(way: OSMParser.OSMWay) -> bool:
	return way.tags.has("landuse") or way.tags.has("natural") or way.tags.has("leisure") or (way.tags.has("amenity") and way.tags.has("area"))

func _build_area(way: OSMParser.OSMWay) -> MeshInstance3D:
	# Simple colored flat polygon for land use areas
	var points: PackedVector3Array = []
	for nid: int in way.node_ids:
		if _osm_data.nodes.has(nid):
			points.append(_osm_data.nodes[nid].local_pos)
	if points.size() < 3:
		return null

	var color := Color(0.3, 0.6, 0.3)  # default green
	var tags := way.tags
	if tags.has("landuse"):
		match tags["landuse"]:
			"residential": color = Color(0.7, 0.7, 0.65)
			"industrial": color = Color(0.6, 0.55, 0.5)
			"commercial": color = Color(0.75, 0.65, 0.6)
			"farmland": color = Color(0.55, 0.7, 0.35)
			"forest": color = Color(0.2, 0.5, 0.15)
			"grass": color = Color(0.4, 0.7, 0.3)
	elif tags.has("natural"):
		match tags["natural"]:
			"water": color = Color(0.2, 0.4, 0.8)
			"wood": color = Color(0.15, 0.45, 0.1)
			"scrub": color = Color(0.4, 0.55, 0.25)
	elif tags.has("leisure"):
		match tags["leisure"]:
			"park": color = Color(0.35, 0.7, 0.3)
			"pitch": color = Color(0.3, 0.65, 0.25)

	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = "Area_%d" % way.id

	# Triangulate the polygon
	var pts_2d: PackedVector2Array = []
	for p: Vector3 in points:
		pts_2d.append(Vector2(p.x, p.z))

	var indices := Geometry2D.triangulate_polygon(pts_2d)
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
		st.add_vertex(Vector3(points[idx].x, 0.01, points[idx].z))

	mesh_instance.mesh = st.commit()
	return mesh_instance
