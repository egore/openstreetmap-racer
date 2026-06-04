class_name OSMTileManager
extends Node3D

## Manages a grid of tiles around the camera. Loads/unloads tiles dynamically.

## Emitted once the OSM file has been parsed and the spatial index is ready.
signal data_loaded(osm_data: OSMParser.OSMData)
## Emitted whenever a tile's geometry has been instanced into the scene.
signal tile_loaded(tile_key: Vector2i)
## Emitted whenever a tile is freed.
signal tile_unloaded(tile_key: Vector2i)

@export var osm_file_path: String = "res://data/map.osm"
@export var tile_size: float = 200.0  # meters per tile edge
@export var load_radius: int = 2      # tiles in each direction to keep loaded
@export var unload_radius: int = 3    # tiles beyond this are freed
## Number of grid cells per tile edge when building displaced terrain from a
## DEM. Higher = smoother slopes but more vertices. Ignored when terrain is flat.
@export var terrain_subdivisions: int = 16

var _osm_data: OSMParser.OSMData = null
var _spatial_index: Dictionary = {}   # Vector2i tile_key -> { ways: [], nodes: [], relations: [] }
var _loaded_tiles: Dictionary = {}    # Vector2i tile_key -> Node3D (tile root)
var _current_tile: Vector2i = Vector2i(999999, 999999)

var _way_builder: OSMWayBuilder = null
var _infrastructure_builder: OSMInfrastructureBuilder = null
var _building_builder: OSMBuildingBuilder = null
var _asset_placer: OSMAssetPlacer = null
var _relation_builder: OSMRelationBuilder = null

## Ordered way-feature handlers. Dispatch is first-match-wins, so this order
## encodes the precedence the old if-elif chain relied on:
##   - power_line / gantry before area  (closed-ring features must claim their
##     ways before the generic closed-ring AreaHandler does)
##   - parking before area              (dedicated styling/naming)
## Adding a feature type = add a handler file and one entry here.
var _way_handlers: Array[OSMWayHandler] = []

func _ready() -> void:
	_way_builder = OSMWayBuilder.new()
	_infrastructure_builder = OSMInfrastructureBuilder.new()
	_building_builder = OSMBuildingBuilder.new()
	_asset_placer = OSMAssetPlacer.new()
	_relation_builder = OSMRelationBuilder.new()

	_way_handlers = [
		RoadHandler.new(),
		RailwayHandler.new(),
		PowerLineHandler.new(),
		GantryHandler.new(),
		WaterwayHandler.new(),
		BuildingHandler.new(),
		BarrierHandler.new(),
		ParkingHandler.new(),
		AreaHandler.new(),
	]

	_load_osm_data()

func _load_osm_data() -> void:
	print("OSMTileManager: Loading OSM data from %s" % osm_file_path)
	_osm_data = OSMParser.parse_file(osm_file_path)
	if _osm_data == null:
		push_error("OSMTileManager: Failed to load OSM data")
		return
	_build_spatial_index()
	# Pass terrain parameters to builders for draped meshes and subdivided ribbons.
	if _has_terrain():
		var grid_step := tile_size / float(max(1, terrain_subdivisions))
		_relation_builder.height_provider = _osm_data.height_provider
		_relation_builder.terrain_grid_step = grid_step
		_way_builder.height_provider = _osm_data.height_provider
		_way_builder.terrain_grid_step = grid_step
	print("OSMTileManager: Spatial index built, ready for tile loading")
	data_loaded.emit(_osm_data)

