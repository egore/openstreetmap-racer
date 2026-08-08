class_name OSMTileManager
extends Node3D

const RoadNetworkContextScript := preload("res://scripts/road_network_context.gd")
const RoadJunctionSolverScript := preload("res://scripts/road_junction_solver.gd")
const OSMJunctionBuilderScript := preload("res://scripts/osm_junction_builder.gd")
const RoadProfileScript := preload("res://scripts/road_profile.gd")

## Manages a grid of tiles around the camera. Loads/unloads tiles dynamically.

# Preloaded so the InMemory/Disk implementations resolve even before Godot's
# global class cache is populated (headless test discovery can race the
# class_name registration otherwise).
const OSMTileSourceScript := preload("res://scripts/osm_tile_source.gd")
# Preloaded (not referenced by bare class_name) so it resolves during headless
# test discovery regardless of class_name cache order.
const FrameTracerScript := preload("res://scripts/frame_tracer.gd")
# The async streaming state machine (parse queue → instance queue → feature
# queue). Owned by this manager but kept in its own file so the manager stays
# focused on grid math, OSM semantics, and scene-tree building. Preloaded for the
# same headless-discovery reason as the sources above.
const TileStreamingPipelineScript := preload("res://scripts/tile_streaming_pipeline.gd")
# Procedural grass/soil ground shader (world-space noise; no textures). One
# shared material serves every ground tile — the pattern is driven by world XZ
# so tiles need no per-instance state and it tiles seamlessly across borders.
const TerrainShader: Shader = preload("res://scripts/shaders/terrain.gdshader")

## Emitted once the OSM file has been parsed and the spatial index is ready.
signal data_loaded(osm_data: OSMParser.OSMData)
## Emitted whenever a tile's geometry has been instanced into the scene.
signal tile_loaded(tile_key: Vector2i)
## Emitted whenever a tile is freed.
signal tile_unloaded(tile_key: Vector2i)

@export var osm_file_path: String = "res://data/map.osm"
## Directory of a pre-baked streaming tile cache (tools/bake_osm_tiles.py). When
## it contains a manifest.json the manager streams from disk (country-scale);
## otherwise it falls back to loading osm_file_path whole (small-map path).
@export var tile_cache_dir: String = "res://data/tiles"
@export var tile_size: float = 200.0  # meters per tile edge (disk cache overrides)
@export var load_radius: int = 2      # tiles in each direction to keep loaded
@export var unload_radius: int = 3    # tiles beyond this are freed
## Max wall-clock time (milliseconds) spent instancing streamed tiles into the
## scene tree per frame. Parsing happens off-thread; instancing must stay on the
## main thread (Godot's scene tree is not thread-safe), so it's spread across
## frames under this budget to avoid a hitch when several tiles arrive at once.
## At least one tile is always drained per frame so a large budget-buster can't
## stall the queue forever.
@export var instance_budget_ms: float = 4.0
## Number of grid cells per tile edge when building displaced terrain from a
## DEM. Higher = smoother slopes but more vertices. Ignored when terrain is flat.
## At 32 (cell ≈ tile_size/32 ≈ 6 m for a 200 m tile) the triangulated surface
## stays close to the underlying bilinear DEM, so the mesh-draped features
## (roads/areas) and the visible terrain agree to within a few centimetres.
@export var terrain_subdivisions: int = 32
## The world's street-lamp light controller. Wired in the scene so the asset
## placer can register each tile's lamps with it (and the manager can drop them
## on unload). Optional: when unset, street lamps render as unlit poles.
@export var street_lamp_lights_path: NodePath

# Backing store for tiles: either the classic parse-everything InMemoryTileSource
# or a streaming DiskTileSource. The manager no longer owns a global OSMData or
# spatial index — it asks the source for each tile's self-contained data.
var _tile_source: OSMTileSourceScript = null
var _height_provider: HeightProvider = null   # map-wide; from the tile source
## Lazily-built shared ground material (TerrainShader). One instance is reused by
## every ground tile; see _get_terrain_material.
var _terrain_material: ShaderMaterial = null
var _loaded_tiles: Dictionary = {}    # Vector2i tile_key -> Node3D (tile root)
var _current_tile: Vector2i = Vector2i(999999, 999999)

# ─── Async tile streaming ─────────────────────────────────────────────────────
# The parse/instance/feature queue state machine lives in TileStreamingPipeline;
# the manager keeps only the scene-tree work it drives (see _ready for wiring).
# A tile crossing can request several new tiles at once. Parsing each (disk read
# + XML parse) on the main thread is what froze the frame, so the pipeline pushes
# parsing to WorkerThreadPool tasks and instances the results on the main thread
# under a per-frame budget. Feature building (meshes + colliders, main-thread
# only) is likewise spread across frames.
# Typed via the preloaded const (not the bare class_name) so it resolves during
# headless test discovery regardless of class_name cache order.
var _pipeline: TileStreamingPipelineScript = null

# Whether the streaming pipeline dispatches parses to worker threads. Headless
# tests set this to false BEFORE add_child (i.e. before _ready builds the
# pipeline) for deterministic single-stepped behaviour; _ready copies it in.
var _use_threads: bool = true

## A single feature build takes longer than this (ms) → warn once. One monster
## feature can still overshoot a frame; this surfaces it rather than hiding it.
const _FEATURE_SLOW_MS := 30.0

