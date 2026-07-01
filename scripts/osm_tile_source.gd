class_name OSMTileSource
extends RefCounted

## Abstract source of per-tile OSM data for OSMTileManager.
##
## Historically OSMTileManager parsed one map.osm fully into RAM, built a global
## spatial index, and served every tile from it. That works for a few km but not
## for a whole country. This abstraction lets the manager stay identical while
## the *origin* of a tile's data varies:
##
##   InMemoryTileSource  parse-everything + spatial index (the classic path;
##                       preserves the small-map workflow and all its tests).
##   DiskTileSource      lazily read pre-baked, self-contained per-tile .osm
##                       files produced by tools/bake_osm_tiles.py, so a
##                       country streams from disk instead of loading whole.
##
## Contract for a "tile bucket" (what load_tile returns):
##   {
##     "osm_data": OSMParser.OSMData,   # self-contained: every node referenced
##                                      # by ways, every way referenced by
##                                      # relations, is present in its dicts.
##     "nodes":     Array,              # standalone tagged nodes in this tile
##     "ways":      Array,              # ways assigned to this tile
##     "relations": Array,              # relations assigned to this tile
##   }
## Builders resolve members through osm_data.nodes / osm_data.ways, so a tile
## bucket must be self-contained.

## True once the source is initialized and safe to query.
func is_ready() -> bool:
	return false

## Tile edge length in meters. The manager adopts this (esp. for DiskTileSource,
## where it comes from the baked manifest).
func get_tile_size() -> float:
	return 200.0

## Map-wide height provider (single DEM), or null when the world is flat. Shared
## across every tile so terrain queries stay global.
func get_height_provider() -> HeightProvider:
	return null

## Dataset center (degrees) used by the projection. Manager exposes it for spawn
## / debug logic.
func get_center_lat() -> float:
	return 0.0

func get_center_lon() -> float:
	return 0.0

## A representative dataset for consumers that want map-wide context (minimap,
## traffic seeding). For the in-memory source this is the full OSMData (every
## way is present). For the disk source it carries only center/bounds/height —
## its nodes/ways/relations dicts are empty because the whole country is never
## resident — so whole-map iterators must degrade gracefully.
func get_global_osm_data() -> OSMParser.OSMData:
	return null

## True if this tile has any content. Empty tiles are still "loaded" as empty
## placeholders by the manager so it doesn't retry them every frame.
func has_tile(_tile_key: Vector2i) -> bool:
	return false


## True when parse_tile would serve this tile from cache (no cold file parse).
## Used by collect_osm_near to decide when to yield between cold parses. The base
## reports false (sources without a file cache never cold-parse — InMemory returns
## references); DiskTileSource overrides to consult its LRU.
func _is_cached(_tile_key: Vector2i) -> bool:
	return false

## Return the self-contained tile bucket (see contract above) for a tile key, or
## null when the tile is empty / unknown.
##
## May touch shared mutable state (the disk source's LRU cache), so this is the
## MAIN-THREAD entry point. Off-thread streaming must use parse_tile() instead.
func load_tile(_tile_key: Vector2i) -> Dictionary:
	return {}


## Thread-safe variant of load_tile: produce a tile bucket WITHOUT touching any
## shared mutable state (no LRU cache). Safe to call from a WorkerThreadPool task
## because it only reads immutable manifest/index data and returns freshly parsed
## objects. Returns {} for empty / unknown tiles.
##
## The default just forwards to load_tile: sources whose load_tile is already
## side-effect-free (InMemoryTileSource) need no separate implementation. Sources
## that cache (DiskTileSource) override this to bypass the cache.
func parse_tile(tile_key: Vector2i) -> Dictionary:
	return load_tile(tile_key)


## Tile key for a world XZ position. Shared with OSMTileManager._pos_to_tile so
## the manager, the baker, and any consumer agree on the tile grid.
func pos_to_tile(pos: Vector3) -> Vector2i:
	var ts := get_tile_size()
	return Vector2i(floori(pos.x / ts), floori(pos.z / ts))