func _build_spatial_index() -> void:
	_spatial_index.clear()

	# Index standalone nodes (nodes with tags that aren't just part of ways)
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
		tile_loaded.emit(tkey)
		return

	var bucket: Dictionary = _spatial_index[tkey]
	var tile_root := Node3D.new()
	tile_root.name = "Tile_%d_%d" % [tkey.x, tkey.y]
	add_child(tile_root)

	# Check whether the tile is fully covered by an area polygon. If so, skip
	# the terrain ground mesh (the draped area renders on top anyway and the
	# terrain underneath is invisible). This saves vertices and avoids z-fighting.
	var tile_covered := false
	if _has_terrain():
		var grid_step := tile_size / float(max(1, terrain_subdivisions))
		var origin_x := float(tkey.x) * tile_size
		var origin_z := float(tkey.y) * tile_size
		for way: OSMParser.OSMWay in bucket["ways"]:
			if AreaHandler.is_area(way) or ParkingHandler.is_parking(way):
				var pts := PolygonUtils.way_to_points(way.node_ids, _osm_data.nodes)
				if pts.size() >= 3 and PolygonUtils.polygon_covers_tile(
						pts, origin_x, origin_z, tile_size, grid_step):
					tile_covered = true
					break
		# Also check multipolygon area relations.
		if not tile_covered:
			for rel: OSMParser.OSMRelation in bucket["relations"]:
				if rel.tags.get("type", "") != "multipolygon":
					continue
				if not (rel.tags.has("landuse") or rel.tags.has("natural") or rel.tags.has("leisure")):
					continue
				for member: Dictionary in rel.members:
					if member["type"] != "way" or member["role"] != "outer":
						continue
					var way_id: int = member["ref"]
					if not _osm_data.ways.has(way_id):
						continue
					var pts := PolygonUtils.way_to_points(
						_osm_data.ways[way_id].node_ids, _osm_data.nodes)
					if pts.size() >= 3 and PolygonUtils.polygon_covers_tile(
							pts, origin_x, origin_z, tile_size, grid_step):
						tile_covered = true
						break
				if tile_covered:
					break

	# Build ground plane for the tile. When fully covered by an area polygon the
	# visible mesh is redundant (the draped area sits on top), but the physics
	# collider is still needed so the car doesn't fall through.
	_build_ground(tile_root, tkey, tile_covered)

	# Collect building:part ways and determine which building outlines to suppress
	var building_part_ways: Array[OSMParser.OSMWay] = []
	var suppressed_building_ids: Dictionary = {}  # building way IDs to skip 3D rendering

	for way: OSMParser.OSMWay in bucket["ways"]:
		if _is_building_part(way):
			building_part_ways.append(way)

	if building_part_ways.size() > 0:
		# For each building:part, find the parent building=* outline that contains it
		for part: OSMParser.OSMWay in building_part_ways:
			var part_points := PolygonUtils.way_to_points(part.node_ids, _osm_data.nodes)
			if part_points.size() < 3:
				continue
			var part_centroid := PolygonUtils.polygon_centroid(part_points)
			for way: OSMParser.OSMWay in bucket["ways"]:
				if not way.tags.has("building") or way.tags.has("building:part"):
					continue
				var bld_points := PolygonUtils.way_to_points(way.node_ids, _osm_data.nodes)
				if bld_points.size() < 3:
					continue
				if _point_in_polygon_xz(part_centroid, bld_points):
					suppressed_building_ids[way.id] = true

	# Process ways (roads, buildings from ways, etc.) via the handler registry.
	# Each way is offered to handlers in priority order; the first match builds
	# it. This replaces the central if-elif dispatch — feature-specific logic now
	# lives in scripts/handlers/*.gd (see _way_handlers).
	var ctx := _make_tile_context(tkey, suppressed_building_ids)
	var processed_way_ids := {}
	for way: OSMParser.OSMWay in bucket["ways"]:
		if processed_way_ids.has(way.id):
			continue
		processed_way_ids[way.id] = true

		var handled := false
		for handler: OSMWayHandler in _way_handlers:
			if handler.matches(way, ctx):
				var node := handler.build(way, ctx)
				if node != null:
					tile_root.add_child(node)
				handled = true
				break
		if not handled and not _is_ignorable_way(way):
			print_debug("Skipping way with tags", way.tags)

	# Render building:part ways as 3D buildings
	for part: OSMParser.OSMWay in building_part_ways:
		if processed_way_ids.has(part.id):
			continue
		processed_way_ids[part.id] = true
		var mesh_instance := _building_builder.build_building_from_way(part, _osm_data)
		if mesh_instance != null:
			tile_root.add_child(mesh_instance)

	# Process standalone nodes (traffic lights, trees, etc.).
	# Placeholder-box assets are merged into MultiMeshInstance3D batches inside
	# the placer; scene assets are still instanced individually.
	var assets_root := _asset_placer.place_assets_batched(bucket["nodes"])
	if assets_root != null:
		tile_root.add_child(assets_root)

	# Process relations (multipolygon buildings, etc.)
	_relation_builder.tile_clip_rect = _tile_clip_rect(tkey) as Variant
	var processed_rel_ids := {}
	for rel: OSMParser.OSMRelation in bucket["relations"]:
		if processed_rel_ids.has(rel.id):
			continue
		processed_rel_ids[rel.id] = true
		var rel_node := _relation_builder.build_relation(rel, _osm_data)
		if rel_node != null:
			tile_root.add_child(rel_node)

	_loaded_tiles[tkey] = tile_root
	tile_loaded.emit(tkey)