# ── Test-facing views onto the pipeline's queues ──────────────────────────────
# The streaming state now lives in _pipeline; these accessors preserve the
# member names the tile-streaming tests read directly (mgr._pending_tiles, etc.)
# so the split stays behaviour-preserving. They return the pipeline's live
# containers by reference — reads see real state, and .has()/.size() work as
# before. Guard against the pre-_ready window (pipeline not built yet).
var _pending_tiles: Dictionary:
	get: return _pipeline._pending_tiles if _pipeline != null else {}
var _instance_queue: Array:
	get: return _pipeline._instance_queue if _pipeline != null else []
var _feature_queue: Array:
	get: return _pipeline._feature_queue if _pipeline != null else []

## One deferred feature-build unit for a tile. `kind` selects the builder; the
## payload fields carry exactly what that builder needs. Kept as a tiny data
## holder so the drain loop stays a simple dispatch.
class FeatureWork extends RefCounted:
	enum Kind { WAY, BUILDING_PART, ASSETS, RELATION, JUNCTION }
	var kind: int
	var tile_key: Vector2i
	var tile_root: Node3D                 # parent to add the built node under
	var osm_data: OSMParser.OSMData
	var way: OSMParser.OSMWay = null      # WAY / BUILDING_PART
	var relation: OSMParser.OSMRelation = null  # RELATION
	var nodes: Array = []                 # ASSETS
	var ctx: OSMTileContext = null        # WAY (handler dispatch context)
	## JUNCTION: the solved intersection to build a cap for.
	var junction: RoadJunctionSolverScript.Junction = null
	## JUNCTION: way_id -> {left,right} kerb flags for the arms meeting here.
	var sidewalks: Dictionary = {}

var _way_builder: OSMWayBuilder = null
var _junction_builder: OSMJunctionBuilderScript = null
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
	_junction_builder = OSMJunctionBuilderScript.new()
	_infrastructure_builder = OSMInfrastructureBuilder.new()
	_building_builder = OSMBuildingBuilder.new()
	_asset_placer = OSMAssetPlacer.new()
	# Hand the asset placer the street-lamp controller so the lamps it builds are
	# registered for day/night switching. Resolved from a NodePath (not a typed
	# export) so the .tscn wires it reliably; left null when the scene has no
	# controller, in which case lamps stay unlit poles.
	_asset_placer.lamp_lights = get_node_or_null(street_lamp_lights_path) as StreetLampLights
	_relation_builder = OSMRelationBuilder.new()

	# Build the streaming pipeline and inject the main-thread work it drives.
	# _use_threads is read here (not before) so tests can flip it pre-_ready.
	_pipeline = TileStreamingPipelineScript.new()
	_pipeline.use_threads = _use_threads
	_pipeline.instance_budget_ms = instance_budget_ms
	_pipeline.configure(
		_parse_tile_with_junctions,
		func(tkey: Vector2i, bucket: Variant) -> void: _instance_tile(tkey, bucket, true),
		_build_feature,
		func(tkey: Vector2i) -> bool: return _loaded_tiles.has(tkey),
		_tile_in_range,
		FrameTracerScript.record_usec)

	_way_handlers = [
		RoadHandler.new(),
		RailwayHandler.new(),
		PowerLineHandler.new(),
		GantryHandler.new(),
		WaterwayHandler.new(),
		BuildingHandler.new(),
		BarrierHandler.new(),
		PlatformHandler.new(),
		ParkingHandler.new(),
		AreaHandler.new(),
		SurfaceHandler.new(),
	]

	_load_osm_data()

## Parse a tile AND solve its road junctions, off the main thread.
##
## Junction solving is pure computation over OSM data (no scene tree), so it
## belongs here in the worker-thread parse phase rather than in the main-thread
## instancing phase where it would eat the frame budget. The solved network is
## attached to the bucket for _instance_tile to hand to the way builder.
##
## The halo (this tile plus its eight neighbours) is what makes tiles agree on
## where to cut a street that crosses their shared border — see
## OSMTileSource.collect_road_halo and RoadNetworkContextScript.
func _parse_tile_with_junctions(tkey: Vector2i) -> Variant:
	var bucket: Dictionary = _tile_source.parse_tile(tkey)
	if bucket.is_empty():
		return bucket
	bucket["road_network"] = _solve_tile_junctions(tkey, bucket)
	return bucket


## Solve the road junctions relevant to one tile. Returns null when the tile has
## no roads, in which case the builder falls back to untrimmed ribbons.
func _solve_tile_junctions(
		tkey: Vector2i, bucket: Dictionary) -> RoadNetworkContextScript:
	var own_ways: Array = []
	for way: OSMParser.OSMWay in bucket["ways"]:
		if way.tags.has("highway"):
			own_ways.append(way)
	if own_ways.is_empty():
		return null

	var halo := _tile_source.collect_road_halo(tkey)
	var halo_ways: Array = halo["ways"]
	var nodes: Dictionary = halo["nodes"]
	# Fall back to the tile's own data if the halo came back empty (single-tile
	# worlds, or a source that doesn't index neighbours).
	if halo_ways.is_empty():
		halo_ways = own_ways
		nodes = (bucket["osm_data"] as OSMParser.OSMData).nodes

	return RoadNetworkContextScript.build(
		own_ways, halo_ways, nodes, _tile_clip_rect(tkey))


