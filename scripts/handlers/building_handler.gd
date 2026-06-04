class_name BuildingHandler
extends OSMWayHandler

## building=* ways → extruded walls + roof (OSMBuildingBuilder).
##
## When a building:part footprint already covers this outline, the manager's
## pre-pass records the way id in ctx.suppressed_building_ids and the 3D outline
## is skipped here (the parts render the detailed massing instead).
##
## Note: building:part ways themselves are rendered by OSMTileManager in a
## dedicated second pass, not through this handler, because they must bypass the
## suppression test.

func handler_name() -> String:
	return "building"


static func is_building(way: OSMParser.OSMWay) -> bool:
	return way.tags.has("building")


func matches(way: OSMParser.OSMWay, _ctx: OSMTileContext) -> bool:
	return is_building(way)


func build(way: OSMParser.OSMWay, ctx: OSMTileContext) -> Node3D:
	if ctx.suppressed_building_ids.has(way.id):
		return null
	return ctx.building_builder.build_building_from_way(way, ctx.osm_data)