## Collect every way whose geometry falls within `radius` meters of `center`,
## as an array of { "way": OSMParser.OSMWay, "points": PackedVector3Array }.
##
## This is the shared query behind both the 3D world (tile-by-tile streaming)
## and the minimap: it walks the tiles overlapping the query square, loads each
## via the same load_tile() path the manager uses (so disk tiles stream + LRU
## cache exactly once), resolves way node positions against each tile's
## self-contained OSMData, and de-duplicates ways that span multiple tiles.
##
## Works uniformly for InMemoryTileSource and DiskTileSource because it only
## relies on the has_tile/parse_tile contract. Returns [] before the source is
## ready.
##
## THREAD-SAFE: uses parse_tile, whose cache is mutex-guarded, so callers may run
## this off the main thread (e.g. the traffic graph rebuild) without racing the
## main-thread streamer. Tiles it parses are cached and shared with streaming, so
## overlapping regions across successive rebuilds don't re-read the same files.
func collect_ways_near(center: Vector3, radius: float) -> Array:
	var out: Array = []
	if not is_ready():
		return out

	var ts := get_tile_size()
	# A way is bucketed into every tile its nodes touch, so scanning the tiles
	# overlapping the query square (plus a one-tile margin for ways whose far
	# node reaches in) is sufficient to find every way in range.
	var min_tile := Vector2i(
		floori((center.x - radius) / ts) - 1,
		floori((center.z - radius) / ts) - 1)
	var max_tile := Vector2i(
		floori((center.x + radius) / ts) + 1,
		floori((center.z + radius) / ts) + 1)

	var seen_ways: Dictionary = {}   # way id -> true (dedupe across tiles)
	var r_sq := radius * radius
	for tx: int in range(min_tile.x, max_tile.x + 1):
		for tz: int in range(min_tile.y, max_tile.y + 1):
			var tkey := Vector2i(tx, tz)
			if not has_tile(tkey):
				continue
			var bucket := parse_tile(tkey)
			if bucket.is_empty():
				continue
			var osm_data: OSMParser.OSMData = bucket["osm_data"]
			for way: OSMParser.OSMWay in bucket["ways"]:
				if seen_ways.has(way.id):
					continue
				var points := _way_points(way, osm_data)
				if points.is_empty():
					continue
				if not _points_within(points, center, r_sq):
					continue
				seen_ways[way.id] = true
				out.append({"way": way, "points": points})
	return out


