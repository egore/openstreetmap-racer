class_name WaterwayHandler
extends OSMWayHandler

## Linear water features (river, stream, ...) → blue ribbon (OSMWayBuilder).
##
## Underground waterways (culverts/tunnels/negative layer) are intentionally
## skipped so they do not paint blue across the surface.

func handler_name() -> String:
	return "waterway"


static func is_waterway(way: OSMParser.OSMWay) -> bool:
	if not way.tags.has("waterway"):
		return false
	if way.tags.get("tunnel", "") != "" or way.tags.has("culvert"):
		return false
	if way.tags.get("layer", "0").to_int() < 0:
		return false
	return true


func matches(way: OSMParser.OSMWay, _ctx: OSMTileContext) -> bool:
	return is_waterway(way)


func build(way: OSMParser.OSMWay, ctx: OSMTileContext) -> Node3D:
	return ctx.way_builder.build_waterway(way, ctx.osm_data)