## Build the per-tile context handed to every way handler. Bundles the shared
## builders and tile parameters so handler build() signatures stay uniform.
func _make_tile_context(tkey: Vector2i, suppressed_building_ids: Dictionary) -> OSMTileContext:
	var ctx := OSMTileContext.new()
	ctx.osm_data = _osm_data
	ctx.tile_key = tkey
	ctx.tile_size = tile_size
	ctx.has_terrain = _has_terrain()
	ctx.grid_step = tile_size / float(max(1, terrain_subdivisions)) if ctx.has_terrain else 0.0
	ctx.tile_clip = _tile_clip_rect(tkey) if ctx.has_terrain else null
	ctx.suppressed_building_ids = suppressed_building_ids
	ctx.way_builder = _way_builder
	ctx.infrastructure_builder = _infrastructure_builder
	ctx.building_builder = _building_builder
	ctx.asset_placer = _asset_placer
	return ctx

func _unload_tile(tkey: Vector2i) -> void:
	var tile_node: Node3D = _loaded_tiles[tkey]
	if tile_node != null:
		tile_node.queue_free()
	_loaded_tiles.erase(tkey)
	tile_unloaded.emit(tkey)


## Number of tiles currently kept in memory (including empty placeholders).
func get_loaded_tile_count() -> int:
	return _loaded_tiles.size()


## Returns the parsed OSM data, or null if it has not loaded yet.
func get_osm_data() -> OSMParser.OSMData:
	return _osm_data


## Terrain elevation (meters) at a world XZ position, or 0.0 when the world is
## flat / not yet loaded. Used by spawn logic to place the car on the ground.
func get_terrain_height(world_pos: Vector3) -> float:
	if not _has_terrain():
		return 0.0
	return _osm_data.height_provider.sample_local_xz(world_pos.x, world_pos.z)


## Eagerly load the tiles around a world position without waiting for the camera
## to drift into them. Returns true once at least the centering tile is present.
## Spawn logic calls this so a ground collider exists before the car is unfrozen,
## which is what prevents the car free-falling through a not-yet-streamed world.
func ensure_tiles_around(world_pos: Vector3) -> bool:
	if _osm_data == null:
		return false
	_current_tile = _pos_to_tile(world_pos)
	_update_tiles()
	return true

func _has_terrain() -> bool:
	return _osm_data != null \
		and _osm_data.height_provider != null \
		and _osm_data.height_provider.is_ready()

func _build_ground(parent: Node3D, tkey: Vector2i, skip_visual: bool = false) -> void:
	if _has_terrain():
		_build_terrain_ground(parent, tkey, skip_visual)
	else:
		_build_flat_ground(parent, tkey)

## Flat fallback ground (no DEM): a single thin box collider + plane mesh.
func _build_flat_ground(parent: Node3D, tkey: Vector2i) -> void:
	var ground_body := StaticBody3D.new()
	ground_body.name = "Ground"
	ground_body.position = Vector3(
		(tkey.x + 0.5) * tile_size,
		-0.05,
		(tkey.y + 0.5) * tile_size
	)

	var ground := MeshInstance3D.new()
	ground.name = "GroundMesh"
	var plane := PlaneMesh.new()
	plane.size = Vector2(tile_size, tile_size)
	ground.mesh = plane

	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.35, 0.55, 0.25)  # grass green
	ground.material_override = mat
	ground_body.add_child(ground)

	var col_shape := CollisionShape3D.new()
	col_shape.name = "GroundCollision"
	var box := BoxShape3D.new()
	box.size = Vector3(tile_size, 0.1, tile_size)
	col_shape.shape = box
	ground_body.add_child(col_shape)

	parent.add_child(ground_body)