## Assemble a self-contained OSMData holding every way within `radius` of
## `center` plus all the nodes those ways reference. Center/height_provider are
## copied from this source so downstream consumers keep the shared coordinate
## frame and terrain.
##
## This is the shape the traffic road network needs: it builds a junction graph
## by matching shared node ids across ways, so it needs the ways AND their nodes
## (not just resolved polylines). Backed by the same tile-walking as
## collect_ways_near, so the traffic graph around the player stays consistent
## with the world and streams a country tile-by-tile instead of loading it whole.
##
## THREAD-SAFE (uses the mutex-guarded parse_tile cache): the traffic manager runs
## this on a WorkerThreadPool task to keep the graph rebuild off the physics
## thread, and the tiles it parses are cached and shared with streaming.
## `yield_every` > 0 makes the collect yield the OS scheduler (delay 0 ms) after
## every that-many COLD tile parses. When this runs on the traffic rebuild thread,
## a fresh region cold-parses dozens of tiles back-to-back — a solid burst of
## allocation that contends with the main thread's per-frame work (GDScript shares
## an allocator/refcounting), which is felt as a stutter even though the work is
## off-thread. Yielding periodically breaks the burst so the main thread gets
## scheduler + allocator breathing room. 0 disables it (cached/warm collects and
## the main-thread minimap path stay tight).
func collect_osm_near(center: Vector3, radius: float, yield_every: int = 0) -> OSMParser.OSMData:
	var data := OSMParser.OSMData.new()
	data.center_lat = get_center_lat()
	data.center_lon = get_center_lon()
	data.height_provider = get_height_provider()
	if not is_ready():
		return data

	var ts := get_tile_size()
	var min_tile := Vector2i(
		floori((center.x - radius) / ts) - 1,
		floori((center.z - radius) / ts) - 1)
	var max_tile := Vector2i(
		floori((center.x + radius) / ts) + 1,
		floori((center.z + radius) / ts) + 1)

	var r_sq := radius * radius
	var cold_parses := 0
	for tx: int in range(min_tile.x, max_tile.x + 1):
		for tz: int in range(min_tile.y, max_tile.y + 1):
			var tkey := Vector2i(tx, tz)
			if not has_tile(tkey):
				continue
			# Yield between cold parses so a fresh region's parse burst doesn't
			# monopolize the shared allocator against the main thread.
			var was_cached := _is_cached(tkey)
			var bucket := parse_tile(tkey)
			if bucket.is_empty():
				continue
			if yield_every > 0 and not was_cached:
				cold_parses += 1
				if cold_parses % yield_every == 0:
					OS.delay_msec(0)  # yield scheduler; near-zero wall time
			var src: OSMParser.OSMData = bucket["osm_data"]
			for way: OSMParser.OSMWay in bucket["ways"]:
				if data.ways.has(way.id):
					continue
				var points := _way_points(way, src)
				if points.is_empty() or not _points_within(points, center, r_sq):
					continue
				data.ways[way.id] = way
				# Pull the way's nodes into the assembled set so the graph builder
				# can resolve every endpoint (self-contained, like a tile file).
				for nid: int in way.node_ids:
					if src.nodes.has(nid) and not data.nodes.has(nid):
						data.nodes[nid] = src.nodes[nid]
	return data


## Resolve a way's node ids to their local positions using the given (possibly
## per-tile, self-contained) dataset. Missing nodes are skipped.
static func _way_points(way: OSMParser.OSMWay, osm_data: OSMParser.OSMData) -> PackedVector3Array:
	var pts := PackedVector3Array()
	for nid: int in way.node_ids:
		if osm_data.nodes.has(nid):
			pts.append((osm_data.nodes[nid] as OSMParser.OSMNode).local_pos)
	return pts


static func _points_within(points: PackedVector3Array, center: Vector3, r_sq: float) -> bool:
	for p: Vector3 in points:
		var dx := p.x - center.x
		var dz := p.z - center.z
		if dx * dx + dz * dz < r_sq:
			return true
	return false


# ══════════════════════════════════════════════════════════════════════════════
# InMemoryTileSource — classic parse-everything path
# ══════════════════════════════════════════════════════════════════════════════

