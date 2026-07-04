class_name PlatformHandler
extends OSMWayHandler

## Public-transport platforms — the raised surfaces where passengers wait for a
## bus, tram, or train. Tagged public_transport=platform (the modern schema) or
## the older railway=platform / highway=platform. These are physical ground
## features, but they are excluded by every existing handler:
##   - RailwayHandler whitelists only track values, so railway=platform slips by.
##   - AreaHandler only claims closed amenity/shop/power/... rings.
##   - SurfaceHandler bails when no `surface` tag is present.
## so a bare platform ring (e.g. {public_transport: platform, bench: no,
## shelter: no}) was reaching OSMTileManager unmatched and logging a skip.
##
## A closed platform ring renders as a flat colored polygon sitting slightly
## proud of the surrounding ground, matching the paved concrete surface a real
## platform presents. Registered before AreaHandler so a platform that also
## carries an amenity/area tag is still styled as a platform.

## Platforms read as light paved concrete unless the way names a surface we know.
const PLATFORM_COLOR := Color(0.62, 0.62, 0.60)

## Raised a touch more than a plain surface (0.012) so the platform edge reads as
## a kerb rather than melting into the road/ballast beside it.
const PLATFORM_Y_OFFSET := 0.05


func handler_name() -> String:
	return "platform"


## True for a closed ring tagged as a transit platform under any of the three
## accepted schemas. Open (linear) platform ways carry no surface to fill, so
## they fall through — the manager's _is_ignorable_way suppresses their noise.
static func is_platform(way: OSMParser.OSMWay) -> bool:
	if not OSMWayHandler.is_closed_way(way):
		return false
	if way.tags.get("public_transport", "") == "platform":
		return true
	if way.tags.get("railway", "") == "platform":
		return true
	if way.tags.get("highway", "") == "platform":
		return true
	return false


func matches(way: OSMParser.OSMWay, _ctx: OSMTileContext) -> bool:
	return is_platform(way)


func build(way: OSMParser.OSMWay, ctx: OSMTileContext) -> Node3D:
	var points := PolygonUtils.way_to_points(way.node_ids, ctx.osm_data.nodes)
	# Honor an explicit surface tag when one is present (many platforms are
	# paving_stones or asphalt); otherwise fall back to plain concrete.
	var surface_val: String = way.tags.get("surface", "")
	var color: Color = SurfaceHandler.SURFACE_COLORS.get(surface_val, PLATFORM_COLOR)
	# Platforms sit at the top of the ground stack (highest y-offset, above any
	# surface/landcover they overlay). Depth-write is dropped downstream so the
	# platform deck never z-fights the plaza/surface it rests on.
	var priority := PolygonUtils.PLATFORM_GROUND_PRIORITY + roundi(
		PolygonUtils.ground_tiebreak_bonus(PolygonUtils.polygon_area_xz(points)))
	var mesh_instance: MeshInstance3D
	if ctx.has_terrain:
		mesh_instance = PolygonUtils.build_terrain_draped_mesh(
			points, color, ctx.osm_data.height_provider, ctx.grid_step,
			PLATFORM_Y_OFFSET, ctx.tile_clip, priority)
	else:
		mesh_instance = PolygonUtils.build_flat_polygon_mesh(
			points, color, PLATFORM_Y_OFFSET, true, priority)
	if mesh_instance != null:
		mesh_instance.name = "Platform_%d" % way.id
	return mesh_instance
