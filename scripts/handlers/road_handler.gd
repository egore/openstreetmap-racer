class_name RoadHandler
extends OSMWayHandler

## highway=* ways → miter-joined road ribbon with sidewalks (OSMWayBuilder).

func handler_name() -> String:
	return "road"


static func is_road(way: OSMParser.OSMWay) -> bool:
	return way.tags.has("highway")


func matches(way: OSMParser.OSMWay, _ctx: OSMTileContext) -> bool:
	return is_road(way)


func build(way: OSMParser.OSMWay, ctx: OSMTileContext) -> Node3D:
	return ctx.way_builder.build_road(way, ctx.osm_data)