class InMemoryTileSource extends OSMTileSource:
	var _osm_data: OSMParser.OSMData = null
	var _spatial_index: Dictionary = {}  # Vector2i -> {nodes, ways, relations}
	var _tile_size: float = 200.0
	var _ready: bool = false

	func _init(osm_file_path: String, tile_size: float) -> void:
		_tile_size = tile_size
		_osm_data = OSMParser.parse_file(osm_file_path)
		if _osm_data == null:
			push_error("InMemoryTileSource: failed to parse %s" % osm_file_path)
			return
		_build_spatial_index()
		_ready = true

	func is_ready() -> bool:
		return _ready

	func get_tile_size() -> float:
		return _tile_size

	func get_height_provider() -> HeightProvider:
		return _osm_data.height_provider if _osm_data != null else null

	func get_center_lat() -> float:
		return _osm_data.center_lat if _osm_data != null else 0.0

	func get_center_lon() -> float:
		return _osm_data.center_lon if _osm_data != null else 0.0

	func get_global_osm_data() -> OSMParser.OSMData:
		return _osm_data

	func has_tile(tile_key: Vector2i) -> bool:
		return _spatial_index.has(tile_key)

	## In-memory tiles never cold-parse (load_tile returns references into the one
	## resident OSMData), so they're always "cached" — collect never needs to yield.
	func _is_cached(_tile_key: Vector2i) -> bool:
		return true

	## In-memory tiles share the one global OSMData for reference resolution —
	## that's exactly the pre-refactor behavior, so builders see identical data.
	func load_tile(tile_key: Vector2i) -> Dictionary:
		if not _spatial_index.has(tile_key):
			return {}
		var bucket: Dictionary = _spatial_index[tile_key]
		return {
			"osm_data": _osm_data,
			"nodes": bucket["nodes"],
			"ways": bucket["ways"],
			"relations": bucket["relations"],
		}

	func _pos_to_tile(pos: Vector3) -> Vector2i:
		return Vector2i(floori(pos.x / _tile_size), floori(pos.z / _tile_size))

	func _ensure_bucket(tkey: Vector2i) -> void:
		if not _spatial_index.has(tkey):
			_spatial_index[tkey] = {"nodes": [], "ways": [], "relations": []}

	## Bin nodes/ways/relations into tiles. Preserved verbatim from the manager's
	## former _build_spatial_index so the split changes structure, not behavior.
	func _build_spatial_index() -> void:
		_spatial_index.clear()

		for node: OSMParser.OSMNode in _osm_data.nodes.values():
			if node.tags.size() > 0:
				var tkey := _pos_to_tile(node.local_pos)
				_ensure_bucket(tkey)
				_spatial_index[tkey]["nodes"].append(node)

		for way: OSMParser.OSMWay in _osm_data.ways.values():
			var tiles_touched := {}
			for nid: int in way.node_ids:
				if _osm_data.nodes.has(nid):
					var node: OSMParser.OSMNode = _osm_data.nodes[nid]
					tiles_touched[_pos_to_tile(node.local_pos)] = true
			for tkey: Vector2i in tiles_touched:
				_ensure_bucket(tkey)
				_spatial_index[tkey]["ways"].append(way)

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
								tiles_touched[_pos_to_tile(node.local_pos)] = true
				elif member["type"] == "node":
					var ref_id: int = member["ref"]
					if _osm_data.nodes.has(ref_id):
						var node: OSMParser.OSMNode = _osm_data.nodes[ref_id]
						tiles_touched[_pos_to_tile(node.local_pos)] = true
			for tkey: Vector2i in tiles_touched:
				_ensure_bucket(tkey)
				_spatial_index[tkey]["relations"].append(rel)


# ══════════════════════════════════════════════════════════════════════════════
# DiskTileSource — stream self-contained per-tile .osm files from data/tiles/
# ══════════════════════════════════════════════════════════════════════════════

