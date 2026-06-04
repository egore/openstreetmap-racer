class_name AreaHandler
extends OSMWayHandler

## Closed land-cover rings (landuse/natural/leisure, plus closed amenity/shop/
## power/area:highway and selected man_made footprints) → flat colored ground,
## with scrub and forest getting scattered vegetation (PolygonUtils).
##
## Registered LAST among the way handlers so more specific features (power
## lines, gantries, parking, ...) claim their closed rings first.

## Closed man_made values that describe a ground footprint (treatment plants,
## works, reservoirs, ...) rather than a point structure or linear feature.
const _MAN_MADE_AREA_VALUES := {
	"wastewater_plant": true, "water_works": true, "works": true,
	"reservoir_covered": true, "storage_tank": true, "wastewater": true,
}


func handler_name() -> String:
	return "area"


static func is_area(way: OSMParser.OSMWay) -> bool:
	if way.tags.has("landuse") or way.tags.has("natural") or way.tags.has("leisure"):
		return true
	# Closed amenity/shop/power/area:highway/man_made rings render as flat
	# colored ground.
	if not OSMWayHandler.is_closed_way(way):
		return false
	if _MAN_MADE_AREA_VALUES.has(way.tags.get("man_made", "")):
		return true
	return way.tags.has("amenity") or way.tags.has("shop") \
		or way.tags.has("power") or way.tags.has("area:highway")


func matches(way: OSMParser.OSMWay, _ctx: OSMTileContext) -> bool:
	return is_area(way)


func build(way: OSMParser.OSMWay, ctx: OSMTileContext) -> Node3D:
	if PolygonUtils.is_scrub(way.tags):
		return _build_scrub(way, ctx)
	if PolygonUtils.is_forest(way.tags):
		return _build_forest(way, ctx)
	return _build_area(way, ctx)


func _build_scrub(way: OSMParser.OSMWay, ctx: OSMTileContext) -> Node3D:
	var points := PolygonUtils.way_to_points(way.node_ids, ctx.osm_data.nodes)
	var node := PolygonUtils.build_scrub_area(
		points, ctx.height_provider(), ctx.grid_step, 0.01, ctx.tile_clip)
	if node != null:
		node.name = "Scrub_%d" % way.id
	return node


func _build_forest(way: OSMParser.OSMWay, ctx: OSMTileContext) -> Node3D:
	var points := PolygonUtils.way_to_points(way.node_ids, ctx.osm_data.nodes)
	var node := PolygonUtils.build_forest_area(
		points, ctx.height_provider(), ctx.grid_step, 0.01, ctx.tile_clip)
	if node != null:
		node.name = "Forest_%d" % way.id
	return node


func _build_area(way: OSMParser.OSMWay, ctx: OSMTileContext) -> MeshInstance3D:
	var points := PolygonUtils.way_to_points(way.node_ids, ctx.osm_data.nodes)
	var color := PolygonUtils.get_area_color(way.tags)
	var mesh_instance: MeshInstance3D
	if ctx.has_terrain:
		mesh_instance = PolygonUtils.build_terrain_draped_mesh(
			points, color, ctx.osm_data.height_provider, ctx.grid_step, 0.01, ctx.tile_clip)
	else:
		mesh_instance = PolygonUtils.build_flat_polygon_mesh(points, color, 0.01, true)
	if mesh_instance != null:
		mesh_instance.name = "Area_%d" % way.id
	return mesh_instance