## Pick a tile source and get it ready. A baked streaming cache
## (tile_cache_dir/manifest.json) wins; otherwise fall back to loading
## osm_file_path whole. Either way the manager then talks only to _tile_source.
func _load_osm_data() -> void:
	_tile_source = _create_tile_source()
	if _tile_source == null or not _tile_source.is_ready():
		push_error("OSMTileManager: Failed to load OSM data")
		return

	# The disk cache is authoritative about tile_size (baked into it); adopt it
	# so the manager's tiling math matches the files on disk.
	tile_size = _tile_source.get_tile_size()
	_height_provider = _tile_source.get_height_provider()

	# Where in the world this map is, which decides which half of the carriageway
	# an approach's markings span. Junction caps are built here rather than by
	# OSMWayBuilder, so the junction builder has to be told separately.
	_junction_builder.region = RoadRegion.for_coordinates(
		_tile_source.get_center_lat(), _tile_source.get_center_lon())

	# Pass terrain parameters to builders for draped meshes and subdivided ribbons.
	if _has_terrain():
		var grid_step := tile_size / float(max(1, terrain_subdivisions))
		# Bind the height field to the exact terrain-mesh grid so draped features
		# can sample the triangulated surface (sample_mesh_height) instead of the
		# smoother raw bilinear field and thus sit flush on the built terrain.
		_height_provider.set_mesh_grid(tile_size, terrain_subdivisions)
		_relation_builder.height_provider = _height_provider
		_relation_builder.terrain_grid_step = grid_step
		_way_builder.height_provider = _height_provider
		_way_builder.terrain_grid_step = grid_step
		_junction_builder.height_provider = _height_provider
		_junction_builder.terrain_grid_step = grid_step
	print("OSMTileManager: Tile source ready, ready for tile loading")
	data_loaded.emit(get_osm_data())

## Prefer the streaming disk cache when a manifest is present, else the classic
## in-memory parse of a single .osm.
func _create_tile_source() -> OSMTileSourceScript:
	var manifest := "%s/manifest.json" % tile_cache_dir.trim_suffix("/")
	if FileAccess.file_exists(manifest):
		print("OSMTileManager: Streaming from tile cache %s" % tile_cache_dir)
		return OSMTileSourceScript.DiskTileSource.new(tile_cache_dir)
	print("OSMTileManager: Loading OSM data from %s" % osm_file_path)
	return OSMTileSourceScript.InMemoryTileSource.new(osm_file_path, tile_size)

func _pos_to_tile(pos: Vector3) -> Vector2i:
	return Vector2i(
		floori(pos.x / tile_size),
		floori(pos.z / tile_size)
	)

func _process(_delta: float) -> void:
	if _tile_source == null:
		return

	# Drain finished parse tasks and instance a budgeted slice of them every
	# frame, regardless of whether the camera moved — tiles requested on an
	# earlier frame keep flowing into the scene without a hitch. The exported
	# budget can be tuned at runtime, so push it into the pipeline each frame.
	_pipeline.instance_budget_ms = instance_budget_ms
	_pipeline.collect_finished_parses()
	_pipeline.drain()

	var camera := get_viewport().get_camera_3d()
	if camera == null:
		return

	var cam_tile := _pos_to_tile(camera.global_position)
	if cam_tile == _current_tile:
		return

	_current_tile = cam_tile
	_update_tiles()

## Request/free tiles for the current camera tile. Loading is asynchronous: each
## needed tile is handed to a WorkerThreadPool parse task (see _request_tile);
## instancing happens later in _process under the frame budget.
func _update_tiles() -> void:
	# Request tiles within radius (async parse; instanced later).
	for dx: int in range(-load_radius, load_radius + 1):
		for dz: int in range(-load_radius, load_radius + 1):
			var tkey := Vector2i(_current_tile.x + dx, _current_tile.y + dz)
			_request_tile(tkey)

	# Unload tiles outside unload_radius
	var to_unload: Array[Vector2i] = []
	for tkey: Vector2i in _loaded_tiles:
		var dist: int = max(abs(tkey.x - _current_tile.x), abs(tkey.y - _current_tile.y))
		if dist > unload_radius:
			to_unload.append(tkey)

	for tkey: Vector2i in to_unload:
		_unload_tile(tkey)

## Ask the streaming pipeline to (asynchronously) load a tile. Thin forwarder:
## the manager decides WHICH tiles to request (see _update_tiles); the pipeline
## owns HOW they are parsed and queued. Kept as a method (not an inlined
## _pipeline.request_tile call) so the tile-streaming tests can drive one tile at
## a time through the manager's surface.
func _request_tile(tkey: Vector2i) -> void:
	_pipeline.request_tile(tkey)

## Main-thread: instance the pipeline's ready tiles + queued features under the
## per-frame budget. Thin forwarder preserved for the tile-streaming tests, which
## single-step the pipeline through the manager.
func _drain_instance_queue() -> void:
	_pipeline.instance_budget_ms = instance_budget_ms
	_pipeline.drain()

## True when a tile is still within the keep radius of the current camera tile.
## Used by the pipeline to drop tiles that drifted out of range while queued.
func _tile_in_range(tkey: Vector2i) -> bool:
	var dist: int = max(abs(tkey.x - _current_tile.x), abs(tkey.y - _current_tile.y))
	return dist <= unload_radius

## Synchronously parse AND instance one tile on the calling (main) thread. Used
## by ensure_tiles_around at spawn, where a collider must exist THIS frame before
## the car is dropped — there's no time to wait for a worker task to finish.
##
## Junctions are solved here too (not just on the streaming path), or the tiles
## the player spawns onto would be the only ones in the world rendering
## untrimmed, cap-less roads. It costs a few ms on top of the parse, which is
## acceptable for the handful of spawn tiles and only happens once.
func _load_tile(tkey: Vector2i) -> void:
	if _loaded_tiles.has(tkey):
		return
	# Cancel any async request for this tile so it isn't instanced twice.
	_pipeline.cancel_pending(tkey)
	var bucket := _tile_source.load_tile(tkey)
	if not bucket.is_empty():
		bucket["road_network"] = _solve_tile_junctions(tkey, bucket)
	_instance_tile(tkey, bucket)