class DiskTileSource extends OSMTileSource:
	## Manifest layout version this source understands (see bake_osm_tiles.py).
	const SUPPORTED_VERSION := 1
	## How many parsed tiles to keep cached before evicting the oldest. Streaming
	## re-visits tiles as the camera drifts, and the traffic graph rebuild collects
	## a whole region of tiles at once, so a generous LRU avoids re-parsing the same
	## file repeatedly without holding the whole country in RAM. The traffic
	## build_radius (~600 m) over a 200 m grid touches ~49 tiles, so the cache must
	## comfortably hold a rebuild's working set AND the streaming ring around it.
	const CACHE_CAPACITY := 128

	var _dir: String = ""
	var _tile_size: float = 200.0
	var _center_lat: float = 0.0
	var _center_lon: float = 0.0
	var _tile_files: Dictionary = {}   # Vector2i -> filename
	var _height_provider: HeightProvider = null
	var _ready: bool = false

	# Thread-safe LRU parse cache. Both the main-thread streaming (load_tile) and
	# the worker-thread region collect (parse_tile, via collect_osm_near) read and
	# write it, so every access is guarded by _cache_mutex. Sharing one cache is
	# the whole point: a tile parsed for the traffic rebuild is then free for the
	# streamer, and vice versa, instead of each path re-parsing the same file.
	# _cache maps tile_key -> bucket; _lru is oldest..newest keys.
	var _cache: Dictionary = {}
	var _lru: Array[Vector2i] = []
	var _cache_mutex := Mutex.new()

	func _init(tiles_dir: String) -> void:
		_dir = tiles_dir.trim_suffix("/")
		if not _load_manifest():
			return
		# One map-wide DEM for now (per-tile DEM is a deferred follow-up). Loaded
		# from the manifest center so its projection matches the baked tiles.
		_height_provider = HeightProvider.new()
		if not _height_provider.load_from_files(_center_lat, _center_lon):
			_height_provider = null
		_ready = true

	func is_ready() -> bool:
		return _ready

	func get_tile_size() -> float:
		return _tile_size

	func get_height_provider() -> HeightProvider:
		return _height_provider

	func get_center_lat() -> float:
		return _center_lat

	func get_center_lon() -> float:
		return _center_lon

	## No country-scale global dataset exists in RAM; hand back a stub carrying
	## just the shared center + height provider. Whole-map consumers (minimap)
	## see empty node/way dicts and must no-op rather than crash.
	func get_global_osm_data() -> OSMParser.OSMData:
		var data := OSMParser.OSMData.new()
		data.center_lat = _center_lat
		data.center_lon = _center_lon
		data.height_provider = _height_provider
		return data

	func has_tile(tile_key: Vector2i) -> bool:
		return _tile_files.has(tile_key)

	## Thread-safe LRU membership check (mutex-guarded) so collect_osm_near can
	## tell a cheap cache hit from a cold file parse and only yield on the latter.
	func _is_cached(tile_key: Vector2i) -> bool:
		_cache_mutex.lock()
		var present := _cache.has(tile_key)
		_cache_mutex.unlock()
		return present

	## Main-thread streaming entry point. Now identical to parse_tile: both go
	## through the shared, mutex-guarded cache, so a tile parsed by either path is
	## reused by the other. Kept as a distinct name for call-site clarity.
	func load_tile(tile_key: Vector2i) -> Dictionary:
		return parse_tile(tile_key)

	## Thread-safe tile fetch: returns a cached bucket if present, else parses the
	## file once and caches it. Safe to call from a WorkerThreadPool task (the
	## traffic rebuild's collect_osm_near) concurrently with main-thread streaming
	## because the cache is guarded by _cache_mutex and the (slow) file parse
	## happens OUTSIDE the lock so it doesn't serialize the two threads.
	func parse_tile(tile_key: Vector2i) -> Dictionary:
		if not _tile_files.has(tile_key):
			return {}

		# Fast path: hit the shared cache under the lock.
		_cache_mutex.lock()
		if _cache.has(tile_key):
			_touch_locked(tile_key)
			var hit: Dictionary = _cache[tile_key]
			_cache_mutex.unlock()
			return hit
		_cache_mutex.unlock()

		# Miss: parse the file WITHOUT holding the lock (disk I/O + XML parse is
		# the slow part; serializing it across threads would defeat the point).
		var bucket := _parse_tile_uncached(tile_key)

		# Publish to the cache. A concurrent caller may have parsed the same tile
		# meanwhile; if so, prefer the already-cached bucket so both callers share
		# one object (harmless either way — buckets are immutable once built).
		_cache_mutex.lock()
		if _cache.has(tile_key):
			_touch_locked(tile_key)
			bucket = _cache[tile_key]
		elif not bucket.is_empty():
			_insert_locked(tile_key, bucket)
		_cache_mutex.unlock()
		return bucket

	## Parse one tile file into a bucket, with no caching. Pure/read-only against
	## shared state (immutable manifest + read-only height sampling), so it's safe
	## to run on any thread.
	func _parse_tile_uncached(tile_key: Vector2i) -> Dictionary:
		var path := "%s/%s" % [_dir, _tile_files[tile_key]]
		# Per-tile files are pre-projected data; elevation comes from the shared
		# provider (apply_elevation=false avoids each tile re-loading a DEM).
		var data := OSMParser.parse_file(path, false)
		data.height_provider = _height_provider
		# Lift nodes onto the shared terrain so streamed tiles sit on the ground.
		if _height_provider != null and _height_provider.is_ready():
			for node: OSMParser.OSMNode in data.nodes.values():
				node.local_pos.y = _height_provider.sample_latlon(node.lat, node.lon)

		return _bucket_from_data(data, tile_key)

	## Split a parsed tile OSMData into the node/way/relation arrays the manager
	## iterates, applying the same "which tile does this belong to" rule the
	## baker used so a self-contained file (which also holds neighbor nodes for
	## closure) only surfaces the features actually assigned here.
	func _bucket_from_data(data: OSMParser.OSMData, tile_key: Vector2i) -> Dictionary:
		var nodes: Array = []
		var ways: Array = []
		var relations: Array = []

		for node: OSMParser.OSMNode in data.nodes.values():
			if node.tags.size() > 0 and _pos_to_tile(node.local_pos) == tile_key:
				nodes.append(node)

		for way: OSMParser.OSMWay in data.ways.values():
			for nid: int in way.node_ids:
				if data.nodes.has(nid) \
						and _pos_to_tile((data.nodes[nid] as OSMParser.OSMNode).local_pos) == tile_key:
					ways.append(way)
					break

		for rel: OSMParser.OSMRelation in data.relations.values():
			if _relation_touches_tile(rel, data, tile_key):
				relations.append(rel)

		return {
			"osm_data": data,
			"nodes": nodes,
			"ways": ways,
			"relations": relations,
		}

	func _relation_touches_tile(
			rel: OSMParser.OSMRelation, data: OSMParser.OSMData, tile_key: Vector2i) -> bool:
		for member: Dictionary in rel.members:
			if member["type"] == "way" and data.ways.has(member["ref"]):
				var w: OSMParser.OSMWay = data.ways[member["ref"]]
				for nid: int in w.node_ids:
					if data.nodes.has(nid) \
							and _pos_to_tile((data.nodes[nid] as OSMParser.OSMNode).local_pos) == tile_key:
						return true
			elif member["type"] == "node" and data.nodes.has(member["ref"]):
				if _pos_to_tile((data.nodes[member["ref"]] as OSMParser.OSMNode).local_pos) == tile_key:
					return true
		return false

	func _pos_to_tile(pos: Vector3) -> Vector2i:
		return Vector2i(floori(pos.x / _tile_size), floori(pos.z / _tile_size))

	func _load_manifest() -> bool:
		var path := "%s/manifest.json" % _dir
		if not FileAccess.file_exists(path):
			return false
		var text := FileAccess.get_file_as_string(path)
		var parsed: Variant = JSON.parse_string(text)
		if typeof(parsed) != TYPE_DICTIONARY:
			push_error("DiskTileSource: malformed manifest at %s" % path)
			return false
		var m: Dictionary = parsed
		var version := int(m.get("version", 0))
		if version != SUPPORTED_VERSION:
			push_error("DiskTileSource: manifest version %d unsupported (expected %d); re-run bake_osm_tiles.py" % [version, SUPPORTED_VERSION])
			return false
		_tile_size = float(m.get("tile_size", 200.0))
		_center_lat = float(m.get("center_lat", 0.0))
		_center_lon = float(m.get("center_lon", 0.0))
		for entry: Dictionary in m.get("tiles", []):
			var tkey := Vector2i(int(entry["x"]), int(entry["z"]))
			_tile_files[tkey] = String(entry["file"])
		return true

	# ─── LRU cache (callers MUST hold _cache_mutex) ──────────────────────────
	func _insert_locked(tkey: Vector2i, bucket: Dictionary) -> void:
		_cache[tkey] = bucket
		_lru.append(tkey)
		while _lru.size() > CACHE_CAPACITY:
			var evict: Vector2i = _lru.pop_front()
			# Only drop it if a later _touch didn't already re-append this key.
			if not _lru.has(evict):
				_cache.erase(evict)

	func _touch_locked(tkey: Vector2i) -> void:
		_lru.erase(tkey)
		_lru.append(tkey)
