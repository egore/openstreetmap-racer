class_name OSMTileContext
extends RefCounted

const RoadNetworkContextScript := preload("res://scripts/road_network_context.gd")

## Shared, per-tile state handed to every OSMWayHandler.build() call.
##
## The way-rendering dispatch used to be a central if-elif chain inside
## OSMTileManager, where each branch reached directly for the manager's private
## builders and tile parameters. Handlers now own their own matching + building
## logic (see osm_way_handler.gd), so this object bundles everything a handler
## might need into one argument instead of widening every build signature.
##
## One context is created per tile load and reused across all handlers for that
## tile. Handlers must treat it as read-only state about the tile being built.

## Parsed OSM dataset (nodes/ways/relations + height provider).
var osm_data: OSMParser.OSMData = null

## Tile coordinate currently being built.
var tile_key: Vector2i = Vector2i.ZERO

## Tile edge length in meters (mirrors OSMTileManager.tile_size).
var tile_size: float = 200.0

## True when a DEM height provider is loaded and ready, so handlers should drape
## geometry onto terrain instead of laying it flat.
var has_terrain: bool = false

## Grid spacing (meters) used when draping/subdividing against terrain. 0.0 when
## the world is flat.
var grid_step: float = 0.0

## [min_x, max_x, min_z, max_z] clip rectangle for this tile, used to trim
## draped area meshes to the tile bounds. null when the world is flat.
var tile_clip: Variant = null

## Building way IDs whose 3D outline must be skipped because a building:part
## footprint already covers them (computed in OSMTileManager's pre-pass).
var suppressed_building_ids: Dictionary = {}

## The solved road intersection layout for this tile (see RoadNetworkContext).
## Tells the way builder how far to pull each road back from the junctions it
## meets, so the intersection caps have room to fill the crossing. null when the
## tile has no roads, in which case ribbons are built full-length.
var road_network: RoadNetworkContextScript = null

# ─── Shared builders ─────────────────────────────────────────────────────────
# These are constructed once by OSMTileManager and shared across tiles. Handlers
# borrow them rather than each owning a builder, matching the previous behavior.
var way_builder: OSMWayBuilder = null
var infrastructure_builder: OSMInfrastructureBuilder = null
var building_builder: OSMBuildingBuilder = null
var asset_placer: OSMAssetPlacer = null


## Convenience: the height provider when terrain is ready, else null. Several
## PolygonUtils helpers accept a nullable provider to switch between draped and
## flat output, so this avoids repeating the has_terrain ternary in handlers.
func height_provider() -> HeightProvider:
	if has_terrain and osm_data != null:
		return osm_data.height_provider
	return null