## Instance a parsed tile bucket into the scene tree. MAIN THREAD ONLY (creates
## nodes, adds physics bodies, emits signals). Split out of the old _load_tile so
## the parse half can run off-thread while this half stays budgeted on the main
## thread.
## Instance a tile. The tile root + ground collider are built immediately (the
## car needs a drivable surface the moment a tile is "loaded"), then the tile's
## FEATURES are either built inline (defer=false, e.g. spawn) or enqueued as
## small per-feature work items drained across frames (defer=true, streaming).
##
## Deferring is what removes the hard freeze: a dense tile's 100-900 ms of
## feature building becomes a few ms per frame spread over several frames.
func _instance_tile(tkey: Vector2i, bucket: Dictionary, defer: bool = false) -> void:
	# Every in-range tile gets a root + ground collider, even when it carries no
	# OSM features. On a streamed country the cache is sparse — tiles between
	# baked features have no file (bucket is empty) — but the car still needs a
	# surface to drive on there, or it falls through the world.
	var tile_root := Node3D.new()
	tile_root.name = "Tile_%d_%d" % [tkey.x, tkey.y]
	add_child(tile_root)

	if bucket.is_empty():
		# No features here: just ground (terrain or flat), then done.
		_build_ground(tile_root, tkey, false)
		_loaded_tiles[tkey] = tile_root
		tile_loaded.emit(tkey)
		return

	var osm_data: OSMParser.OSMData = bucket["osm_data"]

	# ── Prep (cheap, always immediate): coverage check, ground, suppression ──
	var tile_covered := _tile_fully_covered(tkey, bucket, osm_data)

	# Build ground plane for the tile. When fully covered by an area polygon the
	# visible mesh is redundant (the draped area sits on top), but the physics
	# collider is still needed so the car doesn't fall through.
	_build_ground(tile_root, tkey, tile_covered)

	# The tile is "loaded" (surface exists) even though its features may still be
	# streaming in over the next frames. Record it now so streaming/unload logic
	# treats it as present and never re-requests it.
	_loaded_tiles[tkey] = tile_root

	var building_part_ways := _collect_building_part_ways(bucket, osm_data)
	var suppressed_building_ids := _collect_suppressed_buildings(
		building_part_ways, bucket, osm_data)
	var relation_way_ids := _collect_relation_way_ids(bucket["relations"], osm_data)
	var ctx := _make_tile_context(
		tkey, suppressed_building_ids, osm_data,
		bucket.get("road_network", null))

	# ── Feature building: inline (spawn) or queued (streaming) ──
	var items := _plan_tile_features(
		tkey, tile_root, osm_data, bucket, ctx, building_part_ways, relation_way_ids)
	if defer:
		_pipeline.enqueue_features(items)
	else:
		for item: FeatureWork in items:
			_build_feature(item)

	tile_loaded.emit(tkey)

## Assemble the ordered list of deferred feature-build items for a tile: ways
## (via the handler registry), building:part footprints, the standalone-asset
## batch, then relations — the same order the monolithic builder used.
func _plan_tile_features(
		tkey: Vector2i, tile_root: Node3D, osm_data: OSMParser.OSMData,
		bucket: Dictionary, ctx: OSMTileContext,
		building_part_ways: Array[OSMParser.OSMWay],
		relation_way_ids: Dictionary) -> Array[FeatureWork]:
	var items: Array[FeatureWork] = []
	var processed_way_ids := {}

	for way: OSMParser.OSMWay in bucket["ways"]:
		if processed_way_ids.has(way.id):
			continue
		if relation_way_ids.has(way.id):
			processed_way_ids[way.id] = true
			continue
		# building:part ways are built in their own dedicated pass below; don't
		# also queue them as a generic WAY (no way handler claims them, which
		# would otherwise emit a spurious "Skipping way" for every part). Leave
		# them unmarked here so the building_part loop still picks them up.
		if _is_building_part(way):
			continue
		processed_way_ids[way.id] = true
		var w := FeatureWork.new()
		w.kind = FeatureWork.Kind.WAY
		w.tile_key = tkey
		w.tile_root = tile_root
		w.osm_data = osm_data
		w.way = way
		w.ctx = ctx
		items.append(w)

	for part: OSMParser.OSMWay in building_part_ways:
		if processed_way_ids.has(part.id):
			continue
		processed_way_ids[part.id] = true
		var b := FeatureWork.new()
		b.kind = FeatureWork.Kind.BUILDING_PART
		b.tile_key = tkey
		b.tile_root = tile_root
		b.osm_data = osm_data
		b.way = part
		items.append(b)

	var a := FeatureWork.new()
	a.kind = FeatureWork.Kind.ASSETS
	a.tile_key = tkey
	a.tile_root = tile_root
	a.osm_data = osm_data
	a.nodes = bucket["nodes"]
	items.append(a)

	# Intersection caps for the junctions THIS tile owns. Queued after the ways
	# so a cap is built once its arms exist, and skipped entirely when the tile
	# owns none (the common case away from street grids).
	var network: RoadNetworkContextScript = bucket.get("road_network", null)
	if network != null:
		var sidewalks := _collect_arm_sidewalks(bucket)
		for junction: RoadJunctionSolverScript.Junction in network.owned_junctions():
			var jw := FeatureWork.new()
			jw.kind = FeatureWork.Kind.JUNCTION
			jw.tile_key = tkey
			jw.tile_root = tile_root
			jw.osm_data = osm_data
			jw.junction = junction
			jw.sidewalks = sidewalks
			items.append(jw)

	var processed_rel_ids := {}
	for rel: OSMParser.OSMRelation in bucket["relations"]:
		if processed_rel_ids.has(rel.id):
			continue
		processed_rel_ids[rel.id] = true
		var r := FeatureWork.new()
		r.kind = FeatureWork.Kind.RELATION
		r.tile_key = tkey
		r.tile_root = tile_root
		r.osm_data = osm_data
		r.relation = rel
		items.append(r)

	return items

