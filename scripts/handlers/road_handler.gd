class_name RoadHandler
extends OSMWayHandler

## highway=* ways → miter-joined road ribbon with sidewalks (OSMWayBuilder).

func handler_name() -> String:
	return "road"


static func is_road(way: OSMParser.OSMWay) -> bool:
	if not way.tags.has("highway"):
		return false
	# highway=platform is a transit-platform area, not a road ribbon; let the
	# PlatformHandler claim it (registered later in the dispatch order).
	if way.tags.get("highway", "") == "platform":
		return false
	return true


func matches(way: OSMParser.OSMWay, _ctx: OSMTileContext) -> bool:
	return is_road(way)


func build(way: OSMParser.OSMWay, ctx: OSMTileContext) -> Node3D:
	var node := ctx.way_builder.build_road(way, ctx.osm_data)
	if node != null:
		# Tag the mesh so SurfaceDetector can find road surfaces quickly via
		# the scene-tree group instead of walking every tile child.
		node.add_to_group(&"road_surface")
	return node