## DEM-displaced ground: a subdivided grid sampled against the HeightProvider,
## with a trimesh collider matching the visible surface so the car drives on
## the real terrain. Vertices are built in world space (mesh at origin) so the
## sampled heights and the OSM geometry share one coordinate frame.
func _build_terrain_ground(parent: Node3D, tkey: Vector2i, skip_visual: bool = false) -> void:
	var hp := _osm_data.height_provider
	var subs: int = max(1, terrain_subdivisions)
	var origin_x := tkey.x * tile_size
	var origin_z := tkey.y * tile_size
	var step := tile_size / float(subs)

	# Precompute the grid of heights so each interior vertex is sampled once.
	var verts: Array[Vector3] = []
	verts.resize((subs + 1) * (subs + 1))
	for gz: int in range(subs + 1):
		for gx: int in range(subs + 1):
			var wx := origin_x + float(gx) * step
			var wz := origin_z + float(gz) * step
			var wy := hp.sample_local_xz(wx, wz)
			verts[gz * (subs + 1) + gx] = Vector3(wx, wy, wz)

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.35, 0.55, 0.25)  # grass green
	st.set_material(mat)

	for gz: int in range(subs):
		for gx: int in range(subs):
			var i00: int = gz * (subs + 1) + gx
			var i10: int = i00 + 1
			var i01: int = (gz + 1) * (subs + 1) + gx
			var i11: int = i01 + 1
			# Two triangles per cell, wound so the front face points up (+Y).
			# Godot uses clockwise winding for front faces when viewed against the
			# normal; the reversed vertex order here keeps the grass visible from
			# above instead of being backface-culled.
			_add_terrain_tri(st, verts[i00], verts[i11], verts[i01])
			_add_terrain_tri(st, verts[i00], verts[i10], verts[i11])

	st.generate_normals()
	var mesh := st.commit()

	var ground_body := StaticBody3D.new()
	ground_body.name = "Ground"

	# When the tile is fully covered by an area polygon, the visible terrain is
	# redundant (it sits underneath the opaque draped area mesh). Skip the visual
	# mesh to save draw calls and avoid z-fighting, but keep the collider.
	if not skip_visual:
		var ground := MeshInstance3D.new()
		ground.name = "GroundMesh"
		ground.mesh = mesh
		ground_body.add_child(ground)

	var col_shape := CollisionShape3D.new()
	col_shape.name = "GroundCollision"
	# create_trimesh_shape() builds a ONE-SIDED concave collider; bodies approach
	# from the back of the triangle winding pass straight through. Terrain must be
	# collidable from both sides (and our triangle winding is not guaranteed to
	# face up everywhere), so enable backface collision.
	var tri_shape: ConcavePolygonShape3D = mesh.create_trimesh_shape()
	tri_shape.backface_collision = true
	col_shape.shape = tri_shape
	ground_body.add_child(col_shape)

	parent.add_child(ground_body)

func _add_terrain_tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3) -> void:
	st.add_vertex(a)
	st.add_vertex(b)
	st.add_vertex(c)

## building:part footprints are rendered in a dedicated pass (they bypass the
## outline-suppression test), so this predicate stays on the manager rather than
## becoming a way handler.
func _is_building_part(way: OSMParser.OSMWay) -> bool:
	return way.tags.has("building:part")

## Ways we deliberately do not render: untagged ring members consumed by their
## parent relation, explicitly removed features, and abstract man_made outlines
## that carry no usable surface geometry. Returning true suppresses the
## "Skipping way" debug noise for these expected cases.
## OSM "lifecycle" prefixes mark features that are not currently present on the
## ground (disused, abandoned, planned, etc.). Ways tagged only under one of
## these namespaces have no renderable present-day geometry.
const _LIFECYCLE_PREFIXES := [
	"removed:", "disused:", "abandoned:", "razed:", "demolished:",
	"destroyed:", "construction:", "proposed:", "planned:", "was:",
]
func _is_ignorable_way(way: OSMParser.OSMWay) -> bool:
	if way.tags.is_empty():
		return true
	for key: String in way.tags:
		for prefix: String in _LIFECYCLE_PREFIXES:
			if key.begins_with(prefix):
				return true
	# Administrative / political boundaries are abstract lines, not features.
	if way.tags.has("boundary"):
		return true
	# A bare "area=yes/no" with no feature tag carries no surface to render.
	if way.tags.size() == 1 and way.tags.has("area"):
		return true
	# Abstract structural outlines without their own renderable footprint.
	var man_made: String = way.tags.get("man_made", "")
	if man_made == "bridge" or man_made == "embankment":
		return true
	# Bus/transport station outlines are represented elsewhere (nodes/areas).
	if way.tags.get("public_transport", "") == "station":
		return true
	if way.tags.get("amenity", "") == "bus_station":
		return true
	# Underground waterways (culverts/negative layer) are intentionally not drawn
	# on the surface; suppress their skip noise.
	if way.tags.has("waterway"):
		if way.tags.get("tunnel", "") != "" or way.tags.has("culvert") \
				or way.tags.get("layer", "0").to_int() < 0:
			return true
	return false

func _point_in_polygon_xz(point: Vector3, polygon: PackedVector3Array) -> bool:
	var inside := false
	var n := polygon.size()
	var j := n - 1
	for i: int in range(n):
		var pi := polygon[i]
		var pj := polygon[j]
		if ((pi.z > point.z) != (pj.z > point.z)) and \
				(point.x < (pj.x - pi.x) * (point.z - pi.z) / (pj.z - pi.z) + pi.x):
			inside = not inside
		j = i
	return inside

## Return [min_x, max_x, min_z, max_z] for a tile key.
func _tile_clip_rect(tkey: Vector2i) -> Array[float]:
	var ox := float(tkey.x) * tile_size
	var oz := float(tkey.y) * tile_size
	return [ox, ox + tile_size, oz, oz + tile_size]