## Build one queued feature into the scene tree. MAIN THREAD ONLY. A build slower
## than _FEATURE_SLOW_MS is logged as a pathological outlier so a monster feature
## (e.g. a huge multipolygon) can be found and guarded rather than silently
## freezing a frame.
func _build_feature(item: FeatureWork) -> void:
	# The tile may have been unloaded (camera drifted away) while this item waited
	# in the queue; its tile_root is then freed. Skip so we don't parent onto a
	# dead node.
	if not is_instance_valid(item.tile_root) or not _loaded_tiles.has(item.tile_key):
		return

	var t0 := Time.get_ticks_usec()
	match item.kind:
		FeatureWork.Kind.WAY:
			# Clip linear ways (road/waterway/railway ribbons) to this tile so a
			# way spanning many tiles only builds its in-tile portion here, not its
			# whole length in every tile. The builder reads tile_clip_rect; set it
			# per feature and clear it after so nothing else inherits it.
			_way_builder.tile_clip_rect = item.ctx.tile_clip
			_way_builder.network = item.ctx.road_network
			var handled := false
			for handler: OSMWayHandler in _way_handlers:
				if handler.matches(item.way, item.ctx):
					var node := handler.build(item.way, item.ctx)
					if node != null:
						item.tile_root.add_child(node)
					handled = true
					break
			_way_builder.tile_clip_rect = null
			_way_builder.network = null
			if not handled and not _is_ignorable_way(item.way):
				print_debug("Skipping way with tags", item.way.tags)
		FeatureWork.Kind.BUILDING_PART:
			var mi := _building_builder.build_building_from_way(item.way, item.osm_data)
			if mi != null:
				item.tile_root.add_child(mi)
		FeatureWork.Kind.ASSETS:
			var assets_root := _asset_placer.place_assets_batched(item.nodes)
			if assets_root != null:
				item.tile_root.add_child(assets_root)
		FeatureWork.Kind.JUNCTION:
			var jnode := _junction_builder.build_junction(
				item.junction, item.sidewalks)
			if jnode != null:
				# Junction surfaces are drivable road, so the surface detector
				# must find them alongside the ribbons.
				jnode.add_to_group(&"road_surface")
				item.tile_root.add_child(jnode)
		FeatureWork.Kind.RELATION:
			_relation_builder.tile_clip_rect = _tile_clip_rect(item.tile_key) as Variant
			var rel_node := _relation_builder.build_relation(item.relation, item.osm_data)
			if rel_node != null:
				item.tile_root.add_child(rel_node)

	var elapsed_us := Time.get_ticks_usec() - t0
	FrameTracerScript.record_usec("build_feature", elapsed_us)
	if elapsed_us >= int(_FEATURE_SLOW_MS * 1000.0):
		# Print (not push_warning) so it lands inline with the [trace] stream on
		# stdout — push_warning only reaches the debugger/error log. Gated on the
		# tracer so it's silent in normal play. Names the exact feature + tile so a
		# pathological way/relation can be found and guarded.
		if FrameTracerScript.is_enabled():
			print("[trace] SLOW feature %s took %.1f ms at tile %s" % [
				_feature_desc(item), elapsed_us / 1000.0, item.tile_key])

## Human-readable description of a feature work item for slow-build warnings.
func _feature_desc(item: FeatureWork) -> String:
	match item.kind:
		FeatureWork.Kind.WAY:
			return "way %d %s" % [item.way.id, item.way.tags]
		FeatureWork.Kind.BUILDING_PART:
			return "building:part %d" % item.way.id
		FeatureWork.Kind.ASSETS:
			return "assets(%d nodes)" % item.nodes.size()
		FeatureWork.Kind.RELATION:
			return "relation %d %s" % [item.relation.id, item.relation.tags]
	return "unknown"

