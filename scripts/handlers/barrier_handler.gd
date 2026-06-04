class_name BarrierHandler
extends OSMWayHandler

## barrier=* ways → linear barrier mesh (OSMAssetPlacer.place_way_asset).

func handler_name() -> String:
	return "barrier"


static func is_barrier_way(way: OSMParser.OSMWay) -> bool:
	return way.tags.has("barrier")


func matches(way: OSMParser.OSMWay, _ctx: OSMTileContext) -> bool:
	return is_barrier_way(way)


func build(way: OSMParser.OSMWay, ctx: OSMTileContext) -> Node3D:
	return ctx.asset_placer.place_way_asset(way, ctx.osm_data)