## Kerb flags for every road way in a tile, as way_id -> {"left","right"}.
##
## The junction builder needs these to decide whether a corner between two arms
## should carry pavement: a kerb wrapping a corner whose roads have no sidewalks
## would appear out of nowhere. Collected once per tile rather than per junction
## because a way typically meets several of them.
func _collect_arm_sidewalks(bucket: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for way: OSMParser.OSMWay in bucket["ways"]:
		if way.tags.has("highway"):
			out[way.id] = RoadProfileScript.sidewalk_sides(way.tags)
	return out


## True when the tile is entirely under an area polygon (way or multipolygon
## relation), so the visible terrain mesh can be skipped (collider still built).
func _tile_fully_covered(
		tkey: Vector2i, bucket: Dictionary, osm_data: OSMParser.OSMData) -> bool:
	if not _has_terrain():
		return false
	var grid_step := tile_size / float(max(1, terrain_subdivisions))
	var origin_x := float(tkey.x) * tile_size
	var origin_z := float(tkey.y) * tile_size
	for way: OSMParser.OSMWay in bucket["ways"]:
		if AreaHandler.is_area(way) or ParkingHandler.is_parking(way):
			var pts := PolygonUtils.way_to_points(way.node_ids, osm_data.nodes)
			if pts.size() >= 3 and PolygonUtils.polygon_covers_tile(
					pts, origin_x, origin_z, tile_size, grid_step):
				return true
	for rel: OSMParser.OSMRelation in bucket["relations"]:
		if rel.tags.get("type", "") != "multipolygon":
			continue
		if not (rel.tags.has("landuse") or rel.tags.has("natural") or rel.tags.has("leisure")):
			continue
		for member: Dictionary in rel.members:
			if member["type"] != "way" or member["role"] != "outer":
				continue
			var way_id: int = member["ref"]
			if not osm_data.ways.has(way_id):
				continue
			var pts := PolygonUtils.way_to_points(
				osm_data.ways[way_id].node_ids, osm_data.nodes)
			if pts.size() >= 3 and PolygonUtils.polygon_covers_tile(
					pts, origin_x, origin_z, tile_size, grid_step):
				return true
	return false

## Ways in this tile tagged building:part (rendered in their own pass).
func _collect_building_part_ways(
		bucket: Dictionary, _osm_data: OSMParser.OSMData) -> Array[OSMParser.OSMWay]:
	var out: Array[OSMParser.OSMWay] = []
	for way: OSMParser.OSMWay in bucket["ways"]:
		if _is_building_part(way):
			out.append(way)
	return out

## building=* outline ways whose footprint contains a building:part, so the flat
## outline isn't drawn under the detailed part geometry.
func _collect_suppressed_buildings(
		building_part_ways: Array[OSMParser.OSMWay], bucket: Dictionary,
		osm_data: OSMParser.OSMData) -> Dictionary:
	var suppressed: Dictionary = {}
	if building_part_ways.is_empty():
		return suppressed
	for part: OSMParser.OSMWay in building_part_ways:
		var part_points := PolygonUtils.way_to_points(part.node_ids, osm_data.nodes)
		if part_points.size() < 3:
			continue
		var part_centroid := PolygonUtils.polygon_centroid(part_points)
		for way: OSMParser.OSMWay in bucket["ways"]:
			if not way.tags.has("building") or way.tags.has("building:part"):
				continue
			var bld_points := PolygonUtils.way_to_points(way.node_ids, osm_data.nodes)
			if bld_points.size() < 3:
				continue
			if _point_in_polygon_xz(part_centroid, bld_points):
				suppressed[way.id] = true
	return suppressed

## Build the per-tile context handed to every way handler. Bundles the shared
## builders and tile parameters so handler build() signatures stay uniform.
func _make_tile_context(
		tkey: Vector2i, suppressed_building_ids: Dictionary,
		osm_data: OSMParser.OSMData,
		road_network: RoadNetworkContextScript = null) -> OSMTileContext:
	var ctx := OSMTileContext.new()
	ctx.osm_data = osm_data
	ctx.tile_key = tkey
	ctx.tile_size = tile_size
	ctx.has_terrain = _has_terrain()
	ctx.grid_step = tile_size / float(max(1, terrain_subdivisions)) if ctx.has_terrain else 0.0
	ctx.tile_clip = (_tile_clip_rect(tkey) as Variant) if ctx.has_terrain else null
	ctx.suppressed_building_ids = suppressed_building_ids
	ctx.road_network = road_network
	ctx.way_builder = _way_builder
	ctx.infrastructure_builder = _infrastructure_builder
	ctx.building_builder = _building_builder
	ctx.asset_placer = _asset_placer
	return ctx

## Block until every in-flight parse task has finished before this node is torn
## down, then clear the streaming queues. A WorkerThreadPool task holds a bound
## reference into the pipeline; if the node freed while a task was still running,
## that task would call into a freed instance. The wait is bounded (a task only
## parses one tile) and only happens on scene exit.
func _exit_tree() -> void:
	if _pipeline != null:
		_pipeline.shutdown()

func _unload_tile(tkey: Vector2i) -> void:
	var tile_node: Node3D = _loaded_tiles[tkey]
	if tile_node != null:
		# Drop this tile's street lamps from the light controller before freeing
		# the node, so it never drives lights that are about to be torn down. The
		# lamps live under an "Assets" child (the key the placer registered), so
		# look it up rather than passing the tile root. Harmless no-op for tiles
		# with no lamps.
		if _asset_placer != null and _asset_placer.lamp_lights != null:
			var assets := tile_node.get_node_or_null("Assets")
			if assets != null:
				_asset_placer.lamp_lights.unregister_tile(assets)
		tile_node.queue_free()
	_loaded_tiles.erase(tkey)
	# Drop any still-queued feature items for this tile so we don't build onto a
	# freed root (the drain also guards defensively, but pruning keeps the queue
	# from filling with dead work as the camera sweeps across tiles).
	_pipeline.purge_features(func(item: FeatureWork) -> bool: return item.tile_key != tkey)
	tile_unloaded.emit(tkey)


## Number of tiles currently kept in memory (including empty placeholders).
func get_loaded_tile_count() -> int:
	return _loaded_tiles.size()


## Returns a representative OSM dataset, or null if not loaded yet. For the
## in-memory source this is the full map; for the streaming disk source it is a
## stub with center + height provider but empty feature dicts (see
## OSMTileSource.get_global_osm_data).
func get_osm_data() -> OSMParser.OSMData:
	return _tile_source.get_global_osm_data() if _tile_source != null else null


## Collect ways within `radius` meters of a world position, as
## [{ way, points }]. Backed by the same tile source the 3D world streams from,
## so the minimap and the world stay consistent (and disk tiles stream + cache
## once). Returns [] until the source is ready.
func collect_ways_near(center: Vector3, radius: float) -> Array:
	if _tile_source == null:
		return []
	return _tile_source.collect_ways_near(center, radius)


## Assemble a self-contained OSMData of the ways (and their nodes) within
## `radius` meters of a world position, from the same tile source the 3D world
## streams from. Traffic builds its road graph from this so it stays consistent
## with the rendered roads and streams a country region-by-region. Returns an
## empty OSMData until the source is ready.
## `yield_every` > 0 lets an off-main-thread caller (the traffic rebuild thread)
## ask the collect to yield the scheduler every N cold tile parses, so a fresh
## region's parse burst doesn't contend with the main thread's per-frame work.
func collect_osm_near(center: Vector3, radius: float, yield_every: int = 0) -> OSMParser.OSMData:
	if _tile_source == null:
		return OSMParser.OSMData.new()
	return _tile_source.collect_osm_near(center, radius, yield_every)


## True once a tile source is loaded and ready to be queried.
func is_data_ready() -> bool:
	return _tile_source != null and _tile_source.is_ready()


## Terrain elevation (meters) at a world XZ position, or 0.0 when the world is
## flat / not yet loaded. Used by spawn logic to place the car on the ground.
func get_terrain_height(world_pos: Vector3) -> float:
	if not _has_terrain():
		return 0.0
	return _height_provider.sample_local_xz(world_pos.x, world_pos.z)


## Forwards the debug-labels visibility flag to the asset placer so labels on
## newly streamed tiles respect the current setting. Already-placed labels are
## in the "debug_labels" scene-tree group; callers toggle those separately.
func set_show_debug_labels(enabled: bool) -> void:
	_asset_placer.show_debug_labels = enabled


## Eagerly load the tiles around a world position without waiting for the camera
## to drift into them. Returns true once at least the centering tile is present.
## Spawn logic calls this so a ground collider exists before the car is unfrozen,
## which is what prevents the car free-falling through a not-yet-streamed world.
##
## SYNCHRONOUS by design: unlike camera-driven streaming (which parses off-thread
## and instances over several frames), spawn cannot wait — the collider must
## exist THIS frame. So the tiles around the spawn point are parsed + instanced
## inline via _load_tile; the async queue continues to feed the outer ring.
func ensure_tiles_around(world_pos: Vector3) -> bool:
	if _tile_source == null:
		return false
	_current_tile = _pos_to_tile(world_pos)
	# Instance the in-range tiles synchronously so a ground collider is live now.
	for dx: int in range(-load_radius, load_radius + 1):
		for dz: int in range(-load_radius, load_radius + 1):
			_load_tile(Vector2i(_current_tile.x + dx, _current_tile.y + dz))
	return true

func _has_terrain() -> bool:
	return _height_provider != null and _height_provider.is_ready()

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

	ground.material_override = _get_terrain_material()
	ground_body.add_child(ground)

	var col_shape := CollisionShape3D.new()
	col_shape.name = "GroundCollision"
	var box := BoxShape3D.new()
	box.size = Vector3(tile_size, 0.1, tile_size)
	col_shape.shape = box
	ground_body.add_child(col_shape)

	parent.add_child(ground_body)

## Shared procedural ground material, built once on first use. Every ground tile
## (flat or DEM-displaced) reuses this one ShaderMaterial: the grass/soil detail
## is driven from world-space XZ inside the shader, so there is nothing per-tile
## to vary and one material keeps the draw-call state small.
func _get_terrain_material() -> ShaderMaterial:
	if _terrain_material == null:
		_terrain_material = ShaderMaterial.new()
		_terrain_material.shader = TerrainShader
	return _terrain_material


## DEM-displaced ground: a subdivided grid sampled against the HeightProvider,
## with a trimesh collider matching the visible surface so the car drives on
## the real terrain. Vertices are built in world space (mesh at origin) so the
## sampled heights and the OSM geometry share one coordinate frame.
func _build_terrain_ground(parent: Node3D, tkey: Vector2i, skip_visual: bool = false) -> void:
	var _trace := FrameTracerScript.scope("build_terrain_ground")
	var hp := _height_provider
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
	st.set_material(_get_terrain_material())

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

	# The trimesh collider (create_trimesh_shape) is the usual terrain hot spot —
	# it cooks a concave shape from every triangle. Trace it separately so we can
	# tell mesh build from collider cook when a tile hitches.
	FrameTracerScript.begin("terrain_trimesh_collider")
	var tri_shape: ConcavePolygonShape3D = mesh.create_trimesh_shape()
	tri_shape.backface_collision = true
	FrameTracerScript.end("terrain_trimesh_collider")

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
	# create_trimesh_shape() (cooked above, under a trace span) builds a ONE-SIDED
	# concave collider; bodies approaching from the back of the triangle winding
	# pass straight through. Terrain must be collidable from both sides (and our
	# triangle winding is not guaranteed to face up everywhere), so backface
	# collision was enabled on the cooked shape.
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

## Collect way IDs that are members of relations the relation builder will
## render AND that lack their own independent renderable feature tags. These
## ways get their semantics (building=*, landuse=*, etc.) from the parent
## relation, so the per-way handler loop should skip them — the relation
## builder renders them with the merged tag set.
##
## Ways that DO carry their own feature tags (e.g. a highway=* way reused as
## the outer ring of a landuse multipolygon) are NOT suppressed: they need
## independent rendering as roads/railways/etc.
func _collect_relation_way_ids(relations: Array, osm_data: OSMParser.OSMData) -> Dictionary:
	var ids := {}
	for rel: OSMParser.OSMRelation in relations:
		if not _relation_renders_ways(rel):
			continue
		for member: Dictionary in rel.members:
			if member["type"] != "way":
				continue
			var way_id: int = member["ref"]
			if not osm_data.ways.has(way_id):
				continue
			var way: OSMParser.OSMWay = osm_data.ways[way_id]
			# Only suppress the way if no handler would independently claim it
			# based on its own tags. If it has highway/railway/barrier/etc. tags,
			# it needs to be rendered both as that feature AND as part of the
			# relation (the relation builder handles the latter).
			if not _way_has_own_feature(way):
				ids[way_id] = true
	return ids

## True when the relation builder will produce geometry that includes member
## ways (multipolygon buildings/areas, type=building). Route, boundary, and
## other relation types are skipped by the builder and their member ways need
## independent handling.
static func _relation_renders_ways(rel: OSMParser.OSMRelation) -> bool:
	var rel_type: String = rel.tags.get("type", "")
	if rel_type == "building":
		return true
	if rel_type == "multipolygon":
		if rel.tags.has("building") or rel.tags.has("landuse") \
				or rel.tags.has("natural") or rel.tags.has("leisure"):
			return true
	return false

## True when a way's own tags contain a primary feature key that a handler
## would independently claim (highway, building, railway, waterway, barrier,
## landuse, natural, leisure, amenity, power). Ways with only styling tags
## (colour, roof:shape, etc.) return false — their meaning comes from a
## parent relation.
static func _way_has_own_feature(way: OSMParser.OSMWay) -> bool:
	return way.tags.has("highway") or way.tags.has("building") \
		or way.tags.has("building:part") or way.tags.has("railway") \
		or way.tags.has("waterway") or way.tags.has("barrier") \
		or way.tags.has("landuse") or way.tags.has("natural") \
		or way.tags.has("leisure") or way.tags.has("amenity") \
		or way.tags.has("power") or way.tags.has("man_made")

## True when a way carries a secondary feature key that a handler claims only on
## a CLOSED ring (tourism grounds, playground equipment, historic footprints,
## shop/area:highway rings, surface areas, transit platforms). These aren't in
## _way_has_own_feature (which lists always-claimed primary keys), but a closed
## ring keyed on one of them IS renderable ground, so the styling-only skip
## suppression must not swallow it.
static func _has_renderable_area_tag(way: OSMParser.OSMWay) -> bool:
	return way.tags.has("tourism") or way.tags.has("playground") \
		or way.tags.has("historic") or way.tags.has("shop") \
		or way.tags.has("area:highway") or way.tags.has("surface") \
		or way.tags.has("public_transport")

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
	# Ways carrying only styling/metadata tags (material, colour, source,
	# operator, website, ...) with no primary feature key of their own are
	# relation members that get their meaning from a parent relation; they have
	# no independently renderable geometry, so suppress their skip noise. Guarded
	# on _is_renderable_area_tag so a closed land-cover ring keyed only on
	# tourism/playground/historic/shop/... (which AreaHandler DOES claim) is not
	# swallowed here — those must still fall through to their handler.
	if not _way_has_own_feature(way) and not _has_renderable_area_tag(way):
		return true
	# Abstract structural outlines without their own renderable footprint.
	var man_made: String = way.tags.get("man_made", "")
	if man_made == "bridge" or man_made == "embankment":
		return true
	# Coastal flood-defence structures (breakwater/groyne): closed footprints
	# render as ground via AreaHandler. Open linear variants carry no fillable
	# surface, so suppress their expected skip noise.
	if (man_made == "breakwater" or man_made == "groyne") \
			and not OSMWayHandler.is_closed_way(way):
		return true
	# A dyke is a linear flood-defence embankment carrying no fillable surface
	# (rendered elsewhere as terrain relief, not as a way); suppress skip noise.
	if man_made == "dyke":
		return true
	# reinforced_slope / pier are only renderable as a closed ground ring
	# (AreaHandler claims those). Open linear variants carry no fillable surface,
	# so suppress their expected skip noise.
	if (man_made == "reinforced_slope" or man_made == "pier") \
			and not OSMWayHandler.is_closed_way(way):
		return true
	# Bus/transport station outlines are represented elsewhere (nodes/areas).
	if way.tags.get("public_transport", "") == "station":
		return true
	if way.tags.get("amenity", "") == "bus_station":
		return true
	# Street furniture mapped as an open way (bench, waste_basket, ...) is
	# point-like structure with no fillable surface; AreaHandler renders it only
	# when authored as a closed ground ring. Suppress the open-variant skip noise.
	if way.tags.get("amenity", "") == "bench" and not OSMWayHandler.is_closed_way(way):
		return true
	# Open (linear) transit platforms carry no fillable surface; PlatformHandler
	# claims only closed rings, so these expected skips are silenced here.
	if way.tags.get("public_transport", "") == "platform" \
			or way.tags.get("railway", "") == "platform" \
			or way.tags.get("highway", "") == "platform":
		return true
	# Playground equipment (climbingframe, swing, ...) is point-like structure.
	# AreaHandler renders it when authored as a closed ground ring; an open or
	# degenerate outline has no fillable surface, so suppress its skip noise.
	if way.tags.has("playground") and not OSMWayHandler.is_closed_way(way):
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
